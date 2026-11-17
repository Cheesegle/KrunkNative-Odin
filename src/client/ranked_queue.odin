package main

// Krunker's ranked matchmaking queue, following game.min.js (class DLe,
// instance "dx", and the ranked menu component DXe):
//
// - connectWebSocket opens
//   <GAMEFRONTEND_URI with http->ws>/v1/matchmaking/queue?token=<encodeURIComponent(FRVR.auth.getFreshAccessToken())>&maps=<preferredMaps>&regions=<regions>
//   with preferredMaps [0,2,4,11,14,17,42] and regions [C2().regionAcronym]
//   or, with "All regions", Object.keys({as,eu,na}). The client sends nothing.
// - Messages are JSON {type, payload}. QUEUE_STATUS QUEUED starts the
//   "Searching" state and its timer; QUEUE_STATUS MATCHED stores
//   payload.assignment, plays pop_3 at 0.15, waits one second and accepts:
//   it sends JOINED_RANK ("joinedRank") on the current game socket, connects to
//   assignment.connection ("host[:port]", port 3000 when absent) like any
//   game server with the account token (at=), and clears the queue.
// - ERROR clears the queue and shows a popup by payload.code; ALREADY_IN_MATCH
//   keeps payload.payload.serverUrl for REJOIN, COOLDOWN shows
//   payload.payload.cooldown (ms). A message that fails to parse is an
//   internal error. Other types and statuses are ignored.
// - Closing the socket is leaving the queue; a server close clears it.
// - Opening the ranked menu asks GET <API_URI>/ranked/me/connection (Bearer
//   access) and, when data.serverUrl is set, offers REJOIN.
//
// Ranked needs an account: a guest (anonymous FRVR) token or no token never
// opens the socket. The socket runs on a worker thread; the frame thread only
// polls its inbox. network_log is not thread-safe, so only the frame thread logs.

import "base:intrinsics"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import curl "vendor:curl"
import access "../browser_access"
import shared "../shared"
import menuui "../menu"
import kproto "../krunker"

// Krunker's P4 (GAMEFRONTEND_URI) and wf (API_URI). Tests use loopback.
ranked_gamefrontend_origin := "https://gamefrontend.svc.krunker.io"
ranked_api_origin := "https://api.krunker.io"
ranked_connect_timeout_ms := 8000
ranked_check_timeout_ms := 10000
// Krunker waits one second after MATCHED (pop_3) before acceptMatch.
RANKED_ACCEPT_DELAY :: time.Second
RANKED_MESSAGE_LIMIT :: 1 << 20

// Account access for ranked. Tests replace it so no cache or helper is used.
ranked_access_select: proc(client: ^Client, now: i64) -> bool = ranked_access_select_default
ranked_access_select_default :: proc(client: ^Client, now: i64) -> bool { return client_access_select(client, now) }

Ranked_Error_Code :: enum { INTERNAL_ERROR, NO_RANK_DATA, MIN_LEVEL_REQUIREMENT, COOLDOWN, ALREADY_IN_MATCH }
Ranked_Message_Kind :: enum { IGNORED, QUEUED, MATCHED, ERROR, INVALID }

// One parsed queue message. Strings are owned; free with ranked_message_free.
Ranked_Message :: struct {
	kind: Ranked_Message_Kind,
	code: Ranked_Error_Code,
	message: string, // ERROR payload.message
	cooldown_ms: i64, // COOLDOWN payload.payload.cooldown
	server_url: string, // ALREADY_IN_MATCH payload.payload.serverUrl
	connection: string, // MATCHED payload.assignment.connection
	map_name, region: string, // MATCHED payload.assignment.extensions
}

ranked_message_free :: proc(message: ^Ranked_Message) {
	delete(message.message); delete(message.server_url); delete(message.connection)
	delete(message.map_name); delete(message.region)
	message^ = {}
}

@(private = "file")
ranked_json_text :: proc(object: json.Object, key: string) -> string {
	if value, ok := object[key].(json.String); ok { return strings.clone(string(value)) }
	return ""
}

