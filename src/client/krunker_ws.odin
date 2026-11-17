package main

import "core:c"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import curl "vendor:curl"
import glfw "vendor:glfw"
import shared "../shared"
import kproto "../krunker"
import accessui "../browser_access"

Krunker_WS_State :: struct {
	connected:    bool,
	// The WebSocket thread is resolving the invite or upgrading; the result
	// arrives as a CONNECTED or CONNECT_FAILED event.
	connecting:   bool,
	// The join uses a browser-selected socket after a CAPTCHA.
	captcha_handoff: bool,
	got_load:     bool,
	bootstrapped: bool,
	spawned:      bool,
	team:         i32,
	class_index:  i32,
	secondary_index: i32,
	secondary_response_pending: bool,
	secondary_request_revision: u64,
	q_index:      int,
	ah_num:       u8,
	// Runs the join and then owns the curl handle; nil when idle and in tests.
	transport:    ^Krunker_WS_Transport,
	// Received events not applied yet, oldest first.
	inbox:        [dynamic]Krunker_WS_Event,
	rx_logged:    int,
	decode_errors: int,
	input_blocked: bool,
	recv_budget_hits: int,
	rendered_map_revision: u64,
	render_map_ready: bool,
	player_revisions: map[i32]u64,
	player_loadout_revisions: map[i32]u64,
	local_sync_revision: u64,
	local_ammo_revision: u64,
	local_position_revision: u64,
	ready_received: bool,
	bootstrap_step: int,
	last_server_message: string,
	input_elapsed: f64,
	input_duration_remainder_ms: f64,
	send_elapsed: f64,
	input_commands: [dynamic]shared.Input,
	input_reset: bool,
	input_swap: u8,
	command_direction: shared.Vec2,
	render_previous, render_current: Krunker_Render_Sample,
	render_sample_ready: bool,
	prediction_corrections: int,
	// The newest correction (server position minus prediction) and the
	// command it acknowledged. Recorded for the debug window in developer builds.
	last_correction: shared.Vec3,
	last_correction_ack: i32,
	// Set while krunker_ws_process_inbox applies one frame's messages: a
	// fresh l then defers its replay, so several in one frame replay once.
	batching: bool,
	replay: Krunker_Deferred_Replay,
	// The prediction cap dropped commands up to truncated_through before the
	// server acknowledged them; replays before that ACK cannot be exact.
	history_truncated: bool,
	truncated_through: i32,
	// Predicted ramp snap target after the newest acknowledged command.
	acked_ramp_fix: f32,
	acked_has_ramp_fix: bool,
	input_sequence: i32,
	// An l ACK at or above input_sequence names an id this life never sent
	// (the previous life's ACK, or the server's pre-input ACK after start).
	stale_ack_logged: bool,
	// Krodin's own ghost watchdog (Krunker has no equivalent). The ACK only
	// arrives in l (SYNC_PLAYER), which Krunker sends once per second, so
	// stalls are counted in syncs, never in wall time.
	ghost_ack: i32,
	ghost_ack_seen: bool,
	ghost_stalled_syncs: int,
	ghost_fired_at: f64,
	// Since the previous l: whether any q went out, and its summed duration.
	sync_sent: bool,
	sync_sent_ms: f64,
	sync_at: f64,
	life_syncs: int,
	// Respawn timeline for the network log: en sent, start received.
	life_en_at: f64,
	life_start_at: f64,
	life_first_ack_logged: bool,
	input_logged: int,
	heartbeat_logged: int,
	snapshots_received: int,
	server_error: string,
	auth_rejected: bool,
	// Chat messages waiting for the socket, sent in order after control packets.
	chat_outbox: [dynamic]Krunker_Chat_Outgoing,
	// Spectator build: ENTER_GAME carries Krunker's spectate flag (en[6],
	// the browser's `Dc?1:0` from window.setSpect), and this socket never
	// sends gameplay input (q). spectate_target is the sid sent with fpSp,
	// -1 for free cam (fpSp with null).
	spectate: bool,
	spectate_target: i32,
}

Krunker_Chat_Outgoing :: struct { text: string, team: bool }
Krunker_Send_Result :: enum { SENT, AGAIN, FAILED }

krunker_ws_set_status :: proc(client: ^Client, text: string) {
	delete(client.join_status)
	client.join_status = kproto.network_log_safe(text)
	kproto.network_log("status", text)
}

krunker_ws_url_encode :: proc(value: string) -> string {
	return kproto.network_url_encode(value)
}

krunker_ws_json_string :: proc(object: json.Object, key: string) -> (string, bool) {
	raw, found := object[key]
	if !found do return "", false
	if value, ok := raw.(json.String); ok { return string(value), true }
	return "", false
}

krunker_ws_game_version :: proc(value: json.Value) -> string {
	if entries, ok := value.(json.Array); ok {
		for entry in entries {
			if fields, ok := entry.(json.Array); ok && len(fields) > 4 {
				if metadata, ok := fields[4].(json.Object); ok {
					if version, ok := krunker_ws_json_string(metadata, "v"); ok && len(version) > 0 { return strings.clone(version) }
				}
			}
		}
	}
	if object, ok := value.(json.Object); ok {
		if games, found := object["games"]; found { return krunker_ws_game_version(games) }
	}
	return strings.clone("1.0.0")
}

krunker_ws_access_token :: proc() -> (string, bool) {
	when ODIN_OS == .Windows {
		kproto.network_log("auth", "Environment/.env token loading disabled; use Login for browser access.")
		return "", false
	} else {
		if token, ok := os.lookup_env_alloc("KRUNKER_ACCESS_TOKEN", context.allocator); ok {
			if len(token) > 0 { kproto.network_log("auth", fmt.tprintf("source=environment KRUNKER_ACCESS_TOKEN present=true bytes=%d", len(token))); return token, true }
			delete(token)
		}
		data, err := os.read_entire_file_from_path(".env", context.temp_allocator)
		if err != nil { kproto.network_log("auth", fmt.tprintf("ERROR reading .env from working directory: %v", err)); return "", false }
		lines := strings.split_lines(string(data))
		defer delete(lines)
		for raw_line in lines {
			line := strings.trim_space(raw_line)
			if len(line) == 0 || line[0] == '#' do continue
			eq := strings.index(line, "=")
			if eq <= 0 || strings.trim_space(line[:eq]) != "KRUNKER_ACCESS_TOKEN" do continue
			value := strings.trim_space(line[eq + 1:])
			if len(value) >= 2 && ((value[0] == '"' && value[len(value)-1] == '"') || (value[0] == '\'' && value[len(value)-1] == '\'')) { value = value[1:len(value)-1] }
			if len(value) > 0 { kproto.network_log("auth", fmt.tprintf("source=.env KRUNKER_ACCESS_TOKEN present=true bytes=%d", len(value))); return strings.clone(value), true }
		}
		kproto.network_log("auth", "ERROR KRUNKER_ACCESS_TOKEN missing or empty in .env")
		return "", false
	}
}

krunker_ws_http_failure :: proc(stage: string, status: i64, transport_ok: bool, body: []byte) -> string {
	if transport_ok && accessui.captcha_required(body) {
		kproto.network_log("captcha", fmt.tprintf("%s requires a CAPTCHA (HTTP %d). Access and browser session retained; no authentication retry.", stage, status))
		return "Krunker requires a CAPTCHA for this join. Verification is needed before native matchmaking can continue."
	}
	safe := kproto.network_log_safe(string(body), 240)
	defer delete(safe)
	return fmt.tprintf("%s failed: HTTP %d, transport_ok=%v, body=%s. See logs/krunker-network.log", stage, status, transport_ok, safe)
}

