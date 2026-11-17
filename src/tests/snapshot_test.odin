package main

// Snapshot (protocol 12) tests: delta encode/decode round trips (missing and
// stale baselines, tick and value wrap-around), quantisation bounds,
// malformed input, acks, relevance culling (entering and leaving view
// distance), bandwidth per client before and after at 64 and 128 tick with 8
// players, and a loopback session on an OS-chosen port.

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:net"
import "core:time"

import shared "../shared"
import ded "../server/dedicated"

@(private = "file")
snap_fail :: proc(format: string, args: ..any) -> bool {
	fmt.eprintf("Snapshot test failed: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	return false
}

@(private = "file")
random_state :: proc(gen: rand.Generator, id: u32) -> shared.Packet_Player_State {
	r :: proc(gen: rand.Generator, lo, hi: f32) -> f32 { return lo + rand.float32(gen) * (hi - lo) }
	return {
		player_id = id, active = rand.float32(gen) < 0.8, team = i32(rand.int_max(3, gen)), class_id = i32(rand.int_max(8, gen)), secondary_id = 2,
		position = {r(gen, -400, 400), r(gen, -20, 120), r(gen, -400, 400)}, velocity = {r(gen, -0.1, 0.1), r(gen, -0.2, 0.1), r(gen, -0.1, 0.1)},
		x_dir = shared.input_angle_quantize(r(gen, -1.5, 1.5)), y_dir = shared.input_angle_quantize(r(gen, -3.14, 3.14)),
		on_ground = rand.float32(gen) < 0.5, on_ramp = rand.float32(gen) < 0.1, can_slide = rand.float32(gen) < 0.3, on_wall = u8(rand.int_max(5, gen)),
		wall_jump_count = u8(rand.int_max(3, gen)), can_slide_timer = r(gen, 0, 1), cylinder_velocity = {r(gen, -0.1, 0.1), r(gen, -0.1, 0.1)},
		crouch_val = r(gen, 0, 1), aim_val = r(gen, 0, 1), slide_timer = r(gen, 0, 0.5), jump_timer = r(gen, 0, 0.3),
		health = r(gen, 1, 100), max_health = 100, weapon_id = u8(rand.int_max(4, gen)), active_ammo = u32(rand.int_max(30, gen)),
		shot_seq = rand.uint32(gen), ack_seq = i32(rand.int_max(100000, gen)) - 1, spread_plus = r(gen, 0, 0.2), projectile_shot_seq = u32(rand.int_max(50, gen)),
		score = u32(rand.int_max(5000, gen)), kills = u32(rand.int_max(40, gen)), deaths = u32(rand.int_max(40, gen)),
	}
}

@(private = "file")
frames_equal :: proc(a, b: ^shared.Snapshot_Frame) -> bool {
	if a.tick != b.tick || a.server_time_ms != b.server_time_ms || a.you_id != b.you_id || a.match != b.match || a.count != b.count || a.lobby_len != b.lobby_len { return false }
	if string(a.lobby[:a.lobby_len]) != string(b.lobby[:b.lobby_len]) { return false }
	for i in 0 ..< a.count {
		if a.entities[i].id != b.entities[i].id || a.entities[i].words != b.entities[i].words { return false }
	}
	return true
}

@(private = "file")
make_lobby :: proc(frame: ^shared.Snapshot_Frame, local_id: u32, ids: []u32, result: u8 = 0) {
	lobby := shared.Lobby_State{local_id = local_id, team = 1, capacity = 4, select_team = true, team_result = result, team_names = {"Red", "Blue"}}
	for id in ids { lobby.players[lobby.count] = {id = id, team = 1, class_id = 0}; lobby.count += 1 }
	frame.lobby_len = shared.packet_serialize_lobby(frame.lobby[:], &lobby)
}

// Random frames through a server ring and a client ring with a random ack
// delay: every delta decodes to exactly the frame that was encoded, players
// join and leave, and missing or stale baselines behave.
test_snapshot_delta_round_trip :: proc() -> bool {
	r := rand.create(12345)
	gen := rand.default_random_generator(&r)
	server_ring, client_ring := new(shared.Snapshot_Ring), new(shared.Snapshot_Ring)
	defer { free(server_ring); free(client_ring) }
	frame, decoded := new(shared.Snapshot_Frame), new(shared.Snapshot_Frame)
	defer { free(frame); free(decoded) }
	buf := make([]byte, shared.SNAPSHOT_MAX_PACKET)
	defer delete(buf)
	impacts: [dynamic]shared.Bullet_Impact
	kills: [dynamic]shared.Kill_Event
	defer { delete(impacts); delete(kills) }

	// Start just below the u32 wrap so ticks and baselines cross it.
	tick := u32(0xFFFFFF00)
	acked: u32
	has_ack := false
	states: [12]shared.Packet_Player_State
	for &s, i in states { s = random_state(gen, u32(i + 1)) }
	full_bytes, delta_bytes, fulls, deltas := 0, 0, 0, 0
	for step in 0 ..< 600 {
		tick += 1 + u32(rand.int_max(2, gen))
		// Players move a little; some leave and join.
		for &s in states {
			s.position += {rand.float32(gen) - 0.5, (rand.float32(gen) - 0.5) * 0.2, rand.float32(gen) - 0.5}
			s.y_dir = shared.input_angle_quantize(shared.normalize_angle(s.y_dir + 0.05)) // crosses +-PI regularly
			s.x_dir = shared.input_angle_quantize(clamp(s.x_dir + (rand.float32(gen) - 0.5) * 0.1, -1.5, 1.5))
			if rand.float32(gen) < 0.05 { s.shot_seq += 1 }
			s.ack_seq += 3
			if rand.float32(gen) < 0.01 { s.score += 100 }
		}
		frame^ = {}
		frame.tick, frame.server_time_ms, frame.you_id = tick, tick * 15, 3
		frame.match = {phase = 1, map_index = 2, time_ds = u32(3000 - step / 10), team1_score = 5, active_object_index = -1, send_rate = 64, tick_rate = 64}
		ids: [dynamic]u32
		defer delete(ids)
		for &s, i in states {
			if (step / 50 + i) % 7 == 0 && i != 2 { continue } // absent for a while
			frame.entities[frame.count] = shared.snapshot_entity_from_state(&s, s.player_id == frame.you_id)
			frame.count += 1
			append(&ids, s.player_id)
		}
		make_lobby(frame, 3, ids[:], step % 97 == 0 ? 1 : 0)
		clear(&impacts)
		clear(&kills)
		events_in: [2]shared.Bullet_Impact
		events := step % 13 == 0
		if events { events_in = {{origin = {1, 2, 3}, position = {4, 5, 6}, normal = {0, 1, 0}, kind = .World, hit = true, object_index = 7, weapon_id = 1, shooter_uid = 3}, {kind = .Miss, object_index = -1, weapon_id = 1, shooter_uid = 4}} }
		kill_in := [1]shared.Kill_Event{{victim_uid = 4, killer_uid = 3, weapon_id = 1, headshot = true}}
		baseline := has_ack ? shared.snapshot_ring_find(server_ring, acked) : nil
		size := events ? shared.snapshot_encode(buf, frame, baseline, events_in[:], kill_in[:]) : shared.snapshot_encode(buf, frame, baseline)
		if size == 0 { return snap_fail("tick %d did not encode", tick) }
		usable := shared.snapshot_usable_baseline(frame, baseline)
		if usable == nil { fulls += 1; full_bytes += size } else { deltas += 1; delta_bytes += size }
		shared.snapshot_ring_store(server_ring, frame)
		result := shared.snapshot_decode(buf[:size], client_ring, decoded, &impacts, &kills)
		if result != .OK { return snap_fail("tick %d decoded %v (baseline %v)", tick, result, usable != nil) }
		if !frames_equal(frame, decoded) { return snap_fail("tick %d: decoded frame differs (full %v)", tick, usable == nil) }
		if events && (len(impacts) != 2 || impacts[0].object_index != 7 || len(kills) != 1 || !kills[0].headshot) { return snap_fail("events lost: %d impacts, %d kills", len(impacts), len(kills)) }
		if !events && (len(impacts) != 0 || len(kills) != 0) { return snap_fail("phantom events") }
		shared.snapshot_ring_store(client_ring, decoded)
		// The own player's floats are bit-exact.
		for &e in decoded.entities[:decoded.count] {
			if e.id != 3 { continue }
			own := shared.snapshot_entity_to_state(&e, true)
			want := states[2]
			if own.position != want.position || own.velocity != want.velocity || own.can_slide_timer != want.can_slide_timer || own.ack_seq != want.ack_seq || own.cylinder_velocity != want.cylinder_velocity {
				return snap_fail("own player not exact: %v vs %v", own.position, want.position)
			}
		}
		if step % 80 < 40 { acked, has_ack = tick, true } // acks stop for 40 of every 80: stale baselines
	}
	// A delta against a snapshot the client no longer has asks for a full one.
	empty := new(shared.Snapshot_Ring)
	defer free(empty)
	baseline := shared.snapshot_ring_find(server_ring, tick)
	frame.tick = tick + 1
	size := shared.snapshot_encode(buf, frame, baseline)
	if shared.snapshot_decode(buf[:size], empty, decoded) != .NO_BASELINE { return snap_fail("a delta without its baseline must report NO_BASELINE") }
	// Too old a baseline (or a different recipient) is a full snapshot.
	frame.tick = tick + shared.SNAPSHOT_MAX_BACK + 1
	if shared.snapshot_usable_baseline(frame, baseline) != nil { return snap_fail("a baseline %d ticks old must not be used", shared.SNAPSHOT_MAX_BACK + 1) }
	frame.tick = tick + shared.SNAPSHOT_MAX_BACK
	if shared.snapshot_usable_baseline(frame, baseline) == nil { return snap_fail("a baseline %d ticks old is still usable", shared.SNAPSHOT_MAX_BACK) }
	frame.you_id = 4
	if shared.snapshot_usable_baseline(frame, baseline) != nil { return snap_fail("a baseline for another recipient must not be used") }
	if !shared.snapshot_tick_after(2, 0xFFFFFFFE) || shared.snapshot_tick_after(0xFFFFFFFE, 2) { return snap_fail("tick comparison must survive the wrap") }
	fmt.printf("  delta round trip: %d full (%.0f B avg), %d delta (%.0f B avg), ticks wrapped to %d\n",
		fulls, f64(full_bytes) / f64(max(1, fulls)), deltas, f64(delta_bytes) / f64(max(1, deltas)), tick)
	if fulls < 2 || deltas < 400 || delta_bytes / max(1, deltas) >= full_bytes / max(1, fulls) {
		return snap_fail("expected mostly smaller deltas: %d full, %d delta", fulls, deltas)
	}
	fmt.println("Snapshot delta round trip tests OK")
	return true
}

// Quantisation of other players: error bounds, lossless milliradian angles,
// clamped extremes, and values that stay in their valid ranges.
test_snapshot_quantisation :: proc() -> bool {
	r := rand.create(777)
	gen := rand.default_random_generator(&r)
	max_pos, max_angle, max_crouch, max_health: f32
	for _ in 0 ..< 20000 {
		s := random_state(gen, 9)
		s.health = rand.float32(gen) * 100
		e := shared.snapshot_entity_from_state(&s, false)
		d := shared.snapshot_entity_to_state(&e, false)
		for c in 0 ..< 3 { max_pos = max(max_pos, abs(d.position[c] - s.position[c])) }
		max_angle = max(max_angle, abs(shared.normalize_angle(d.y_dir - s.y_dir)), abs(d.x_dir - s.x_dir))
		max_crouch = max(max_crouch, abs(d.crouch_val - s.crouch_val), abs(d.aim_val - s.aim_val))
		max_health = max(max_health, abs(d.health - s.health))
		if d.crouch_val < 0 || d.crouch_val > 1 || d.health > f32(d.max_health) || d.health < 0 { return snap_fail("dequantised values out of range: crouch %f health %f", d.crouch_val, d.health) }
		if d.velocity != {} || d.ack_seq != -1 || d.slide_timer != 0 { return snap_fail("own-only fields must not reach other players") }
		if d.team != s.team || d.class_id != s.class_id || d.shot_seq != s.shot_seq || d.on_wall != s.on_wall || d.on_ground != s.on_ground || d.active != s.active { return snap_fail("integer fields must be exact") }
		// Angles on the command grid are lossless.
		if d.x_dir != s.x_dir || (abs(s.y_dir) < 3.1415 && d.y_dir != s.y_dir) { return snap_fail("milliradian angles must be lossless: %v %v vs %v %v", d.x_dir, d.y_dir, s.x_dir, s.y_dir) }
	}
	fmt.printf("  quantisation: max error position %.5f (bound %.5f), angle %.6f rad, crouch/aim %.5f, health %.4f\n", max_pos, 0.5 / 128.0, max_angle, max_crouch, max_health)
	if max_pos > 0.5 / 128 + 1e-4 || max_angle > 0.0005 + 1e-6 || max_crouch > 0.5 / 255 + 1e-6 || max_health > 0.5 / 16 + 1e-4 {
		return snap_fail("quantisation error over its bound")
	}
	// Extremes clamp instead of wrapping; NaN becomes 0.
	huge := shared.Packet_Player_State{player_id = 1, position = {1e12, -1e12, f32(math.nan_f32())}, max_health = 100}
	e := shared.snapshot_entity_from_state(&huge, false)
	d := shared.snapshot_entity_to_state(&e, false)
	if !(d.position.x > 1e7 && d.position.y < -1e7 && d.position.z == 0) { return snap_fail("extremes: %v", d.position) }
	fmt.println("Snapshot quantisation tests OK")
	return true
}

// Truncated, extended and corrupted packets fail cleanly.
test_snapshot_malformed :: proc() -> bool {
	r := rand.create(99)
	gen := rand.default_random_generator(&r)
	ring := new(shared.Snapshot_Ring)
	defer free(ring)
	frame, decoded := new(shared.Snapshot_Frame), new(shared.Snapshot_Frame)
	defer { free(frame); free(decoded) }
	frame.tick, frame.you_id = 100, 1
	frame.match = {tick_rate = 64, send_rate = 64}
	for i in 0 ..< 4 {
		s := random_state(gen, u32(i + 1))
		frame.entities[i] = shared.snapshot_entity_from_state(&s, i == 0)
	}
	frame.count = 4
	make_lobby(frame, 1, {1, 2, 3, 4})
	buf: [4096]byte
	size := shared.snapshot_encode(buf[:], frame, nil)
	if shared.snapshot_decode(buf[:size], ring, decoded) != .OK { return snap_fail("a valid full snapshot must decode") }
	bad := 0
	for cut in 0 ..< size - 1 {
		// Keep the header's length consistent with the cut.
		tmp: [4096]byte
		copy(tmp[:], buf[:cut])
		if cut >= shared.PACKET_HEADER_SIZE { tmp[5], tmp[6] = u8((cut - 7) & 0xff), u8((cut - 7) >> 8) }
		if shared.snapshot_decode(tmp[:cut], ring, decoded) != .OK { bad += 1 }
	}
	flips := 0
	for _ in 0 ..< 2000 {
		tmp := buf
		tmp[shared.PACKET_HEADER_SIZE + rand.int_max(size - shared.PACKET_HEADER_SIZE, gen)] ~= u8(1 + rand.int_max(255, gen))
		if shared.snapshot_decode(tmp[:size], ring, decoded) == .OK { flips += 1 } // may still be valid; must not crash
	}
	ack: [shared.SNAPSHOT_ACK_PACKET_SIZE]byte
	n := shared.packet_serialize_snapshot_ack(ack[:], 0xFFFFFFFF, shared.SNAPSHOT_ACK_RESET)
	tick, flags, ok := shared.packet_deserialize_snapshot_ack(ack[:n])
	if !ok || tick != 0xFFFFFFFF || flags != shared.SNAPSHOT_ACK_RESET { return snap_fail("ack round trip") }
	ack[11] = 0x80
	if _, _, bad_ok := shared.packet_deserialize_snapshot_ack(ack[:n]); bad_ok { return snap_fail("unknown ack flags must be rejected") }
	fmt.printf("  malformed: %d of %d truncations rejected, %d of 2000 byte flips still decoded\n", bad, size - 1, flips)
	if bad != size - 1 { return snap_fail("a truncated snapshot decoded") }
	fmt.println("Snapshot malformed input tests OK")
	return true
}

@(private = "file")
Snap_World :: struct {
	server:   ^ded.Server,
	gameplay: ^shared.Gameplay_Config,
}

@(private = "file")
snap_world_init :: proc(w: ^Snap_World, tick_rate: int) -> bool {
	settings := ded.server_settings_default()
	ded.server_settings_apply_args(&settings, []string{"--maps", "burg", "--rotation", "sequential", "--tick-rate", fmt.tprint(tick_rate)}, nil)
	ded.server_settings_validate(&settings, nil)
	w.gameplay = shared.config_load_gameplay()
	w.server = new(ded.Server)
	if !ded.server_init(w.server, settings, w.gameplay, false) { return false }
	w.server.game.match.phase = .LIVE
	w.server.game.match.phase_remaining = 0
	return true
}

@(private = "file")
snap_world_destroy :: proc(w: ^Snap_World) {
	ded.server_destroy(w.server)
	free(w.server)
	shared.config_destroy_gameplay(w.gameplay)
}

@(private = "file")
fake_client :: proc(ns: ^ded.Net_Server, player: ^shared.Player) -> ^ded.Net_Client {
	c := new(ded.Net_Client)
	c.id, c.active, c.joined, c.player = u32(player.uid), true, true, player
	c.snapshots = new(shared.Snapshot_Ring)
	append(&ns.clients, c)
	return c
}

@(private = "file")
fake_clients_destroy :: proc(ns: ^ded.Net_Server) {
	for c in ns.clients { free(c.snapshots); free(c) }
	delete(ns.clients)
	ns.clients = nil
}

// Relevance: a player beyond view_distance arrives culled (inactive, pose
// frozen) and comes back with its real pose; a dead recipient sees everyone.
test_snapshot_relevance :: proc() -> bool {
	w: Snap_World
	if !snap_world_init(&w, 64) { snap_world_destroy(&w); return snap_fail("relevance: server_init") }
	defer snap_world_destroy(&w)
	game := &w.server.game
	players: [3]^shared.Player
	for &p, i in players {
		p = shared.player_init(game)
		p.uid = i32(i + 1)
		shared.game_players_add(game, p)
		shared.player_spawn(p, 0)
	}
	players[0].position, players[1].position, players[2].position = {0, 0, 0}, {50, 0, 0}, {500, 0, 0}
	ns: ded.Net_Server
	ns.view_distance = 200
	ns.team_capacity = 4
	defer fake_clients_destroy(&ns)
	me := fake_client(&ns, players[0])
	for p in players[1:] { fake_client(&ns, p) }
	client_ring := new(shared.Snapshot_Ring)
	frame, decoded := new(shared.Snapshot_Frame), new(shared.Snapshot_Frame)
	defer { free(client_ring); free(frame); free(decoded) }
	buf := make([]byte, shared.SNAPSHOT_MAX_PACKET)
	defer delete(buf)
	match: shared.Snapshot_Match
	tick := u64(10)
	send :: proc(ns: ^ded.Net_Server, game: ^shared.Game, me: ^ded.Net_Client, frame, decoded: ^shared.Snapshot_Frame, ring: ^shared.Snapshot_Ring, buf: []byte, tick: u64, match: shared.Snapshot_Match) -> (states: [3]shared.Packet_Player_State, size: int, ok: bool) {
		frame.you_id, frame.tick = me.id, u32(tick)
		baseline := me.has_ack ? shared.snapshot_usable_baseline(frame, shared.snapshot_ring_find(me.snapshots, me.acked_tick)) : nil
		ded.net_server_build_snapshot(ns, game, me, frame, baseline, tick, 64, match)
		size = shared.snapshot_encode(buf, frame, baseline)
		shared.snapshot_ring_store(me.snapshots, frame)
		if shared.snapshot_decode(buf[:size], ring, decoded) != .OK || decoded.count != 3 { return }
		shared.snapshot_ring_store(ring, decoded)
		ded.net_server_snapshot_ack(me, decoded.tick, 0)
		for &e, i in decoded.entities[:3] { states[i] = shared.snapshot_entity_to_state(&e, e.id == me.id) }
		return states, size, true
	}
	s, size0, ok := send(&ns, game, me, frame, decoded, client_ring, buf, tick, match)
	if !ok || !s[1].active || s[2].active || !s[2].culled || s[2].position != {} {
		return snap_fail("far player must arrive culled with no pose: near %v far %v culled %v at %v", s[1].active, s[2].active, s[2].culled, s[2].position)
	}
	if s[2].team != players[2].team || s[2].class_id != players[2].class_index { return snap_fail("a culled player still carries its scoreboard info") }
	// Comes within range: real pose, active.
	tick += 1
	players[2].position = {150, 0, 0}
	s, _, ok = send(&ns, game, me, frame, decoded, client_ring, buf, tick, match)
	if !ok || !s[2].active || s[2].culled || abs(s[2].position.x - 150) > 0.01 { return snap_fail("entering: active %v culled %v at %v", s[2].active, s[2].culled, s[2].position) }
	// Leaves again: culled, pose frozen at the last one sent.
	tick += 1
	players[2].position = {900, 0, 0}
	players[2].score = 300
	size3: int
	ok3: bool
	s, size3, ok3 = send(&ns, game, me, frame, decoded, client_ring, buf, tick, match)
	if !ok3 || s[2].active || !s[2].culled || abs(s[2].position.x - 150) > 0.01 || s[2].score != 300 {
		return snap_fail("leaving: active %v culled %v at %v score %d", s[2].active, s[2].culled, s[2].position, s[2].score)
	}
	// Staying out costs almost nothing.
	tick += 1
	players[2].position = {950, 0, 30}
	_, size4, _ := send(&ns, game, me, frame, decoded, client_ring, buf, tick, match)
	// A dead recipient (death cam) sees everyone, as Krunker only culls for
	// living players.
	tick += 1
	players[0].active = false
	s, _, ok = send(&ns, game, me, frame, decoded, client_ring, buf, tick, match)
	if !ok || !s[2].active || abs(s[2].position.x - 950) > 0.01 { return snap_fail("a dead recipient must see far players: %v", s[2].position) }
	players[0].active = true
	if me.snapshot_stats.culled != 3 { return snap_fail("culled count %d, want 3", me.snapshot_stats.culled) }
	fmt.printf("  relevance (view_distance 200): first snapshot %d B, leaving view %d B, staying out %d B\n", size0, size3, size4)
	fmt.println("Snapshot relevance tests OK")
	return true
}

// Bytes per client per second with 8 players moving, jumping, turning and
// shooting on burg, at 64 and 128 tick. Before: protocol 11 (every 2nd tick,
// MATCH_STATE + LOBBY_STATE + one 129-byte GAME_STATE per player + impact
// and kill packets). After: protocol 12, delta against the snapshot acked one
// round trip (60 ms) earlier, every tick (and every 2nd tick for comparison).
test_snapshot_bandwidth :: proc() -> bool {
	fmt.println("  bandwidth per client, 8 players, 60 ms round trip:")
	for tick_rate in ([2]int{64, 128}) {
		before, after, after_half := snapshot_bandwidth_run(tick_rate)
		if after <= 0 || before <= 0 { return snap_fail("bandwidth run at %d failed", tick_rate) }
		// The new format at the same rate as before must be far smaller, and
		// one per tick must still not cost more than the old every-2nd-tick.
		if after_half >= before * 0.5 || after >= before {
			return snap_fail("%d tick: before %.2f KB/s, after %.2f KB/s (every 2nd tick %.2f)", tick_rate, before, after, after_half)
		}
	}
	fmt.println("Snapshot bandwidth tests OK")
	return true
}

@(private = "file")
snapshot_bandwidth_run :: proc(tick_rate: int) -> (before_kbs, after_kbs, after_half_kbs: f64) {
	PLAYERS :: 8
	SECONDS :: 6
	RTT :: 0.06
	w: Snap_World
	if !snap_world_init(&w, tick_rate) { snap_world_destroy(&w); return }
	defer snap_world_destroy(&w)
	game := &w.server.game
	ns: ded.Net_Server
	ns.team_capacity = 4
	defer fake_clients_destroy(&ns)
	bots: [PLAYERS]^shared.Player
	streams: [PLAYERS]ded.Command_Stream
	remainders: [PLAYERS]f64
	for i in 0 ..< PLAYERS {
		bot := shared.player_init(game)
		bot.uid = i32(i + 1)
		bot.team = i32(i % 2 + 1)
		shared.game_players_add(game, bot)
		shared.player_spawn(bot, i32(i % len(game.classes)))
		bot.swap_timer = 0
		bots[i] = bot
		ded.command_stream_init(&streams[i], 0)
		fake_client(&ns, bot)
	}
	defer for &cs in streams { ded.command_stream_destroy(&cs) }
	// A second set of rings for the every-2nd-tick variant.
	half_rings: [PLAYERS]^shared.Snapshot_Ring
	half_acked: [PLAYERS]u32
	half_has: [PLAYERS]bool
	for &ring in half_rings { ring = new(shared.Snapshot_Ring) }
	defer for ring in half_rings { free(ring) }
	frame := new(shared.Snapshot_Frame)
	defer free(frame)
	buf := make([]byte, shared.SNAPSHOT_MAX_PACKET)
	defer delete(buf)
	rtt_ticks := u32(math.ceil(RTT * f64(tick_rate)))
	ticks := tick_rate * SECONDS
	dt := 1 / f32(tick_rate)
	before_bytes, after_bytes, after_half_bytes, after_count: int
	// Events each per-tick snapshot carries: only those since the previous tick.
	impact_mark, kill_mark: int
	for tick in 1 ..= ticks {
		for bot, i in bots {
			ded.command_stream_push(&streams[i], shared.Input{
				seq = i32(tick), delta = shared.input_command_duration_ms(f64(tick_rate), 1, &remainders[i]) / 1000,
				move_dir = i32((tick / (tick_rate / 2) + i) % 8), y_dir = shared.input_angle_quantize(shared.normalize_angle(f32(tick) * 0.02 + f32(i))),
				x_dir = shared.input_angle_quantize(0.2 * math.sin(f32(tick) * 0.03)),
				shoot = (tick + i * 7) % 40 < 6, jump = (tick + i * 13) % (tick_rate * 2) == 0,
			})
		}
		game.now = f32(tick) * dt
		for &cs, i in streams { ded.command_stream_run(&cs, bots[i], game, f64(tick) * f64(dt)) }
		shared.game_tick(game, f32(tick) * dt, dt)
		for bot in bots { if !bot.active { shared.player_spawn(bot, bot.class_index); bot.swap_timer = 0 } }

		match_state := shared.packet_match_state_from_game(game)
		tick_impacts, tick_kills := game.impacts[min(impact_mark, len(game.impacts)):], game.kill_events[min(kill_mark, len(game.kill_events)):]
		for client, i in ns.clients {
			// The ack arrives one round trip after the snapshot was sent.
			if tick > int(rtt_ticks) {
				ded.net_server_snapshot_ack(client, u32(tick) - rtt_ticks, 0)
			}
			match_state.send_rate = f32(tick_rate)
			match := shared.snapshot_match_from_state(&match_state, tick_rate)
			frame.you_id, frame.tick = client.id, u32(tick)
			baseline := client.has_ack ? shared.snapshot_usable_baseline(frame, shared.snapshot_ring_find(client.snapshots, client.acked_tick)) : nil
			ded.net_server_build_snapshot(&ns, game, client, frame, baseline, u64(tick), tick_rate, match)
			size := shared.snapshot_encode(buf, frame, baseline, tick_impacts, tick_kills)
			shared.snapshot_ring_store(client.snapshots, frame)
			after_bytes += size
			after_count += 1
			if tick % 2 == 0 {
				// Every 2nd tick, delta against the newest of those acked.
				if tick > int(rtt_ticks) + 1 {
					acked := u32(tick) - rtt_ticks
					acked -= acked % 2
					if shared.snapshot_ring_find(half_rings[i], acked) != nil { half_acked[i], half_has[i] = acked, true }
				}
				match_state.send_rate = f32(tick_rate) / 2
				half_match := shared.snapshot_match_from_state(&match_state, tick_rate)
				half_base := half_has[i] ? shared.snapshot_usable_baseline(frame, shared.snapshot_ring_find(half_rings[i], half_acked[i])) : nil
				ded.net_server_build_snapshot(&ns, game, client, frame, half_base, u64(tick), tick_rate, half_match)
				after_half_bytes += shared.snapshot_encode(buf, frame, half_base, game.impacts[:], game.kill_events[:])
				shared.snapshot_ring_store(half_rings[i], frame)
				// Protocol 11: MATCH_STATE (roster) + LOBBY_STATE + N x GAME_STATE + events.
				before_bytes += (7 + 42 + 4 * PLAYERS) + (7 + 80 + 12 * PLAYERS) + PLAYERS * (7 + shared.PACKET_PLAYER_STATE_PAYLOAD_SIZE) +
					len(game.impacts) * (7 + shared.PACKET_BULLET_IMPACT_PAYLOAD_SIZE) + len(game.kill_events) * (7 + shared.PACKET_KILL_FEED_PAYLOAD_SIZE)
			}
		}
		impact_mark, kill_mark = len(game.impacts), len(game.kill_events)
		if tick % 2 == 0 {
			clear(&game.impacts)
			clear(&game.kill_events)
			impact_mark, kill_mark = 0, 0
		}
		free_all(context.temp_allocator)
	}
	seconds := f64(SECONDS)
	before_kbs = f64(before_bytes) / PLAYERS / seconds / 1024
	after_kbs = f64(after_bytes) / PLAYERS / seconds / 1024
	after_half_kbs = f64(after_half_bytes) / PLAYERS / seconds / 1024
	half := ticks / 2 * PLAYERS
	fmt.printf("  %v tick | protocol 11, every 2nd tick: %v Hz, %.0f B per snapshot, %.2f KB/s per client\n", tick_rate, tick_rate / 2, f64(before_bytes) / f64(half), before_kbs)
	fmt.printf("  %v tick | protocol 12, every 2nd tick: %v Hz, %.0f B per snapshot, %.2f KB/s per client\n", tick_rate, tick_rate / 2, f64(after_half_bytes) / f64(half), after_half_kbs)
	fmt.printf("  %v tick | protocol 12, every tick (default): %v Hz, %.0f B per snapshot, %.2f KB/s per client\n", tick_rate, tick_rate, f64(after_bytes) / f64(after_count), after_kbs)
	return
}

// A real listener on an OS-chosen loopback port (never 21015), 64 tick with
// snapshot_rate 32: snapshots are numbered every 2nd tick with the matching
// server time, the first is full, acknowledged ones turn into deltas that
// decode, and a RESET ack brings a full one back.
test_snapshot_loopback :: proc() -> bool {
	settings := ded.server_settings_default()
	ded.server_settings_apply_args(&settings, []string{"--bind", "127.0.0.1", "--port", "0", "--maps", "burg", "--snapshot-rate", "32"}, nil)
	ded.server_settings_validate(&settings, nil)
	server := new(ded.Server)
	defer free(server)
	if !ded.server_init(server, settings, nil, true) {
		ded.server_destroy(server)
		return snap_fail("loopback: could not listen")
	}
	defer ded.server_destroy(server)
	if server.snapshot_divisor != 2 { return snap_fail("snapshot_rate 32 at 64 tick: divisor %d", server.snapshot_divisor) }
	port := ded.net_server_port(&server.net)
	if port == 0 || port == 21015 { return snap_fail("loopback: port %d", port) }
	socket, err := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = port})
	if err != nil { return snap_fail("loopback: dial %v", err) }
	defer net.close(socket)
	net.set_blocking(socket, false)
	connect: [32]byte
	net.send_tcp(socket, connect[:shared.packet_serialize_connect(connect[:], 0)])

	ring := new(shared.Snapshot_Ring)
	frame := new(shared.Snapshot_Frame)
	defer { free(ring); free(frame) }
	recv := make([]byte, shared.SNAPSHOT_MAX_PACKET)
	defer delete(recv)
	recv_len := 0
	received, fulls, deltas, own_seen := 0, 0, 0, 0
	last_tick: u32
	reset_sent, full_after_reset := false, false
	start := time.tick_now()
	for time.tick_since(start) < 5 * time.Second && !(full_after_reset && deltas > 20) {
		ded.server_step(server)
		for {
			n, rerr := net.recv_tcp(socket, recv[recv_len:])
			if n <= 0 { if rerr != nil && rerr != .Would_Block && rerr != .Timeout { return snap_fail("loopback recv %v", rerr) }; break }
			recv_len += n
		}
		for recv_len >= shared.PACKET_HEADER_SIZE {
			header, _ := shared.packet_deserialize_header(recv[:recv_len])
			size := shared.PACKET_HEADER_SIZE + int(header.payload_len)
			if recv_len < size { break }
			if header.packet_type == .SNAPSHOT {
				if shared.snapshot_decode(recv[:size], ring, frame) != .OK { return snap_fail("loopback: snapshot %d did not decode", received) }
				full := recv[shared.PACKET_HEADER_SIZE + 8] == 0
				if received == 0 && !full { return snap_fail("the first snapshot must be full") }
				if received > 0 && frame.tick - last_tick != 2 { return snap_fail("ticks %d -> %d, want a step of 2", last_tick, frame.tick) }
				if frame.tick % 2 != 0 || frame.server_time_ms != frame.tick * 1000 / 64 || frame.match.tick_rate != 64 || frame.match.send_rate != 32 {
					return snap_fail("tick %d time %d ms rate %d send %.1f", frame.tick, frame.server_time_ms, frame.match.tick_rate, frame.match.send_rate)
				}
				if full { fulls += 1 } else { deltas += 1 }
				if reset_sent && full { full_after_reset = true }
				for &e in frame.entities[:frame.count] { if e.id == frame.you_id { own_seen += 1 } }
				shared.snapshot_ring_store(ring, frame)
				last_tick = frame.tick
				received += 1
				ack: [shared.SNAPSHOT_ACK_PACKET_SIZE]byte
				flags: u8 = 0
				if deltas == 10 && !reset_sent { flags, reset_sent = shared.SNAPSHOT_ACK_RESET, true }
				net.send_tcp(socket, ack[:shared.packet_serialize_snapshot_ack(ack[:], frame.tick, flags)])
			}
			recv_len -= size
			copy(recv[:recv_len], recv[size:size + recv_len])
		}
		time.sleep(time.Millisecond)
	}
	fmt.printf("  loopback: %d snapshots (%d full, %d delta), own player in %d, full again after RESET %v\n", received, fulls, deltas, own_seen, full_after_reset)
	if deltas <= 20 || !full_after_reset || own_seen == 0 || fulls > 4 {
		return snap_fail("loopback: %d full, %d delta, own %d, reset %v", fulls, deltas, own_seen, full_after_reset)
	}
	fmt.println("Snapshot loopback tests OK")
	return true
}

