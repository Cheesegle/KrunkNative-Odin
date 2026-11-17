package dedicated

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import shared "../../shared"

SERVER_VERSION :: "1.1.0"

Server :: struct {
	settings:     Server_Settings,
	game:         shared.Game,
	net:          Net_Server,
	net_ok:       bool,
	lifecycle:    Lifecycle,
	budget:       Tick_Budget,
	now:          f32,
	fixed_delta:  f32,
	tick:         u64,
	// A snapshot goes out every snapshot_divisor ticks (server_snapshot_divisor).
	snapshot_divisor: int,
}

// The snapshot rate in Hz the server is actually using.
server_send_rate :: proc(server: ^Server) -> f32 {
	return f32(server.settings.tick_rate) / f32(max(1, server.snapshot_divisor))
}

// server_init sets up the simulation (and, with open_net, the listener). The
// Server must not move afterwards: game.server points at it.
server_init :: proc(server: ^Server, settings: Server_Settings, gameplay: ^shared.Gameplay_Config, open_net: bool) -> bool {
	server.settings = settings
	s := &server.settings
	server.fixed_delta = 1.0 / f32(s.tick_rate)
	server.snapshot_divisor = server_snapshot_divisor(s)
	tick_budget_init(&server.budget, s.tick_rate)
	lifecycle_init(&server.lifecycle, s.maps[:], s.rotation, s.intermission, s.seed)

	config := gameplay != nil ? gameplay.game : shared.DEFAULT_GAME_CONFIG
	config.tick_rate = i32(s.tick_rate)
	config.max_players = i32(s.max_players)
	shared.load_default_maps()
	if gameplay != nil {
		shared.game_configure(&server.game, &config, nil, nil, gameplay.weapons, gameplay.classes)
	} else {
		shared.game_configure(&server.game, &config, nil, nil, nil, nil)
	}
	server.game.server = server

	if !server_start_match(server, lifecycle_current_slot(&server.lifecycle)) {
		fmt.eprintln("Failed to load any map from the rotation; quitting.")
		return false
	}

	if open_net {
		ns, ok := net_server_init(s.bind, s.port, s.max_players, s.team_size)
		if !ok {
			return false
		}
		server.net = ns
		server.net.view_distance = s.view_distance
		server.net_ok = true
	}
	return true
}

// server_start_match loads `slot` (falling forward through the rotation if a
// map fails to load) and starts a fresh match on it. Connected players stay
// connected but must deploy again, as after a Krunker game ends.
server_start_match :: proc(server: ^Server, slot: i32) -> bool {
	game := &server.game
	// game_init drops the player list (it does not free players); keep it.
	players := slice.clone(game.players[:], context.temp_allocator)

	target := slot
	ready := false
	for attempt in 0 ..< max(1, len(server.lifecycle.rotation)) {
		shared.game_init(game, target, server.settings.mode, false)
		if game.ready {
			ready = true
			break
		}
		fmt.eprintf("[Server] Map %s (slot %d) failed to load; trying the next one\n", map_slot_name(target), target)
		if attempt + 1 < len(server.lifecycle.rotation) {
			target = lifecycle_advance(&server.lifecycle)
		}
	}

	clear(&game.impacts)
	for player in players {
		player.active = false
		player.respawn_timer = 0
		player.score, player.kills, player.deaths = 0, 0, 0
		shared.game_players_add(game, player)
	}
	if ready {
		fmt.printf("[Server] Match %d on %s: %d spawns, %d objects, %d objectives\n",
			server.lifecycle.matches + 1, map_slot_name(target), len(game.map_inst.spawns), len(game.map_inst.objects), len(game.objective_indices))
	}
	return ready
}