krunker_ws_log_token_expiry :: proc(token: string) {
	parts := strings.split(token, ".")
	defer delete(parts)
	if len(parts) != 3 { kproto.network_log("auth", "access token is not a three-part JWT; expiry unavailable"); return }
	data, err := base64.decode(parts[1], base64.DEC_URL_TABLE)
	if err != nil { kproto.network_log("auth", fmt.tprintf("JWT payload decode failed=%v; expiry unavailable", err)); return }
	defer delete(data)
	value, parse_err := json.parse_string(string(data), parse_integers = true)
	if parse_err != .None { kproto.network_log("auth", "JWT payload JSON invalid; expiry unavailable"); return }
	defer json.destroy_value(value)
	if object, ok := value.(json.Object); ok {
		if expiry, ok := object["exp"].(json.Integer); ok {
			now := time.time_to_unix(time.now())
			kproto.network_log("auth", fmt.tprintf("JWT exp_unix=%d now_unix=%d remaining_seconds=%d expired=%v (decoded only; signature not verified here)", expiry, now, i64(expiry)-now, i64(expiry) <= now))
			return
		}
	}
	kproto.network_log("auth", "JWT exp missing; expiry unavailable")
}

// Tests point this at a loopback matchmaker.
krunker_matchmaker_origin := "https://matchmaker.krunker.io"
// Starts the verification helper; tests replace it so no browser launches.
krunker_captcha_start: proc(^Client) -> bool = client_browser_captcha_start

krunker_ws_resolve_invite :: proc(link: ^shared.Join_Link, access: string, rejected: ^bool, http: proc(string, string, string, string) -> ([dynamic]byte, i64, bool) = kproto.network_http, captcha: string = "", needs_captcha: ^bool = nil) -> (string, bool, string) {
	rejected^ = false
	if needs_captcha != nil { needs_captcha^ = false }
	if len(access) == 0 {
		when ODIN_OS == .Windows { return "", false, "Browser access is missing. Click Login, then retry Join. See logs/krunker-network.log" }
		else { return "", false, "KRUNKER_ACCESS_TOKEN is missing; set it in .env. See logs/krunker-network.log" }
	}
	kproto.network_log_secret(access)
	krunker_ws_log_token_expiry(access)
	access_encoded := krunker_ws_url_encode(access)
	defer delete(access_encoded)
	kproto.network_log_secret(access_encoded)
	validation, validation_status, validation_ok := http(fmt.tprintf("%s/generate-token", krunker_matchmaker_origin), "GET", "", "generate-token")
	defer delete(validation)
	if !validation_ok || validation_status < 200 || validation_status >= 300 || len(strings.trim_space(string(validation[:]))) == 0 || accessui.captcha_required(validation[:]) {
		return "", false, krunker_ws_http_failure("matchmaker /generate-token", validation_status, validation_ok, validation[:])
	}
	validation_token := strings.trim_space(string(validation[:]))
	kproto.network_log_secret(validation_token)
	validation_encoded := krunker_ws_url_encode(validation_token)
	defer delete(validation_encoded)
	kproto.network_log_secret(validation_encoded)
	kproto.network_log("generate-token", fmt.tprintf("validation token received; bytes=%d (value redacted)", len(validation_token)))
	version := strings.clone("1.0.0")
	defer delete(version)
	game_list, game_status, game_ok := http(fmt.tprintf("%s/game-list?hostname=krunker.io", krunker_matchmaker_origin), "GET", "", "game-list")
	defer delete(game_list)
	if game_ok && accessui.captcha_required(game_list[:]) { return "", false, krunker_ws_http_failure("matchmaker /game-list", game_status, true, game_list[:]) }
	if game_ok && game_status >= 200 && game_status < 300 {
		if value, err := json.parse_string(string(game_list[:]), parse_integers = true); err == .None {
			delete(version)
			version = krunker_ws_game_version(value)
			json.destroy_value(value)
		} else { kproto.network_log("game-list", fmt.tprintf("ERROR JSON parse=%v; using fallback version=1.0.0; body=%s", err, string(game_list[:]))) }
	} else { kproto.network_log("game-list", "WARNING game list unavailable; using fallback version=1.0.0") }
	data_query, query_ok := kproto.krunker_seek_data_query(version)
	if !query_ok { return "", false, "Could not serialize matchmaker dataQuery; see logs/krunker-network.log" }
	defer delete(data_query)
	kproto.network_log("seek-game", fmt.tprintf("game=%s region=sgp hostname=krunker.io autoChangeGame=false dataQuery=%s; version 1.0.0 means fallback if absent from metadata", link.game_id, data_query))
	data_encoded := krunker_ws_url_encode(data_query)
	game_encoded := krunker_ws_url_encode(link.game_id)
	defer delete(data_encoded)
	defer delete(game_encoded)
	seek := fmt.tprintf("%s/seek-game?hostname=krunker.io&region=sgp&autoChangeGame=false&validationToken=%s&dataQuery=%s&accessToken=%s&game=%s", krunker_matchmaker_origin, validation_encoded, data_encoded, access_encoded, game_encoded)
	if len(captcha) > 0 {
		if !accessui.captcha_token_valid(captcha) { return "", false, accessui.status_text("CAPTCHA_BAD_TOKEN") }
		kproto.network_log_secret(captcha)
		encoded := krunker_ws_url_encode(captcha); defer delete(encoded)
		kproto.network_log_secret(encoded)
		seek = fmt.tprintf("%s&captchaToken=%s", seek, encoded)
		kproto.network_log("captcha", "Retrying native seek-game with the browser proof and a fresh native validation token; proof omitted.")
	}
	assignment_body, status, ok := http(seek, "GET", "", "seek-game")
	defer delete(assignment_body)
	if !ok || status < 200 || status >= 300 || accessui.captcha_required(assignment_body[:]) || accessui.token_rejected(status, assignment_body[:]) {
		if needs_captcha != nil { needs_captcha^ = ok && accessui.captcha_required(assignment_body[:]) }
		rejected^ = ok && accessui.token_rejected(status, assignment_body[:])
		return "", false, krunker_ws_http_failure("matchmaker /seek-game", status, ok, assignment_body[:])
	}
	value, parse_err := json.parse_string(string(assignment_body[:]), parse_integers = true)
	if parse_err != .None { kproto.network_log("seek-game", fmt.tprintf("ERROR JSON parse=%v body=%s", parse_err, string(assignment_body[:]))); return "", false, "matchmaker returned invalid JSON; see logs/krunker-network.log" }
	defer json.destroy_value(value)
	object, object_ok := value.(json.Object)
	if !object_ok { kproto.network_log("seek-game", fmt.tprintf("ERROR expected object; body=%s", string(assignment_body[:]))); return "", false, "matchmaker response was not an object; see logs/krunker-network.log" }
	host, host_ok := krunker_ws_json_string(object, "host")
	client_key, key_ok := krunker_ws_json_string(object, "clientId")
	game_id, game_id_ok := krunker_ws_json_string(object, "gameId")
	port: i64 = 443
	if raw_port, found := object["port"]; found {
		if parsed, ok := raw_port.(json.Integer); ok && parsed > 0 && parsed <= 65535 { port = i64(parsed) }
	}
	if key_ok { kproto.network_log_secret(client_key) }
	kproto.network_log("seek-game", fmt.tprintf("assignment host_present=%v clientId_present=%v gameId_present=%v port=%d body=%s", host_ok, key_ok, game_id_ok, port, string(assignment_body[:])))
	if !host_ok || !key_ok || !game_id_ok || len(host) == 0 || len(client_key) == 0 || len(game_id) == 0 { return "", false, "matchmaker response omitted host, clientId, or gameId; see logs/krunker-network.log" }
	resolved_game := krunker_ws_url_encode(game_id)
	resolved_key := krunker_ws_url_encode(client_key)
	defer delete(resolved_game)
	defer delete(resolved_key)
	kproto.network_log_secret(resolved_key)
	url := ""
	if len(krunker_lobby_origin_override) > 0 {
		url = fmt.aprintf("%s/ws?gameId=%s&clientKey=%s&at=%s", krunker_lobby_origin_override, resolved_game, resolved_key, access_encoded)
	} else if accessui.assignment_uses_explicit_port(host, port) {
		url = fmt.aprintf("wss://%s:%d/ws?gameId=%s&clientKey=%s&at=%s", host, port, resolved_game, resolved_key, access_encoded)
	} else {
		url = fmt.aprintf("wss://%s/ws?gameId=%s&clientKey=%s&at=%s", host, resolved_game, resolved_key, access_encoded)
	}
	return url, true, ""
}

