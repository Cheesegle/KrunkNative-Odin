package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import curl "vendor:curl"
import kproto "../krunker"

// The live Krunker WebSocket runs on its own thread. It owns the curl handle
// after the upgrade and does every send, receive and frame reassembly, so a
// slow socket, TLS work inside curl or a burst after a ping spike can never
// stall the frame loop. The frame thread decodes and applies messages, in
// arrival order, and keeps all game state; it only exchanges byte buffers
// with this thread through two queues.

Krunker_WS_Event_Kind :: enum u8 {
	MESSAGE, // payload is one complete binary message
	CLOSED,  // the server closed the socket; payload is the close reason
	FAILED,  // a send, receive or frame error; text says what failed
}

Krunker_WS_Event :: struct {
	kind: Krunker_WS_Event_Kind,
	payload: []byte,
	close_code: int, // -1 when the close frame had no status
	text: string,
}

Krunker_WS_Outbound :: struct {
	bytes: []byte,
	opcode: string, // a string literal, for diagnostics
	input: bool,
}

Krunker_WS_Transport :: struct {
	handle: ^curl.CURL,
	// Both threads allocate and free the queued buffers with this allocator.
	allocator: runtime.Allocator,
	mutex: sync.Mutex,
	outbox: [dynamic]Krunker_WS_Outbound,
	inbox: [dynamic]Krunker_WS_Event,
	queued_inputs: int, // q packets not yet completely sent
	stop: bool,
	ended: bool, // the thread queued CLOSED or FAILED and does no more I/O
	thread: ^thread.Thread,
	wait: Krunker_WS_Wait,
	error_buffer: ^[curl.ERROR_SIZE]byte,
	// Owned by the transport thread.
	message: kproto.Krunker_WS_Message,
	buffer: [4096]byte,
	frames: int,
	send_blocked: bool,
}

// Frames received per pass before the thread checks its outbox again.
KRUNKER_WS_RECV_PASS :: 64
// Upper bound on a wait; socket and wake events normally end it sooner.
KRUNKER_WS_IDLE_WAIT_MS :: 10
KRUNKER_WS_BLOCKED_WAIT_MS :: 2
// Received messages the frame thread has not taken yet. Beyond this the
// thread stops reading until it does, as an idle socket did before: memory
// stays bounded when the frame loop stalls or stops polling after an error.
KRUNKER_WS_INBOX_LIMIT :: 4096

// Takes ownership of handle. The thread does not run until started.
krunker_ws_transport_create :: proc(handle: ^curl.CURL, error_buffer: ^[curl.ERROR_SIZE]byte) -> ^Krunker_WS_Transport {
	transport := new(Krunker_WS_Transport)
	transport.handle = handle
	transport.allocator = context.allocator
	transport.error_buffer = error_buffer
	transport.outbox.allocator = context.allocator
	transport.inbox.allocator = context.allocator
	transport.message.buffer.allocator = context.allocator
	return transport
}

krunker_ws_transport_start :: proc(transport: ^Krunker_WS_Transport) -> bool {
	if !krunker_ws_wait_init(&transport.wait, transport.handle) { return false }
	transport.thread = thread.create(krunker_ws_transport_run)
	if transport.thread == nil { return false }
	transport.thread.data = transport
	transport.thread.init_context = context
	thread.start(transport.thread)
	return true
}

// Stops and joins the thread, then releases the curl handle and every
// queued buffer. Safe at any point, including in the middle of a burst.
krunker_ws_transport_destroy :: proc(transport: ^Krunker_WS_Transport) {
	if transport == nil do return
	sync.mutex_lock(&transport.mutex)
	transport.stop = true
	sync.mutex_unlock(&transport.mutex)
	krunker_ws_wait_wake(&transport.wait)
	if transport.thread != nil {
		thread.join(transport.thread)
		thread.destroy(transport.thread)
	}
	krunker_ws_wait_fini(&transport.wait)
	if transport.handle != nil { curl.easy_cleanup(transport.handle) }
	for item in transport.outbox { delete(item.bytes, transport.allocator) }
	delete(transport.outbox)
	krunker_ws_events_free(transport.inbox[:], transport.allocator)
	delete(transport.inbox)
	delete(transport.message.buffer)
	free(transport, transport.allocator)
}