// server_step runs exactly one server tick: network input (every received
// command simulated with its own duration), the world update, match lifecycle
// and (every snapshot_divisor ticks) the snapshot broadcast.
server_step :: proc(server: ^Server) {
	server.tick += 1
	server.now += server.fixed_delta

	if server.net_ok {
		net_server_poll(&server.net, &server.game)
		// Damage and kills inside these commands are stamped with this tick.
		if server.game.ready { server.game.now = server.now }
		net_server_run_commands(&server.net, &server.game)
	}

	shared.game_tick(&server.game, server.now, server.fixed_delta)

	if start_next, slot := lifecycle_update(&server.lifecycle, server.game.match.phase, server.fixed_delta); start_next {
		server_start_match(server, slot)
	} else if server.lifecycle.state == .INTERMISSION {
		// Clients show this as the end screen countdown (Krunker's "t" packet
		// carries endTimer the same way). The sim no longer runs the clock.
		server.game.match.time_remaining = server.lifecycle.remaining
	}

	if server.tick % u64(max(1, server.snapshot_divisor)) == 0 {
		if server.net_ok {
			net_server_broadcast_snapshot(&server.net, &server.game, server.tick, server.settings.tick_rate, server_send_rate(server))
		} else {
			// Headless (tests): nobody consumes the reliable events.
			clear(&server.game.impacts)
			clear(&server.game.kill_events)
		}
	}
}

server_player_count :: proc(server: ^Server) -> int {
	return server.net_ok ? len(server.net.clients) : len(server.game.players)
}

server_destroy :: proc(server: ^Server, reason := shared.Disconnect_Reason.SHUTDOWN) {
	if server.net_ok {
		net_server_close(&server.net, reason)
		server.net_ok = false
	}
	shared.game_destroy(&server.game)
	server_settings_destroy(&server.settings)
}

server_log_budget :: proc(server: ^Server) {
	b := &server.budget
	fmt.printf("[Tick] %d Hz | avg %.3f ms, max %.3f ms (budget %.2f ms) | late %d, over budget %d | players %d",
		server.settings.tick_rate, tick_budget_average(b), b.max_ms, b.budget_ms, b.late, b.over, server_player_count(server))
	if server.net_ok {
		// Snapshot bandwidth: average size, and per client per second.
		stats := net_server_take_snapshot_stats(&server.net)
		seconds := max(b.window, 1e-6)
		clients := f64(stats.snapshots) * f64(server.snapshot_divisor) / max(1, f64(b.ticks))
		fmt.printf(" | snapshots %.4g Hz: %.0f B avg, %.2f KB/s per client, %d full, %d culled",
			server_send_rate(server), f64(stats.bytes) / max(1, f64(stats.snapshots)), f64(stats.bytes) / 1024 / seconds / max(1, clients), stats.full, stats.culled)
	}
	fmt.println()
	tick_budget_reset(b)
}

// server_run is the dedicated server's real-time loop. It returns when a
// shutdown is requested (or quit_after elapses).
server_run :: proc(server: ^Server) {
	sleeper: Precise_Sleeper
	precise_sleeper_init(&sleeper)
	defer precise_sleeper_destroy(&sleeper)
	fmt.printf("[Server] Tick timing: %s\n", precise_sleeper_kind(&sleeper))

	start := time.tick_now()
	clock_ns :: proc(start: time.Tick) -> i64 { return i64(time.tick_since(start)) }
	clock: Tick_Clock
	tick_clock_init(&clock, server.settings.tick_rate, clock_ns(start))
	quit_after_ns := i64(f64(server.settings.quit_after) * 1e9)

	for !quit_requested() {
		now := clock_ns(start)
		if quit_after_ns > 0 && now >= quit_after_ns {
			fmt.printf("[Server] --quit-after %.1f s reached\n", server.settings.quit_after)
			break
		}
		for {
			due, lateness := tick_clock_due(&clock, now)
			if !due || quit_requested() { break }
			work_start := time.tick_now()
			server_step(server)
			work := time.tick_since(work_start)
			tick_budget_record(&server.budget, time.duration_milliseconds(work), f64(lateness) / 1e6)
			tick_clock_advance(&clock)
			if server.settings.stats_interval > 0 && server.budget.window >= f64(server.settings.stats_interval) {
				server_log_budget(server)
			}
			free_all(context.temp_allocator)
			now = clock_ns(start)
		}
		precise_sleep(&sleeper, tick_clock_wait(&clock, clock_ns(start)))
	}
	if clock.resyncs > 0 {
		fmt.printf("[Server] Skipped %d stalls longer than %d ms\n", clock.resyncs, MAX_TICK_STALL / 1_000_000)
	}
}