krunker_ws_pack_string :: proc(out: ^[dynamic]byte, value: string) {
	if len(value) < 32 { append(out, byte(0xA0 | len(value))) }
	else if len(value) < 256 { append(out, 0xD9, byte(len(value))) }
	else { append(out, 0xDA, byte(len(value) >> 8), byte(len(value))) }
	append(out, value)
}

krunker_ws_pack_int :: proc(out: ^[dynamic]byte, value: i32) {
	if value >= 0 && value < 128 { append(out, byte(value)) }
	else if value < 0 && value >= -32 { append(out, byte(i8(value))) }
	else if value >= 0 && value < 256 { append(out, 0xCC, byte(value)) }
	else if value >= 0 && value < 65536 { append(out, 0xCD, byte(value >> 8), byte(value)) }
	else if value >= 0 { append(out, 0xCE, byte(value >> 24), byte(value >> 16), byte(value >> 8), byte(value)) }
	else if value >= -128 { append(out, 0xD0, byte(i8(value))) }
	else if value >= -32768 { append(out, 0xD1, byte(value >> 8), byte(value)) }
	else { append(out, 0xD2, byte(value >> 24), byte(value >> 16), byte(value >> 8), byte(value)) }
}

krunker_ws_pack_nil :: proc(out: ^[dynamic]byte) { append(out, 0xC0) }
krunker_ws_pack_array :: proc(out: ^[dynamic]byte, count: int) { if count < 16 { append(out, byte(0x90 | count)) } else { append(out, 0xDC, byte(count >> 8), byte(count)) } }
krunker_ws_pack_map :: proc(out: ^[dynamic]byte, count: int) { append(out, byte(0x80 | count)) }

krunker_ws_finish_packet :: proc(payload: [dynamic]byte, opcode: string, ah_num: ^u8) -> [dynamic]byte {
	ah_num^ = kproto.krunker_msgpack_counter_next(ah_num^, opcode)
	out := make([dynamic]byte, len(payload) + 2)
	copy(out[:len(payload)], payload[:])
	out[len(payload)] = byte(ah_num^ >> 4)
	out[len(payload) + 1] = byte(ah_num^ & 15)
	delete(payload)
	return out
}

krunker_ws_message :: proc(opcode: string, ah_num: ^u8, q_index: int, team: i32 = 0, class_index: i32 = 0, secondary_index: i32 = 2, spectate: bool = false, spectate_target: i32 = -1) -> [dynamic]byte {
	message: [dynamic]byte
	switch opcode {
	case "load":
		krunker_ws_pack_array(&message, 1); krunker_ws_pack_string(&message, "load")
	case "po":
		krunker_ws_pack_array(&message, 1); krunker_ws_pack_string(&message, "po")
	case "joinedRank":
		// Oa.JOINED_RANK, sent before leaving for a ranked match (acceptMatch).
		krunker_ws_pack_array(&message, 1); krunker_ws_pack_string(&message, "joinedRank")
	case "v":
		krunker_ws_pack_array(&message, 1); krunker_ws_pack_string(&message, "v")
	case "en":
		// Build 5fHFc: opcode + 12 arguments, including the 35-field loadout.
		krunker_ws_pack_array(&message, 13); krunker_ws_pack_string(&message, "en")
		krunker_ws_pack_array(&message, 35)
		krunker_ws_pack_int(&message, class_index); krunker_ws_pack_int(&message, 2482)
		krunker_ws_pack_array(&message, 2); krunker_ws_pack_int(&message, -1); krunker_ws_pack_int(&message, -1)
		values := [?]i32{-1, -1, 2, 0, 0, 1, -1, -1, 1, 0, -1, -1, -1, -1, -1, -1, 0, -1, -1, 1, 1, 1, -1, -1, -1, 0}
		values[2] = secondary_index >= 0 ? secondary_index : 2
		// en[6]: the browser's spectate switch (`parseInt(i0),Dc?1:0,`).
		values[3] = spectate ? 1 : 0
		for value in values { krunker_ws_pack_int(&message, value) }
		krunker_ws_pack_array(&message, 2); krunker_ws_pack_nil(&message); krunker_ws_pack_int(&message, -1)
		krunker_ws_pack_int(&message, -1); krunker_ws_pack_int(&message, -1); krunker_ws_pack_int(&message, -1); krunker_ws_pack_int(&message, 1)
		krunker_ws_pack_int(&message, -1) // titleIndex; no equipped title
		krunker_ws_pack_int(&message, 16); krunker_ws_pack_int(&message, 18)
		for _ in 0 ..< 6 { append(&message, 0xC2) }
		krunker_ws_pack_nil(&message); append(&message, 0xC2); append(&message, 0xC2)
	case "fpSp":
		// Krunker's spectate target: aa.send(Da.fpSp, a ? a.sid : null).
		krunker_ws_pack_array(&message, 2); krunker_ws_pack_string(&message, "fpSp")
		if spectate_target < 0 { krunker_ws_pack_nil(&message) } else { krunker_ws_pack_int(&message, spectate_target) }
	case "team":
		krunker_ws_pack_array(&message, 3); krunker_ws_pack_string(&message, "cd"); krunker_ws_pack_string(&message, "t"); krunker_ws_pack_int(&message, team)
	case "class":
		krunker_ws_pack_array(&message, 3); krunker_ws_pack_string(&message, "cd"); krunker_ws_pack_string(&message, "c"); krunker_ws_pack_map(&message, 2); krunker_ws_pack_string(&message, "c"); krunker_ws_pack_int(&message, class_index); krunker_ws_pack_string(&message, "s")
		if secondary_index < 0 { krunker_ws_pack_nil(&message) } else { krunker_ws_pack_int(&message, secondary_index) }
	case "q":
		switch q_index {
		case 0:
			krunker_ws_pack_array(&message, 7); krunker_ws_pack_string(&message, "q"); krunker_ws_pack_int(&message, 0); krunker_ws_pack_int(&message, 0); krunker_ws_pack_array(&message, 2); krunker_ws_pack_int(&message, 8); krunker_ws_pack_int(&message, 33); krunker_ws_pack_int(&message, 0); krunker_ws_pack_array(&message, 2); krunker_ws_pack_int(&message, 0); krunker_ws_pack_int(&message, -4712); krunker_ws_pack_map(&message, 11)
			keys := [?]string{"0-4", "0-5", "0-6", "0-7", "0-8", "0-9", "0-10", "0-11", "0-12", "0-13", "0-14"}
			for key in keys { krunker_ws_pack_string(&message, key); krunker_ws_pack_int(&message, key == "0-4" ? -1 : 0) }
		case 1:
			krunker_ws_pack_array(&message, 5); krunker_ws_pack_string(&message, "q"); krunker_ws_pack_int(&message, 0); krunker_ws_pack_int(&message, 2); krunker_ws_pack_array(&message, 3); krunker_ws_pack_int(&message, 8); krunker_ws_pack_int(&message, 12); krunker_ws_pack_int(&message, 15); krunker_ws_pack_int(&message, 0)
		case 2:
			krunker_ws_pack_array(&message, 5); krunker_ws_pack_string(&message, "q"); krunker_ws_pack_int(&message, 0); krunker_ws_pack_int(&message, 5); krunker_ws_pack_array(&message, 3); krunker_ws_pack_int(&message, 22); krunker_ws_pack_int(&message, 11); krunker_ws_pack_int(&message, 8); krunker_ws_pack_int(&message, 0)
		case:
			krunker_ws_pack_array(&message, 5); krunker_ws_pack_string(&message, "q"); krunker_ws_pack_int(&message, 0); krunker_ws_pack_int(&message, 8); krunker_ws_pack_array(&message, 5); krunker_ws_pack_int(&message, 10); krunker_ws_pack_int(&message, 12); krunker_ws_pack_int(&message, 5); krunker_ws_pack_int(&message, 6); krunker_ws_pack_int(&message, 6); krunker_ws_pack_int(&message, 0)
		}
	}
	return krunker_ws_finish_packet(message, opcode, ah_num)
}