ranked_message_parse :: proc(text: string) -> (message: Ranked_Message) {
	value, err := json.parse_string(text, parse_integers = true)
	if err != .None { message.kind = .INVALID; return }
	defer json.destroy_value(value)
	root, is_object := value.(json.Object)
	if !is_object { message.kind = .INVALID; return }
	kind, _ := root["type"].(json.String)
	payload, has_payload := root["payload"].(json.Object)
	switch string(kind) {
	case "QUEUE_STATUS":
		// Krunker reads payload.status unguarded: a missing payload throws into
		// its "Failed to parse server message" path.
		if !has_payload { message.kind = .INVALID; return }
		status, _ := payload["status"].(json.String)
		switch string(status) {
		case "QUEUED": message.kind = .QUEUED
		case "MATCHED":
			assignment, has_assignment := payload["assignment"].(json.Object)
			connection, has_connection := assignment["connection"].(json.String)
			if !has_assignment || !has_connection || len(connection) == 0 { message.kind = .INVALID; return }
			message.kind = .MATCHED
			message.connection = strings.clone(string(connection))
			if extensions, ok := assignment["extensions"].(json.Object); ok {
				if name, ok := extensions["map"].(json.String); ok { message.map_name = strings.clone(strings.trim_space(string(name))) }
				message.region = ranked_json_text(extensions, "region")
			}
		case: message.kind = .IGNORED
		}
	case "ERROR":
		if !has_payload { message.kind = .INVALID; return }
		message.kind = .ERROR
		code, _ := payload["code"].(json.String)
		switch string(code) {
		case "NO_RANK_DATA": message.code = .NO_RANK_DATA
		case "MIN_LEVEL_REQUIREMENT": message.code = .MIN_LEVEL_REQUIREMENT
		case "COOLDOWN": message.code = .COOLDOWN
		case "ALREADY_IN_MATCH": message.code = .ALREADY_IN_MATCH
		case: message.code = .INTERNAL_ERROR // Krunker's default case.
		}
		message.message = ranked_json_text(payload, "message")
		if inner, ok := payload["payload"].(json.Object); ok {
			message.server_url = ranked_json_text(inner, "serverUrl")
			#partial switch cooldown in inner["cooldown"] {
			case json.Integer: message.cooldown_ms = i64(cooldown)
			case json.Float: message.cooldown_ms = i64(cooldown)
			}
		}
	case: message.kind = .IGNORED
	}
	return
}

// The maps and regions to queue, in Krunker's orders.
ranked_selected_maps :: proc(prefs: menuui.Ranked_Preferences, allocator := context.temp_allocator) -> []i32 {
	mask := menuui.ranked_map_mask(prefs)
	maps := make([dynamic]i32, 0, len(menuui.RANKED_MAPS), allocator)
	for id, i in menuui.RANKED_MAPS { if mask & (1 << u32(i)) != 0 { append(&maps, id) } }
	return maps[:]
}

ranked_selected_regions :: proc(prefs: menuui.Ranked_Preferences, allocator := context.temp_allocator) -> []string {
	// One region, or Object.keys({as, eu, na}) for All regions.
	choice := menuui.ranked_region_choice(prefs)
	regions := make([dynamic]string, 0, len(menuui.RANKED_REGIONS), allocator)
	for region, i in menuui.RANKED_REGIONS { if choice == menuui.RANKED_ALL_REGIONS_CHOICE || choice == i32(i) { append(&regions, region) } }
	return regions[:]
}

// connectWebSocket's URL. The token is percent-encoded like encodeURIComponent.
ranked_queue_url :: proc(origin, token: string, maps: []i32, regions: []string) -> string {
	builder := strings.builder_make()
	// P4.replace("http","ws"): https -> wss, http -> ws.
	if strings.has_prefix(origin, "http") { strings.write_string(&builder, "ws"); strings.write_string(&builder, origin[4:]) }
	else { strings.write_string(&builder, origin) }
	encoded := kproto.network_url_encode(token); defer delete(encoded)
	strings.write_string(&builder, "/v1/matchmaking/queue?token=")
	strings.write_string(&builder, encoded)
	strings.write_string(&builder, "&maps=")
	for id, i in maps {
		if i > 0 { strings.write_byte(&builder, ',') }
		strings.write_int(&builder, int(id))
	}
	strings.write_string(&builder, "&regions=")
	for region, i in regions {
		if i > 0 { strings.write_byte(&builder, ',') }
		strings.write_string(&builder, region)
	}
	return strings.to_string(builder)
}