krunker_ws_events_free :: proc(events: []Krunker_WS_Event, allocator: runtime.Allocator) {
	for event in events {
		delete(event.payload, allocator)
		delete(event.text, allocator)
	}
}

// Queues one packet behind everything queued before it; the thread sends
// them strictly in this order and retries E_AGAIN with the same bytes, so the
// counter in each trailer is final when the packet is queued. Takes ownership
// of bytes, which must come from the transport allocator. Returns false once
// the connection has ended.
krunker_ws_transport_send :: proc(transport: ^Krunker_WS_Transport, bytes: []byte, opcode: string, input := false) -> bool {
	sync.mutex_lock(&transport.mutex)
	if transport.ended || transport.stop {
		sync.mutex_unlock(&transport.mutex)
		delete(bytes, transport.allocator)
		return false
	}
	append(&transport.outbox, Krunker_WS_Outbound{bytes, opcode, input})
	if input { transport.queued_inputs += 1 }
	sync.mutex_unlock(&transport.mutex)
	krunker_ws_wait_wake(&transport.wait)
	return true
}

// q packets still waiting for the socket.
krunker_ws_transport_input_backlog :: proc(transport: ^Krunker_WS_Transport) -> int {
	sync.mutex_lock(&transport.mutex)
	defer sync.mutex_unlock(&transport.mutex)
	return transport.queued_inputs
}

// Moves every received event, oldest first, to the end of out.
krunker_ws_transport_receive :: proc(transport: ^Krunker_WS_Transport, out: ^[dynamic]Krunker_WS_Event) {
	sync.mutex_lock(&transport.mutex)
	defer sync.mutex_unlock(&transport.mutex)
	append(out, ..transport.inbox[:])
	clear(&transport.inbox)
}

@(private = "file")
krunker_ws_transport_push :: proc(transport: ^Krunker_WS_Transport, event: Krunker_WS_Event) {
	sync.mutex_lock(&transport.mutex)
	defer sync.mutex_unlock(&transport.mutex)
	append(&transport.inbox, event)
	if event.kind != .MESSAGE { transport.ended = true }
}

@(private = "file")
krunker_ws_transport_fail :: proc(transport: ^Krunker_WS_Transport, text: string) {
	kproto.network_log("ws-thread", text)
	krunker_ws_transport_push(transport, {kind = .FAILED, text = strings.clone(text, transport.allocator)})
}

@(private = "file")
krunker_ws_transport_detail :: proc(transport: ^Krunker_WS_Transport) -> string {
	if transport.error_buffer == nil do return ""
	return string(cast(cstring)&transport.error_buffer[0])
}

// Sends queued packets in order until the socket would block. Returns false
// after a send error, which ends the connection.
@(private = "file")
krunker_ws_transport_flush :: proc(transport: ^Krunker_WS_Transport) -> (progressed, ok: bool) {
	for {
		sync.mutex_lock(&transport.mutex)
		if len(transport.outbox) == 0 {
			sync.mutex_unlock(&transport.mutex)
			return progressed, true
		}
		item := transport.outbox[0]
		pending := len(transport.outbox)
		sync.mutex_unlock(&transport.mutex)
		sent: c.size_t
		code := curl.ws_send(transport.handle, raw_data(item.bytes), c.size_t(len(item.bytes)), &sent, 0, curl.WS_BINARY)
		if code == .E_AGAIN && sent == 0 {
			// Nothing was taken: retry these exact bytes, counter included.
			if !transport.send_blocked { kproto.network_log("ws-send", fmt.tprintf("would block; opcode=%s queued=%d", item.opcode, pending)) }
			transport.send_blocked = true
			return progressed, true
		}
		if code != .E_OK || int(sent) != len(item.bytes) {
			krunker_ws_transport_fail(transport, fmt.tprintf("send ERROR opcode=%s curl=%v (%s) sent=%d expected=%d detail=%s", item.opcode, code, string(curl.easy_strerror(code)), sent, len(item.bytes), krunker_ws_transport_detail(transport)))
			return progressed, false
		}
		if transport.send_blocked { kproto.network_log("ws-send", fmt.tprintf("resumed; opcode=%s queued=%d", item.opcode, pending)) }
		transport.send_blocked = false
		sync.mutex_lock(&transport.mutex)
		ordered_remove(&transport.outbox, 0)
		if item.input { transport.queued_inputs -= 1 }
		sync.mutex_unlock(&transport.mutex)
		delete(item.bytes, transport.allocator)
		progressed = true
	}
}

