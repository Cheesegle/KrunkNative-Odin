package main

// Dedicated server tests: settings precedence and clamping, the rotation and
// intermission state machine on fake time, tick scheduling, max_players over
// loopback, and a headless 128 Hz soak with bots.

import "core:fmt"
import "core:math"
import "core:net"
import "core:strings"
import "core:time"

import shared "../shared"
import ded "../server/dedicated"

@(private = "file")
server_test_fail :: proc(format: string, args: ..any) -> bool {
	fmt.eprintf("Server test failed: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	return false
}

@(private = "file")
warnings_contain :: proc(warnings: []string, needle: string) -> bool {
	for w in warnings {
		if strings.contains(w, needle) { return true }
	}
	return false
}

@(private = "file")
slot_of :: proc(name: string) -> i32 {
	slot, _, _ := ded.map_name_to_slot(name)
	return slot
}

test_server_settings :: proc() -> bool {
	// Defaults.
	{
		s := ded.server_settings_default()
		defer ded.server_settings_destroy(&s)
		warnings: [dynamic]string
		defer ded.warnings_destroy(&warnings)
		ded.server_settings_validate(&s, &warnings)
		if s.port != 21015 || s.tick_rate != 64 || s.max_players != 8 || s.team_size != 4 || s.intermission != 25 || s.rotation != .SHUFFLE || s.mode != 0 {
			return server_test_fail("defaults: %v", s)
		}
		if len(s.maps) != len(shared.ROTATION_MAPS) || len(warnings) != 0 {
			return server_test_fail("default rotation has %d maps, %d warnings", len(s.maps), len(warnings))
		}
	}

	// server.toml values, unknown and unloadable maps, clamping, and the
	// admin password never appearing in warnings or the summary.
	{
		source := `
# comment
[server]
name = "  My Krodin Server  "
port = 27015
tick_rate = 200
max_players = 0
team_size = 9
maps = ["burg", "LittleTown", "nope", "ss_v3", "frontier"]
rotation = "sequential"
intermission = 300
admin_password = "hunter2-secret"
stats_interval = 5
colour = "red"
`
		s := ded.server_settings_default()
		defer ded.server_settings_destroy(&s)
		warnings: [dynamic]string
		defer ded.warnings_destroy(&warnings)
		if !ded.server_settings_apply_toml(&s, source, &warnings) {
			return server_test_fail("server.toml did not parse")
		}
		ded.server_settings_validate(&s, &warnings)
		if s.port != 27015 || s.tick_rate != 128 || s.max_players != 1 || s.team_size != 4 || s.intermission != 120 || s.stats_interval != 5 || s.rotation != .SEQUENTIAL {
			return server_test_fail("toml clamp: port %d tick %d max %d team %d interm %.1f", s.port, s.tick_rate, s.max_players, s.team_size, s.intermission)
		}
		if s.name != "My Krodin Server" || s.admin_password != "hunter2-secret" {
			return server_test_fail("toml strings: %q", s.name)
		}
		if len(s.maps) != 3 || s.maps[0] != slot_of("burg") || s.maps[1] != slot_of("sandstorm") || s.maps[2] != slot_of("frontier") {
			return server_test_fail("toml maps: %v", s.maps[:])
		}
		for needle in ([]string{"tick_rate 200", "max_players 0", "team_size 9", "intermission", "\"LittleTown\" is not in the client map table", "unknown map \"nope\"", "unknown key \"colour\""}) {
			if !warnings_contain(warnings[:], needle) {
				return server_test_fail("missing warning %q in %v", needle, warnings[:])
			}
		}
		summary := ded.server_settings_summary(&s)
		if warnings_contain(warnings[:], "hunter2") || strings.contains(summary, "hunter2") || !strings.contains(summary, "admin_password=set") {
			return server_test_fail("admin password leaked or not reported as set: %s", summary)
		}
	}

	// Precedence: defaults < game.toml tick_rate < server.toml < flags.
	{
		s := ded.server_settings_default()
		defer ded.server_settings_destroy(&s)
		ded.server_settings_apply_game_toml_tick_rate(&s, 30)
		if s.tick_rate != 30 {
			return server_test_fail("game.toml fallback ignored")
		}
		ded.server_settings_apply_toml(&s, "tick_rate = 96\nmax_players = 10\nport = 1234\n", nil)
		if s.tick_rate != 96 || s.max_players != 10 {
			return server_test_fail("server.toml did not override game.toml")
		}
		args := []string{"--tick-rate", "100", "--port=27016", "--maps", "subzero,burg", "--name", "Flag Name", "--admin-password=pw", "--intermission", "3", "--team-size", "2", "--rotation", "sequential", "--mode", "Hardpoint", "--stats-interval", "0", "--quit-after", "1.5", "--seed", "7"}
		result, err := ded.server_settings_apply_args(&s, args, nil)
		if result != .OK {
			return server_test_fail("flags rejected: %s", err)
		}
		warnings: [dynamic]string
		defer ded.warnings_destroy(&warnings)
		ded.server_settings_validate(&s, &warnings)
		if s.tick_rate != 100 || s.port != 27016 || s.max_players != 10 || s.name != "Flag Name" || s.admin_password != "pw" || s.team_size != 2 || s.stats_interval != 0 || s.quit_after != 1.5 || s.seed != 7 {
			return server_test_fail("flags did not override: %v", s)
		}
		if s.intermission != 5 || !warnings_contain(warnings[:], "intermission 3.0") {
			return server_test_fail("intermission not clamped to 5: %.1f", s.intermission)
		}
		if len(s.maps) != 2 || s.maps[0] != slot_of("subzero") || s.maps[1] != slot_of("burg") {
			return server_test_fail("flag maps: %v", s.maps[:])
		}
	}

	// Flag errors and help.
	{
		cases := []struct { args: []string, want: ded.Args_Result } {
			{{"--help"}, .HELP},
			{{"--port", "21015", "-h"}, .HELP},
			{{"--bogus", "1"}, .ERROR},
			{{"--tick-rate", "fast"}, .ERROR},
			{{"--port"}, .ERROR},
			{{"stray"}, .ERROR},
			{{"--rotation", "backwards"}, .ERROR},
			{{"--mode", "ffa"}, .ERROR},
		}
		for c in cases {
			s := ded.server_settings_default()
			result, _ := ded.server_settings_apply_args(&s, c.args, nil)
			ded.server_settings_destroy(&s)
			if result != c.want {
				return server_test_fail("args %v gave %v, want %v", c.args, result, c.want)
			}
		}
		if path, found := ded.server_args_config_path([]string{"--port", "1", "--config=custom.toml"}); !found || path != "custom.toml" {
			return server_test_fail("--config not found before loading")
		}
		if !ded.server_args_wants_help([]string{"--tick-rate", "64", "--help"}) {
			return server_test_fail("--help not detected")
		}
	}

	// Long names are cut on a UTF-8 boundary.
	{
		s := ded.server_settings_default()
		defer ded.server_settings_destroy(&s)
		ded.server_settings_apply_args(&s, []string{"--name", "ééééééééééééééééééééééééé"}, nil) // 50 bytes
		ded.server_settings_validate(&s, nil)
		if len(s.name) > ded.MAX_SERVER_NAME_LEN || len(s.name) % 2 != 0 {
			return server_test_fail("name not truncated on a rune boundary: %d bytes", len(s.name))
		}
	}

	// DISCONNECT reason round trip; the client's own DISCONNECT stays empty.
	{
		buf: [16]byte
		size := shared.packet_serialize_disconnect(buf[:], .SERVER_FULL)
		reason, ok := shared.packet_deserialize_disconnect(buf[:size])
		if size != shared.PACKET_HEADER_SIZE + 1 || !ok || reason != .SERVER_FULL {
			return server_test_fail("disconnect reason round trip")
		}
		size = shared.packet_serialize_disconnect(buf[:])
		reason, ok = shared.packet_deserialize_disconnect(buf[:size])
		if size != shared.PACKET_HEADER_SIZE || !ok || reason != .NONE {
			return server_test_fail("empty disconnect round trip")
		}
	}

	fmt.println("Server settings tests OK")
	return true
}

test_server_rotation :: proc() -> bool {
	// Pure state machine on fake time.
	{
		rotation := []i32{0, 3, 5}
		lc: ded.Lifecycle
		ded.lifecycle_init(&lc, rotation, .SEQUENTIAL, 5, 1)
		if ded.lifecycle_current_slot(&lc) != 0 {
			return server_test_fail("sequential rotation should start on the first map")
		}
		dt: f32 = 1.0 / 64.0
		for _ in 0 ..< 640 {
			if start, _ := ded.lifecycle_update(&lc, .LIVE, dt); start {
				return server_test_fail("rotated while the match was live")
			}
		}
		expected := []i32{3, 5, 0, 3}
		for want in expected {
			// The match ends; the next map must start after exactly 5 s.
			ticks := 0
			started := false
			slot: i32
			for ticks < 64 * 10 && !started {
				started, slot = ded.lifecycle_update(&lc, .ENDED, dt)
				ticks += 1
			}
			// One tick to notice ENDED, then 5 s * 64 ticks of intermission.
			if !started || slot != want || ticks != 1 + 5 * 64 {
				return server_test_fail("sequential: started %v slot %d after %d ticks, want slot %d after %d", started, slot, ticks, want, 1 + 5 * 64)
			}
			if lc.state != .PLAYING {
				return server_test_fail("lifecycle should be PLAYING after rotating")
			}
			// The new match is live: no second rotation from a stale phase.
			if again, _ := ded.lifecycle_update(&lc, .LIVE, dt); again {
				return server_test_fail("rotated twice for one ended match")
			}
		}

		// Shuffle: deterministic per seed, never the same map twice in a row,
		// and every map comes up.
		a, b: ded.Lifecycle
		maps := []i32{0, 1, 2, 3, 4, 5, 6, 7}
		ded.lifecycle_init(&a, maps, .SHUFFLE, 5, 42)
		ded.lifecycle_init(&b, maps, .SHUFFLE, 5, 42)
		seen: [8]bool
		prev := ded.lifecycle_current_slot(&a)
		seen[prev] = true
		for _ in 0 ..< 64 {
			next_a := ded.lifecycle_advance(&a)
			next_b := ded.lifecycle_advance(&b)
			if next_a != next_b || next_a == prev {
				return server_test_fail("shuffle: %d after %d (twin %d)", next_a, prev, next_b)
			}
			seen[next_a] = true
			prev = next_a
		}
		for s in seen { if !s { return server_test_fail("shuffle never visited every map: %v", seen) } }

		single: ded.Lifecycle
		ded.lifecycle_init(&single, []i32{4}, .SHUFFLE, 5, 9)
		if ded.lifecycle_advance(&single) != 4 {
			return server_test_fail("one-map rotation must replay that map")
		}
	}

	// The real server sim: an ended match rotates to the next map after the
	// intermission, keeps connected players (waiting to deploy, scores reset)
	// and puts the new map slot in MATCH_STATE.
	{
		settings := ded.server_settings_default()
		ded.server_settings_apply_args(&settings, []string{"--maps", "burg,sandstorm", "--rotation", "sequential", "--intermission", "5", "--tick-rate", "64"}, nil)
		ded.server_settings_validate(&settings, nil)
		server := new(ded.Server)
		defer free(server)
		if !ded.server_init(server, settings, nil, false) {
			ded.server_destroy(server)
			return server_test_fail("server_init failed")
		}
		defer ded.server_destroy(server)
		game := &server.game
		if game.current_map_index != slot_of("burg") || !game.ready {
			return server_test_fail("first map is slot %d, want burg", game.current_map_index)
		}

		bot := shared.player_init(game)
		bot.uid = 77
		shared.game_players_add(game, bot)
		shared.player_spawn(bot, 0)
		bot.score, bot.kills = 120, 3

		for _ in 0 ..< 64 { ded.server_step(server) }
		// End the match as game_resolve_round does.
		game.match.phase = .ENDED
		game.move_lock = true
		ded.server_step(server)
		if server.lifecycle.state != .INTERMISSION {
			return server_test_fail("server did not enter the intermission")
		}
		for _ in 0 ..< 64 * 2 { ded.server_step(server) }
		if game.current_map_index != slot_of("burg") || game.match.phase != .ENDED {
			return server_test_fail("map changed before the intermission ended")
		}
		if math.abs(game.match.time_remaining - 3.0) > 0.05 {
			return server_test_fail("intermission countdown is %.3f s, want ~3", game.match.time_remaining)
		}
		for _ in 0 ..< 64 * 3 { ded.server_step(server) }
		if game.current_map_index != slot_of("sandstorm") || !game.ready || game.match.phase == .ENDED || game.move_lock {
			return server_test_fail("after the intermission: slot %d phase %v", game.current_map_index, game.match.phase)
		}
		if len(game.players) != 1 || game.players[0] != bot || bot.active || bot.score != 0 || bot.kills != 0 {
			return server_test_fail("player not carried over to the next match: %d players, active %v score %d", len(game.players), bot.active, bot.score)
		}
		state := shared.packet_match_state_from_game(game)
		if state.map_index != slot_of("sandstorm") || state.player_count != 1 {
			return server_test_fail("MATCH_STATE carries slot %d", state.map_index)
		}
		// The bot deploys again on the new map, as a client's CONNECT does.
		shared.player_spawn(bot, 0)
		for _ in 0 ..< 8 { ded.server_step(server) }
		if !bot.active || bot.position.y < game.map_inst.death_y {
			return server_test_fail("bot could not respawn on the new map")
		}
		if server.lifecycle.matches != 1 {
			return server_test_fail("matches = %d", server.lifecycle.matches)
		}
	}

	fmt.println("Server rotation tests OK")
	return true
}

test_server_tick_timing :: proc() -> bool {
	period: i64 = 1_000_000_000 / 128

	// Fake time: deadlines are absolute, so wake-up jitter never drifts.
	{
		clock: ded.Tick_Clock
		ded.tick_clock_init(&clock, 128, 0)
		now: i64 = 0
		ticks := 0
		for i in 0 ..< 1280 {
			// Wake up 0..1.5 ms late, deterministically.
			now = i64(i) * period + i64((i * 7919) % 1500) * 1000
			for {
				due, lateness := ded.tick_clock_due(&clock, now)
				if !due { break }
				if lateness >= period { return server_test_fail("tick %d reported %d ns late", ticks, lateness) }
				ticks += 1
				ded.tick_clock_advance(&clock)
			}
		}
		if ticks != 1280 || clock.resyncs != 0 {
			return server_test_fail("fake clock ran %d ticks (resyncs %d), want 1280", ticks, clock.resyncs)
		}
		// A 100 ms hitch is caught up tick by tick; a 1 s stall is skipped.
		now += 100_000_000
		want_caught := int((now - clock.next) / period) + 1
		caught := 0
		for {
			due, _ := ded.tick_clock_due(&clock, now)
			if !due { break }
			caught += 1
			ded.tick_clock_advance(&clock)
		}
		if caught != want_caught || caught < 12 || clock.resyncs != 0 {
			return server_test_fail("100 ms hitch ran %d catch-up ticks, want %d", caught, want_caught)
		}
		now += 1_000_000_000
		caught = 0
		for {
			due, _ := ded.tick_clock_due(&clock, now)
			if !due { break }
			caught += 1
			ded.tick_clock_advance(&clock)
		}
		if caught != 1 || clock.resyncs != 1 {
			return server_test_fail("1 s stall ran %d ticks (resyncs %d), want 1 and 1", caught, clock.resyncs)
		}
	}

	// Budget accounting.
	{
		b: ded.Tick_Budget
		ded.tick_budget_init(&b, 128)
		ded.tick_budget_record(&b, 1.0, 0)
		ded.tick_budget_record(&b, 3.0, 0.5)
		ded.tick_budget_record(&b, 9.0, 8.0)
		if b.ticks != 3 || math.abs(ded.tick_budget_average(&b) - 13.0 / 3.0) > 1e-9 || b.max_ms != 9 || b.late != 1 || b.over != 1 {
			return server_test_fail("tick budget: %v", b)
		}
		ded.tick_budget_reset(&b)
		if b.ticks != 0 || math.abs(b.budget_ms - 7.8125) > 1e-9 {
			return server_test_fail("tick budget reset: %v", b)
		}
	}

	// Real time, bounded to ~0.5 s: 64 ticks at 128 Hz on the platform sleeper
	// (high-resolution waitable timer on Windows, clock_nanosleep on Linux).
	{
		sleeper: ded.Precise_Sleeper
		ded.precise_sleeper_init(&sleeper)
		defer ded.precise_sleeper_destroy(&sleeper)
		start := time.tick_now()
		clock: ded.Tick_Clock
		ded.tick_clock_init(&clock, 128, 0)
		TICKS :: 64
		starts: [TICKS]i64
		count := 0
		deadline := 2 * time.Second
		for count < TICKS && time.tick_since(start) < deadline {
			now := i64(time.tick_since(start))
			if due, _ := ded.tick_clock_due(&clock, now); due {
				starts[count] = now
				count += 1
				ded.tick_clock_advance(&clock)
				continue
			}
			ded.precise_sleep(&sleeper, ded.tick_clock_wait(&clock, i64(time.tick_since(start))))
		}
		if count != TICKS {
			return server_test_fail("real-time clock ran %d of %d ticks in 2 s", count, TICKS)
		}
		total := starts[TICKS - 1] - starts[0]
		ideal := i64(TICKS - 1) * period
		max_late: i64
		sum_late: i64
		for t, i in starts {
			late := t - i64(i) * period
			max_late = max(max_late, late)
			sum_late += late
		}
		fmt.printf("  tick timing (%s): 63 periods in %.3f ms (ideal %.3f), mean wake lateness %.3f ms, max %.3f ms\n",
			ded.precise_sleeper_kind(&sleeper), f64(total) / 1e6, f64(ideal) / 1e6, f64(sum_late) / f64(TICKS) / 1e6, f64(max_late) / 1e6)
		// Absolute deadlines: the run can be late by one wake-up, never drift.
		if total < ideal - 1_000_000 || total > ideal + 30_000_000 {
			return server_test_fail("real-time ticks took %.3f ms for an ideal %.3f ms", f64(total) / 1e6, f64(ideal) / 1e6)
		}
	}

	fmt.println("Server tick timing tests OK")
	return true
}

test_server_max_players :: proc() -> bool {
	settings := ded.server_settings_default()
	ded.server_settings_apply_args(&settings, []string{"--bind", "127.0.0.1", "--port", "0", "--max-players", "2", "--maps", "burg"}, nil)
	// Port 0 asks the OS for a free loopback port.
	ded.server_settings_validate(&settings, nil)
	if settings.port != 0 {
		ded.server_settings_destroy(&settings)
		return server_test_fail("port 0 was not kept")
	}
	server := new(ded.Server)
	defer free(server)
	if !ded.server_init(server, settings, nil, true) {
		ded.server_destroy(server)
		return server_test_fail("could not listen on loopback")
	}
	defer ded.server_destroy(server)
	port := ded.net_server_port(&server.net)
	if port == 0 {
		return server_test_fail("no bound port")
	}

	sockets: [3]net.TCP_Socket
	open: [3]bool
	defer {
		for socket, i in sockets {
			if open[i] { net.close(socket) }
		}
	}
	for &socket, i in sockets {
		s, err := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = port})
		if err != nil {
			return server_test_fail("dial %d failed: %v", i, err)
		}
		socket = s
		open[i] = true
	}

	start := time.tick_now()
	for (len(server.net.clients) < 2 || server.net.rejected < 1) && time.tick_since(start) < 3 * time.Second {
		ded.net_server_poll(&server.net, &server.game)
		time.sleep(time.Millisecond)
	}
	if len(server.net.clients) != 2 || server.net.rejected != 1 {
		return server_test_fail("accepted %d, rejected %d; want 2 and 1", len(server.net.clients), server.net.rejected)
	}
	// Refused connections never get a player; accepted ones are not in the
	// match until they deploy.
	if len(server.game.players) != 0 {
		return server_test_fail("%d players in the match before anyone deployed", len(server.game.players))
	}

	// The refused client hears why, then the server closes the connection.
	refused := sockets[2]
	net.set_blocking(refused, false)
	buf: [32]byte
	got := 0
	closed := false
	for !closed && time.tick_since(start) < 6 * time.Second {
		n, err := net.recv_tcp(refused, buf[got:])
		if n > 0 {
			got += n
		} else if err == nil {
			closed = true
		} else if err != .Would_Block && err != .Timeout {
			closed = true
		} else {
			time.sleep(time.Millisecond)
		}
	}
	reason, ok := shared.packet_deserialize_disconnect(buf[:got])
	if !ok || reason != .SERVER_FULL || !closed {
		return server_test_fail("refused client got %d bytes (reason %v ok %v closed %v)", got, reason, ok, closed)
	}

	// A slot frees up when a client leaves.
	net.close(sockets[0])
	open[0] = false
	for len(server.net.clients) > 1 && time.tick_since(start) < 9 * time.Second {
		ded.net_server_poll(&server.net, &server.game)
		time.sleep(time.Millisecond)
	}
	if len(server.net.clients) != 1 || !ded.net_server_has_room(&server.net) {
		return server_test_fail("slot not released: %d clients", len(server.net.clients))
	}

	fmt.println("Server max_players tests OK")
	return true
}