// Krunker's Mme: "host[:port]" with port 3000 when absent, then iY builds
// wss://host[:port]/ws?...&at=<access>. Krodin only sends the account token to
// Krunker's own hosts.
ranked_match_url :: proc(connection, token: string) -> (string, bool) {
	parts := strings.split(connection, ":"); defer delete(parts)
	if len(parts) == 0 || len(parts) > 2 { return "", false }
	host := parts[0]
	port: i64 = 3000
	if len(parts) == 2 {
		parsed, ok := strconv.parse_i64(parts[1])
		if !ok || parsed <= 0 || parsed > 65535 { return "", false }
		port = parsed
	}
	if len(host) == 0 || len(host) > 253 || !strings.has_suffix(host, ".krunker.io") { return "", false }
	for b in host { if !(b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '-' || b == '.' || b == '_') { return "", false } }
	encoded := kproto.network_url_encode(token); defer delete(encoded)
	if access.assignment_uses_explicit_port(host, port) { return fmt.aprintf("wss://%s:%d/ws?at=%s", host, port, encoded), true }
	return fmt.aprintf("wss://%s/ws?at=%s", host, encoded), true
}

// Redacts the token in every form it may appear in a log line.
ranked_register_secret :: proc(token: string) {
	if len(token) == 0 { return }
	kproto.network_log_secret(token)
	encoded := kproto.network_url_encode(token); defer delete(encoded)
	kproto.network_log_secret(encoded)
}

// The queue socket, owned by the worker until done is set.
Ranked_Job :: struct {
	url: string,
	timeout_ms: int,
	cancel, done, opened: bool, // atomic
	mutex: sync.Mutex,
	inbox: [dynamic]string, // Complete text messages, under mutex.
	code: curl.code,
	status: i64,
	error_text: string,
	server_closed: bool,
	close_code: int,
	thread: ^thread.Thread,
}

@(private = "file")
ranked_job_push :: proc(job: ^Ranked_Job, message: []byte) {
	sync.mutex_lock(&job.mutex)
	append(&job.inbox, strings.clone(string(message)))
	sync.mutex_unlock(&job.mutex)
}