// Queues a control packet on the WebSocket thread, which sends packets in
// queue order and retries E_AGAIN with the same bytes. The counter therefore
// advances here, exactly once per packet, as it did after a complete send.
krunker_ws_send :: proc(state: ^Krunker_WS_State, opcode: string) -> bool {
	// A spectator never plays: Krunker's browser sends q only for an active
	// local player (`ht && ht.active`), so the spectator build refuses it.
	if state.spectate && opcode == "q" { return true }
	if state.transport == nil {
		kproto.network_log("ws-send", fmt.tprintf("ERROR opcode=%s: no WebSocket connection", opcode))
		return false
	}
	next_counter := state.ah_num
	packet := krunker_ws_message(opcode, &next_counter, state.q_index, state.team, state.class_index, state.secondary_index, state.spectate, state.spectate_target)
	bytes := len(packet)
	trailer := [2]byte{packet[bytes-2], packet[bytes-1]}
	if !krunker_ws_transport_send(state.transport, packet[:], opcode) {
		kproto.network_log("ws-send", fmt.tprintf("ERROR opcode=%s: the WebSocket connection has ended", opcode))
		return false
	}
	state.ah_num = next_counter
	if opcode == "v" && state.spawned { state.heartbeat_logged += 1 }
	if opcode != "v" || !state.spawned || state.heartbeat_logged <= 3 || state.heartbeat_logged % 120 == 0 {
		kproto.network_log("ws-send", fmt.tprintf("opcode=%s bytes=%d counter=%d trailer=[%02x %02x] q_index=%d", opcode, bytes, state.ah_num, trailer[0], trailer[1], state.q_index))
	}
	if opcode == "q" { state.q_index += 1 }
	if opcode == "en" { state.life_en_at = glfw.GetTime() }
	return true
}

// Queues one complete chat frame on the WebSocket thread (in order after
// earlier packets). FAILED once the connection has ended.
krunker_ws_send_bytes :: proc(state: ^Krunker_WS_State, packet: []byte) -> Krunker_Send_Result {
	// Connected always has a transport in the game; without one (tests, the
	// moment before CONNECTED is applied) the chat stays queued.
	if state.transport == nil { return .AGAIN }
	owned := slice.clone(packet, state.transport.allocator)
	if !krunker_ws_transport_send(state.transport, owned, "ct") {
		kproto.network_log("chat", "ERROR ct: the WebSocket connection has ended")
		return .FAILED
	}
	return .SENT
}

krunker_ws_queue_chat :: proc(state: ^Krunker_WS_State, text: string, team: bool) {
	clean := kproto.krunker_chat_clean_outgoing(text)
	if len(clean) == 0 { return }
	append(&state.chat_outbox, Krunker_Chat_Outgoing{strings.clone(clean), team})
}

// Sends queued chat as CHAT_MESSAGE ["ct", tab, text]. The WebSocket thread
// keeps packets in queue order, so each takes the next shared trailer counter
// when it is queued. Only lengths are logged, never chat text.
krunker_ws_flush_chat :: proc(state: ^Krunker_WS_State, send: proc(^Krunker_WS_State, []byte) -> Krunker_Send_Result = krunker_ws_send_bytes) -> bool {
	for len(state.chat_outbox) > 0 {
		if !state.connected { return true }
		item := state.chat_outbox[0]
		next := kproto.krunker_msgpack_counter_next(state.ah_num, kproto.KRUNKER_CHAT_SEND_OPCODE)
		packet, ok := kproto.krunker_chat_encode(item.text, item.team, next)
		if ok {
			result := send(state, packet)
			delete(packet)
			if result == .AGAIN { return true }
			if result == .FAILED { return false }
			state.ah_num = next
			kproto.network_log("chat", fmt.tprintf("SENT ct tab=%d text_bytes=%d counter=%d", item.team ? 1 : 0, len(item.text), next))
		}
		delete(item.text)
		ordered_remove(&state.chat_outbox, 0)
	}
	return true
}

// Team selection is already confirmed in the lobby. Send the current class
// before one entry request, without delaying input after the server starts us.
KRUNKER_BOOTSTRAP_OPS := [?]string{"po", "class", "en"}

krunker_ws_bootstrap_tick :: proc(client: ^Client, send_control: proc(^Krunker_WS_State, string) -> bool = krunker_ws_send) {
	state := &client.krunker
	if krunker_client_respawn_remaining(client, glfw.GetTime()) > 0 { return }
	if !state.connected || !state.got_load || !state.ready_received || state.bootstrapped || !client.spawn_pending do return
	for state.bootstrap_step < len(KRUNKER_BOOTSTRAP_OPS) {
		opcode := KRUNKER_BOOTSTRAP_OPS[state.bootstrap_step]
		if !send_control(state, opcode) { state.connected = false; krunker_ws_set_status(client, "Krunker lobby bootstrap send failed; see logs/krunker-network.log"); return }
		state.bootstrap_step += 1
	}
	if state.bootstrap_step == len(KRUNKER_BOOTSTRAP_OPS) {
		state.bootstrapped = true
		state.input_sequence = max(state.input_sequence, 13)
		if !state.spawned && len(state.last_server_message) == 0 { krunker_ws_set_status(client, "Team/class selected; waiting for server spawn confirmation.") }
	}
}

// Keep initial protocol discovery and all unknown/error/lifecycle packets.
// Routine traffic otherwise caused thousands of synchronous console/file writes
// on the gameplay thread during a single match.
krunker_ws_routine_packet :: proc(value: kproto.Krunker_Msgpack_Value) -> bool {
	if numeric, ok := value.(i64); ok { return numeric >= 4 && numeric <= 9 }
	if opcode, ok := value.(string); ok {
		switch opcode {
		case "k", "l", "gmsg", "ai", "t", "h", "s", "4", "5", "6", "7", "8", "9", "ts", "pi", "pir", "uamo", "uobj": return true
		}
	}
	return false
}

