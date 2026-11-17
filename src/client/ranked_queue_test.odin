package main

import "base:runtime"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import access "../browser_access"
import menuui "../menu"
import kproto "../krunker"
import clay "../third_party/clay"

when ODIN_TEST {
	// A fake Krunker matchmaking queue (WebSocket) and API on loopback. Nothing
	// here contacts gamefrontend.svc.krunker.io, api.krunker.io or FRVR.
	Ranked_Test_Server :: struct {
		listener: net.TCP_Socket,
		port: int,
		thread: ^thread.Thread,
		stop: bool, // atomic
		mutex: sync.Mutex,
		// Configuration, under the mutex.
		frames: []string, // Text frames sent after the handshake (not owned).
		frame_delay_ms: int,
		close_after: bool, // Close from the server after the frames.
		connection_body: string, // Reply to GET /ranked/me/connection (not owned).
		// Observations, under the mutex.
		queue_requests: [dynamic]string, // Request targets (owned).
		authorization: string, // Authorization header of the API request (owned).
		client_closed, disconnected: int,
	}

	ranked_test_server_start :: proc(server: ^Ranked_Test_Server) -> bool {
		listener, err := net.listen_tcp({net.IP4_Loopback, 0})
		if err != nil { return false }
		endpoint, endpoint_err := net.bound_endpoint(listener)
		if endpoint_err != nil { net.close(listener); return false }
		server.listener, server.port = listener, endpoint.port
		server.thread = thread.create(ranked_test_server_run)
		server.thread.data = server
		server.thread.init_context = context
		thread.start(server.thread)
		return true
	}

	ranked_test_server_stop :: proc(server: ^Ranked_Test_Server) {
		sync.atomic_store(&server.stop, true)
		net.close(server.listener)
		thread.join(server.thread)
		thread.destroy(server.thread)
		for request in server.queue_requests { delete(request) }
		delete(server.queue_requests)
		delete(server.authorization)
	}

	ranked_test_server_run :: proc(t: ^thread.Thread) {
		server := cast(^Ranked_Test_Server)t.data
		for !sync.atomic_load(&server.stop) {
			socket, _, err := net.accept_tcp(server.listener)
			if err != nil { break }
			ranked_test_server_session(server, socket)
			net.close(socket)
		}
	}

	ranked_test_send_text :: proc(socket: net.TCP_Socket, text: string) {
		frame: [dynamic]byte
		defer delete(frame)
		append(&frame, 0x81)
		if len(text) < 126 { append(&frame, byte(len(text))) }
		else { append(&frame, 126, byte(len(text) >> 8), byte(len(text))) }
		append(&frame, ..transmute([]byte)text)
		net.send_tcp(socket, frame[:])
	}

	ranked_test_server_session :: proc(server: ^Ranked_Test_Server, socket: net.TCP_Socket) {
		net.set_option(socket, .Receive_Timeout, 20 * time.Millisecond)
		request: [dynamic]byte
		defer delete(request)
		chunk: [4096]byte
		start := time.tick_now()
		header_end := -1
		for header_end < 0 {
			if time.duration_seconds(time.tick_since(start)) > 5 || sync.atomic_load(&server.stop) { return }
			n, err := net.recv_tcp(socket, chunk[:])
			if err == .Timeout || err == .Would_Block { continue }
			if err != nil || n == 0 { return }
			append(&request, ..chunk[:n])
			header_end = strings.index(string(request[:]), "\r\n\r\n")
		}
		headers := string(request[:header_end])
		line := headers[:strings.index(headers, "\r\n")]
		if strings.has_prefix(line, "GET /ranked/me/connection ") {
			sync.mutex_lock(&server.mutex)
			delete(server.authorization)
			server.authorization = strings.clone(guest_test_header(headers, "Authorization"))
			body := server.connection_body
			sync.mutex_unlock(&server.mutex)
			response := fmt.aprintf("HTTP/1.1 200 Fixture\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
			defer delete(response)
			net.send_tcp(socket, transmute([]byte)response)
			return
		}
		if !strings.has_prefix(line, "GET /v1/matchmaking/queue?") {
			net.send_tcp(socket, transmute([]byte)string("HTTP/1.1 404 Fixture\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
			return
		}
		target := line[len("GET "):]
		if space := strings.index(target, " "); space >= 0 { target = target[:space] }
		key := guest_test_header(headers, "Sec-WebSocket-Key")
		ctx: sha1.Context
		sha1.init(&ctx)
		sha1.update(&ctx, transmute([]byte)key)
		sha1.update(&ctx, transmute([]byte)string("258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
		digest: [sha1.DIGEST_SIZE]byte
		sha1.final(&ctx, digest[:])
		accept := base64.encode(digest[:]); defer delete(accept)
		handshake := fmt.aprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept)
		defer delete(handshake)
		net.send_tcp(socket, transmute([]byte)handshake)
		sync.mutex_lock(&server.mutex)
		append(&server.queue_requests, strings.clone(target))
		frames, delay, close_after := server.frames, server.frame_delay_ms, server.close_after
		sync.mutex_unlock(&server.mutex)
		for frame in frames {
			time.sleep(time.Duration(delay) * time.Millisecond)
			ranked_test_send_text(socket, frame)
		}
		if close_after { net.send_tcp(socket, []byte{0x88, 0x02, 0x03, 0xE8}) }
		// Wait for the client's close frame or disconnect, within a deadline.
		incoming: [dynamic]byte
		defer delete(incoming)
		hold := time.tick_now()
		for time.duration_seconds(time.tick_since(hold)) < 6 && !sync.atomic_load(&server.stop) {
			n, err := net.recv_tcp(socket, chunk[:])
			if err == .Timeout || err == .Would_Block { continue }
			if err != nil || n == 0 {
				sync.mutex_lock(&server.mutex); server.disconnected += 1; sync.mutex_unlock(&server.mutex)
				return
			}
			append(&incoming, ..chunk[:n])
			// Client frames are masked; walk whole frames looking for a close.
			for len(incoming) >= 2 {
				length := int(incoming[1] & 0x7f)
				header := 2
				if length == 126 { if len(incoming) < 4 { break }; length = int(incoming[2])<<8 | int(incoming[3]); header = 4 }
				if incoming[1] & 0x80 != 0 { header += 4 }
				if len(incoming) < header + length { break }
				if incoming[0] & 0x0f == 8 {
					sync.mutex_lock(&server.mutex); server.client_closed += 1; sync.mutex_unlock(&server.mutex)
					return
				}
				remove_range(&incoming, 0, header + length)
			}
		}
	}

	ranked_test_jwt :: proc(tag: string, seconds: i64, guest: bool = false) -> string {
		// fmt treats braces specially, so the JSON goes in as arguments.
		extra := guest ? `,"extra":{"platform":"anonymous"}}` : `,"extra":{"platform":"krunker"}}`
		payload := fmt.tprintf("%s%d%s%s%s%s", `{"exp":`, time.time_to_unix(time.now()) + seconds, `,"sub":"`, tag, `"`, extra)
		encoded := base64.encode(transmute([]byte)payload, base64.ENC_URL_TABLE, options = {.No_Padding}); defer delete(encoded)
		return fmt.aprintf("eyJhbGciOiJIUzI1NiJ9.%s.sig+/=%s", string(encoded), tag)
	}

	// Account selection without the encrypted cache or the browser helper.
	ranked_test_select :: proc(client: ^Client, now: i64) -> bool {
		return access.token_state(client.access.token, now) == .READY
	}

	ranked_test_joins: [dynamic]string
	ranked_test_join :: proc(client: ^Client, url: string) -> bool {
		append(&ranked_test_joins, strings.clone(url))
		return true
	}

	Ranked_Test :: struct {
		server: Ranked_Test_Server,
		client: Client,
		previous_frontend, previous_api, previous_log: string,
		previous_select: proc(^Client, i64) -> bool,
		log_path: string,
	}

	ranked_test_begin :: proc(t: ^testing.T, r: ^Ranked_Test, name: string, token: string) -> bool {
		if !testing.expect(t, ranked_test_server_start(&r.server), "fake queue server") { return false }
		r.previous_frontend, r.previous_api, r.previous_select, r.previous_log = ranked_gamefrontend_origin, ranked_api_origin, ranked_access_select, kproto.network_log_path
		ranked_gamefrontend_origin = fmt.aprintf("http://127.0.0.1:%d", r.server.port)
		ranked_api_origin = fmt.aprintf("http://127.0.0.1:%d", r.server.port)
		ranked_access_select = ranked_test_select
		r.log_path = fmt.aprintf("bin/ranked-%s.log", name)
		os.remove(r.log_path)
		kproto.network_log_close()
		kproto.network_log_path = r.log_path
		r.client.access.token = strings.clone(token)
		return true
	}

	ranked_test_end :: proc(r: ^Ranked_Test) {
		ranked_shutdown(&r.client)
		delete(r.client.access.token)
		ranked_test_server_stop(&r.server)
		delete(ranked_gamefrontend_origin); delete(ranked_api_origin)
		ranked_gamefrontend_origin, ranked_api_origin, ranked_access_select = r.previous_frontend, r.previous_api, r.previous_select
		kproto.network_log_close()
		kproto.network_log_path = r.previous_log
		kproto.network_log_clear_secrets()
		delete(r.log_path)
		for url in ranked_test_joins { delete(url) }
		delete(ranked_test_joins); ranked_test_joins = nil
	}

	Ranked_Test_Until :: enum { SEARCHING, IDLE, JOINED, POPUP, REJOIN, CHECKED, REAPED }

	// Ticks like the frame loop until the condition holds; every wait has a deadline.
	ranked_test_until :: proc(client: ^Client, until: Ranked_Test_Until, seconds: f64 = 5) -> bool {
		start := time.tick_now()
		for time.duration_seconds(time.tick_since(start)) < seconds {
			ranked_tick(client, ranked_test_join)
			q := &client.ranked
			switch until {
			case .SEARCHING: if q.phase == .SEARCHING { return true }
			case .IDLE: if q.phase == .IDLE && q.job == nil { return true }
			case .JOINED: if len(ranked_test_joins) > 0 { return true }
			case .POPUP: if q.popup != .NONE { return true }
			case .REJOIN: if q.rejoin { return true }
			case .CHECKED: if q.check == nil { return true }
			case .REAPED: if q.job == nil && len(q.abandoned) == 0 && len(q.abandoned_checks) == 0 { return true }
			}
			time.sleep(5 * time.Millisecond)
		}
		return false
	}

	ranked_test_server_count :: proc(server: ^Ranked_Test_Server, closed: bool) -> int {
		sync.mutex_lock(&server.mutex); defer sync.mutex_unlock(&server.mutex)
		return closed ? server.client_closed : len(server.queue_requests)
	}

	ranked_test_wait_closed :: proc(server: ^Ranked_Test_Server, count: int) -> bool {
		start := time.tick_now()
		for time.duration_seconds(time.tick_since(start)) < 5 {
			if ranked_test_server_count(server, true) >= count { return true }
			time.sleep(5 * time.Millisecond)
		}
		return false
	}

	ranked_test_log_clean :: proc(t: ^testing.T, r: ^Ranked_Test, token: string) {
		kproto.network_log_close()
		data, err := os.read_entire_file_from_path(r.log_path, context.allocator)
		if !testing.expect(t, err == nil, "network log written") { return }
		defer delete(data)
		encoded := kproto.network_url_encode(token); defer delete(encoded)
		testing.expect(t, strings.contains(string(data), "[ranked]"), "the queue is logged")
		testing.expect(t, !strings.contains(string(data), token) && !strings.contains(string(data), encoded), "the account token reached the network log")
	}

	@(test)
	ranked_message_parsing :: proc(t: ^testing.T) {
		Case :: struct { text: string, kind: Ranked_Message_Kind, code: Ranked_Error_Code }
		cases := []Case{
			{`{"type":"QUEUE_STATUS","payload":{"status":"QUEUED"}}`, .QUEUED, .INTERNAL_ERROR},
			{`{"type":"QUEUE_STATUS","payload":{"status":"SEARCHING_WIDER"}}`, .IGNORED, .INTERNAL_ERROR},
			{`{"type":"QUEUE_STATUS"}`, .INVALID, .INTERNAL_ERROR},
			{`{"type":"QUEUE_STATUS","payload":{"status":"MATCHED"}}`, .INVALID, .INTERNAL_ERROR},
			{`{"type":"ERROR","payload":{"code":"COOLDOWN","message":"wait","payload":{"cooldown":90000}}}`, .ERROR, .COOLDOWN},
			{`{"type":"ERROR","payload":{"code":"ALREADY_IN_MATCH","payload":{"serverUrl":"r1.krunker.io:443"}}}`, .ERROR, .ALREADY_IN_MATCH},
			{`{"type":"ERROR","payload":{"code":"INTERNAL_ERROR"}}`, .ERROR, .INTERNAL_ERROR},
			{`{"type":"ERROR","payload":{"code":"NO_RANK_DATA"}}`, .ERROR, .NO_RANK_DATA},
			{`{"type":"ERROR","payload":{"code":"MIN_LEVEL_REQUIREMENT"}}`, .ERROR, .MIN_LEVEL_REQUIREMENT},
			{`{"type":"ERROR","payload":{"code":"SOMETHING_NEW"}}`, .ERROR, .INTERNAL_ERROR},
			{`{"type":"ERROR"}`, .INVALID, .INTERNAL_ERROR},
			// Krunker's switch has no INTERNAL_ERROR type (a mod's guess); it is ignored.
			{`{"type":"INTERNAL_ERROR"}`, .IGNORED, .INTERNAL_ERROR},
			{`{"type":"QUEUE_STATS","payload":{"players":12}}`, .IGNORED, .INTERNAL_ERROR},
			{`not json`, .INVALID, .INTERNAL_ERROR},
			{`[1,2]`, .INVALID, .INTERNAL_ERROR},
		}
		for c in cases {
			message := ranked_message_parse(c.text)
			testing.expectf(t, message.kind == c.kind && (message.kind != .ERROR || message.code == c.code), "%s parsed as %v %v", c.text, message.kind, message.code)
			ranked_message_free(&message)
		}
		matched := ranked_message_parse(`{"type":"QUEUE_STATUS","payload":{"status":"MATCHED","assignment":{"connection":"m1.krunker.io:443","extensions":{"map":" sandstorm_v3 ","region":"eu"}}}}`)
		defer ranked_message_free(&matched)
		testing.expect(t, matched.kind == .MATCHED && matched.connection == "m1.krunker.io:443" && matched.map_name == "sandstorm_v3" && matched.region == "eu", "MATCHED carries the assignment")
		cooldown := ranked_message_parse(cases[4].text); defer ranked_message_free(&cooldown)
		testing.expect(t, cooldown.cooldown_ms == 90000 && cooldown.message == "wait", "COOLDOWN carries payload.payload.cooldown")
		already := ranked_message_parse(cases[5].text); defer ranked_message_free(&already)
		testing.expect(t, already.server_url == "r1.krunker.io:443", "ALREADY_IN_MATCH carries serverUrl")
	}

	@(test)
	ranked_url_building :: proc(t: ^testing.T) {
		token := "a.b+c/d=e"
		prefs: menuui.Ranked_Preferences
		url := ranked_queue_url("https://gamefrontend.svc.krunker.io", token, ranked_selected_maps(prefs), ranked_selected_regions(prefs))
		testing.expectf(t, url == "wss://gamefrontend.svc.krunker.io/v1/matchmaking/queue?token=a.b%2Bc%2Fd%3De&maps=0,2,4,11,14,17,42&regions=eu", "Krunker's defaults: %s", url)
		delete(url)
		prefs.all_regions = true
		url = ranked_queue_url("http://127.0.0.1:1", token, ranked_selected_maps(prefs), ranked_selected_regions(prefs))
		testing.expectf(t, url == "ws://127.0.0.1:1/v1/matchmaking/queue?token=a.b%2Bc%2Fd%3De&maps=0,2,4,11,14,17,42&regions=as,eu,na", "all regions: %s", url)
		delete(url)
		prefs = {region_mask = 0b100, excluded_maps = 0b1111110}
		url = ranked_queue_url("https://x", token, ranked_selected_maps(prefs), ranked_selected_regions(prefs))
		testing.expectf(t, strings.has_suffix(url, "&maps=0&regions=na"), "chosen map and region: %s", url)
		delete(url)
		// An older save with several regions ticked queues all of them.
		prefs = {region_mask = 0b101}
		url = ranked_queue_url("https://x", token, ranked_selected_maps(prefs), ranked_selected_regions(prefs))
		testing.expectf(t, strings.has_suffix(url, "&regions=as,eu,na"), "several old regions: %s", url)
		delete(url)

		Case :: struct { connection, url: string, ok: bool }
		cases := []Case{
			{"m1.krunker.io:443", "wss://m1.krunker.io/ws?at=a.b%2Bc%2Fd%3De", true},
			{"m1.krunker.io", "wss://m1.krunker.io/ws?at=a.b%2Bc%2Fd%3De", true},
			{"ip_10_0_0_1.krunker.io:5003", "wss://ip_10_0_0_1.krunker.io:5003/ws?at=a.b%2Bc%2Fd%3De", true},
			{"ip_10_0_0_1.krunker.io", "wss://ip_10_0_0_1.krunker.io:3000/ws?at=a.b%2Bc%2Fd%3De", true},
			{"evil.example.com:443", "", false},
			{"krunker.io.evil.com:443", "", false},
			{"m1.krunker.io:0", "", false},
			{"m1.krunker.io:x", "", false},
			{"a:b:c", "", false},
			{"", "", false},
			{"m1.krunker.io/x:443", "", false},
		}
		for c in cases {
			built, ok := ranked_match_url(c.connection, token)
			testing.expectf(t, ok == c.ok && built == c.url, "%q built %q %v", c.connection, built, ok)
			delete(built)
		}
	}

	@(test)
	ranked_refuses_guest_and_missing_tokens :: proc(t: ^testing.T) {
		// The spectator build has no ranked queue; spectator_ranked_test.odin covers that.
		if KRODIN_SPECTATOR { return }
		r: Ranked_Test
		guest := ranked_test_jwt("guest", 3600, guest = true); defer delete(guest)
		if !ranked_test_begin(t, &r, "guest", guest) { return }
		defer ranked_test_end(&r)
		client := &r.client
		testing.expect(t, !ranked_queue_begin(client) && client.ranked.job == nil && client.ranked.phase == .IDLE, "a guest token never opens the queue")
		testing.expect(t, !ranked_view(client, true).logged_in, "a guest shows the login prompt")
		delete(client.access.token); client.access.token = ""
		testing.expect(t, !ranked_queue_begin(client) && client.ranked.job == nil, "no token never opens the queue")
		expiring := ranked_test_jwt("old", 30); defer delete(expiring)
		client.access.token = strings.clone(expiring)
		testing.expect(t, !ranked_queue_begin(client) && client.ranked.job == nil, "an expiring token never opens the queue")
		testing.expect(t, !ranked_join_server(client, "m1.krunker.io:443", ranked_test_join) && len(ranked_test_joins) == 0, "no join without account access")
		testing.expect(t, client.ranked.rejoin && client.ranked.rejoin_url == "m1.krunker.io:443" && client.ranked.popup == .LOGIN_EXPIRED, "the match is kept for Rejoin after login")
		ranked_open(client)
		testing.expect(t, client.ranked.check == nil, "the ranked-match check needs account access")
		time.sleep(50 * time.Millisecond)
		testing.expect(t, ranked_test_server_count(&r.server, false) == 0, "the fake server saw no queue socket")
	}

	@(test)
	ranked_queue_matches_and_joins :: proc(t: ^testing.T) {
		// The spectator build has no ranked queue; spectator_ranked_test.odin covers that.
		if KRODIN_SPECTATOR { return }
		r: Ranked_Test
		token := ranked_test_jwt("account", 3600); defer delete(token)
		if !ranked_test_begin(t, &r, "match", token) { return }
		defer ranked_test_end(&r)
		client := &r.client
		r.server.frames = []string{`{"type":"QUEUE_STATUS","payload":{"status":"QUEUED"}}`, `{"type":"QUEUE_STATS"}`, `{"type":"QUEUE_STATUS","payload":{"status":"MATCHED","assignment":{"connection":"m1.krunker.io:443","extensions":{"map":"site","region":"eu"}}}}`}
		r.server.frame_delay_ms = 150
		client.ranked_prefs = {region_mask = 0b100}
		testing.expect(t, ranked_queue_begin(client) && client.ranked.phase == .CONNECTING, "queue socket opening")
		testing.expect(t, ranked_view(client, true).logged_in && menuui.ranked_button_label(ranked_view(client, true)) == "LOADING...", "LOADING while connecting")
		if !testing.expect(t, ranked_test_until(client, .SEARCHING), "QUEUED starts the search") { return }
		testing.expect(t, menuui.ranked_button_label(ranked_view(client, true)) == "CANCEL", "CANCEL while searching")
		sync.mutex_lock(&r.server.mutex)
		target := len(r.server.queue_requests) > 0 ? r.server.queue_requests[0] : ""
		sync.mutex_unlock(&r.server.mutex)
		encoded := kproto.network_url_encode(token); defer delete(encoded)
		testing.expectf(t, target == fmt.tprintf("/v1/matchmaking/queue?token=%s&maps=0,2,4,11,14,17,42&regions=na", encoded), "queue request %s", target)
		found := time.tick_now()
		if !testing.expect(t, ranked_test_until(client, .JOINED), "MATCHED joins the assigned server") { return }
		testing.expectf(t, time.duration_seconds(time.tick_since(found)) >= 0.9, "Krunker waits a second after MATCHED")
		testing.expectf(t, ranked_test_joins[0] == fmt.tprintf("wss://m1.krunker.io/ws?at=%s", encoded), "join URL %s", ranked_test_joins[0])
		testing.expect(t, client.ranked.phase == .IDLE && client.ranked.job == nil && client.ranked.popup == .NONE, "the queue clears after accepting")
		testing.expect(t, ranked_test_wait_closed(&r.server, 1), "the queue socket is closed after the match")
		ranked_test_log_clean(t, &r, token)
	}

	@(test)
	ranked_queue_errors_cooldown_and_rejoin :: proc(t: ^testing.T) {
		// The spectator build has no ranked queue; spectator_ranked_test.odin covers that.
		if KRODIN_SPECTATOR { return }
		r: Ranked_Test
		token := ranked_test_jwt("errors", 3600); defer delete(token)
		if !ranked_test_begin(t, &r, "errors", token) { return }
		defer ranked_test_end(&r)
		client := &r.client
		r.server.frames = []string{`{"type":"ERROR","payload":{"code":"COOLDOWN","message":"Cooldown","payload":{"cooldown":90000}}}`}
		testing.expect(t, ranked_queue_begin(client), "queue opened")
		testing.expect(t, ranked_test_until(client, .POPUP) && client.ranked.popup == .COOLDOWN && client.ranked.phase == .IDLE, "COOLDOWN shows Krunker's popup and clears the queue")
		view := ranked_view(client, true)
		testing.expectf(t, view.popup_title == "Cooldown" && (strings.has_suffix(view.popup_text, "1:30") || strings.has_suffix(view.popup_text, "1:29")), "cooldown text %s", view.popup_text)
		testing.expectf(t, strings.has_prefix(view.status, "On cooldown: queue again in 1:"), "cooldown countdown %s", view.status)
		client.ranked.popup = .NONE
		ranked_test_until(client, .IDLE)

		r.server.frames = []string{`{"type":"ERROR","payload":{"code":"ALREADY_IN_MATCH","payload":{"serverUrl":"r9.krunker.io:443"}}}`}
		testing.expect(t, ranked_queue_begin(client), "queue opened")
		testing.expect(t, ranked_test_until(client, .REJOIN) && client.ranked.rejoin_url == "r9.krunker.io:443", "ALREADY_IN_MATCH offers Rejoin")
		view = ranked_view(client, true)
		testing.expect(t, menuui.ranked_button_label(view) == "REJOIN" && view.status == "You are already in a Ranked game.", "Krunker's REJOIN state")
		ranked_queue_action(client, ranked_test_join)
		encoded := kproto.network_url_encode(token); defer delete(encoded)
		testing.expect(t, len(ranked_test_joins) == 1 && ranked_test_joins[0] == fmt.tprintf("wss://r9.krunker.io/ws?at=%s", encoded), "REJOIN joins serverUrl")
		client.ranked.rejoin = false
		ranked_test_until(client, .IDLE)

		r.server.frames = []string{`{"type":"ERROR","payload":{"code":"INTERNAL_ERROR"}}`}
		testing.expect(t, ranked_queue_begin(client), "queue opened")
		testing.expect(t, ranked_test_until(client, .POPUP) && client.ranked.popup == .INTERNAL_ERROR, "INTERNAL_ERROR popup")
		testing.expect(t, ranked_view(client, true).popup_title == "Internal Error", "Krunker's Internal Error popup")
		client.ranked.popup = .NONE
		ranked_test_until(client, .IDLE)

		r.server.frames = []string{`{"type":"QUEUE_STATUS"`}
		testing.expect(t, ranked_queue_begin(client), "queue opened")
		testing.expect(t, ranked_test_until(client, .POPUP) && client.ranked.popup == .INTERNAL_ERROR && client.ranked.phase == .IDLE, "an unparsable message is an internal error")
		ranked_test_log_clean(t, &r, token)
	}

	@(test)
	ranked_leave_queue_and_server_close :: proc(t: ^testing.T) {
		// The spectator build has no ranked queue; spectator_ranked_test.odin covers that.
		if KRODIN_SPECTATOR { return }
		r: Ranked_Test
		token := ranked_test_jwt("leave", 3600); defer delete(token)
		if !ranked_test_begin(t, &r, "leave", token) { return }
		defer ranked_test_end(&r)
		client := &r.client
		r.server.frames = []string{`{"type":"QUEUE_STATUS","payload":{"status":"QUEUED"}}`}
		testing.expect(t, ranked_queue_begin(client), "queue opened")
		if !testing.expect(t, ranked_test_until(client, .SEARCHING), "searching") { return }
		testing.expect(t, strings.has_prefix(menuui.ranked_global_status(ranked_view(client, false)), "Searching for match... (0:0"), "the queue status shows outside the ranked menu")
		ranked_queue_action(client, ranked_test_join) // CANCEL
		testing.expect(t, client.ranked.phase == .IDLE && client.ranked.job == nil && client.ranked.popup == .NONE, "leaving clears the queue")
		testing.expect(t, ranked_test_wait_closed(&r.server, 1), "leaving sends a close frame")
		testing.expect(t, ranked_test_until(client, .REAPED), "the worker finishes and is freed")

		// Logout (Forget browser session) uses ranked_cancel too.
		testing.expect(t, ranked_queue_begin(client) && ranked_test_until(client, .SEARCHING), "searching again")
		ranked_cancel(client, "Logged out; left the ranked queue.")
		testing.expect(t, client.ranked.phase == .IDLE && ranked_test_wait_closed(&r.server, 2), "logout leaves the queue")

		r.server.close_after = true
		testing.expect(t, ranked_queue_begin(client), "queue opened")
		testing.expect(t, ranked_test_until(client, .SEARCHING) || client.ranked.phase == .IDLE, "queued")
		testing.expect(t, ranked_test_until(client, .IDLE) && client.ranked.popup == .NONE, "a server close clears the queue without a popup")
		testing.expect(t, len(ranked_test_joins) == 0, "nothing was joined")
	}

	@(test)
	ranked_connect_failure_and_running_match_check :: proc(t: ^testing.T) {
		// The spectator build has no ranked queue; spectator_ranked_test.odin covers that.
		if KRODIN_SPECTATOR { return }
		r: Ranked_Test
		token := ranked_test_jwt("check", 3600); defer delete(token)
		if !ranked_test_begin(t, &r, "check", token) { return }
		defer ranked_test_end(&r)
		client := &r.client
		r.server.connection_body = `{"data":{"serverUrl":"r2.krunker.io:443"},"error":null}`
		ranked_open(client)
		testing.expect(t, client.ranked.check != nil && menuui.ranked_button_label(ranked_view(client, true)) == "LOADING...", "opening Ranked checks for a running match")
		testing.expect(t, ranked_test_until(client, .CHECKED) && client.ranked.rejoin && client.ranked.rejoin_url == "r2.krunker.io:443", "a running match offers Rejoin")
		sync.mutex_lock(&r.server.mutex)
		testing.expect(t, r.server.authorization == fmt.tprintf("Bearer %s", token), "the API check sends Bearer access")
		sync.mutex_unlock(&r.server.mutex)
		r.server.connection_body = `{"data":null,"error":null}`
		ranked_open(client)
		testing.expect(t, !client.ranked.rejoin && ranked_test_until(client, .CHECKED) && !client.ranked.rejoin, "no running match: no Rejoin")

		// A closed port: the connect fails and shows Krunker's Internal Error.
		closed, err := net.listen_tcp({net.IP4_Loopback, 0})
		if !testing.expect(t, err == nil, "port probe") { return }
		endpoint, _ := net.bound_endpoint(closed)
		net.close(closed)
		delete(ranked_gamefrontend_origin)
		ranked_gamefrontend_origin = fmt.aprintf("http://127.0.0.1:%d", endpoint.port)
		testing.expect(t, ranked_queue_begin(client), "queue opening")
		testing.expect(t, ranked_test_until(client, .POPUP, 10) && client.ranked.popup == .INTERNAL_ERROR && client.ranked.phase == .IDLE, "a failed connect is an internal error")
		ranked_test_log_clean(t, &r, token)
	}

	ranked_test_saved: Client_Settings
	ranked_test_save :: proc(settings: Client_Settings) -> bool { ranked_test_saved = settings; return true }

	@(test)
	ranked_preferences_persist :: proc(t: ^testing.T) {
		prefs: menuui.Ranked_Preferences
		testing.expect(t, menuui.ranked_region_choice(prefs) == 1 && menuui.ranked_map_mask(prefs) == 0b1111111, "older files queue Krunker's defaults (Europe, every map)")
		// Migration from the checkbox saves: several regions or All regions -> All regions; one region -> it.
		Migration :: struct { old: menuui.Ranked_Preferences, choice: i32, migrated: menuui.Ranked_Preferences }
		migrations := []Migration{
			{{}, 1, {}},
			{{region_mask = 0b001}, 0, {region_mask = 0b001}},
			{{region_mask = 0b100}, 2, {region_mask = 0b100}},
			{{region_mask = 0b101}, 3, {all_regions = true}},
			{{region_mask = 0b111}, 3, {all_regions = true}},
			{{region_mask = 0b010, all_regions = true}, 3, {all_regions = true}},
			{{region_mask = 0xf8}, 1, {}},
		}
		for m in migrations {
			testing.expectf(t, menuui.ranked_region_choice(m.old) == m.choice && menuui.ranked_preferences_validate(m.old) == m.migrated, "%v migrates to choice %d", m.old, m.choice)
		}
		menuui.ranked_set_region(&prefs, 3)
		testing.expect(t, prefs.all_regions && prefs.region_mask == 0, "All regions")
		menuui.ranked_set_region(&prefs, 0)
		testing.expect(t, !prefs.all_regions && prefs.region_mask == 0b001, "one region")
		menuui.ranked_set_region(&prefs, 9)
		testing.expect(t, menuui.ranked_region_choice(prefs) == 0, "out-of-range choices are ignored")
		for i in 0 ..< 6 { menuui.ranked_toggle_map(&prefs, i32(i)) }
		menuui.ranked_toggle_map(&prefs, 6)
		testing.expect(t, menuui.ranked_map_mask(prefs) == 0b1000000, "the last map stays selected")
		testing.expect(t, menuui.ranked_preferences_validate({excluded_maps = 0xffff, region_mask = 0xff}) == menuui.Ranked_Preferences{all_regions = true}, "validation drops unknown bits")

		client: Client
		apply := ranked_preferences_action
		apply(&client, {kind = .RANKED_REGION, index = 3}, ranked_test_save)
		testing.expect(t, client.ranked_prefs.all_regions && ranked_test_saved.ranked.all_regions, "All regions saves immediately")
		apply(&client, {kind = .RANKED_REGION, index = 2}, ranked_test_save)
		testing.expect(t, ranked_test_saved.ranked.region_mask == 0b100 && !ranked_test_saved.ranked.all_regions, "a single region saves immediately")
		apply(&client, {kind = .RANKED_MAP, index = 3}, ranked_test_save)
		testing.expect(t, ranked_test_saved.ranked.excluded_maps == 0b1000, "map choices save immediately")
		client.ranked.phase = .SEARCHING
		apply(&client, {kind = .RANKED_MAP, index = 4}, ranked_test_save)
		testing.expect(t, client.ranked_prefs.excluded_maps == 0b1000, "choices are locked while queued")
		client.ranked.phase = .IDLE

		path := "bin/ranked-settings-test.json"
		settings := client_settings_defaults()
		settings.ranked = {region_mask = 0b001, all_regions = true, excluded_maps = 0b0000110}
		testing.expect(t, client_settings_save(settings, path), "settings saved")
		loaded := client_settings_load(path)
		testing.expect(t, loaded.ranked == menuui.Ranked_Preferences{all_regions = true, excluded_maps = 0b0000110}, "ranked choices persist in client-settings.json")
		testing.expect(t, os.write_entire_file(path, transmute([]byte)string(`{"version":1,"ranked":{"region_mask":5,"all_regions":false,"excluded_maps":0}}`)) == nil, "checkbox-era file written")
		loaded = client_settings_load(path)
		testing.expect(t, loaded.ranked == menuui.Ranked_Preferences{all_regions = true}, "two ticked regions load as All regions")
		testing.expect(t, os.write_entire_file(path, transmute([]byte)string(`{"version":1,"ranked":{"region_mask":4,"all_regions":false,"excluded_maps":0}}`)) == nil, "checkbox-era file written")
		loaded = client_settings_load(path)
		testing.expect(t, loaded.ranked == menuui.Ranked_Preferences{region_mask = 0b100}, "one ticked region loads as that region")
		testing.expect(t, os.write_entire_file(path, transmute([]byte)string(`{"version":1}`)) == nil, "older file written")
		loaded = client_settings_load(path)
		testing.expect(t, loaded.ranked == menuui.Ranked_Preferences{}, "an older file uses Krunker's defaults (Europe, every map)")
		os.remove(path)
	}

	@(test)
	ranked_menu_renders :: proc(t: ^testing.T) {
		// The spectator build has no ranked queue; spectator_ranked_test.odin covers that.
		if KRODIN_SPECTATOR { return }
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init()), "GLFW initialization failed") do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(1280, 720, "Ranked", nil, nil)
		if !testing.expect(t, window != nil, "hidden OpenGL window failed") do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		ui := ui_init()
		defer { ui_fini(ui); resource_cache_fini() }
		state: menuui.State
		if !testing.expect(t, menuui.init(&state, menu_measure_text, ui), "menu initialization failed") do return
		defer menuui.fini(&state)

		// Opening Ranked is navigation the client also hears.
		action := menuui.activate(&state, {action = {kind = .RANKED_OPEN}})
		testing.expect(t, action.kind == .RANKED_OPEN && state.page == .RANKED, "the Ranked button opens the page and tells the client")

		os.make_directory("bin/ranked-queue")
		Scene :: struct { name: string, ranked: menuui.Ranked_View, labels: []string, controls: int, dropdown: bool }
		scenes := []Scene{
			{"logged_out", {login_supported = true, status = "Ready to compete? Join the ranked queue!"}, {"Log in to play ranked", "Login"}, 2, false},
			{"idle", {logged_in = true, status = "Ready to compete? Join the ranked queue!", prefs = {excluded_maps = 0b0100000}}, {"FIND MATCH", "Region", "Europe", "Region: Europe", "[x] Burg", "[ ] Bureau", "[x] Frontier"}, 10, false},
			{"region_dropdown", {logged_in = true, status = "Ready to compete? Join the ranked queue!", prefs = {region_mask = 0b100}}, {"Asia", "Europe", "North America", "All regions", "Region: North America"}, 4, true},
			{"searching", {logged_in = true, phase = .SEARCHING, elapsed = 75, status = "Looking for match... (1:15)", prefs = {all_regions = true}}, {"CANCEL", "Looking for match... (1:15)", "Searching for match... (1:15)", "All regions"}, 10, false},
			{"cooldown", {logged_in = true, status = "On cooldown: queue again in 1:30", tone = .WARNING, popup_title = "Cooldown", popup_text = "You are on cooldown and cannot queue for ranked matches. Cooldown will end in 1:30"}, {"Cooldown", "OK"}, 1, false},
			{"rejoin", {logged_in = true, rejoin = true, status = "You are already in a Ranked game.", tone = .WARNING}, {"REJOIN", "You are already in a Ranked game."}, 10, false},
		}
		view := menuui.View{resolution = "1280 x 720", sensitivity = 1, bindings = menuui.default_bindings(), visuals = menuui.DEFAULT_VISUAL_SETTINGS}
		for size in ([?][2]i32{{1280, 720}, {1920, 1080}}) {
			glfw.SetWindowSize(window, size[0], size[1])
			glfw.PollEvents()
			gl.Viewport(0, 0, size[0], size[1])
			ui_update(ui, f32(size[0]), f32(size[1]))
			pixels := make([]u8, int(size[0]*size[1]*3))
			defer delete(pixels)
			for scene in scenes {
				view.ranked_queue = scene.ranked
				state.page = .RANKED
				state.settings_dropdown = scene.dropdown ? .RANKED_REGION : .NONE
				menuui.build(&state, view, {}, ui.width, ui.height, 1.0/60.0)
				commands := menuui.build(&state, view, {}, ui.width, ui.height, 1.0/60.0)
				testing.expect(t, state.errors == 0, "menu layout reported an error")
				overlay := clay.GetElementData(clay.ID("Overlay")).boundingBox
				screen := clay.BoundingBox{0, 0, f32(size[0]), f32(size[1])}
				testing.expectf(t, ranked_test_inside(overlay, screen), "%s: the ranked page fits at %v", scene.name, size)
				for label in scene.labels {
					found := false
					for command in commands.internalArray[:commands.length] {
						if command.commandType != .Text { continue }
						text := command.renderData.text.stringContents
						if string(text.chars[:text.length]) != label { continue }
						found = true
						testing.expectf(t, ranked_test_inside(command.boundingBox, screen), "%s: %q fits at %v", scene.name, label, size)
					}
					testing.expectf(t, found, "%s: %q is drawn at %v", scene.name, label, size)
				}
				testing.expectf(t, state.control_count == scene.controls, "%s: %d controls (expected %d)", scene.name, state.control_count, scene.controls)
				if scene.dropdown {
					options := clay.GetElementData(clay.ID("SettingsOptions")).boundingBox
					field := clay.GetElementData(clay.ID("RankedRegion")).boundingBox
					maps := clay.GetElementData(clay.ID("RankedMaps")).boundingBox
					testing.expectf(t, ranked_test_inside(options, overlay) && options.y >= field.y + field.height - 1 && options.y < maps.y + maps.height, "the region list opens below its field over the maps at %v: %v", size, options)
					on_top := false
					for command in commands.internalArray[:commands.length] {
						if command.commandType != .Text || command.zIndex <= 10 { continue }
						text := command.renderData.text.stringContents
						if string(text.chars[:text.length]) == "North America" { on_top = true }
					}
					testing.expectf(t, on_top, "the region list draws above the page at %v", size)
				}
				if len(scene.ranked.popup_title) > 0 {
					popup := clay.GetElementData(clay.ID("RankedPopup")).boundingBox
					testing.expectf(t, ranked_test_inside(popup, overlay), "the popup sits in the ranked page at %v", size)
				}
				gl.ClearColor(0.17, 0.17, 0.17, 1)
				ui_flush()
				gl.Clear(gl.COLOR_BUFFER_BIT)
				menu_render_commands(ui, commands)
				gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
				ui_flush()
				gl.ReadPixels(0, 0, size[0], size[1], gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
				testing.expect(t, stbi.write_png(fmt.ctprintf("bin/ranked-queue/%s_%dx%d.png", scene.name, size[0], size[1]), size[0], size[1], 3, &pixels[(size[1]-1)*size[0]*3], -size[0]*3) != 0, "preview PNG written")
			}
		}
		// The region dropdown: choosing closes it and tells the client; Escape
		// and a click outside close it; it stays closed while queued.
		view.ranked_queue = scenes[1].ranked
		state.page, state.settings_dropdown = .RANKED, .NONE
		menuui.build(&state, view, {}, 1280, 720, 1.0/60.0)
		opened := menuui.activate(&state, {action = {kind = .SETTINGS_DROPDOWN, index = i32(menuui.Settings_Dropdown.RANKED_REGION)}})
		testing.expect(t, opened.kind == .NONE && state.settings_dropdown == .RANKED_REGION && state.focus == clay.ID("SettingsOption", 1).id, "the dropdown opens on the current region")
		menuui.build(&state, view, {}, 1280, 720, 1.0/60.0)
		testing.expect(t, state.settings_dropdown == .RANKED_REGION, "the dropdown stays open on the ranked page")
		chosen := menuui.activate(&state, {action = {kind = .RANKED_REGION, index = 3}})
		testing.expect(t, chosen.kind == .RANKED_REGION && chosen.index == 3 && state.settings_dropdown == .NONE, "choosing closes the dropdown and tells the client")
		menuui.activate(&state, {action = {kind = .SETTINGS_DROPDOWN, index = i32(menuui.Settings_Dropdown.RANKED_REGION)}})
		menuui.build(&state, view, {}, 1280, 720, 1.0/60.0)
		state.previous = {}
		testing.expect(t, menuui.interact(&state, {escape = true}, view).kind == .NONE && state.settings_dropdown == .NONE && state.page == .RANKED, "Escape closes the dropdown, not the page")
		menuui.activate(&state, {action = {kind = .SETTINGS_DROPDOWN, index = i32(menuui.Settings_Dropdown.RANKED_REGION)}})
		menuui.build(&state, view, {}, 1280, 720, 1.0/60.0)
		state.previous = {}
		testing.expect(t, menuui.interact(&state, {down = true, pointer = {5, 700}}, view).kind == .NONE && state.settings_dropdown == .NONE, "a click outside closes the dropdown")
		state.settings_dropdown = .RANKED_REGION
		view.ranked_queue = scenes[3].ranked
		menuui.build(&state, view, {}, 1280, 720, 1.0/60.0)
		testing.expect(t, state.settings_dropdown == .NONE, "the dropdown closes while queued")

		// Escape closes the popup before the page.
		view.ranked_queue = scenes[4].ranked
		state.page = .RANKED
		menuui.build(&state, view, {}, 1280, 720, 1.0/60.0)
		state.previous = {}
		testing.expect(t, menuui.interact(&state, {escape = true}, view).kind == .RANKED_POPUP_CLOSE && state.page == .RANKED, "Escape closes Krunker's popup")
	}

	ranked_test_inside :: proc(box, parent: clay.BoundingBox) -> bool {
		return box.width > 0 && box.height > 0 && box.x >= parent.x-1 && box.y >= parent.y-1 && box.x+box.width <= parent.x+parent.width+1 && box.y+box.height <= parent.y+parent.height+1
	}
}