ranked_job_run :: proc(data: rawptr) {
	cpu_pin_current_thread_off_game_core()
	job := cast(^Ranked_Job)data
	defer intrinsics.atomic_store(&job.done, true)
	handle := curl.easy_init()
	if handle == nil { job.code = .E_FAILED_INIT; return }
	defer curl.easy_cleanup(handle)
	url_c := strings.clone_to_cstring(job.url); defer delete(url_c)
	error_buffer: [curl.ERROR_SIZE]byte
	headers: ^curl.slist
	headers = curl.slist_append(headers, "Origin: https://krunker.io")
	headers = curl.slist_append(headers, "Referer: https://krunker.io/")
	headers = curl.slist_append(headers, "User-Agent: Mozilla/5.0 (Krodin)")
	defer curl.slist_free_all(headers)
	setup := []curl.code{
		curl.easy_setopt(handle, .URL, url_c),
		curl.easy_setopt(handle, .NOSIGNAL, c.long(1)),
		curl.easy_setopt(handle, .CONNECTTIMEOUT_MS, c.long(job.timeout_ms)),
		curl.easy_setopt(handle, .TIMEOUT_MS, c.long(job.timeout_ms)),
		curl.easy_setopt(handle, .CONNECT_ONLY, c.long(2)),
		curl.easy_setopt(handle, .ERRORBUFFER, rawptr(&error_buffer[0])),
		curl.easy_setopt(handle, .XFERINFOFUNCTION, curl.xferinfo_callback(kproto.network_http_cancel_check)),
		curl.easy_setopt(handle, .XFERINFODATA, rawptr(&job.cancel)),
		curl.easy_setopt(handle, .NOPROGRESS, c.long(0)),
		curl.easy_setopt(handle, .HTTPHEADER, headers),
	}
	for code in setup { if code != .E_OK { job.code = code; job.error_text = strings.clone(string(curl.easy_strerror(code))); return } }
	job.code = curl.easy_perform(handle)
	status: c.long
	curl.easy_getinfo(handle, .RESPONSE_CODE, &status)
	job.status = i64(status)
	if job.code != .E_OK {
		detail := string(cast(cstring)&error_buffer[0])
		job.error_text = strings.clone(len(detail) > 0 ? detail : string(curl.easy_strerror(job.code)))
		return
	}
	intrinsics.atomic_store(&job.opened, true)
	message: [dynamic]byte
	defer delete(message)
	buffer: [4096]byte
	for !intrinsics.atomic_load(&job.cancel) {
		received: c.size_t
		meta: ^curl.ws_frame
		code := curl.ws_recv(handle, rawptr(&buffer[0]), c.size_t(len(buffer)), &received, &meta)
		if code == .E_AGAIN { time.sleep(10 * time.Millisecond); continue }
		if code != .E_OK { job.code = code; job.error_text = strings.clone(string(curl.easy_strerror(code))); break }
		if meta == nil { break }
		if .CLOSE in meta.flags {
			job.server_closed = true
			job.close_code = received >= 2 ? int(buffer[0])*256 + int(buffer[1]) : -1
			break
		}
		if .PING in meta.flags || .PONG in meta.flags { continue }
		append(&message, ..buffer[:int(received)])
		if len(message) > RANKED_MESSAGE_LIMIT { job.error_text = strings.clone("queue message too large"); break }
		// A message ends with the last chunk of a frame that is not followed by
		// a continuation frame.
		if meta.bytesleft == 0 && .CONT not_in meta.flags {
			if .BINARY not_in meta.flags { ranked_job_push(job, message[:]) }
			clear(&message)
		}
	}
	if intrinsics.atomic_load(&job.cancel) {
		// Leaving the queue: Krunker's clearState closes the socket (1000).
		sent: c.size_t
		close_payload := [2]byte{0x03, 0xE8}
		curl.ws_send(handle, rawptr(&close_payload[0]), 2, &sent, 0, curl.WS_CLOSE)
	}
}

ranked_job_take :: proc(job: ^Ranked_Job) -> [dynamic]string {
	sync.mutex_lock(&job.mutex)
	defer sync.mutex_unlock(&job.mutex)
	messages := job.inbox
	job.inbox = {}
	return messages
}

ranked_job_free :: proc(job: ^Ranked_Job) {
	if job.thread != nil {
		thread.join(job.thread)
		thread.destroy(job.thread)
		curl.global_cleanup()
	}
	for message in job.inbox { delete(message) }
	delete(job.inbox)
	delete(job.url)
	delete(job.error_text)
	free(job)
}

// GET /ranked/me/connection, Krunker's fetchIsPlayerInRankedMatch.
Ranked_Check_Job :: struct {
	url, token: string,
	timeout_ms: int,
	cancel, done: bool, // atomic
	result: kproto.Network_HTTP_Result,
	thread: ^thread.Thread,
}

ranked_check_run :: proc(data: rawptr) {
	cpu_pin_current_thread_off_game_core()
	job := cast(^Ranked_Check_Job)data
	job.result = kproto.network_http_quiet(job.url, "GET", "", job.timeout_ms, &job.cancel, job.token)
	intrinsics.atomic_store(&job.done, true)
}

ranked_check_free :: proc(job: ^Ranked_Check_Job) {
	if job.thread != nil {
		thread.join(job.thread)
		thread.destroy(job.thread)
		curl.global_cleanup()
	}
	kproto.network_http_result_free(&job.result)
	delete(job.url)
	delete(job.token)
	free(job)
}

// bp() returns the body's data field; serverUrl marks a running ranked match.
ranked_check_server_url :: proc(body: []byte) -> string {
	value, err := json.parse(body, parse_integers = true)
	if err != .None { return "" }
	defer json.destroy_value(value)
	root, ok := value.(json.Object)
	if !ok { return "" }
	data, has_data := root["data"].(json.Object)
	if !has_data { return "" }
	url, has_url := data["serverUrl"].(json.String)
	return has_url ? strings.clone(string(url)) : ""
}

