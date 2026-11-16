package main

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
import curl "vendor:curl"
import glfw "vendor:glfw"
import access "../browser_access"
import shared "../shared"
import menuui "../menu"
import kproto "../krunker"

when ODIN_TEST {
	// A fake FRVR auth service and Krunker matchmaker on loopback. Nothing in
	// these tests contacts crucible.frvr.com, Krunker or any other real host.
	Guest_Test_Server :: struct {
		listener: net.TCP_Socket,
		port: int,
		thread: ^thread.Thread,
		stop: bool, // atomic
		mutex: sync.Mutex,
		// Configuration; change under the mutex while the server runs.
		delay_ms: int,
		login_status, refresh_status: int,
		login_body, refresh_body: string, // not owned
		seek_reject: int, // reject this many seek-game requests as "invalid token"
		seek_captcha: bool,
		// Observations, under the mutex.
		logins, refreshes, seeks, requests: int,
		login_headers_ok, login_body_ok: bool,
		refresh_seen: string, // owned
		seek_tokens: [dynamic]string, // owned
	}

	guest_test_server_start :: proc(server: ^Guest_Test_Server) -> bool {
		listener, err := net.listen_tcp({net.IP4_Loopback, 0})
		if err != nil { return false }
		endpoint, endpoint_err := net.bound_endpoint(listener)
		if endpoint_err != nil { net.close(listener); return false }
		server.listener, server.port = listener, endpoint.port
		if server.login_status == 0 { server.login_status = 201 }
		if server.refresh_status == 0 { server.refresh_status = 201 }
		server.thread = thread.create(guest_test_server_run)
		server.thread.data = server
		server.thread.init_context = context
		thread.start(server.thread)
		return true
	}

	guest_test_server_stop :: proc(server: ^Guest_Test_Server) {
		sync.atomic_store(&server.stop, true)
		net.close(server.listener)
		thread.join(server.thread)
		thread.destroy(server.thread)
		delete(server.refresh_seen)
		for token in server.seek_tokens { delete(token) }
		delete(server.seek_tokens)
	}

	guest_test_server_run :: proc(t: ^thread.Thread) {
		server := cast(^Guest_Test_Server)t.data
		for !sync.atomic_load(&server.stop) {
			socket, _, err := net.accept_tcp(server.listener)
			if err != nil { break }
			guest_test_server_session(server, socket)
			net.close(socket)
		}
	}

	guest_test_header :: proc(headers, name: string) -> string {
		lines := strings.split_lines(headers); defer delete(lines)
		for line in lines {
			colon := strings.index(line, ":")
			if colon > 0 && strings.equal_fold(strings.trim_space(line[:colon]), name) { return strings.trim_space(line[colon+1:]) }
		}
		return ""
	}

	guest_test_server_session :: proc(server: ^Guest_Test_Server, socket: net.TCP_Socket) {
		net.set_option(socket, .Receive_Timeout, 20 * time.Millisecond)
		request: [dynamic]byte
		defer delete(request)
		chunk: [4096]byte
		start := time.tick_now()
		header_end, content_length := -1, 0
		for {
			if time.duration_seconds(time.tick_since(start)) > 5 || sync.atomic_load(&server.stop) { return }
			if header_end < 0 {
				if i := strings.index(string(request[:]), "\r\n\r\n"); i >= 0 {
					header_end = i + 4
					content_length, _ = strconv.parse_int(guest_test_header(string(request[:i]), "Content-Length"))
				}
			}
			if header_end >= 0 && len(request) >= header_end + content_length { break }
			n, err := net.recv_tcp(socket, chunk[:])
			if err == .Timeout || err == .Would_Block { continue }
			if err != nil || n == 0 { return }
			append(&request, ..chunk[:n])
		}
		headers := string(request[:header_end])
		body := string(request[header_end:header_end + content_length])
		line := headers[:strings.index(headers, "\r\n")]
		sync.mutex_lock(&server.mutex)
		delay := server.delay_ms
		server.requests += 1
		sync.mutex_unlock(&server.mutex)
		for time.duration_milliseconds(time.tick_since(start)) < f64(delay) {
			if sync.atomic_load(&server.stop) { return }
			time.sleep(5 * time.Millisecond)
		}
		status, reply := 404, "not found"
		sync.mutex_lock(&server.mutex)
		switch {
		case strings.has_prefix(line, "POST /v1/auth/login "):
			server.logins += 1
			server.login_body_ok = body == `{"platform":"anonymous"}`
			server.login_headers_ok = guest_test_header(headers, "Content-Type") == "application/json" && guest_test_header(headers, "Origin") == "https://krunker.io"
			status, reply = server.login_status, server.login_body
		case strings.has_prefix(line, "POST /v1/auth/refresh "):
			server.refreshes += 1
			delete(server.refresh_seen)
			server.refresh_seen = strings.clone(body)
			status, reply = server.refresh_status, server.refresh_body
		case strings.has_prefix(line, "GET /generate-token "):
			status, reply = 200, "fixture-validation-token"
		case strings.has_prefix(line, "GET /game-list"):
			status, reply = 200, `{"games":[]}`
		case strings.has_prefix(line, "GET /seek-game?"):
			server.seeks += 1
			query := line[len("GET /seek-game?"):]
			if space := strings.index(query, " "); space >= 0 { query = query[:space] }
			for field in strings.split(query, "&", context.temp_allocator) {
				if strings.has_prefix(field, "accessToken=") {
					decoded, ok := net.percent_decode(field[len("accessToken="):])
					if ok { append(&server.seek_tokens, decoded) } else { delete(decoded) }
				}
			}
			switch {
			case server.seek_captcha:
				status, reply = 403, `{"error":"CaptchaRequired"}`
			case server.seeks <= server.seek_reject:
				status, reply = 401, `{"error":"invalid token"}`
			case:
				status, reply = 200, `{"host":"lobby-fixture.krunker.io","clientId":"fixture-client","gameId":"FRA:fixture","port":443}`
			}
		}
		sync.mutex_unlock(&server.mutex)
		response := fmt.aprintf("HTTP/1.1 %d Fixture\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", status, len(reply), reply)
		defer delete(response)
		net.send_tcp(socket, transmute([]byte)response)
	}

	// Unsigned fixture JWTs with an anonymous platform claim, like FRVR's.
	guest_test_jwt :: proc(tag: string, seconds: i64) -> string {
		payload := fmt.tprintf("%s%d%s%s%s", `{"exp":`, time.time_to_unix(time.now()) + seconds, `,"sub":"`, tag, `","extra":{"platform":"anonymous","verified":false}}`)
		encoded := base64.encode(transmute([]byte)payload, base64.ENC_URL_TABLE, options = {.No_Padding}); defer delete(encoded)
		return fmt.aprintf("eyJhbGciOiJIUzI1NiJ9.%s.fixturesig%s", string(encoded), tag)
	}

	Guest_Test_Pair :: struct { access_token, refresh_token, body: string }
	guest_test_pair :: proc(tag: string, access_seconds: i64 = 3600) -> Guest_Test_Pair {
		pair: Guest_Test_Pair
		pair.access_token = guest_test_jwt(fmt.tprintf("%saccess", tag), access_seconds)
		pair.refresh_token = guest_test_jwt(fmt.tprintf("%srefresh", tag), 86400)
		pair.body = strings.concatenate({`{"accessToken":"`, pair.access_token, `","refreshToken":"`, pair.refresh_token, `"}`})
		return pair
	}
	guest_test_pair_free :: proc(pair: ^Guest_Test_Pair) { delete(pair.access_token); delete(pair.refresh_token); delete(pair.body) }

	Guest_Test :: struct {
		server: Guest_Test_Server,
		client: Client,
		window: glfw.WindowHandle,
		previous_origin, previous_matchmaker, previous_cache, previous_log: string,
		previous_timeout: int,
		previous_captcha: proc(^Client) -> bool,
		log_path: string,
	}

	guest_test_connects: int
	guest_test_resolved: string

	// Mirrors krunker_ws_connect_ready up to the WebSocket: resolve the invite
	// through the (fake) matchmaker with the guest token, retrying once.
	guest_test_connect :: proc(client: ^Client, link: ^shared.Join_Link) -> bool {
		guest_test_connects += 1
		curl.global_init(curl.GLOBAL_DEFAULT); defer curl.global_cleanup()
		rejected: bool
		url, ok, error_text := krunker_ws_resolve_invite(link, client.guest.access_token, &rejected)
		if !ok {
			if client_guest_retry(client, rejected) { return true }
			krunker_ws_set_status(client, error_text); return false
		}
		delete(guest_test_resolved)
		guest_test_resolved = url
		krunker_ws_set_status(client, "Fixture lobby resolved.")
		return true
	}
	guest_test_persists: int
	guest_test_persist :: proc(value: string) -> bool { guest_test_persists += 1; return true }
	guest_test_no_cache :: proc() -> string { return "" }

	guest_test_begin :: proc(t: ^testing.T, g: ^Guest_Test, name: string) -> bool {
		guest_test_connects, guest_test_persists = 0, 0
		if !testing.expect(t, bool(glfw.Init()), "GLFW initialization failed") { return false }
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
		g.window = glfw.CreateWindow(320, 240, "Guest join", nil, nil)
		if !testing.expect(t, g.window != nil, "hidden window failed") { glfw.Terminate(); return false }
		g.client.window = g.window
		if !testing.expect(t, guest_test_server_start(&g.server), "fake auth/matchmaker server") { return false }
		g.previous_origin, g.previous_matchmaker, g.previous_cache = guest_auth_origin, krunker_matchmaker_origin, guest_cache_directory
		g.previous_timeout, g.previous_captcha, g.previous_log = guest_auth_timeout_ms, krunker_captcha_start, kproto.network_log_path
		guest_auth_origin = fmt.aprintf("http://127.0.0.1:%d/v1/auth", g.server.port)
		krunker_matchmaker_origin = fmt.aprintf("http://127.0.0.1:%d", g.server.port)
		guest_cache_directory = fmt.aprintf("bin/guest-cache-%s", name)
		g.log_path = fmt.aprintf("bin/guest-%s.log", name)
		os.remove(g.log_path)
		kproto.network_log_close()
		kproto.network_log_path = g.log_path
		return true
	}

	guest_test_end :: proc(g: ^Guest_Test) {
		client := &g.client
		client_access_cancel(client)
		delete(client.access.token); delete(client.access.assignment_url)
		client_guest_shutdown(client)
		krunker_ws_disconnect(&client.krunker)
		kproto.krunker_world_reset(&client.krunker_world)
		delete(client.join_status); delete(client.selection_status)
		shared.join_link_free(&client.join_link)
		guest_test_server_stop(&g.server)
		when ODIN_OS == .Windows { access.cache_invalidate(guest_cache_directory, access.GUEST_CACHE_NAME) }
		os.remove_all(guest_cache_directory)
		delete(guest_auth_origin); delete(krunker_matchmaker_origin); delete(guest_cache_directory)
		guest_auth_origin, krunker_matchmaker_origin, guest_cache_directory = g.previous_origin, g.previous_matchmaker, g.previous_cache
		guest_auth_timeout_ms, krunker_captcha_start = g.previous_timeout, g.previous_captcha
		kproto.network_log_close()
		kproto.network_log_path = g.previous_log
		kproto.network_log_clear_secrets()
		delete(g.log_path)
		delete(guest_test_resolved); guest_test_resolved = ""
		glfw.DestroyWindow(g.window)
		glfw.Terminate()
	}

	// Ticks like the frame loop until no sign-in is pending. Records the
	// longest tick while the worker was still busy.
	guest_test_wait :: proc(client: ^Client, connect: proc(^Client, ^shared.Join_Link) -> bool = guest_test_connect, persist: proc(string) -> bool = guest_test_persist, longest_ms: ^f64 = nil, seconds: f64 = 5) -> bool {
		start := time.tick_now()
		for time.duration_seconds(time.tick_since(start)) < seconds {
			tick := time.tick_now()
			client_guest_tick(client, connect, persist)
			if longest_ms != nil && client.guest.status == .PENDING { longest_ms^ = max(longest_ms^, time.duration_milliseconds(time.tick_since(tick))) }
			if client.guest.job == nil && client.guest.status != .PENDING { return true }
			time.sleep(2 * time.Millisecond)
		}
		return false
	}

	guest_test_log_clean :: proc(t: ^testing.T, g: ^Guest_Test, secrets: []string) {
		kproto.network_log_close()
		data, err := os.read_entire_file_from_path(g.log_path, context.allocator)
		if !testing.expect(t, err == nil, "network log written") { return }
		defer delete(data)
		text := string(data)
		testing.expect(t, strings.contains(text, "[guest-auth]"), "guest sign-in is logged")
		for secret in secrets {
			if len(secret) == 0 { continue }
			encoded := kproto.network_url_encode(secret); defer delete(encoded)
			testing.expectf(t, !strings.contains(text, secret) && !strings.contains(text, encoded), "a guest token reached the network log: %s", secret[len(secret)-16:])
		}
	}

	@(test)
	guest_join_from_menu_signs_in_and_uses_the_token :: proc(t: ^testing.T) {
		g: Guest_Test
		if !guest_test_begin(t, &g, "success") { return }
		defer guest_test_end(&g)
		pair := guest_test_pair("first"); defer guest_test_pair_free(&pair)
		g.server.login_body, g.server.delay_ms = pair.body, 250
		client := &g.client
		menuui.set_invite(&client.menu, "https://krunker.io/?game=FRA:fixture")
		// The menu's Play as guest action queues a guest join, like Join.
		menu_apply_action(client, {kind = .JOIN_GUEST})
		testing.expect(t, client.guest.active && client.join_queued == 2 && client.join_status == "Signing in as guest...")
		// client_tick runs the queued join two frames later.
		start := time.tick_now()
		client_join_invite(client)
		join_ms := time.duration_milliseconds(time.tick_since(start))
		testing.expect(t, client.guest.status == .PENDING && client.access.status == .IDLE, "guest sign-in never starts the browser helper")
		testing.expect(t, client.join_status == "Signing in as guest...")
		// A duplicate Join while signing in is ignored.
		menu_apply_action(client, {kind = .JOIN_LINK})
		testing.expect(t, client.join_queued == 0 && client.guest.active)
		longest: f64
		testing.expect(t, guest_test_wait(client, guest_test_connect, guest_cache_save, &longest), "sign-in finishes before its deadline")
		testing.expectf(t, join_ms < 50 && longest < 50, "the frame thread never waits for the 250 ms login (join %.1f ms, longest tick %.1f ms)", join_ms, longest)
		testing.expect(t, client.guest.status == .READY && client.guest.access_token == pair.access_token && client.guest.refresh_token == pair.refresh_token)
		sync.mutex_lock(&g.server.mutex)
		testing.expect(t, g.server.logins == 1 && g.server.login_body_ok && g.server.login_headers_ok, "POST /v1/auth/login with Content-Type: application/json and {\"platform\":\"anonymous\"}")
		testing.expect(t, len(g.server.seek_tokens) == 1 && g.server.seek_tokens[0] == pair.access_token, "seek-game receives the guest access token")
		sync.mutex_unlock(&g.server.mutex)
		encoded := kproto.network_url_encode(pair.access_token); defer delete(encoded)
		testing.expect(t, strings.contains(guest_test_resolved, fmt.tprintf("&at=%s", encoded)), "the game socket URL carries the guest token")
		testing.expect(t, client.join_status == "Fixture lobby resolved." && guest_test_connects == 1)
		// Status text is redacted too.
		krunker_ws_set_status(client, fmt.tprintf("diagnostic %s %s", pair.access_token, pair.refresh_token))
		testing.expect(t, !strings.contains(client.join_status, pair.access_token) && !strings.contains(client.join_status, pair.refresh_token))
		when ODIN_OS == .Windows {
			// Krunker's SDK keeps the guest pair in localStorage; Krodin keeps it
			// DPAPI-encrypted. A new session reuses it without a login.
			cached := guest_cache_load(); defer delete(cached)
			testing.expect(t, len(cached) > 0 && !strings.contains(cached, "\x00") && guest_test_cache_matches(cached, &pair))
			other: Client
			other.guest.active = true
			other.join_link, _ = shared.join_link_parse("https://krunker.io/?game=FRA:fixture")
			testing.expect(t, client_guest_connect(&other, &other.join_link, guest_test_connect))
			testing.expect(t, other.guest.status == .READY && other.guest.access_token == pair.access_token && guest_test_connects == 2)
			sync.mutex_lock(&g.server.mutex)
			testing.expect(t, g.server.logins == 1, "cached guest access needs no login")
			sync.mutex_unlock(&g.server.mutex)
			client_guest_shutdown(&other)
			delete(other.join_status)
			shared.join_link_free(&other.join_link)
		}
		guest_test_log_clean(t, &g, {pair.access_token, pair.refresh_token})
	}

	guest_test_cache_matches :: proc(cached: string, pair: ^Guest_Test_Pair) -> bool {
		access_token, refresh_token, ok := guest_cache_parse(cached)
		defer { delete(access_token); delete(refresh_token) }
		return ok && access_token == pair.access_token && refresh_token == pair.refresh_token
	}

	@(test)
	guest_sign_in_reports_http_errors_and_malformed_json :: proc(t: ^testing.T) {
		g: Guest_Test
		if !guest_test_begin(t, &g, "errors") { return }
		defer guest_test_end(&g)
		client := &g.client
		client.guest.active, client.guest.cache_loaded = true, true
		client.join_link, _ = shared.join_link_parse("https://krunker.io/?game=FRA:fixture")
		expired := guest_test_pair("expired", 30); defer guest_test_pair_free(&expired)
		cases := []struct { status: int, body, expect: string }{
			{503, `{"error":"maintenance window"}`, "Guest sign-in failed: HTTP 503, body={\"error\":\"maintenance window\"}"},
			{401, `{"message":"invalid credentials"}`, "Guest sign-in failed: HTTP 401"},
			{201, `not json`, "returned no usable token pair (HTTP 201)"},
			{201, `{"accessToken":"abc"}`, "returned no usable token pair"},
			{201, expired.body, "returned no usable token pair"}, // like the SDK: access must outlive exp - 60 s
		}
		for c in cases {
			sync.mutex_lock(&g.server.mutex)
			g.server.login_status, g.server.login_body = c.status, c.body
			sync.mutex_unlock(&g.server.mutex)
			testing.expect(t, client_guest_connect(client, &client.join_link, guest_test_connect, guest_test_no_cache))
			testing.expect(t, guest_test_wait(client))
			testing.expectf(t, client.guest.status == .ERROR && strings.contains(client.join_status, c.expect), "status for HTTP %d %s: %s", c.status, c.body, client.join_status)
			testing.expect(t, guest_test_connects == 0 && guest_test_persists == 0 && len(client.guest.access_token) == 0, "a failed sign-in never joins")
		}
		guest_test_log_clean(t, &g, {expired.access_token, expired.refresh_token})
	}

	@(test)
	guest_sign_in_times_out_and_cancels_without_stalling :: proc(t: ^testing.T) {
		g: Guest_Test
		if !guest_test_begin(t, &g, "timeout") { return }
		defer guest_test_end(&g)
		pair := guest_test_pair("late"); defer guest_test_pair_free(&pair)
		g.server.login_body, g.server.delay_ms = pair.body, 3000
		client := &g.client
		client.guest.cache_loaded = true
		menuui.set_invite(&client.menu, "https://krunker.io/?game=FRA:fixture")
		// Timeout: the worker's request gives up; the frame keeps running.
		guest_auth_timeout_ms = 300
		menu_apply_action(client, {kind = .JOIN_GUEST})
		client_join_invite(client)
		longest: f64
		start := time.tick_now()
		testing.expect(t, guest_test_wait(client, longest_ms = &longest, seconds = 4))
		elapsed := time.duration_milliseconds(time.tick_since(start))
		testing.expectf(t, client.guest.status == .ERROR && client.join_status == "Guest sign-in timed out. Check your connection and retry Play as guest.", "timeout status: %s", client.join_status)
		testing.expectf(t, elapsed < 1500 && longest < 50, "timeout after %.0f ms, longest tick %.1f ms", elapsed, longest)
		testing.expect(t, guest_test_connects == 0)
		// Cancel: returns at once; the worker aborts and is reaped.
		guest_auth_timeout_ms = 15000
		for cycle in 0 ..< 3 {
			menu_apply_action(client, {kind = .JOIN_GUEST})
			client_join_invite(client)
			testing.expect(t, client.guest.status == .PENDING)
			time.sleep(30 * time.Millisecond)
			tick := time.tick_now()
			menu_apply_action(client, {kind = .CANCEL_JOIN})
			cancel_ms := time.duration_milliseconds(time.tick_since(tick))
			testing.expectf(t, cancel_ms < 20 && client.guest.status == .IDLE && client.guest.job == nil && client.join_status == "Join cancelled.", "cycle %d cancel took %.1f ms", cycle, cancel_ms)
			reap_start := time.tick_now()
			for len(client.guest.abandoned) > 0 && time.duration_seconds(time.tick_since(reap_start)) < 3 {
				client_guest_tick(client, guest_test_connect, guest_test_persist)
				time.sleep(5 * time.Millisecond)
			}
			testing.expectf(t, len(client.guest.abandoned) == 0, "cycle %d: the cancelled worker exits (%.0f ms)", cycle, time.duration_milliseconds(time.tick_since(reap_start)))
		}
		testing.expect(t, guest_test_connects == 0 && len(client.guest.access_token) == 0, "a cancelled sign-in never joins")
		// Shutdown with a request in flight joins the worker within a second or so.
		menu_apply_action(client, {kind = .JOIN_GUEST})
		client_join_invite(client)
		time.sleep(30 * time.Millisecond)
		tick := time.tick_now()
		client_guest_shutdown(client)
		testing.expectf(t, time.duration_milliseconds(time.tick_since(tick)) < 2500, "shutdown waited %.0f ms", time.duration_milliseconds(time.tick_since(tick)))
	}

	@(test)
	guest_expiry_refreshes_and_rejection_retries_once :: proc(t: ^testing.T) {
		g: Guest_Test
		if !guest_test_begin(t, &g, "refresh") { return }
		defer guest_test_end(&g)
		client := &g.client
		client.guest.active, client.guest.cache_loaded = true, true
		client.join_link, _ = shared.join_link_parse("https://krunker.io/?game=FRA:fixture")
		old := guest_test_pair("old", 30); defer guest_test_pair_free(&old) // inside the SDK's 60 s margin
		renewed := guest_test_pair("renewed"); defer guest_test_pair_free(&renewed)
		fresh := guest_test_pair("fresh"); defer guest_test_pair_free(&fresh)
		retry := guest_test_pair("retry"); defer guest_test_pair_free(&retry)

		// 1. Expiring access + valid refresh token: POST /refresh, no login.
		client.guest.access_token, client.guest.refresh_token = strings.clone(old.access_token), strings.clone(old.refresh_token)
		g.server.refresh_body = renewed.body
		testing.expect(t, client_guest_connect(client, &client.join_link, guest_test_connect))
		testing.expect(t, client.join_status == "Renewing guest access...")
		testing.expect(t, guest_test_wait(client))
		sync.mutex_lock(&g.server.mutex)
		testing.expect(t, g.server.refreshes == 1 && g.server.logins == 0 && g.server.refresh_seen == strings.concatenate({`{"refreshToken":"`, old.refresh_token, `"}`}, context.temp_allocator))
		testing.expect(t, len(g.server.seek_tokens) == 1 && g.server.seek_tokens[0] == renewed.access_token)
		sync.mutex_unlock(&g.server.mutex)
		testing.expect(t, client.guest.access_token == renewed.access_token && client.guest.refresh_token == renewed.refresh_token && guest_test_connects == 1)

		// 2. A rejected refresh falls back to one anonymous login.
		delete(client.guest.access_token); client.guest.access_token = strings.clone(old.access_token)
		sync.mutex_lock(&g.server.mutex)
		g.server.refresh_status, g.server.refresh_body, g.server.login_body = 401, `{"error":"invalid refresh token"}`, fresh.body
		sync.mutex_unlock(&g.server.mutex)
		testing.expect(t, client_guest_connect(client, &client.join_link, guest_test_connect))
		testing.expect(t, guest_test_wait(client))
		sync.mutex_lock(&g.server.mutex)
		testing.expect(t, g.server.refreshes == 2 && g.server.logins == 1)
		sync.mutex_unlock(&g.server.mutex)
		testing.expect(t, client.guest.access_token == fresh.access_token && guest_test_connects == 2)

		// 3. seek-game rejects the token once: one new token, one retry, joined.
		sync.mutex_lock(&g.server.mutex)
		g.server.seek_reject, g.server.refresh_status, g.server.refresh_body = g.server.seeks + 1, 201, retry.body
		sync.mutex_unlock(&g.server.mutex)
		testing.expect(t, client_guest_connect(client, &client.join_link, guest_test_connect), "fresh access is reused without a request")
		testing.expect(t, client.guest.status == .PENDING && client.guest.retried)
		testing.expect(t, guest_test_wait(client))
		sync.mutex_lock(&g.server.mutex)
		testing.expect(t, g.server.seeks == 4 && g.server.refreshes == 3 && g.server.logins == 1 && g.server.seek_tokens[3] == retry.access_token)
		sync.mutex_unlock(&g.server.mutex)
		testing.expect(t, client.guest.status == .READY && client.join_status == "Fixture lobby resolved." && guest_test_connects == 4)

		// 4. Always rejected, through the real connect path: exactly one retry.
		client.guest.retried = false
		sync.mutex_lock(&g.server.mutex)
		g.server.seek_reject = 1000
		seeks_before, auth_before := g.server.seeks, g.server.logins + g.server.refreshes
		sync.mutex_unlock(&g.server.mutex)
		client_guest_connect(client, &client.join_link, krunker_ws_connect_ready)
		testing.expect(t, guest_test_wait(client, krunker_ws_connect_ready))
		for _ in 0 ..< 20 { client_guest_tick(client, krunker_ws_connect_ready, guest_test_persist); time.sleep(10 * time.Millisecond) }
		sync.mutex_lock(&g.server.mutex)
		testing.expectf(t, g.server.seeks - seeks_before == 2 && g.server.logins + g.server.refreshes - auth_before == 1, "seeks=%d auth=%d", g.server.seeks - seeks_before, g.server.logins + g.server.refreshes - auth_before)
		sync.mutex_unlock(&g.server.mutex)
		testing.expectf(t, client.guest.status == .ERROR && client.guest.job == nil && strings.contains(client.join_status, "seek-game failed: HTTP 401"), "status: %s", client.join_status)
		testing.expect(t, !client.krunker.connected)
		guest_test_log_clean(t, &g, {old.access_token, old.refresh_token, renewed.access_token, renewed.refresh_token, fresh.access_token, fresh.refresh_token, retry.access_token, retry.refresh_token})
	}

	guest_test_helper_missing :: proc(client: ^Client) -> bool { return false }
	guest_test_helper_started :: proc(client: ^Client) -> bool { return client.access.captcha_pending }
	guest_test_proof_connect :: proc(client: ^Client, link: ^shared.Join_Link) -> bool {
		// krunker_ws_connect_ready would combine this proof with the guest token.
		if !client.guest.active || client.access.captcha_token != "fixture-proof+/=" { panic("the proof must continue the guest join") }
		guest_test_connects += 1
		return true
	}

	@(test)
	guest_captcha_uses_the_verification_flow_or_explains_why_not :: proc(t: ^testing.T) {
		when ODIN_OS == .Windows {
			g: Guest_Test
			if !guest_test_begin(t, &g, "captcha") { return }
			defer guest_test_end(&g)
			client := &g.client
			pair := guest_test_pair("captcha"); defer guest_test_pair_free(&pair)
			client.guest.active, client.guest.cache_loaded = true, true
			client.guest.access_token, client.guest.refresh_token = strings.clone(pair.access_token), strings.clone(pair.refresh_token)
			client.join_link, _ = shared.join_link_parse("https://krunker.io/?game=FRA:fixture")
			g.server.seek_captcha = true
			// No browser helper: a clear message instead of a silent failure.
			krunker_captcha_start = guest_test_helper_missing
			testing.expect(t, !krunker_ws_connect_ready(client, &client.join_link))
			testing.expect(t, client.join_status == GUEST_CAPTCHA_HELPER_TEXT && client.guest.status != .PENDING)
			// With the helper, the proof continues the guest join.
			krunker_captcha_start = guest_test_helper_started
			client.access.captcha_retried, client.access.status = false, .IDLE
			testing.expect(t, krunker_ws_connect_ready(client, &client.join_link) && client.access.status == .PENDING && client.access.captcha_pending)
			client_access_tick(client, access_test_captcha_poll, guest_test_proof_connect, access_test_persist)
			testing.expect(t, guest_test_connects == 1 && client.guest.access_token == pair.access_token)
			delete(client.access.captcha_token); client.access.captcha_token = ""
			// A browser socket handoff carries the browser's own account: refused.
			client.access.captcha_retried, client.access.status = false, .IDLE
			testing.expect(t, krunker_ws_connect_ready(client, &client.join_link) && client.access.status == .PENDING)
			client_access_tick(client, access_test_assignment_poll, guest_test_proof_connect, access_test_persist)
			testing.expect(t, client.access.status == .ERROR && client.join_status == GUEST_CAPTCHA_IDENTITY_TEXT && guest_test_connects == 1)
			testing.expect(t, len(client.access.token) == 0 && client.guest.access_token == pair.access_token, "the guest identity is kept")
			sync.mutex_lock(&g.server.mutex)
			testing.expect(t, g.server.logins == 0 && g.server.refreshes == 0, "a CAPTCHA is not a token rejection")
			sync.mutex_unlock(&g.server.mutex)
		}
	}

	@(test)
	guest_tokens_are_redacted_from_logs :: proc(t: ^testing.T) {
		defer kproto.network_log_clear_secrets()
		guest: Client_Guest
		pair := guest_test_pair("redact"); defer guest_test_pair_free(&pair)
		guest.access_token, guest.refresh_token = strings.clone(pair.access_token), strings.clone(pair.refresh_token)
		defer { delete(guest.access_token); delete(guest.refresh_token) }
		guest_register_secrets(&guest)
		encoded := kproto.network_url_encode(pair.refresh_token); defer delete(encoded)
		// Registered secrets, the refreshToken/accessToken keys and bare JWTs.
		for text in ([]string{pair.body, fmt.tprintf("refresh=%s", encoded), fmt.tprintf("free text %s", pair.refresh_token)}) {
			safe := kproto.network_log_safe(text); defer delete(safe)
			testing.expectf(t, !strings.contains(safe, pair.access_token) && !strings.contains(safe, pair.refresh_token) && !strings.contains(safe, encoded), "leaked: %s", safe)
		}
		kproto.network_log_clear_secrets()
		unregistered := kproto.network_log_safe(`{"refreshToken":"opaque-refresh-value","accessToken":"opaque-access-value"}`); defer delete(unregistered)
		testing.expect(t, !strings.contains(unregistered, "opaque-refresh-value") && !strings.contains(unregistered, "opaque-access-value"))
	}

	@(test)
	guest_cache_and_expiry_parsing :: proc(t: ^testing.T) {
		pair := guest_test_pair("parse"); defer guest_test_pair_free(&pair)
		now := time.time_to_unix(time.now())
		exp, ok := access.token_expiry(pair.access_token)
		testing.expect(t, ok && exp > now + 3500 && access.token_fresh(pair.access_token, now) && !access.token_fresh(pair.access_token, exp - 60))
		testing.expect(t, access.token_state(pair.access_token, now) == .GUEST, "account login still rejects guest tokens")
		guest: Client_Guest
		guest.access_token, guest.refresh_token = pair.access_token, pair.refresh_token
		value := guest_cache_value(&guest); defer delete(value)
		testing.expect(t, guest_test_cache_matches(value, &pair))
		for bad in ([]string{"", "v1\nonly", "v2\na.b.c\nd.e.f", "v1\nbad token\na.b.c"}) {
			a, r, valid := guest_cache_parse(bad)
			testing.expect(t, !valid && len(a) == 0 && len(r) == 0)
		}
	}

	@(test)
	nameless_players_are_named_guest_by_sid :: proc(t: ^testing.T) {
		world: kproto.Krunker_World_State
		defer kproto.krunker_world_reset(&world)
		records := make([]kproto.Krunker_Msgpack_Value, 53 * 2); defer delete(records)
		for &value in records { value = kproto.krunker_msgpack_nil() }
		records[1], records[5] = i64(7), ""
		records[53 + 1], records[53 + 5] = i64(9), "Named"
		packet := []kproto.Krunker_Msgpack_Value{i64(0), records}
		testing.expect(t, kproto.krunker_world_apply_add_players(&world, packet))
		names: [2]string
		for player in world.players {
			if player.sid == 7 { names[0] = player.name }
			if player.sid == 9 { names[1] = player.name }
		}
		testing.expectf(t, names[0] == "Guest_7" && names[1] == "Named", "names: %v", names)
	}
}