krunker_ws_apply_world :: proc(client: ^Client, payload: []byte, send_control: proc(^Krunker_WS_State, string) -> bool = krunker_ws_send) {
	state := &client.krunker
	messages, counter, error_text := kproto.krunker_msgpack_decode_packet(payload)
	if len(error_text) != 0 {
		state.decode_errors += 1
		if state.decode_errors <= 20 { kproto.network_log("msgpack", fmt.tprintf("ERROR decode complete_message_bytes=%d error=%s count=%d", len(payload), error_text, state.decode_errors)) }
		return
	}
	for value in messages {
		packet, ok := value.([]kproto.Krunker_Msgpack_Value)
		if !ok || len(packet) == 0 do continue
		opcode, is_text := packet[0].(string)
		// Only suppress routine updates. A late disconnect/error/challenge must
		// remain visible after the initial packet trace has reached its limit.
		if state.rx_logged <= 40 || !krunker_ws_routine_packet(packet[0]) {
			kproto.network_log("msgpack", fmt.tprintf("RECV opcode=%v args=%d trailer=%d complete_message_bytes=%d", packet[0], len(packet)-1, counter, len(payload)))
		}
		// A deferred replay may wait across l and remote-only k updates. Run
		// it before anything else can read or reset the local player.
		if !is_text || opcode != "l" && opcode != "k" { krunker_client_finish_replay(client) }
		client.krunker_world.received_at = glfw.GetTime()
		applied := kproto.krunker_world_apply_packet(&client.krunker_world, packet)
		if is_text {
			switch opcode {
			case "load":
				if !state.got_load {
					state.got_load = true
					if !send_control(state, "load") { state.connected = false; return }
					krunker_ws_set_status(client, "Krunker connected; loading lobby...")
				}
			case "io-init":
				kproto.network_log("ownership", fmt.tprintf("socket identity accepted=%v string_id=%v (value redacted); waiting for numeric player SID", applied, len(client.krunker_world.local_socket_id) > 0))
			case "uid":
				kproto.network_log("ownership", fmt.tprintf("lobby connection identity accepted=%v (value redacted)", applied))
			case "cd", "cda":
				for player in client.krunker_world.lobby_players {
					if player.id == client.krunker_world.local_connection_uid {
						kproto.network_log("lobby-selection", fmt.tprintf("server team=%d class=%d requested_team=%d pending=%v", player.team, player.class_index, client.requested_team, client.team_pending))
					}
				}
			case "pi":
				// SOCKET_PING is answered with the application PING (po), even
				// while the player is choosing a team/class in the lobby.
				if !send_control(state, "po") { state.connected = false; return }
			case "init":
				state.spawned = false
				kproto.network_log("world", fmt.tprintf("init map=%d mode=%d comp=%v ranked=%v", client.krunker_world.map_index, client.krunker_world.mode_index, client.krunker_world.is_comp, client.krunker_world.is_ranked))
				if len(packet) > 7 {
					if entries, ok := packet[7].([]kproto.Krunker_Msgpack_Map_Entry); ok {
						for entry in entries {
							if key, text := entry.key.(string); text && (key == "tmSize" || key == "maxPlayers" || key == "specSlots" || key == "lives" || key == "classes" || key == "limitClasses" || strings.has_prefix(key, "classLim")) {
								kproto.network_log("lobby-config", fmt.tprintf("%s=%v type=%T", key, entry.value, entry.value))
							}
						}
					}
				}
				kproto.network_log("lobby-config", fmt.tprintf("total_capacity=%d team_capacity=%d", client.krunker_world.lobby_capacity, client.krunker_world.lobby_team_capacity))
			case "rg":
				if len(packet) > 2 { kproto.network_log("loadout", fmt.tprintf("sid=%v reset=%v applied=%v countdown=%v", packet[1], packet[2], applied, client.krunker_world.countdown)) }
			case "ready":
				state.ready_received = client.krunker_world.ready
				if !state.ready_received { state.connected = false; krunker_ws_set_status(client, "Lobby sent ready(false); connection rejected."); return }
				krunker_ws_set_status(client, "Lobby ready. Choose a team and class, then enter game.")
			case "start":
				kproto.network_log("spawn", fmt.tprintf("server start received; local_sid=%d players=%d; waiting for renderer handoff", client.krunker_world.local_sid, len(client.krunker_world.players)))
				krunker_ws_reset_input_for_start(client, glfw.GetTime())
				if !state.spawned { krunker_ws_set_status(client, "Server confirmed entry; waiting for local player position...") }
			case "rds", "obj", "gsc", "lkt", "ulm":
				world := &client.krunker_world
				kproto.network_log("match-state", fmt.tprintf("opcode=%s applied=%v round=%d wins=%v phase=%v locked=%v countdown=%v objective_seconds=%.3f", opcode, applied, world.match.round_current, world.match.round_wins, world.match.phase, world.move_lock, world.countdown, world.match.objective.rotation_remaining))
			case "l":
				state.snapshots_received += 1
				if state.snapshots_received <= 3 || state.snapshots_received % 120 == 0 {
					kproto.network_log("server-sync", fmt.tprintf("local snapshot=%d live_inputs_sent=%d; responding with v", state.snapshots_received, state.input_logged))
				}
				// Browser answers each local snapshot, including l(0), with PONG.
				if !send_control(state, "v") { state.connected = false; return }
			case "dc", "error":
				kproto.network_log("server-error", fmt.tprintf("opcode=%s args=%v", opcode, packet[1:]))
				reason := "Server did not supply a text reason"
				if len(packet) > 1 { if text, ok := packet[1].(string); ok && len(text) > 0 { reason = text } }
				when ODIN_OS == .Windows {
					if !state.ready_received && client_access_browser_link(&client.join_link) && accessui.token_rejection_reason(reason) {
						// Defer cleanup/retry until the next client tick, outside packet iteration.
						state.auth_rejected, state.connected = true, false
						return
					}
				}
				client.team_pending = false
				client.spawn_pending = false
				client.requested_team = client.lobby_team
				client_selection_status(client, reason)
				delete(state.server_error)
				state.server_error = strings.clone(reason)
				krunker_ws_set_status(client, fmt.tprintf("Krunker %s: %s; see logs/krunker-network.log", opcode == "dc" ? "disconnected" : "error", reason))
				if opcode == "dc" { state.connected = false; return }
			case "cpt":
				kproto.network_log("server-error", "server requested a CAPTCHA challenge; native challenge response is not implemented")
				krunker_ws_set_status(client, "Krunker requested a CAPTCHA; see logs/krunker-network.log")
			case "fe":
				// FAILED_TO_ENTER is usually sent without arguments. It still ends
				// this request, so the player can retry instead of waiting forever.
				if state.spawned { kproto.network_log("spawn", "ignored late entry rejection during active life"); continue }
				client.krunker_world.respawn_available_at = max(client.krunker_world.respawn_available_at, glfw.GetTime()+0.5)
				client.spawn_pending, client.team_pending = false, false
				client.requested_team = client.lobby_team
				state.bootstrapped, state.secondary_response_pending = false, false
				state.bootstrap_step = 0
				reason := "Server rejected entry. Try again."
				if len(packet) > 1 { if text, ok := packet[1].(string); ok && len(text) > 0 { reason = text } }
				client_selection_status(client, reason)
				kproto.network_log("spawn", fmt.tprintf("entry rejected; server_args=%v", packet[1:]))
				krunker_ws_set_status(client, reason)
			case "ch":
				krunker_client_receive_chat(client, packet)
			case "chi":
				// Localized server chat can explain a subsequent argumentless fe.
				kproto.network_log("server-notice", fmt.tprintf("localized_args=%v", packet[1:]))
				krunker_client_apply_notice(client, packet)
			case "gmsg":
				if len(packet) > 1 {
					if message, ok := packet[1].(string); ok && message != state.last_server_message {
						delete(state.last_server_message)
						state.last_server_message = strings.clone(message)
						kproto.network_log("server-message", fmt.tprintf("opcode=%s message=%s countdown=%v seconds=%.3f", opcode, message, client.krunker_world.countdown, client.krunker_world.countdown_remaining))
						if !state.spawned {
							if message == "wt" { krunker_ws_set_status(client, "Connected to lobby; server is waiting for players before spawning.") }
							else if len(message) > 0 { krunker_ws_set_status(client, fmt.tprintf("Lobby: %s", message)) }
						}
					}
				}
			case "f":
				kproto.network_log("input", fmt.tprintf("server reported input synchronization failure args=%v next_seq=%d unsent=%d predicted=%d; next q will reset input synchronization", packet[1:], state.input_sequence, len(state.input_commands), len(client.predicted_inputs)))
				krunker_client_reset_prediction(client)
				state.input_reset = true
			}
		}
		if applied { krunker_client_sync_world(client) }
	}
}