Ranked_Popup :: enum { NONE, INTERNAL_ERROR, NO_RANK_DATA, MIN_LEVEL_REQUIREMENT, COOLDOWN, LOGIN_EXPIRED }

Ranked_Queue :: struct {
	phase: menuui.Ranked_Phase,
	job: ^Ranked_Job,
	check: ^Ranked_Check_Job,
	abandoned: [dynamic]^Ranked_Job,
	abandoned_checks: [dynamic]^Ranked_Check_Job,
	started, found_at: time.Time,
	connection: string, // The MATCHED assignment's server.
	map_name, region: string, // For the match-found notice.
	rejoin_url: string, // Krunker's eS store.
	rejoin: bool, // "You are already in a Ranked game.": the button reads REJOIN.
	popup: Ranked_Popup,
	cooldown_until: time.Time,
}

ranked_log :: proc(text: string) { kproto.network_log("ranked", text) }

// Krunker's clearState: back to idle, timer and assignment dropped, socket
// closed. The REJOIN offer and any popup stay.
ranked_clear_state :: proc(client: ^Client) {
	q := &client.ranked
	if q.job != nil {
		intrinsics.atomic_store(&q.job.cancel, true)
		append(&q.abandoned, q.job)
		q.job = nil
	}
	q.phase = .IDLE
	q.started, q.found_at = {}, {}
	delete(q.connection); q.connection = ""
	delete(q.map_name); q.map_name = ""
	delete(q.region); q.region = ""
}

ranked_cancel_check :: proc(client: ^Client) {
	q := &client.ranked
	if q.check != nil {
		intrinsics.atomic_store(&q.check.cancel, true)
		append(&q.abandoned_checks, q.check)
		q.check = nil
	}
}

ranked_reap :: proc(q: ^Ranked_Queue, wait: bool = false) {
	for i := len(q.abandoned) - 1; i >= 0; i -= 1 {
		job := q.abandoned[i]
		if !wait && !intrinsics.atomic_load(&job.done) { continue }
		ranked_job_free(job)
		ordered_remove(&q.abandoned, i)
	}
	for i := len(q.abandoned_checks) - 1; i >= 0; i -= 1 {
		job := q.abandoned_checks[i]
		if !wait && !intrinsics.atomic_load(&job.done) { continue }
		ranked_check_free(job)
		ordered_remove(&q.abandoned_checks, i)
	}
}

// Leaving: Leave Queue, logout and quit.
ranked_cancel :: proc(client: ^Client, reason: string) {
	q := &client.ranked
	if q.job != nil || q.phase != .IDLE { ranked_log(reason) }
	ranked_clear_state(client)
	ranked_cancel_check(client)
}

ranked_shutdown :: proc(client: ^Client) {
	ranked_cancel(client, "Client closing; left the ranked queue.")
	ranked_reap(&client.ranked, true)
	delete(client.ranked.abandoned)
	delete(client.ranked.abandoned_checks)
	delete(client.ranked.rejoin_url)
	client.ranked = {}
}

// The account token for ranked, or "" for a guest or missing token.
ranked_account_token :: proc(client: ^Client) -> string {
	now := time.time_to_unix(time.now())
	if !ranked_access_select(client, now) || access.token_state(client.access.token, now) != .READY { return "" }
	return client.access.token
}

// Ranked forbids spectators ("Spectating Disabled in Ranked"), so the
// spectator build (KRODIN_SPECTATOR) has no ranked queue at all: every entry
// point (menu action, queue start, rejoin, match join, tick) checks this.
ranked_allowed :: proc() -> bool { return !KRODIN_SPECTATOR }