// Receives frames until the socket is empty, or one pass is done. Complete
// messages are queued for the frame thread. Returns false when the
// connection ended.
@(private = "file")
krunker_ws_transport_drain :: proc(transport: ^Krunker_WS_Transport) -> (progressed, ok: bool) {
	for _ in 0 ..< KRUNKER_WS_RECV_PASS {
		sync.mutex_lock(&transport.mutex)
		full := len(transport.inbox) >= KRUNKER_WS_INBOX_LIMIT
		sync.mutex_unlock(&transport.mutex)
		if full do return progressed, true
		received: c.size_t
		meta: ^curl.ws_frame
		code := curl.ws_recv(transport.handle, &transport.buffer[0], c.size_t(len(transport.buffer)), &received, &meta)
		if code == .E_AGAIN do return progressed, true
		if code != .E_OK {
			krunker_ws_transport_fail(transport, fmt.tprintf("receive ERROR curl=%v (%s) detail=%s", code, string(curl.easy_strerror(code)), krunker_ws_transport_detail(transport)))
			return progressed, false
		}
		progressed = true
		transport.frames += 1
		if meta != nil && transport.frames <= 40 { kproto.network_log("ws-recv", fmt.tprintf("frame=%d bytes=%d flags=%d offset=%d bytesleft=%d (frame logging limited to first 40)", transport.frames, received, meta.flags, meta.offset, meta.bytesleft)) }
		if meta != nil && (meta.flags & curl.WS_CLOSE) == curl.WS_CLOSE {
			event := Krunker_WS_Event{kind = .CLOSED, close_code = -1}
			if received >= 2 {
				event.close_code = int(transport.buffer[0])*256 + int(transport.buffer[1])
				event.payload = make([]byte, int(received) - 2, transport.allocator)
				copy(event.payload, transport.buffer[2:int(received)])
			}
			krunker_ws_transport_push(transport, event)
			return progressed, false
		}
		if received == 0 do return progressed, true
		if meta == nil {
			krunker_ws_transport_fail(transport, "WebSocket receive omitted frame metadata.")
			return progressed, false
		}
		if (meta.flags & (curl.WS_PING | curl.WS_PONG)) != {} { continue }
		if (meta.flags & curl.WS_TEXT) != {} { kproto.network_log("ws-recv", "ignoring unexpected text frame"); continue }
		payload, complete, assembly_error := kproto.krunker_ws_message_feed(&transport.message, transport.buffer[:int(received)], i64(meta.offset), i64(meta.bytesleft), (meta.flags & curl.WS_CONT) != {})
		if len(assembly_error) > 0 {
			krunker_ws_transport_fail(transport, assembly_error)
			return progressed, false
		}
		if !complete do continue
		message := make([]byte, len(payload), transport.allocator)
		copy(message, payload)
		krunker_ws_transport_push(transport, {kind = .MESSAGE, payload = message})
	}
	return progressed, true
}

@(private = "file")
krunker_ws_transport_run :: proc(t: ^thread.Thread) {
	transport := cast(^Krunker_WS_Transport)t.data
	for {
		sync.mutex_lock(&transport.mutex)
		stop := transport.stop
		sync.mutex_unlock(&transport.mutex)
		if stop do break
		sent, send_ok := krunker_ws_transport_flush(transport)
		if !send_ok do break
		received, recv_ok := krunker_ws_transport_drain(transport)
		if !recv_ok do break
		free_all(context.temp_allocator)
		if !sent && !received {
			krunker_ws_wait(&transport.wait, transport.send_blocked ? KRUNKER_WS_BLOCKED_WAIT_MS : KRUNKER_WS_IDLE_WAIT_MS)
		}
	}
	// With init_context set, the thread owns its default temp allocator.
	if context.temp_allocator.procedure == runtime.default_temp_allocator_proc {
		runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
	}
}