// Krunker's START handler (krunkbox u3e) calls St.reset(), which sets isn=0
// and clears tmpInpts, and clears every pending input field: the reset flag
// (eR=0), the first input id (M7=null), batched durations/angles/controls
// and shot timing. The next life's inputs therefore restart at id 0. Only
// input state is reset; the packet counter (ah_num) continues.
krunker_ws_reset_input_for_start :: proc(client: ^Client, now: f64) {
	state := &client.krunker
	kproto.network_log("input", fmt.tprintf("start: restarting input ids at 0 (previous next_seq=%d unsent=%d predicted=%d reset_pending=%v)", state.input_sequence, len(state.input_commands), len(client.predicted_inputs), state.input_reset))
	krunker_client_reset_prediction(client)
	state.input_sequence = 0
	state.input_reset = false
	state.input_blocked = false
	state.stale_ack_logged = false
	krunker_ws_ghost_reset(state)
	state.life_start_at = now
	died_at := client.krunker_world.respawn_available_at - KRUNKER_DEATH_DELAY_SECONDS
	kproto.network_log("respawn", fmt.tprintf("start: death->en=%s en->start=%s", krunker_ws_ms_between(died_at, state.life_en_at), krunker_ws_ms_between(state.life_en_at, now)))
}

KRUNKER_DEATH_DELAY_SECONDS :: 2.8 // krunkbox bS=2800 (deathDelay); health.odin uses the same

krunker_ws_ms_between :: proc(from, to: f64) -> string {
	if from <= 0 || to <= 0 || to < from { return "n/a" }
	return fmt.tprintf("%.0fms", (to - from) * 1000)
}

// Server ACK bookkeeping for one life. An ACK that is not below
// input_sequence is not for anything this life sent: ignore it, so it can
// neither drop fresh predictions nor move the sequence past queued commands
// (krunker_input_encode_batch requires consecutive ids). Returns whether the
// ACK applies to this life.
krunker_ws_accept_ack :: proc(state: ^Krunker_WS_State, ack: i32) -> bool {
	if ack >= state.input_sequence {
		if !state.stale_ack_logged {
			state.stale_ack_logged = true
			kproto.network_log("input", fmt.tprintf("ignoring ACK %d for an input this life has not sent (next_seq=%d unsent=%d)", ack, state.input_sequence, len(state.input_commands)))
		}
		return false
	}
	return true
}

// The server sends l (SYNC_PLAYER, the only packet carrying the ACK) from
// syncState once per second (syncFrequency=1). Two consecutive syncs without
// ACK progress, with q sent before each, is about 2 s of ignored input. A
// wall-clock threshold of 1 s fired whenever an l was a few ms late.
KRUNKER_GHOST_STALLED_SYNCS :: 2
KRUNKER_GHOST_COOLDOWN_SECONDS :: 3.0

krunker_ws_ghost_reset :: proc(state: ^Krunker_WS_State) {
	state.ghost_ack, state.ghost_ack_seen = 0, false
	state.ghost_stalled_syncs, state.ghost_fired_at = 0, 0
	state.sync_sent, state.sync_sent_ms, state.sync_at, state.life_syncs = false, 0, 0, 0
	state.life_first_ack_logged = false
}

// A q went out, carrying sent_ms of input time.
krunker_ws_ghost_note_sent :: proc(state: ^Krunker_WS_State, sent_ms: f64) {
	state.sync_sent = true
	state.sync_sent_ms += sent_ms
}

// A fresh l arrived. accepted is krunker_ws_accept_ack's verdict: a stale
// ACK is no progress. A sync is stalled only when q went out since the
// previous sync and the ACK did not move, so a late l never counts.
krunker_ws_ghost_note_sync :: proc(state: ^Krunker_WS_State, ack: i32, accepted: bool, now: f64) {
	progressed := accepted && (!state.ghost_ack_seen || ack != state.ghost_ack)
	if progressed {
		// ACKs are monotonic within a life, so any change is progress.
		state.ghost_ack, state.ghost_ack_seen = ack, true
		if !state.life_first_ack_logged && ack > 0 {
			state.life_first_ack_logged = true
			kproto.network_log("respawn", fmt.tprintf("first ACK %d: start->ack=%s", ack, krunker_ws_ms_between(state.life_start_at, now)))
		}
	}
	if progressed || !state.sync_sent { state.ghost_stalled_syncs = 0 } else { state.ghost_stalled_syncs += 1 }
	// Input time sent vs wall time between syncs, to show whether Krodin
	// ever sends more input time than real time.
	wall := state.sync_at > 0 ? now - state.sync_at : 0
	skew := wall > 0.5 && abs(state.sync_sent_ms / 1000 - wall) > 0.15 * wall
	if state.life_syncs < 4 || state.ghost_stalled_syncs > 0 || skew {
		kproto.network_log("sync", fmt.tprintf("life_sync=%d ack=%d accepted=%v progressed=%v stalled=%d input_ms=%.0f wall_ms=%.0f next_seq=%d unsent=%d", state.life_syncs, ack, accepted, progressed, state.ghost_stalled_syncs, state.sync_sent_ms, wall * 1000, state.input_sequence, len(state.input_commands)))
	}
	state.sync_sent, state.sync_sent_ms, state.sync_at = false, 0, now
	state.life_syncs += 1
}

// Krodin's own recovery for "ghosting": the server stops acknowledging our
// inputs (e.g. it dropped the f reset while we were dead) and never sends
// another f. After KRUNKER_GHOST_STALLED_SYNCS syncs without ACK progress
// while alive, the next q carries the reset flag, at most once per
// KRUNKER_GHOST_COOLDOWN_SECONDS.
krunker_ws_ghost_watchdog :: proc(client: ^Client, now: f64) -> bool {
	state := &client.krunker
	world := &client.krunker_world
	if !state.connected || !state.spawned || !state.bootstrapped || client.me == nil || !client.me.active { state.ghost_stalled_syncs = 0; return false }
	if world.has_match && world.match.phase == .ENDED { state.ghost_stalled_syncs = 0; return false }
	if state.ghost_stalled_syncs < KRUNKER_GHOST_STALLED_SYNCS { return false }
	if state.ghost_fired_at > 0 && now - state.ghost_fired_at < KRUNKER_GHOST_COOLDOWN_SECONDS { return false }
	kproto.network_log("ghost", fmt.tprintf("no input ACK progress over %d syncs (ack=%d seen=%v next_seq=%d unsent=%d); next q carries the reset flag", state.ghost_stalled_syncs, state.ghost_ack, state.ghost_ack_seen, state.input_sequence, len(state.input_commands)))
	state.input_reset = true
	state.ghost_fired_at = now
	state.ghost_stalled_syncs = 0
	return true
}