// startMatchmaking. Returns false without opening a socket when there is no
// account token.
ranked_queue_begin :: proc(client: ^Client) -> bool {
	q := &client.ranked
	if !ranked_allowed() { ranked_log("Ranked is not available in the spectator build; no socket opened."); return false }
	if q.phase != .IDLE || q.job != nil { return false }
	token := ranked_account_token(client)
	if len(token) == 0 {
		ranked_log("Ranked needs account access; no socket opened (guest or missing token).")
		return false
	}
	ranked_register_secret(token)
	maps := ranked_selected_maps(client.ranked_prefs)
	regions := ranked_selected_regions(client.ranked_prefs)
	url := ranked_queue_url(ranked_gamefrontend_origin, token, maps, regions)
	if curl.global_init(curl.GLOBAL_DEFAULT) != .E_OK {
		delete(url)
		q.popup = .INTERNAL_ERROR
		ranked_log("Could not initialize libcurl for the ranked queue.")
		return false
	}
	job := new(Ranked_Job)
	job.url, job.timeout_ms = url, ranked_connect_timeout_ms
	ranked_log(fmt.tprintf("Joining the ranked queue: maps=%v regions=%v url=%s", maps, regions, url))
	job.thread = thread.create_and_start_with_data(job, ranked_job_run, context)
	if job.thread == nil {
		curl.global_cleanup()
		ranked_job_free(job)
		q.popup = .INTERNAL_ERROR
		return false
	}
	q.job, q.phase, q.popup = job, .CONNECTING, .NONE
	q.cooldown_until = {}
	return true
}

// Opening the ranked menu: Krunker resets the REJOIN offer and asks whether
// a ranked match is already running.
ranked_open :: proc(client: ^Client) {
	if !ranked_allowed() { return }
	q := &client.ranked
	q.rejoin = false
	token := ranked_account_token(client)
	if len(token) == 0 || q.phase != .IDLE || q.check != nil || len(ranked_api_origin) == 0 { return }
	ranked_register_secret(token)
	if curl.global_init(curl.GLOBAL_DEFAULT) != .E_OK { return }
	job := new(Ranked_Check_Job)
	job.url, job.token, job.timeout_ms = fmt.aprintf("%s/ranked/me/connection", ranked_api_origin), strings.clone(token), ranked_check_timeout_ms
	job.thread = thread.create_and_start_with_data(job, ranked_check_run, context)
	if job.thread == nil { curl.global_cleanup(); ranked_check_free(job); return }
	q.check = job
}

// Leaves the current session and opens the ranked server's game socket
// through the live path, as Krunker's iY does for any server.
ranked_join_live :: proc(client: ^Client, url: string) -> bool {
	kproto.network_log_begin()
	client_leave_session(client, false)
	link, ok := shared.join_link_parse(url)
	if !ok { krunker_ws_set_status(client, "The ranked match server address was not valid."); return false }
	shared.join_link_free(&client.join_link)
	client.join_link = link
	kproto.krunker_world_reset(&client.krunker_world)
	client.guest.active = false
	net_client_disconnect(&client.net)
	client.menu.page = .HOME
	krunker_ws_set_status(client, "Connecting to match...")
	return krunker_ws_connect_ready(client, &client.join_link)
}

// Krunker's acceptMatch and quickJoinRankedMatch: JOINED_RANK on the current
// game socket, then a join to the ranked server.
ranked_join_server :: proc(client: ^Client, server: string, join: proc(^Client, string) -> bool = ranked_join_live) -> bool {
	q := &client.ranked
	if !ranked_allowed() { ranked_log("Ranked is not available in the spectator build; not joining."); return false }
	token := ranked_account_token(client)
	if len(token) == 0 {
		// Keep the server so REJOIN works after logging in again.
		if server != q.rejoin_url { delete(q.rejoin_url); q.rejoin_url = strings.clone(server) }
		q.rejoin, q.popup = true, .LOGIN_EXPIRED
		ranked_log("Ranked match found but account access is no longer usable; offering Rejoin after login.")
		return false
	}
	ranked_register_secret(token)
	url, ok := ranked_match_url(server, token)
	if !ok {
		ranked_log(fmt.tprintf("Refused ranked server %q: not a *.krunker.io host[:port].", server))
		q.popup = .INTERNAL_ERROR
		return false
	}
	defer delete(url)
	if client.krunker.connected { krunker_ws_send(&client.krunker, "joinedRank") }
	ranked_log(fmt.tprintf("Joining ranked match server=%s url=%s", server, url))
	return join(client, url)
}

