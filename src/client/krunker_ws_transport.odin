package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import curl "vendor:curl"
import shared "../shared"
import kproto "../krunker"
import accessui "../browser_access"

// The live Krunker connection runs on its own thread, from the first
// matchmaker request to the last frame. The thread resolves the invite
// (generate-token, game-list, seek-game), performs the WebSocket upgrade,
// then owns the curl handle and does every send, receive and frame
// reassembly. DNS, TLS, slow servers, a burst after a ping spike or a
// cancelled join can therefore never stall the frame loop. The frame thread
// starts the job, applies the events it reports (status, connected or
// failed, then messages) in order, and keeps all game state; the two threads
// only exchange byte buffers and strings through two queues.

Krunker_WS_Event_Kind :: enum u8 {
	MESSAGE,        // payload is one complete binary message
	CLOSED,         // the server closed the socket; payload is the close reason
	FAILED,         // a send, receive or frame error; text says what failed
	STATUS,         // join progress for the status line; text
	CONNECTED,      // the upgrade succeeded; messages follow
	CONNECT_FAILED, // matchmaking or the upgrade failed; see the fields below
}

Krunker_WS_Event :: struct {
	kind: Krunker_WS_Event_Kind,
	payload: []byte,
	close_code: int, // -1 when the close frame had no status
	text: string,
	// CONNECT_FAILED: what the old synchronous join decided from.
	upgrade, rejected, needs_captcha: bool,
	http_status: i64,
	code: curl.code,
}

Krunker_WS_Outbound :: struct {
	bytes: []byte,
	opcode: string, // a string literal, for diagnostics
	input: bool,
}

// What the thread needs to join. Strings are owned by the transport.
Krunker_WS_Join :: struct {
	url: string,     // a known WebSocket URL; empty means resolve the invite
	game_id: string, // resolve: the invite's game
	token: string,   // resolve: account access
	captcha: string, // resolve: a CAPTCHA proof for seek-game
}

