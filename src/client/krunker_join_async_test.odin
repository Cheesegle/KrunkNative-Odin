package main

import "base:runtime"
import "core:encoding/base64"
import "core:fmt"
import "core:net"
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
	// A fake matchmaker and lobby on loopback. Every request (generate-token,
	// game-list, seek-game and the WebSocket upgrade) waits delay_ms first,
	// like a slow or lagging server, so the tests can show that none of that
	// waiting reaches the frame loop.
	Join_Test_Server :: struct {
		listener: net.TCP_Socket,
		port: int,
		thread: ^thread.Thread,
		delay_ms: int,    // atomic
		seek_status: int, // 200, or a rejection
		seek_body: string,
		stop: bool,       // atomic
		requests: int,    // atomic; requests answered or abandoned
		upgrades: int,    // atomic
	}

	join_test_server_start :: proc(server: ^Join_Test_Server) -> bool {
		listener, err := net.listen_tcp({net.IP4_Loopback, 0})
		if err != nil { return false }
		endpoint, endpoint_err := net.bound_endpoint(listener)
		if endpoint_err != nil { net.close(listener); return false }
		server.listener, server.port = listener, endpoint.port
		if server.seek_status == 0 { server.seek_status = 200 }
		server.thread = thread.create(join_test_server_run)
		server.thread.data = server
		server.thread.init_context = context
		thread.start(server.thread)
		return true
	}

	join_test_server_stop :: proc(server: ^Join_Test_Server) {
		sync.atomic_store(&server.stop, true)
		net.close(server.listener)
		thread.join(server.thread)
		thread.destroy(server.thread)
	}

	join_test_server_run :: proc(t: ^thread.Thread) {
		server := cast(^Join_Test_Server)t.data
		for !sync.atomic_load(&server.stop) {
			socket, _, err := net.accept_tcp(server.listener)
			if err != nil { break }
			join_test_server_session(server, socket)
			net.close(socket)
			free_all(context.temp_allocator)
		}
		runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
	}

	join_test_server_session :: proc(server: ^Join_Test_Server, socket: net.TCP_Socket) {
		net.set_option(socket, .Receive_Timeout, 20 * time.Millisecond)
		request: [dynamic]byte
		defer delete(request)
		chunk: [2048]byte
		for !strings.contains(string(request[:]), "\r\n\r\n") {
			n, err := net.recv_tcp(socket, chunk[:])
			if err == .Timeout || err == .Would_Block { if sync.atomic_load(&server.stop) { return }; continue }
			if err != nil || n == 0 { return }
			append(&request, ..chunk[:n])
		}
		defer sync.atomic_add(&server.requests, 1)
		// Wait like a slow server; a lower delay set meanwhile ends it early.
		start := time.tick_now()
		for time.duration_milliseconds(time.tick_since(start)) < f64(sync.atomic_load(&server.delay_ms)) {
			if sync.atomic_load(&server.stop) { return }
			time.sleep(5 * time.Millisecond)
		}
		text := string(request[:])
		line := text[:strings.index(text, "\r\n")]
		key := ""
		for header in strings.split_lines(text, context.temp_allocator) {
			if colon := strings.index(header, ":"); colon > 0 && strings.equal_fold(strings.trim_space(header[:colon]), "Sec-WebSocket-Key") { key = strings.trim_space(header[colon+1:]) }
		}
		if len(key) > 0 {
			ctx: sha1.Context
			digest: [sha1.DIGEST_SIZE]byte
			sha1.init(&ctx)
			sha1.update(&ctx, transmute([]byte)key)
			sha1.update(&ctx, transmute([]byte)string("258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
			sha1.final(&ctx, digest[:])
			response := fmt.tprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", base64.encode(digest[:], allocator = context.temp_allocator))
			if _, err := net.send_tcp(socket, transmute([]byte)response); err != nil { return }
			sync.atomic_add(&server.upgrades, 1)
			// Stay open, idle, until the client goes away.
			for !sync.atomic_load(&server.stop) {
				n, err := net.recv_tcp(socket, chunk[:])
				if err == .Timeout || err == .Would_Block { continue }
				if err != nil || n == 0 { return }
			}
			return
		}
		status, body := 200, ""
		switch {
		case strings.contains(line, "/generate-token"): body = "fixture-validation-token"
		case strings.contains(line, "/game-list"): body = `{"games":[]}`
		case strings.contains(line, "/seek-game"):
			status = server.seek_status
			body = status == 200 ? `{"host":"lobby.fixture.invalid","clientId":"fixture-client","gameId":"FRA:fixture","port":443}` : server.seek_body
		case: status, body = 404, "not found"
		}
		response := fmt.tprintf("HTTP/1.1 %d Fixture\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", status, len(body), body)
		net.send_tcp(socket, transmute([]byte)response)
	}

	Join_Test :: struct {
		server: Join_Test_Server,
		client: Client,
		previous_log, previous_origin: string,
	}

	join_test_begin :: proc(t: ^testing.T, j: ^Join_Test) -> bool {
		if !testing.expect(t, bool(glfw.Init())) { return false }
		j.previous_log = ws_test_log_to("logs/krunker-network-join-test.log")
		if !testing.expect(t, join_test_server_start(&j.server), "fake matchmaker") { return false }
		j.previous_origin = krunker_matchmaker_origin
		krunker_matchmaker_origin = fmt.aprintf("http://127.0.0.1:%d", j.server.port)
		krunker_lobby_origin_override = fmt.aprintf("ws://127.0.0.1:%d", j.server.port)
		j.client.access.token = strings.clone("fixture-access-token")
		return true
	}

	join_test_end :: proc(j: ^Join_Test) {
		krunker_ws_disconnect(&j.client.krunker)
		krunker_ws_reap(wait = true)
		join_test_server_stop(&j.server)
		delete(krunker_matchmaker_origin); krunker_matchmaker_origin = j.previous_origin
		delete(krunker_lobby_origin_override); krunker_lobby_origin_override = ""
		delete(j.client.join_status); delete(j.client.selection_status)
		delete(j.client.access.token); delete(j.client.access.assignment_url)
		shared.join_link_free(&j.client.join_link)
		kproto.krunker_world_reset(&j.client.krunker_world)
		// The join registered its tokens for redaction; they belong to this test.
		kproto.network_log_clear_secrets()
		ws_test_log_restore(j.previous_log)
		glfw.Terminate()
	}

	join_test_link :: proc(j: ^Join_Test) -> bool {
		shared.join_link_free(&j.client.join_link)
		link, ok := shared.join_link_parse("https://krunker.io/?game=FRA:fixture")
		j.client.join_link = link
		return ok && krunker_ws_connect_ready(&j.client, &j.client.join_link)
	}

	Join_Frames :: struct {
		frames: int,
		worst_ns: i64,
		statuses: [dynamic]string,
	}

	// Runs frames like client_tick until the join ends: each frame polls the
	// connection (timed) and then idles about 4 ms, as a 240 Hz frame would.
	join_test_frames :: proc(j: ^Join_Test, seconds: f64, access_retry: Krunker_WS_Access_Retry = krunker_ws_access_retry_default) -> (result: Join_Frames) {
		start := time.tick_now()
		last := ""
		for (j.client.krunker.connecting || j.client.krunker.transport != nil && !j.client.krunker.connected) && time.duration_seconds(time.tick_since(start)) < seconds {
			frame := time.tick_now()
			krunker_ws_reap()
			if j.client.krunker.transport != nil { krunker_ws_transport_receive(j.client.krunker.transport, &j.client.krunker.inbox) }
			krunker_ws_process_inbox(&j.client, access_retry = access_retry)
			elapsed := i64(time.tick_since(frame))
			result.worst_ns = max(result.worst_ns, elapsed)
			result.frames += 1
			if j.client.join_status != last {
				last = j.client.join_status
				append(&result.statuses, strings.clone(last, context.temp_allocator))
			}
			time.sleep(4 * time.Millisecond)
		}
		return
	}

	join_test_saw :: proc(statuses: []string, text: string) -> bool {
		for status in statuses { if strings.contains(status, text) { return true } }
		return false
	}

	// A join against servers that take a second per request never stalls
	// a frame, and the status line follows its progress.
	@(test)
	krunker_join_runs_off_the_frame_thread :: proc(t: ^testing.T) {
		j: Join_Test
		defer join_test_end(&j)
		if !join_test_begin(t, &j) do return
		DELAY :: 1000
		sync.atomic_store(&j.server.delay_ms, DELAY)

		// What the frame thread used to wait for: the three matchmaker
		// requests, run inline here exactly as the old join ran them.
		rejected: bool
		inline_start := time.tick_now()
		url, resolved, _ := krunker_ws_resolve_invite(&j.client.join_link, j.client.access.token, &rejected)
		inline_ms := time.duration_milliseconds(time.tick_since(inline_start))
		delete(url)
		testing.expect(t, resolved, "the fake matchmaker must resolve the invite")

		join_start := time.tick_now()
		start_ms: f64
		{
			call := time.tick_now()
			if !testing.expect(t, join_test_link(&j), "the join must start") do return
			start_ms = time.duration_milliseconds(time.tick_since(call))
		}
		frames := join_test_frames(&j, 15)
		defer delete(frames.statuses)
		join_ms := time.duration_milliseconds(time.tick_since(join_start))
		fmt.printf("[join] inline matchmaker requests (old frame-thread join, without the upgrade): %.0f ms; async join: %.0f ms over %d frames, start call %.3f ms, worst frame %.3f ms\n",
			inline_ms, join_ms, frames.frames, start_ms, f64(frames.worst_ns) / 1e6)
		testing.expectf(t, inline_ms >= 3 * DELAY, "the inline requests must take the server delay (%.0f ms)", inline_ms)
		testing.expectf(t, j.client.krunker.connected, "the join must connect (status %s)", j.client.join_status)
		testing.expectf(t, join_ms >= 4 * DELAY && frames.frames > 200, "the join must take its four delayed requests while frames keep running (%.0f ms, %d frames)", join_ms, frames.frames)
		limit_ms := ODIN_OPTIMIZATION_MODE == .None ? 8.0 : 4.0
		testing.expectf(t, f64(frames.worst_ns) / 1e6 < limit_ms && start_ms < limit_ms, "no frame may wait on the network (worst %.3f ms, start %.3f ms)", f64(frames.worst_ns) / 1e6, start_ms)
		testing.expect(t, join_test_saw(frames.statuses[:], "Krunker WebSocket connected"), "the status line must report the connection")
		testing.expect(t, strings.contains(j.client.join_status, "waiting for server load") && sync.atomic_load(&j.server.upgrades) == 1)
	}

	// Cancel aborts a request in flight without waiting, frees the thread,
	// and a new join afterwards works.
	@(test)
	krunker_join_cancel_aborts_promptly :: proc(t: ^testing.T) {
		j: Join_Test
		defer join_test_end(&j)
		if !join_test_begin(t, &j) do return
		sync.atomic_store(&j.server.delay_ms, 30000)
		for cycle in 0 ..< 3 {
			if !testing.expect(t, join_test_link(&j)) do return
			time.sleep(300 * time.Millisecond) // the first request is now in flight
			krunker_ws_poll(&j.client)
			testing.expect(t, j.client.krunker.connecting && strings.contains(j.client.join_status, "Resolving"))
			cancel := time.tick_now()
			krunker_ws_disconnect(&j.client.krunker) // what Cancel and Leave do
			cancel_ms := time.duration_milliseconds(time.tick_since(cancel))
			testing.expectf(t, cancel_ms < 5 && !j.client.krunker.connecting && j.client.krunker.transport == nil, "cycle %d: cancel must not wait (%.3f ms)", cycle, cancel_ms)
			// curl's progress callback aborts the request; the reaper frees it.
			released := time.tick_now()
			for len(krunker_ws_reaper) > 0 && time.duration_seconds(time.tick_since(released)) < 5 {
				krunker_ws_reap()
				time.sleep(5 * time.Millisecond)
			}
			abort_ms := time.duration_milliseconds(time.tick_since(released))
			fmt.printf("[join] cycle %d: cancel returned in %.3f ms; the aborted request ended %.0f ms later\n", cycle, cancel_ms, abort_ms)
			testing.expectf(t, len(krunker_ws_reaper) == 0 && abort_ms < 2500, "cycle %d: the aborted join must end promptly (%.0f ms)", cycle, abort_ms)
		}
		// Rejoin after the cancels.
		sync.atomic_store(&j.server.delay_ms, 0)
		if !testing.expect(t, join_test_link(&j)) do return
		frames := join_test_frames(&j, 10)
		delete(frames.statuses)
		testing.expectf(t, j.client.krunker.connected, "a rejoin after cancelling must connect (status %s)", j.client.join_status)
	}

	Retry_Probe :: struct { calls: int, rejected: bool }
	retry_probe: Retry_Probe
	join_test_retry :: proc(client: ^Client, rejected: bool) -> bool {
		retry_probe.calls += 1
		retry_probe.rejected = rejected
		return rejected
	}

	// A rejected token still leads to the browser-access retry, and other
	// failures show the same status text as before.
	@(test)
	krunker_join_failures_reach_the_frame_thread :: proc(t: ^testing.T) {
		j: Join_Test
		defer join_test_end(&j)
		if !join_test_begin(t, &j) do return
		j.server.seek_status, j.server.seek_body = 403, `{"error":"Invalid token"}`
		retry_probe = {}
		if !testing.expect(t, join_test_link(&j)) do return
		frames := join_test_frames(&j, 10, join_test_retry)
		delete(frames.statuses)
		testing.expect(t, !j.client.krunker.connecting && !j.client.krunker.connected && j.client.krunker.transport == nil)
		testing.expectf(t, retry_probe.calls == 1 && retry_probe.rejected, "a rejected token must request browser access (calls %d)", retry_probe.calls)

		// Not a token problem: the old message, with no browser retry.
		j.server.seek_status, j.server.seek_body = 500, "fixture outage"
		retry_probe = {}
		if !testing.expect(t, join_test_link(&j)) do return
		frames = join_test_frames(&j, 10, join_test_retry)
		delete(frames.statuses)
		testing.expectf(t, strings.has_prefix(j.client.join_status, "matchmaker /seek-game failed: HTTP 500") && !retry_probe.rejected,
			"server errors must keep their status text (%s)", j.client.join_status)

		// An unreachable lobby: the upgrade fails with the old message.
		j.server.seek_status = 200
		delete(krunker_lobby_origin_override)
		krunker_lobby_origin_override = strings.clone("ws://127.0.0.1:1")
		if !testing.expect(t, join_test_link(&j)) do return
		frames = join_test_frames(&j, 10, join_test_retry)
		delete(frames.statuses)
		testing.expectf(t, strings.has_prefix(j.client.join_status, "Krunker WebSocket upgrade failed: HTTP 0 curl="),
			"upgrade failures must keep their status text (%s)", j.client.join_status)
	}

	// The native server connect resolves and dials on a worker.
	@(test)
	native_connect_runs_off_the_frame_thread :: proc(t: ^testing.T) {
		listener, err := net.listen_tcp({net.IP4_Loopback, 0})
		if !testing.expect(t, err == nil) do return
		defer net.close(listener)
		endpoint, _ := net.bound_endpoint(listener)
		client: Client
		defer { net_client_disconnect(&client.net); delete(client.join_status) }
		start := time.tick_now()
		net_client_connect_start(&client, "127.0.0.1", endpoint.port)
		start_ms := time.duration_milliseconds(time.tick_since(start))
		testing.expect(t, client.net_connect != nil && strings.has_prefix(client.join_status, "Connecting to 127.0.0.1"))
		for client.net_connect != nil && time.duration_seconds(time.tick_since(start)) < 5 {
			net_client_connect_poll(&client)
			time.sleep(time.Millisecond)
		}
		testing.expectf(t, client.net.connected && client.join_status == fmt.tprintf("Connected to 127.0.0.1:%d.", endpoint.port) && start_ms < 5,
			"the connect must finish on a later frame (status %s, start %.3f ms)", client.join_status, start_ms)
		// Cancelling a dial in progress returns at once; the worker is freed later.
		net_client_connect_start(&client, "127.0.0.1", endpoint.port)
		net_client_connect_cancel(&client)
		testing.expect(t, client.net_connect == nil)
		for len(net_connect_reaper) > 0 && time.duration_seconds(time.tick_since(start)) < 5 {
			net_client_connect_poll(&client)
			time.sleep(time.Millisecond)
		}
		testing.expect(t, len(net_connect_reaper) == 0, "cancelled connects must be freed")
	}
}