ranked_handle_message :: proc(client: ^Client, text: string) {
	q := &client.ranked
	message := ranked_message_parse(text)
	defer ranked_message_free(&message)
	ranked_log(fmt.tprintf("recv %s", text))
	switch message.kind {
	case .IGNORED:
	case .QUEUED:
		if q.phase != .SEARCHING { q.phase, q.started = .SEARCHING, time.now() }
	case .MATCHED:
		// isInOtherRankedMatch: already playing ranked on another server.
		if client.krunker.connected && client.krunker_world.is_ranked {
			host := message.connection
			if colon := strings.index(host, ":"); colon >= 0 { host = host[:colon] }
			if client.join_link.host != host {
				ranked_log("Match found while playing another ranked match; ignoring it.")
				ranked_clear_state(client)
				return
			}
		}
		delete(q.connection); q.connection = strings.clone(message.connection)
		delete(q.map_name); q.map_name = strings.clone(message.map_name)
		delete(q.region); q.region = strings.clone(message.region)
		q.phase, q.found_at = .FOUND, time.now()
		audio_play_effect(client.audio, "pop_3", .UI, 0.15)
	case .ERROR:
		if message.code == .ALREADY_IN_MATCH && len(message.server_url) > 0 {
			delete(q.rejoin_url); q.rejoin_url = strings.clone(message.server_url)
		}
		ranked_clear_state(client)
		switch message.code {
		case .ALREADY_IN_MATCH: q.rejoin = len(q.rejoin_url) > 0
		case .COOLDOWN:
			q.popup = .COOLDOWN
			q.cooldown_until = time.time_add(time.now(), time.Duration(max(message.cooldown_ms, 0)) * time.Millisecond)
		case .NO_RANK_DATA: q.popup = .NO_RANK_DATA
		case .MIN_LEVEL_REQUIREMENT: q.popup = .MIN_LEVEL_REQUIREMENT
		case .INTERNAL_ERROR: q.popup = .INTERNAL_ERROR
		}
	case .INVALID:
		ranked_log("Failed to parse server message.")
		ranked_clear_state(client)
		q.popup = .INTERNAL_ERROR
	}
}

ranked_tick :: proc(client: ^Client, join: proc(^Client, string) -> bool = ranked_join_live) {
	// The spectator build never starts a queue, check or join.
	if !ranked_allowed() { return }
	q := &client.ranked
	ranked_reap(q)
	if check := q.check; check != nil && intrinsics.atomic_load(&check.done) {
		q.check = nil
		defer ranked_check_free(check)
		r := &check.result
		ranked_log(fmt.tprintf("GET /ranked/me/connection HTTP=%d curl=%v body=%s", r.status, r.code, string(r.body[:])))
		if r.code == .E_OK && r.status >= 200 && r.status < 300 {
			if url := ranked_check_server_url(r.body[:]); len(url) > 0 {
				delete(q.rejoin_url); q.rejoin_url = url
				q.rejoin = true
			}
		}
	}
	if job := q.job; job != nil {
		done := intrinsics.atomic_load(&job.done)
		messages := ranked_job_take(job)
		for text in messages {
			if q.job == job { ranked_handle_message(client, text) }
			delete(text)
		}
		delete(messages)
		if done && q.job == job {
			if !intrinsics.atomic_load(&job.opened) {
				ranked_log(fmt.tprintf("Failed to connect to matchmaking server: HTTP %d curl=%v (%s)", job.status, job.code, job.error_text))
				ranked_clear_state(client)
				q.popup = .INTERNAL_ERROR
			} else {
				ranked_log(fmt.tprintf("Queue socket closed: server_close=%v code=%d curl=%v", job.server_closed, job.close_code, job.code))
				ranked_clear_state(client)
			}
		}
	}
	if q.phase == .FOUND && time.since(q.found_at) >= RANKED_ACCEPT_DELAY {
		server := strings.clone(q.connection); defer delete(server)
		ranked_join_server(client, server, join)
		ranked_clear_state(client)
	}
}

