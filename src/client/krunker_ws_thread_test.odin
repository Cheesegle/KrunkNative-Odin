package main

import "base:runtime"
import "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "core:crypto/legacy/sha1"
import glfw "vendor:glfw"
import shared "../shared"
import kproto "../krunker"

when ODIN_TEST {
	// A minimal WebSocket server on loopback, so the real libcurl transport
	// and its thread run without any external network. It answers one
	// upgrade per connection, sends a scripted burst, optionally closes, and
	// records the client's frames.
	WS_Test_Server :: struct {
		listener: net.TCP_Socket,
		port: int,
		thread: ^thread.Thread,
		connections: int,
		burst: [][]byte,
		close_code: int, // 0: keep the socket open after the burst
		close_reason: string,
		mutex: sync.Mutex,
		received: [dynamic][]byte,
		stop: bool,
		handshakes: int,
	}

	ws_test_server_start :: proc(server: ^WS_Test_Server, connections: int) -> bool {
		listener, err := net.listen_tcp({net.IP4_Loopback, 0})
		if err != nil { return false }
		endpoint, endpoint_err := net.bound_endpoint(listener)
		if endpoint_err != nil { net.close(listener); return false }
		server.listener, server.port, server.connections = listener, endpoint.port, connections
		server.thread = thread.create(ws_test_server_run)
		server.thread.data = server
		server.thread.init_context = context
		thread.start(server.thread)
		return true
	}

	ws_test_server_stop :: proc(server: ^WS_Test_Server) {
		sync.atomic_store(&server.stop, true)
		// Closing the listener also ends an accept that will never complete.
		net.close(server.listener)
		thread.join(server.thread)
		thread.destroy(server.thread)
		for frame in server.received { delete(frame) }
		delete(server.received)
	}

	ws_test_server_frames :: proc(server: ^WS_Test_Server) -> int {
		sync.mutex_lock(&server.mutex)
		defer sync.mutex_unlock(&server.mutex)
		return len(server.received)
	}

	ws_test_send_frame :: proc(socket: net.TCP_Socket, opcode: byte, payload: []byte) -> bool {
		header: [10]byte
		header[0] = 0x80 | opcode
		size := 2
		if len(payload) < 126 { header[1] = byte(len(payload)) }
		else if len(payload) < 65536 { header[1] = 126; header[2], header[3] = byte(len(payload) >> 8), byte(len(payload)); size = 4 }
		else {
			header[1] = 127
			for i in 0 ..< 8 { header[2+i] = byte(u64(len(payload)) >> uint(56 - 8*i)) }
			size = 10
		}
		if _, err := net.send_tcp(socket, header[:size]); err != nil { return false }
		if len(payload) > 0 { if _, err := net.send_tcp(socket, payload); err != nil { return false } }
		return true
	}

	ws_test_recv_exact :: proc(server: ^WS_Test_Server, socket: net.TCP_Socket, out: []byte) -> bool {
		filled := 0
		for filled < len(out) {
			n, err := net.recv_tcp(socket, out[filled:])
			if err == .Timeout || err == .Would_Block { if sync.atomic_load(&server.stop) { return false }; continue }
			if err != nil || n == 0 { return false }
			filled += n
		}
		return true
	}

	ws_test_server_run :: proc(t: ^thread.Thread) {
		server := cast(^WS_Test_Server)t.data
		for _ in 0 ..< server.connections {
			socket, _, err := net.accept_tcp(server.listener)
			if err != nil { break }
			ws_test_server_session(server, socket)
			net.close(socket)
			free_all(context.temp_allocator)
		}
		runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
	}

	ws_test_server_session :: proc(server: ^WS_Test_Server, socket: net.TCP_Socket) {
		net.set_option(socket, .Receive_Timeout, 50 * time.Millisecond)
		request: [dynamic]byte
		defer delete(request)
		chunk: [1024]byte
		for !strings.contains(string(request[:]), "\r\n\r\n") {
			n, err := net.recv_tcp(socket, chunk[:])
			if err == .Timeout || err == .Would_Block { if sync.atomic_load(&server.stop) { return }; continue }
			if err != nil || n == 0 { return }
			append(&request, ..chunk[:n])
		}
		key := ""
		for line in strings.split_lines(string(request[:]), context.temp_allocator) {
			if colon := strings.index(line, ":"); colon > 0 && strings.equal_fold(strings.trim_space(line[:colon]), "Sec-WebSocket-Key") { key = strings.trim_space(line[colon+1:]) }
		}
		ctx: sha1.Context
		digest: [sha1.DIGEST_SIZE]byte
		sha1.init(&ctx)
		sha1.update(&ctx, transmute([]byte)key)
		sha1.update(&ctx, transmute([]byte)string("258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
		sha1.final(&ctx, digest[:])
		accept := base64.encode(digest[:], allocator = context.temp_allocator)
		response := fmt.tprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept)
		if _, err := net.send_tcp(socket, transmute([]byte)response); err != nil { return }
		sync.atomic_add(&server.handshakes, 1)
		for payload in server.burst { if !ws_test_send_frame(socket, 0x2, payload) { return } }
		if server.close_code > 0 {
			close_payload := make([]byte, 2 + len(server.close_reason), context.temp_allocator)
			close_payload[0], close_payload[1] = byte(server.close_code >> 8), byte(server.close_code)
			copy(close_payload[2:], server.close_reason)
			ws_test_send_frame(socket, 0x8, close_payload)
		}
		// Record client frames (masked, per RFC 6455) until asked to stop.
		for !sync.atomic_load(&server.stop) {
			head: [2]byte
			if !ws_test_recv_exact(server, socket, head[:]) { return }
			length := int(head[1] & 0x7f)
			if length == 126 { ext: [2]byte; if !ws_test_recv_exact(server, socket, ext[:]) { return }; length = int(ext[0]) << 8 | int(ext[1]) }
			else if length == 127 { return }
			mask: [4]byte
			if head[1] & 0x80 != 0 && !ws_test_recv_exact(server, socket, mask[:]) { return }
			payload := make([]byte, length)
			if !ws_test_recv_exact(server, socket, payload) { delete(payload); return }
			for &b, i in payload { b ~= mask[i % 4] }
			if head[0] & 0x0f == 0x8 { delete(payload); return }
			sync.mutex_lock(&server.mutex)
			append(&server.received, payload)
			sync.mutex_unlock(&server.mutex)
		}
	}

	ws_test_connect :: proc(t: ^testing.T, client: ^Client, port: int) -> bool {
		link := shared.Join_Link{scheme = "ws", raw = fmt.tprintf("ws://127.0.0.1:%d/ws", port)}
		return testing.expectf(t, krunker_ws_connect_ready(client, &link) && client.krunker.connected && client.krunker.transport != nil,
			"loopback WebSocket must connect (status: %s)", client.join_status)
	}

	ws_test_gmsg :: proc(i: int) -> []byte {
		packet, _ := kproto.krunker_msgpack_encode_packet("gmsg", []kproto.Krunker_Msgpack_Value{fmt.tprintf("m%d", i)}, 0)
		return packet
	}

	ws_test_wait :: proc(condition: proc(rawptr) -> bool, data: rawptr, seconds: f64 = 5) -> bool {
		deadline := time.tick_now()
		for !condition(data) {
			if time.duration_seconds(time.tick_since(deadline)) > seconds { return false }
			time.sleep(time.Millisecond)
		}
		return true
	}

	ws_test_log_to :: proc(path: string) -> string {
		previous := kproto.network_log_path
		kproto.network_log_close()
		kproto.network_log_path = path
		return previous
	}

	ws_test_log_restore :: proc(previous: string) {
		kproto.network_log_close()
		os.remove(kproto.network_log_path)
		kproto.network_log_path = previous
	}

	// Messages reach the frame thread in arrival order, and packets the frame
	// thread queues reach the server in queue order with the exact counter
	// sequence (ah_num) that Krunker expects.
	@(test)
	krunker_ws_thread_preserves_order :: proc(t: ^testing.T) {
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		previous := ws_test_log_to("logs/krunker-network-thread-test.log")
		defer ws_test_log_restore(previous)
		MESSAGES :: 400
		burst := make([][]byte, MESSAGES)
		defer { for b in burst { delete(b) }; delete(burst) }
		for &b, i in burst { b = ws_test_gmsg(i) }
		server := WS_Test_Server{burst = burst}
		if !testing.expect(t, ws_test_server_start(&server, 1), "loopback listener") do return
		defer ws_test_server_stop(&server)
		client: Client
		defer { krunker_ws_disconnect(&client.krunker); delete(client.join_status); delete(client.selection_status) }
		if !ws_test_connect(t, &client, server.port) do return
		state := &client.krunker

		// Receive order, straight from the transport.
		events: [dynamic]Krunker_WS_Event
		defer { krunker_ws_events_free(events[:], state.transport.allocator); delete(events) }
		deadline := time.tick_now()
		for len(events) < MESSAGES && time.duration_seconds(time.tick_since(deadline)) < 5 {
			krunker_ws_transport_receive(state.transport, &events)
			time.sleep(time.Millisecond)
		}
		if !testing.expectf(t, len(events) == MESSAGES, "every message must arrive (%d/%d)", len(events), MESSAGES) do return
		for event, i in events {
			if event.kind != .MESSAGE || string(event.payload) != string(burst[i]) {
				testing.expectf(t, false, "message %d arrived out of order", i)
				return
			}
		}

		// Send order and counters, interleaving control packets with q.
		opcodes := [?]string{"po", "v", "q", "load", "v", "q", "po"}
		SENDS :: 210
		expected_counter: u8
		state.spawned, state.bootstrapped = true, true
		for i in 0 ..< SENDS {
			opcode := opcodes[i % len(opcodes)]
			if opcode == "q" {
				// Wait for the previous q to leave so no commands are held back.
				for krunker_ws_transport_input_backlog(state.transport) > 0 { time.sleep(100 * time.Microsecond) }
				append(&state.input_commands, shared.Input{seq = i32(100 + i), delta = 0.003, move_dir = -1})
				state.send_elapsed = KRUNKER_SEND_SECONDS
				krunker_ws_send_input(&client)
				testing.expect(t, len(state.input_commands) == 0, "q must be queued once the previous one has gone")
			} else {
				testing.expect(t, krunker_ws_send(state, opcode))
			}
			expected_counter = kproto.krunker_msgpack_counter_next(expected_counter, opcode)
		}
		testing.expect(t, state.ah_num == expected_counter, "the counter advances once per queued packet")
		Wait :: struct { server: ^WS_Test_Server, count: int }
		wait := Wait{&server, SENDS}
		ok := ws_test_wait(proc(data: rawptr) -> bool { w := cast(^Wait)data; return ws_test_server_frames(w.server) >= w.count }, &wait)
		if !testing.expectf(t, ok, "the server must receive every packet (%d/%d)", ws_test_server_frames(&server), SENDS) do return
		counter: u8
		sync.mutex_lock(&server.mutex)
		defer sync.mutex_unlock(&server.mutex)
		for frame, i in server.received[:SENDS] {
			opcode := opcodes[i % len(opcodes)]
			counter = kproto.krunker_msgpack_counter_next(counter, opcode)
			messages, trailer, error_text := kproto.krunker_msgpack_decode_packet(frame)
			if !testing.expectf(t, len(error_text) == 0 && len(messages) == 1, "packet %d must decode", i) do return
			root := messages[0].([]kproto.Krunker_Msgpack_Value)
			name, _ := root[0].(string)
			if opcode == "team" || opcode == "class" { name = opcode }
			if !testing.expectf(t, trailer == counter && name == opcode, "packet %d: expected %s with counter %d, got %v with %d", i, opcode, counter, root[0], trailer) do return
		}
	}

	// Disconnecting in the middle of a large burst joins the thread and frees
	// everything; a reconnect afterwards works normally.
	@(test)
	krunker_ws_thread_disconnect_mid_burst_and_reconnect :: proc(t: ^testing.T) {
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		previous := ws_test_log_to("logs/krunker-network-thread-test.log")
		defer ws_test_log_restore(previous)
		burst := make([][]byte, 5000)
		defer { for b in burst { delete(b) }; delete(burst) }
		for &b, i in burst { b = ws_test_gmsg(i) }
		server := WS_Test_Server{burst = burst}
		if !testing.expect(t, ws_test_server_start(&server, 2), "loopback listener") do return
		defer ws_test_server_stop(&server)
		client: Client
		defer { krunker_ws_disconnect(&client.krunker); delete(client.join_status); delete(client.selection_status); kproto.krunker_world_reset(&client.krunker_world) }
		for attempt in 0 ..< 2 {
			if !ws_test_connect(t, &client, server.port) do return
			start := time.tick_now()
			for client.krunker.rx_logged < 50 && time.duration_seconds(time.tick_since(start)) < 5 {
				krunker_ws_poll(&client)
				time.sleep(time.Millisecond)
			}
			testing.expectf(t, client.krunker.connected && client.krunker.rx_logged >= 50, "attempt %d must apply messages before the disconnect", attempt)
			testing.expect(t, client.krunker.last_server_message == fmt.tprintf("m%d", client.krunker.rx_logged - 1), "messages apply in order")
			// The thread is still receiving the burst here.
			krunker_ws_disconnect(&client.krunker)
			testing.expect(t, client.krunker.transport == nil && !client.krunker.connected, "disconnect must release the transport")
		}
		testing.expect(t, sync.atomic_load(&server.handshakes) == 2, "both connections must complete the upgrade")
	}

	// A server close in the middle of a burst ends the session only after the
	// messages that preceded it.
	@(test)
	krunker_ws_thread_server_close_after_burst :: proc(t: ^testing.T) {
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		previous := ws_test_log_to("logs/krunker-network-thread-test.log")
		defer ws_test_log_restore(previous)
		burst := make([][]byte, 60)
		defer { for b in burst { delete(b) }; delete(burst) }
		for &b, i in burst { b = ws_test_gmsg(i) }
		server := WS_Test_Server{burst = burst, close_code = 4000, close_reason = "fixture closed"}
		if !testing.expect(t, ws_test_server_start(&server, 1), "loopback listener") do return
		defer ws_test_server_stop(&server)
		client: Client
		defer { krunker_ws_disconnect(&client.krunker); delete(client.join_status); delete(client.selection_status); kproto.krunker_world_reset(&client.krunker_world) }
		if !ws_test_connect(t, &client, server.port) do return
		start := time.tick_now()
		for client.krunker.connected && time.duration_seconds(time.tick_since(start)) < 5 {
			krunker_ws_poll(&client)
			time.sleep(time.Millisecond)
		}
		testing.expect(t, !client.krunker.connected, "a close frame must end the session")
		testing.expectf(t, client.krunker.rx_logged == 60 && client.krunker.last_server_message == "m59", "all 60 messages must apply before the close (applied %d, last %s)", client.krunker.rx_logged, client.krunker.last_server_message)
		testing.expectf(t, strings.contains(client.join_status, "4000 fixture closed"), "the close reason must reach the status (%s)", client.join_status)
		testing.expect(t, !krunker_ws_send(&client.krunker, "po"), "sending after the close must fail instead of queueing")
	}

	// The background log writer keeps every line, in order per thread, and
	// network_log_close writes all of them before returning.
	@(test)
	network_log_writer_keeps_every_line :: proc(t: ^testing.T) {
		path := "logs/krunker-network-writer-test.log"
		os.remove(path)
		previous := ws_test_log_to(path)
		defer ws_test_log_restore(previous)
		THREADS :: 3
		LINES :: 2000
		writers: [THREADS]^thread.Thread
		for &writer, i in writers {
			writer = thread.create(proc(th: ^thread.Thread) {
				for line in 0 ..< LINES { kproto.network_log("writer-test", fmt.tprintf("thread=%d line=%d", th.user_index, line)) }
			})
			writer.user_index = i
			thread.start(writer)
		}
		for writer in writers { thread.join(writer); thread.destroy(writer) }
		kproto.network_log_close()
		data, err := os.read_entire_file_from_path(path, context.allocator)
		defer delete(data)
		if !testing.expect(t, err == nil, "the log file must exist") do return
		next: [THREADS]int
		lines := 0
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			if !strings.contains(line, "[writer-test]") do continue
			lines += 1
			thread_index, line_index := -1, -1
			if at := strings.index(line, "thread="); at >= 0 {
				fields := strings.fields(line[at:], context.temp_allocator)
				if len(fields) == 2 {
					thread_index, _ = strconv.parse_int(strings.trim_prefix(fields[0], "thread="))
					line_index, _ = strconv.parse_int(strings.trim_prefix(fields[1], "line="))
				}
			}
			if !testing.expectf(t, thread_index >= 0 && thread_index < THREADS && line_index == next[thread_index], "line out of order: %s", line) do return
			next[thread_index] += 1
		}
		testing.expectf(t, lines == THREADS * LINES, "every line must be written (%d/%d)", lines, THREADS * LINES)
	}
}