// Encoding is side-effect free: E_AGAIN and pending control messages must keep
// the reset flag, commands, and packet counter for the eventual successful send.
krunker_ws_encode_input :: proc(state: ^Krunker_WS_State) -> ([]byte, bool) {
	count := min(len(state.input_commands), kproto.KRUNKER_MAX_INPUT_BATCH)
	counter := kproto.krunker_msgpack_counter_next(state.ah_num, "q")
	return kproto.krunker_input_encode_batch(state.input_commands[:count], counter, false, state.input_reset)
}

krunker_ws_input_sent :: proc(state: ^Krunker_WS_State, count: int, counter: u8) {
	state.ah_num = counter
	state.input_reset = false
	copy(state.input_commands[:], state.input_commands[count:])
	resize(&state.input_commands, len(state.input_commands)-count)
	state.send_elapsed = max(0, state.send_elapsed - KRUNKER_SEND_SECONDS)
	state.input_logged += 1
}

krunker_ws_send_input :: proc(client: ^Client) {
	state := &client.krunker
	if state.spectate || client.krunker_world.spectating do return
	if !state.connected || !state.spawned || !state.bootstrapped do return
	if state.send_elapsed < KRUNKER_SEND_SECONDS || len(state.input_commands) == 0 do return
	if state.transport == nil {
		kproto.network_log("input", "ERROR q: no WebSocket connection")
		krunker_ws_set_status(client, "Live input send failed; see logs/krunker-network.log")
		state.connected = false
		return
	}
	// While an earlier q still waits for the socket, keep commands here: they
	// join the next batch, as they did when a send returned E_AGAIN.
	if krunker_ws_transport_input_backlog(state.transport) > 0 {
		if !state.input_blocked { kproto.network_log("input", fmt.tprintf("q send would block: next_seq=%d unsent=%d", state.input_sequence, len(state.input_commands))) }
		state.input_blocked = true
		return
	}
	count := min(len(state.input_commands), kproto.KRUNKER_MAX_INPUT_BATCH)
	first_sequence := state.input_commands[0].seq
	counter := kproto.krunker_msgpack_counter_next(state.ah_num, "q")
	reset := state.input_reset
	packet, ok := krunker_ws_encode_input(state)
	if !ok { krunker_ws_set_status(client, "Could not encode live movement input."); state.connected = false; return }
	bytes := len(packet)
	if !krunker_ws_transport_send(state.transport, packet, "q", true) {
		kproto.network_log("input", "ERROR q: the WebSocket connection has ended")
		krunker_ws_set_status(client, "Live input send failed; see logs/krunker-network.log")
		state.connected = false
		return
	}
	// Queued packets are sent in order or the connection ends, so the
	// commands, reset flag and counter are consumed now.
	sent_ms: f64
	for command in state.input_commands[:count] { sent_ms += f64(math.round(command.delta * 1000)) }
	krunker_ws_input_sent(state, count, counter)
	krunker_ws_ghost_note_sent(state, sent_ms)
	if state.input_blocked || len(state.input_commands) > kproto.KRUNKER_MAX_INPUT_BATCH {
		kproto.network_log("input", fmt.tprintf("q send resumed/backlog: seq=%d remaining=%d", first_sequence, len(state.input_commands)))
	}
	state.input_blocked = false
	if reset || state.input_logged <= 3 || state.input_logged % 120 == 0 { kproto.network_log("input", fmt.tprintf("SENT live q seq=%d samples=%d last_seq=%d bytes=%d counter=%d reset=%v", first_sequence, count, first_sequence+i32(count)-1, bytes, counter, reset)) }
}

// Network work the frame thread may do per frame. Messages beyond it wait
// for the next frame. The one coalesced replay at the end is bounded by the
// prediction history (KRUNKER_MAX_PREDICTED_INPUTS).
KRUNKER_WS_APPLY_BUDGET :: 2 * time.Millisecond

krunker_ws_poll :: proc(client: ^Client) {
	state := &client.krunker
	if !state.connected && !state.connecting do return
	if state.connected && !krunker_ws_flush_chat(state) { state.connected = false; krunker_ws_set_status(client, "Krunker WebSocket send failed."); return }
	if state.transport != nil { krunker_ws_transport_receive(state.transport, &state.inbox) }
	krunker_ws_process_inbox(client)
	krunker_ws_bootstrap_tick(client)
}

// Applies received messages in arrival order until the budget is spent, then
// runs at most one prediction replay, from the newest acknowledged l.
// The browser-access retry after a rejected token; tests replace it so no
// helper process starts.
Krunker_WS_Access_Retry :: #type proc(client: ^Client, rejected: bool) -> bool
krunker_ws_access_retry_default :: proc(client: ^Client, rejected: bool) -> bool { return client_access_retry(client, rejected) }

krunker_ws_process_inbox :: proc(client: ^Client, send_control: proc(^Krunker_WS_State, string) -> bool = krunker_ws_send, budget := KRUNKER_WS_APPLY_BUDGET, access_retry: Krunker_WS_Access_Retry = krunker_ws_access_retry_default) {
	state := &client.krunker
	start := time.tick_now()
	processed := 0
	failure: Krunker_WS_Event
	failed := false
	state.batching = true
	for processed < len(state.inbox) && (state.connected || state.connecting) {
		if processed > 0 && time.tick_since(start) >= budget {
			state.recv_budget_hits += 1
			if state.recv_budget_hits <= 3 || state.recv_budget_hits % 120 == 0 { kproto.network_log("ws-recv", fmt.tprintf("apply budget reached: messages=%d waiting=%d count=%d unsent=%d", processed, len(state.inbox)-processed, state.recv_budget_hits, len(state.input_commands))) }
			break
		}
		event := &state.inbox[processed]
		processed += 1
		switch event.kind {
		case .MESSAGE:
			state.rx_logged += 1
			if len(event.payload) > 4096 { kproto.network_log("ws-message", fmt.tprintf("reassembled complete message bytes=%d", len(event.payload))) }
			krunker_ws_apply_world(client, event.payload, send_control)
		case .CLOSED:
			reason := string(event.payload)
			code_text := event.close_code >= 0 ? fmt.tprintf("%d", event.close_code) : "absent"
			kproto.network_log("ws-close", fmt.tprintf("code=%s reason=%s close_payload_bytes=%d got_load=%v bootstrapped=%v spawned=%v live_inputs_sent=%d local_snapshots=%d", code_text, reason, event.close_code >= 0 ? len(event.payload) + 2 : 0, state.got_load, state.bootstrapped, state.spawned, state.input_logged, state.snapshots_received))
			if len(state.server_error) > 0 { krunker_ws_set_status(client, fmt.tprintf("Krunker disconnected: %s; see logs/krunker-network.log", state.server_error)) }
			else if event.close_code < 0 { krunker_ws_set_status(client, "Krunker lobby closed the WebSocket without a status or reason; see logs/krunker-network.log") }
			else { krunker_ws_set_status(client, fmt.tprintf("Krunker lobby closed the WebSocket: %d %s; see logs/krunker-network.log", event.close_code, reason)) }
			state.connected = false
		case .FAILED:
			kproto.network_log("ws-recv", fmt.tprintf("ERROR %s got_load=%v bootstrapped=%v spawned=%v", event.text, state.got_load, state.bootstrapped, state.spawned))
			krunker_ws_set_status(client, fmt.tprintf("Krunker WebSocket failed: %s; see logs/krunker-network.log", event.text))
			state.connected = false
		case .STATUS:
			krunker_ws_set_status(client, event.text)
		case .CONNECTED:
			state.connecting, state.connected = false, true
			if state.captcha_handoff { kproto.network_log("captcha", "Native matchmaking accepted the challenge handoff; opening the existing native WebSocket transport.") }
			client_clear_players(client)
			client.game.is_local = false
			client.game.server_hits_players = true
			state.team = 0
			state.class_index = client.selected_class
			state.secondary_index = client_secondary_request(client, client.selected_class)
			// The spectator build joins every lobby as a spectator (en[6] = 1).
			state.spectate, state.spectate_target = KRODIN_SPECTATOR, -1
			krunker_ws_set_status(client, "Krunker WebSocket connected; waiting for server load…")
		case .CONNECT_FAILED:
			failure, failed = event^, true
			failure.text = strings.clone(event.text, context.temp_allocator)
			failure.payload = nil
			state.connecting = false
		}
	}
	allocator := state.transport != nil ? state.transport.allocator : context.allocator
	krunker_ws_events_free(state.inbox[:processed], allocator)
	remove_range(&state.inbox, 0, processed)
	state.batching = false
	krunker_client_finish_replay(client)
	if failed { krunker_ws_connect_failed(client, failure, access_retry) }
}