// The ranked button: REJOIN, FIND MATCH or CANCEL.
ranked_queue_action :: proc(client: ^Client, join: proc(^Client, string) -> bool = ranked_join_live) {
	if !ranked_allowed() { return }
	q := &client.ranked
	if q.rejoin && len(q.rejoin_url) > 0 {
		server := strings.clone(q.rejoin_url); defer delete(server)
		ranked_join_server(client, server, join)
		return
	}
	#partial switch q.phase {
	case .IDLE: ranked_queue_begin(client)
	case .SEARCHING: ranked_cancel(client, "Left the ranked queue.")
	}
}

ranked_popup_text :: proc(q: ^Ranked_Queue) -> (title, text: string) {
	switch q.popup {
	case .NONE:
	case .INTERNAL_ERROR: return "Internal Error", "An internal error occurred. Please try again later."
	case .NO_RANK_DATA: return "Rank Data Missing", "We could not retrieve your ranked data. Please try again later."
	case .MIN_LEVEL_REQUIREMENT: return "Level Required", "You must be level 10 or higher to access Ranked Mode."
	case .COOLDOWN:
		remaining := int(max(time.duration_seconds(time.diff(time.now(), q.cooldown_until)), 0))
		return "Cooldown", fmt.tprintf("You are on cooldown and cannot queue for ranked matches. Cooldown will end in %s", menuui.ranked_format_time(remaining))
	case .LOGIN_EXPIRED: return "Login Required", "Your login expired before the match started. Log in again, then use Rejoin."
	}
	return "", ""
}

ranked_view :: proc(client: ^Client, page_open: bool) -> menuui.Ranked_View {
	q := &client.ranked
	view := menuui.Ranked_View{phase = q.phase, rejoin = q.rejoin, checking = q.check != nil, prefs = client.ranked_prefs}
	view.login_supported = ODIN_OS == .Windows
	view.login_pending = client.access.status == .PENDING
	if page_open { view.logged_in = access.token_state(client.access.token, time.time_to_unix(time.now())) == .READY }
	if q.phase == .SEARCHING { view.elapsed = int(time.duration_seconds(time.since(q.started))) }
	view.popup_title, view.popup_text = ranked_popup_text(q)
	if q.popup == .MIN_LEVEL_REQUIREMENT || q.popup == .NO_RANK_DATA || q.popup == .INTERNAL_ERROR || q.popup == .LOGIN_EXPIRED { view.tone = .ERROR }
	cooldown := time.duration_seconds(time.diff(time.now(), q.cooldown_until))
	switch {
	case q.rejoin:
		view.status, view.tone = "You are already in a Ranked game.", .WARNING
	case q.phase == .SEARCHING:
		view.status = fmt.tprintf("Looking for match... (%s)", menuui.ranked_format_time(view.elapsed))
	case q.phase == .FOUND:
		view.status = len(q.map_name) > 0 ? fmt.tprintf("Match found! %s (%s)", q.map_name, q.region) : "Match found!"
	case q.phase == .CONNECTING:
		view.status = "Joining the ranked queue..."
	case cooldown > 0:
		// Krodin's own: Krunker shows the cooldown once in its popup.
		view.status, view.tone = fmt.tprintf("On cooldown: queue again in %s", menuui.ranked_format_time(int(cooldown + 0.999))), .WARNING
	case:
		view.status = "Ready to compete? Join the ranked queue!"
	}
	return view
}

// Region and map choices save immediately, like Krunker's
// s_rankedAllRegions localStorage entry.
ranked_preferences_action :: proc(client: ^Client, action: menuui.Action, save: proc(Client_Settings) -> bool = ranked_settings_save) {
	if client.ranked.phase != .IDLE { return }
	#partial switch action.kind {
	case .RANKED_REGION: menuui.ranked_set_region(&client.ranked_prefs, action.index)
	case .RANKED_MAP: menuui.ranked_toggle_map(&client.ranked_prefs, action.index)
	case: return
	}
	client.ranked_prefs = menuui.ranked_preferences_validate(client.ranked_prefs)
	save(client_settings_snapshot(client))
}

ranked_settings_save :: proc(settings: Client_Settings) -> bool { return client_settings_save(settings) }