// test_server_soak runs 10 s of simulated 128 Hz ticks on a real map with six
// bots moving, jumping, turning and shooting, and checks the average tick
// stays well inside the 7.8 ms budget. No sockets; fixed inputs and tick count.
test_server_soak :: proc() -> bool {
	settings := ded.server_settings_default()
	ded.server_settings_apply_args(&settings, []string{"--maps", "burg", "--rotation", "sequential", "--tick-rate", "128"}, nil)
	ded.server_settings_validate(&settings, nil)
	gameplay := shared.config_load_gameplay()
	defer shared.config_destroy_gameplay(gameplay)
	server := new(ded.Server)
	defer free(server)
	if !ded.server_init(server, settings, gameplay, false) {
		ded.server_destroy(server)
		return server_test_fail("soak: server_init failed")
	}
	defer ded.server_destroy(server)
	game := &server.game
	// Keep the soak on one map and live for its whole run.
	game.match.phase = .LIVE
	game.match.phase_remaining = 0

	BOTS :: 6
	bots: [BOTS]^shared.Player
	start_pos: [BOTS]shared.Vec3
	for i in 0 ..< BOTS {
		bot := shared.player_init(game)
		bot.uid = i32(100 + i)
		shared.game_players_add(game, bot)
		shared.player_spawn(bot, i32(i % len(game.classes)))
		bot.swap_timer = 0
		bots[i] = bot
		start_pos[i] = bot.position
	}

	TICKS :: 128 * 10
	dt := server.fixed_delta
	sum_ms, max_ms: f64
	for tick in 0 ..< TICKS {
		for bot, i in bots {
			if !bot.active { continue }
			input := shared.Input{
				seq      = i32(tick),
				delta    = dt,
				move_dir = i32((tick / 64 + i) % 8),
				y_dir    = f32(tick) * 0.01 + f32(i),
				x_dir    = 0.1 * math.sin(f32(tick) * 0.05),
				shoot    = (tick + i * 7) % 20 < 12,
				jump     = (tick + i * 13) % 96 == 0,
				reload   = (tick + i) % 400 == 0,
			}
			shared.player_queue_input(bot, &input)
		}
		work_start := time.tick_now()
		ded.server_step(server)
		ms := time.duration_milliseconds(time.tick_since(work_start))
		sum_ms += ms
		max_ms = max(max_ms, ms)
		free_all(context.temp_allocator)
	}

	avg := sum_ms / f64(TICKS)
	budget := 1000.0 / 128.0
	shots: u32
	moved := 0
	for bot, i in bots {
		shots += bot.shot_seq
		for v in bot.position { if v != v { return server_test_fail("soak: bot %d position is NaN", i) } }
		if bot.active && (bot.position.x != start_pos[i].x || bot.position.z != start_pos[i].z) { moved += 1 }
	}
	fmt.printf("  soak: %d ticks at 128 Hz, %d bots: avg %.3f ms, max %.3f ms (budget %.3f ms), %d shots\n",
		TICKS, BOTS, avg, max_ms, budget, shots)
	if shots == 0 || moved == 0 {
		return server_test_fail("soak bots did not act: %d shots, %d moved", shots, moved)
	}
	if avg >= budget {
		return server_test_fail("soak average tick %.3f ms is over the %.3f ms budget", avg, budget)
	}
	if server.tick != TICKS || game.match.phase != .LIVE {
		return server_test_fail("soak ran %d ticks, phase %v", server.tick, game.match.phase)
	}

	fmt.println("Server soak test OK")
	return true
}