// snapshot_rate and view_distance from server.toml and flags: defaults (one
// snapshot per tick, no culling), divisors, clamping with warnings.
test_snapshot_settings :: proc() -> bool {
	Case :: struct { toml: string, args: []string, rate, divisor: int, view: f32, warn: bool }
	cases := []Case{
		{"", nil, 64, 1, 0, false},
		{"tick_rate = 128\n", nil, 128, 1, 0, false},
		{"snapshot_rate = 32\n", nil, 32, 2, 0, false},
		{"snapshot_rate = 10\nview_distance = 1000\n", nil, 10, 6, 1000, true}, // 64 / 10 is not whole: every 6th tick
		{"", {"--tick-rate", "128", "--snapshot-rate", "64", "--view-distance", "500"}, 64, 2, 500, false},
		{"snapshot_rate = 500\n", nil, 64, 1, 0, true}, // clamped to the tick rate
		{"snapshot_rate = 3\n", nil, 10, 6, 0, true}, // raised to Krunker's default snf
		{"view_distance = 20\n", nil, 64, 1, 100, true},
		{"view_distance = -5\n", nil, 64, 1, 0, true},
	}
	for c, i in cases {
		s := ded.server_settings_default()
		defer ded.server_settings_destroy(&s)
		warnings: [dynamic]string
		defer ded.warnings_destroy(&warnings)
		if len(c.toml) > 0 { ded.server_settings_apply_toml(&s, c.toml, &warnings) }
		if c.args != nil { ded.server_settings_apply_args(&s, c.args, &warnings) }
		ded.server_settings_validate(&s, &warnings)
		divisor := ded.server_snapshot_divisor(&s)
		if s.snapshot_rate != c.rate || divisor != c.divisor || s.view_distance != c.view || (len(warnings) > 0) != c.warn {
			return snap_fail("settings case %d: rate %d divisor %d view %v warnings %v", i, s.snapshot_rate, divisor, s.view_distance, warnings[:])
		}
	}
	fmt.println("Snapshot settings tests OK")
	return true
}

test_snapshots :: proc() -> bool {
	return test_snapshot_settings() && test_snapshot_delta_round_trip() && test_snapshot_quantisation() && test_snapshot_malformed() &&
		test_snapshot_relevance() && test_snapshot_bandwidth() && test_snapshot_loopback()
}