// run is the whole dedicated server: settings, startup, loop, shutdown. It
// returns the process exit code.
run :: proc(args: []string) -> int {
	if server_args_wants_help(args) {
		fmt.print(SERVER_HELP)
		return 0
	}

	fmt.println("==================================================")
	fmt.printf("  Krodin Dedicated Server v%s\n", SERVER_VERSION)
	fmt.println("==================================================")

	warnings: [dynamic]string
	defer warnings_destroy(&warnings)
	settings := server_settings_default()

	game_config_path := shared.concat(shared.assets_path(), "config/game.toml")
	defer delete(game_config_path)
	gameplay := shared.config_load_gameplay(game_config_path)
	defer shared.config_destroy_gameplay(gameplay)
	// game.toml's tick_rate was the only server setting before server.toml.
	server_settings_apply_game_toml_tick_rate(&settings, gameplay.game.tick_rate)

	explicit_path, has_explicit := server_args_config_path(args)
	config_path := has_explicit ? explicit_path : strings.concatenate({shared.assets_path(), SERVER_CONFIG_PATH}, context.temp_allocator)
	if data, err := os.read_entire_file_from_path(config_path, context.temp_allocator); err == nil {
		server_settings_apply_toml(&settings, string(data), &warnings)
		fmt.printf("[Server] Settings from %s\n", config_path)
	} else if has_explicit {
		fmt.eprintf("Cannot read --config %s: %v\n", config_path, err)
		server_settings_destroy(&settings)
		return 1
	} else {
		fmt.printf("[Server] No %s; using defaults and flags\n", config_path)
	}

	result, arg_error := server_settings_apply_args(&settings, args, &warnings)
	switch result {
	case .HELP:
		fmt.print(SERVER_HELP)
		server_settings_destroy(&settings)
		return 0
	case .ERROR:
		fmt.eprintf("Error: %s\n", arg_error)
		server_settings_destroy(&settings)
		return 2
	case .OK:
	}
	server_settings_validate(&settings, &warnings)
	for w in warnings {
		fmt.eprintf("[Server] Warning: %s\n", w)
	}
	fmt.printf("[Server] %s\n", server_settings_summary(&settings))
	if settings.max_players > 2 * settings.team_size {
		fmt.printf("[Server] Note: max_players %d is more than two teams of %d; team select is limited to %d per team and the rest are auto-assigned.\n",
			settings.max_players, settings.team_size, settings.team_size)
	}

	if !install_shutdown_handlers() {
		fmt.eprintln("[Server] Warning: could not install the Ctrl+C/SIGTERM handler")
	}

	server := new(Server)
	defer free(server)
	if !server_init(server, settings, gameplay, true) {
		server_destroy(server, .NONE)
		shared.unload_default_maps()
		return 1
	}
	fmt.printf("[Server] Listening on %s:%d (tick rate %d Hz, %d players max). Press Ctrl+C to stop.\n",
		server.settings.bind, net_server_port(&server.net), server.settings.tick_rate, server.settings.max_players)

	server_run(server)

	fmt.println("[Server] Shutting down...")
	if server.budget.ticks > 0 {
		server_log_budget(server)
	}
	server_destroy(server)
	shared.unload_default_maps()
	fmt.println("[Server] Stopped.")
	shutdown_finished()
	return 0
}