// Never waits: a join still in flight is aborted and its thread is freed by
// krunker_ws_reap once it finishes.
krunker_ws_disconnect :: proc(state: ^Krunker_WS_State) {
	if state.connected { diag_event(.LEFT_GAME) }
	if state.transport != nil { kproto.network_log("disconnect", fmt.tprintf("connected=%v connecting=%v got_load=%v bootstrapped=%v spawned=%v unapplied=%d", state.connected, state.connecting, state.got_load, state.bootstrapped, state.spawned, len(state.inbox))) }
	allocator := context.allocator
	if state.transport != nil {
		allocator = state.transport.allocator
		krunker_ws_transport_release(state.transport)
	}
	krunker_ws_events_free(state.inbox[:], allocator)
	delete(state.inbox)
	delete(state.player_revisions)
	delete(state.player_loadout_revisions)
	delete(state.input_commands)
	delete(state.last_server_message)
	delete(state.server_error)
	for item in state.chat_outbox { delete(item.text) }
	delete(state.chat_outbox)
	state^ = {}
}

krunker_ws_connect :: proc(client: ^Client, link: ^shared.Join_Link) -> bool {
	diag_event(.JOIN_STARTED)
	// Play as guest: anonymous FRVR access, never the browser helper.
	if client.guest.active && client_access_browser_link(link) {
		if client.access.status == .PENDING { return true }
		client.access.captcha_retried = false
		return client_guest_connect(client, link)
	}
	when ODIN_OS == .Windows {
		if client.access.status == .PENDING { return true }
		client.access.captcha_retried = false
		if client_access_browser_link(link) && !client_access_select(client, time.time_to_unix(time.now())) {
			return client_access_begin(client)
		}
	}
	return krunker_ws_connect_ready(client, link)
}

// Starts a join on the WebSocket thread and returns at once. Status updates
// and the result arrive through krunker_ws_poll.
krunker_ws_connect_ready :: proc(client: ^Client, link: ^shared.Join_Link) -> bool {
	krunker_ws_disconnect(&client.krunker)
	state := &client.krunker
	kproto.network_log("curl", fmt.tprintf("library=%s protocol_build=%s counter_increment=%d", string(curl.version()), kproto.KRUNKER_PROTOCOL_BUILD, kproto.KRUNKER_COUNTER_INCREMENT))
	kproto.network_log("invite", fmt.tprintf("scheme=%s host=%s port=%d path=%s game=%s team_hint=%s", link.scheme, link.host, link.port, link.path, link.game_id, link.team_hint))
	join: Krunker_WS_Join
	status := "Connecting to the lobby…"
	if link.scheme == "http" || link.scheme == "https" || link.scheme == "game" {
		status = "Resolving lobby through Krunker matchmaker…"
		guest := client.guest.active
		token := guest ? client.guest.access_token : client.access.token
		legacy := ""
		defer delete(legacy)
		when ODIN_OS != .Windows {
			if !guest {
				legacy, _ = krunker_ws_access_token()
				token = legacy
			}
		}
		proof := client.access.captcha_token
		client.access.captcha_token = ""
		if len(client.access.assignment_url) > 0 {
			join.url = client.access.assignment_url
			client.access.assignment_url = ""
			delete(proof)
			kproto.network_log("captcha", "Using the exact browser-selected WebSocket URL through native libcurl; assigned browser socket was never opened.")
		} else {
			join.game_id, join.token, join.captcha = strings.clone(link.game_id), strings.clone(token), proof
		}
		state.captcha_handoff = len(join.captcha) > 0
	} else if link.scheme == "ws" || link.scheme == "wss" {
		join.url = strings.clone(link.raw)
	} else {
		krunker_ws_set_status(client, "This link is not a Krunker WebSocket or browser invite.")
		return false
	}
	transport := krunker_ws_transport_create(nil, join)
	if !krunker_ws_transport_start(transport) {
		krunker_ws_transport_release(transport)
		krunker_ws_set_status(client, "Could not start the Krunker WebSocket thread or initialize libcurl.")
		return false
	}
	state.transport, state.connecting = transport, true
	krunker_ws_set_status(client, status)
	return true
}

// The frame-thread half of a failed join: the same browser access, CAPTCHA
// and status decisions the synchronous join made.
krunker_ws_connect_failed :: proc(client: ^Client, failure: Krunker_WS_Event, access_retry: Krunker_WS_Access_Retry = krunker_ws_access_retry_default) {
	state := &client.krunker
	krunker_ws_disconnect(state)
	error_text := failure.text
	guest := client.guest.active
	if failure.upgrade {
		rejected := failure.rejected && client_access_browser_link(&client.join_link)
		if rejected && guest {
			if client_guest_retry(client, true) { return }
		} else if rejected {
			when ODIN_OS == .Windows {
				if access_retry(client, true) { return }
			}
		}
		if len(error_text) == 0 { error_text = fmt.tprintf("Krunker WebSocket upgrade failed: HTTP %d curl=%v; see logs/krunker-network.log", failure.http_status, failure.code) }
		krunker_ws_set_status(client, error_text)
		return
	}
	when ODIN_OS == .Windows {
		// Guests use the same verification handoff as Krunker's page.
		if failure.needs_captcha {
			if !client.access.captcha_retried {
				if client_captcha_begin(client, krunker_captcha_start) { return }
				if client.access.status == .ERROR {
					if guest { krunker_ws_set_status(client, GUEST_CAPTCHA_HELPER_TEXT) }
					return
				}
			} else { error_text = accessui.status_text("CAPTCHA_REJECTED") }
		}
		if !guest && access_retry(client, failure.rejected) { return }
	} else {
		if guest && failure.needs_captcha { error_text = GUEST_CAPTCHA_UNSUPPORTED_TEXT }
	}
	if guest && client_guest_retry(client, failure.rejected) { return }
	krunker_ws_set_status(client, error_text)
}