Krunker_WS_Transport :: struct {
	handle: ^curl.CURL,
	// Both threads allocate and free the queued buffers with this allocator.
	allocator: runtime.Allocator,
	mutex: sync.Mutex,
	outbox: [dynamic]Krunker_WS_Outbound,
	inbox: [dynamic]Krunker_WS_Event,
	queued_inputs: int, // q packets not yet completely sent
	stop: bool,         // also aborts in-flight HTTP and the upgrade
	ended: bool,        // the thread queued CLOSED or FAILED and does no more I/O
	thread: ^thread.Thread,
	wait: Krunker_WS_Wait,
	global_ready: bool,
	// Owned by the transport thread.
	join: Krunker_WS_Join,
	error_buffer: [curl.ERROR_SIZE]byte,
	upgrade_capture: kproto.Network_HTTP_Capture,
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

// Test hook: when set, the lobby WebSocket URL from seek-game uses this
// origin (for example ws://127.0.0.1:1234) instead of wss://<host>.
krunker_lobby_origin_override: string

// Takes ownership of handle (nil until the thread connects) and of join's
// strings. The thread does not run until started.
krunker_ws_transport_create :: proc(handle: ^curl.CURL = nil, join: Krunker_WS_Join = {}) -> ^Krunker_WS_Transport {
	transport := new(Krunker_WS_Transport)
	transport.handle = handle
	transport.join = join
	transport.allocator = context.allocator
	transport.outbox.allocator = context.allocator
	transport.inbox.allocator = context.allocator
	transport.message.buffer.allocator = context.allocator
	transport.upgrade_capture.body.allocator = context.allocator
	transport.upgrade_capture.headers.allocator = context.allocator
	return transport
}

krunker_ws_transport_start :: proc(transport: ^Krunker_WS_Transport) -> bool {
	if curl.global_init(curl.GLOBAL_DEFAULT) != .E_OK { return false }
	transport.global_ready = true
	if !krunker_ws_wait_init(&transport.wait) { return false }
	transport.thread = thread.create(krunker_ws_transport_run)
	if transport.thread == nil { return false }
	transport.thread.data = transport
	transport.thread.init_context = context
	thread.start(transport.thread)
	return true
}

// Releases the curl handle, the wait objects and every queued buffer. The
// thread must have finished; krunker_ws_transport_release arranges that.
krunker_ws_transport_destroy :: proc(transport: ^Krunker_WS_Transport) {
	if transport == nil do return
	if transport.thread != nil {
		thread.join(transport.thread)
		thread.destroy(transport.thread)
	}
	krunker_ws_wait_fini(&transport.wait)
	if transport.handle != nil { curl.easy_cleanup(transport.handle) }
	if transport.global_ready { curl.global_cleanup() }
	for item in transport.outbox { delete(item.bytes, transport.allocator) }
	delete(transport.outbox)
	krunker_ws_events_free(transport.inbox[:], transport.allocator)
	delete(transport.inbox)
	delete(transport.message.buffer)
	delete(transport.upgrade_capture.body)
	delete(transport.upgrade_capture.headers)
	delete(transport.join.url, transport.allocator)
	delete(transport.join.game_id, transport.allocator)
	delete(transport.join.token, transport.allocator)
	delete(transport.join.captcha, transport.allocator)
	free(transport, transport.allocator)
}

// Transports told to stop whose thread may still be finishing an aborted
// request. The frame thread frees them once done, without ever waiting.
krunker_ws_reaper: [dynamic]^Krunker_WS_Transport

// Stops the transport without waiting for its thread. Pending HTTP requests
// and the upgrade abort through curl's progress callback; I/O stops at the
// next wake. The transport is freed now if its thread already finished,
// otherwise by krunker_ws_reap on a later frame.
krunker_ws_transport_release :: proc(transport: ^Krunker_WS_Transport) {
	if transport == nil do return
	sync.atomic_store(&transport.stop, true)
	krunker_ws_wait_wake(&transport.wait)
	if transport.thread == nil || thread.is_done(transport.thread) {
		krunker_ws_transport_destroy(transport)
		return
	}
	if krunker_ws_reaper == nil { krunker_ws_reaper = make([dynamic]^Krunker_WS_Transport, runtime.heap_allocator()) }
	append(&krunker_ws_reaper, transport)
}

// Frees released transports whose thread has finished. With wait set (at
// shutdown, or in tests), waits for all of them.
krunker_ws_reap :: proc(wait := false) {
	for i := 0; i < len(krunker_ws_reaper); {
		transport := krunker_ws_reaper[i]
		if wait || thread.is_done(transport.thread) {
			krunker_ws_transport_destroy(transport)
			unordered_remove(&krunker_ws_reaper, i)
			continue
		}
		i += 1
	}
	if len(krunker_ws_reaper) == 0 && krunker_ws_reaper != nil {
		delete(krunker_ws_reaper)
		krunker_ws_reaper = nil
	}
}

@(private = "file")
krunker_ws_transport_stopped :: proc(transport: ^Krunker_WS_Transport) -> bool {
	return sync.atomic_load(&transport.stop)
}

@(private = "file")
krunker_ws_transport_status :: proc(transport: ^Krunker_WS_Transport, text: string) {
	krunker_ws_transport_push(transport, {kind = .STATUS, text = strings.clone(text, transport.allocator)})
}

// Resolves the invite if needed and performs the upgrade, as the frame
// thread used to. Reports CONNECTED, or CONNECT_FAILED with what the frame
// thread needs to choose browser access, a CAPTCHA or an error message.
// Returns false when the join failed or was cancelled.
@(private = "file")
krunker_ws_transport_connect :: proc(transport: ^Krunker_WS_Transport) -> bool {
	kproto.network_http_abort = &transport.stop
	defer kproto.network_http_abort = nil
	join := &transport.join
	url := join.url
	resolved := ""
	defer delete(resolved)
	if len(url) == 0 {
		link := shared.Join_Link{game_id = join.game_id}
		rejected, needs_captcha: bool
		ok: bool
		error_text: string
		resolved, ok, error_text = krunker_ws_resolve_invite(&link, join.token, &rejected, captcha = join.captcha, needs_captcha = &needs_captcha)
		if krunker_ws_transport_stopped(transport) { return false }
		if !ok {
			krunker_ws_transport_push(transport, {kind = .CONNECT_FAILED, text = strings.clone(error_text, transport.allocator), rejected = rejected, needs_captcha = needs_captcha})
			return false
		}
		url = resolved
	}
	kproto.network_log("websocket", fmt.tprintf("CONNECT %s; awaiting lobby selection", url))
	handle := curl.easy_init()
	if handle == nil {
		krunker_ws_transport_push(transport, {kind = .CONNECT_FAILED, text = strings.clone("Could not allocate the Krunker WebSocket handle.", transport.allocator)})
		return false
	}
	url_c := strings.clone_to_cstring(url, context.temp_allocator)
	headers: ^curl.slist
	headers = curl.slist_append(headers, "Origin: https://krunker.io")
	headers = curl.slist_append(headers, "Referer: https://krunker.io/")
	headers = curl.slist_append(headers, "User-Agent: Mozilla/5.0 (Krodin)")
	defer curl.slist_free_all(headers)
	setup := []curl.code{
		curl.easy_setopt(handle, .ERRORBUFFER, rawptr(&transport.error_buffer[0])),
		curl.easy_setopt(handle, .HEADERFUNCTION, curl.write_callback(kproto.network_http_header)),
		curl.easy_setopt(handle, .HEADERDATA, rawptr(&transport.upgrade_capture)),
		curl.easy_setopt(handle, .WRITEFUNCTION, curl.write_callback(kproto.network_http_write)),
		curl.easy_setopt(handle, .WRITEDATA, rawptr(&transport.upgrade_capture)),
		curl.easy_setopt(handle, .DEBUGFUNCTION, curl.debug_callback(kproto.network_http_debug)),
		curl.easy_setopt(handle, .VERBOSE, c.long(1)),
		curl.easy_setopt(handle, .URL, url_c),
		curl.easy_setopt(handle, .CONNECTTIMEOUT_MS, c.long(8000)),
		curl.easy_setopt(handle, .TIMEOUT_MS, c.long(1000)),
		curl.easy_setopt(handle, .CONNECT_ONLY, c.long(2)),
		curl.easy_setopt(handle, .HTTPHEADER, headers),
	}
	option_names := []string{"ERRORBUFFER", "HEADERFUNCTION", "HEADERDATA", "WRITEFUNCTION", "WRITEDATA", "DEBUGFUNCTION", "VERBOSE", "URL", "CONNECTTIMEOUT_MS", "TIMEOUT_MS", "CONNECT_ONLY", "HTTPHEADER"}
	for code, i in setup {
		if code != .E_OK {
			kproto.network_log("websocket", fmt.tprintf("ERROR curl option=%s code=%v (%s)", option_names[i], code, string(curl.easy_strerror(code))))
			curl.easy_cleanup(handle)
			krunker_ws_transport_push(transport, {kind = .CONNECT_FAILED, text = strings.clone("Could not configure WebSocket; see logs/krunker-network.log", transport.allocator)})
			return false
		}
	}
	kproto.network_http_set_abort(handle, &transport.stop)
	kproto.network_log("websocket", "upgrade connect_timeout=8000ms timeout=1000ms Origin=https://krunker.io Referer=https://krunker.io/ User-Agent=Mozilla/5.0 (Krodin)")
	code := curl.easy_perform(handle)
	status := kproto.network_http_info(handle, "websocket", code, string(cast(cstring)&transport.error_buffer[0]))
	kproto.network_log("websocket", fmt.tprintf("upgrade response headers=%s body=%s", string(transport.upgrade_capture.headers[:]), string(transport.upgrade_capture.body[:])))
	if krunker_ws_transport_stopped(transport) {
		curl.easy_cleanup(handle)
		return false
	}
	if code != .E_OK {
		rejected := accessui.token_rejected(status, transport.upgrade_capture.body[:])
		curl.easy_cleanup(handle)
		krunker_ws_transport_push(transport, {kind = .CONNECT_FAILED, upgrade = true, rejected = rejected, http_status = status, code = code})
		return false
	}
	// The progress callback is only for the upgrade; WebSocket I/O is non-blocking.
	curl.easy_setopt(handle, .NOPROGRESS, c.long(1))
	transport.handle = handle
	krunker_ws_wait_attach(&transport.wait, handle)
	krunker_ws_transport_push(transport, {kind = .CONNECTED})
	return true
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
	if transport.ended || sync.atomic_load(&transport.stop) {
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
	if event.kind == .CLOSED || event.kind == .FAILED || event.kind == .CONNECT_FAILED { transport.ended = true }
}

@(private = "file")
krunker_ws_transport_fail :: proc(transport: ^Krunker_WS_Transport, text: string) {
	kproto.network_log("ws-thread", text)
	krunker_ws_transport_push(transport, {kind = .FAILED, text = strings.clone(text, transport.allocator)})
}

@(private = "file")
krunker_ws_transport_detail :: proc(transport: ^Krunker_WS_Transport) -> string {
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
	cpu_pin_current_thread_off_game_core() // never the game thread's core (cpu_affinity.odin)
	transport := cast(^Krunker_WS_Transport)t.data
	connected := krunker_ws_transport_connect(transport)
	for connected {
		if krunker_ws_transport_stopped(transport) do break
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
