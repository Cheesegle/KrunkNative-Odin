package main

import "core:fmt"
import "core:math"
import "core:testing"
import "core:time"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import shared "../shared"
import kproto "../krunker"

when ODIN_TEST {
	// Offline reproduction of a live lobby with a ping spike. A deterministic
	// authoritative peer processes the client's real q packets and answers with
	// msgpack l (1 Hz, as in tester logs) and k (30 Hz) packets. During the
	// spike both directions stall, then everything queued arrives at once.
	Spike_Packet :: struct { at: f64, bytes: []byte }

	Spike_Stats :: struct {
		worst_ns, worst_replay_ns, worst_decode_ns, worst_log_ns: i64,
		worst_messages, worst_replays, worst_replay_commands: int,
		baseline_worst_ns, baseline_total_ns: i64,
		baseline_frames: int,
		max_replays_per_frame, max_waiting: int,
		max_pending, snaps, coalesced: int,
		// Largest correction outside the two seconds after the spike.
		steady_correction: f32,
		steady_correction_frame: int,
		spike_correction: f32,
	}

	spike_stub_send :: proc(state: ^Krunker_WS_State, opcode: string) -> bool { return true }

	spike_l_packet :: proc(server: ^shared.Player, ack: i32, ping: i32) -> []byte {
		values: [25]kproto.Krunker_Msgpack_Value
		values[0], values[1] = i64(ack), i64(ping)
		values[2], values[3], values[4] = f64(server.position.x), f64(server.position.y), f64(server.position.z)
		values[5], values[6], values[7] = f64(server.velocity.y), f64(server.velocity.x), f64(server.velocity.z)
		values[8] = f64(server.direction.y)
		values[9], values[10], values[11] = server.on_ground, server.did_jump, server.did_wall_jump
		values[12], values[13], values[14] = i64(server.wall_jump_count), i64(server.on_wall), server.on_ladder
		values[15], values[16], values[17] = f64(1 - server.aim_val), f64(server.crouch_val), i64(server.loadout_index)
		values[18], values[19], values[20] = f64(server.slide_timer * 1000), server.can_slide, server.on_terrain
		values[21], values[22], values[23] = f64(server.x_vel_cylinder), f64(server.z_vel_cylinder), kproto.krunker_msgpack_nil()
		values[24] = f64(server.can_slide_timer * 1000)
		packet, _ := kproto.krunker_msgpack_encode_packet("l", []kproto.Krunker_Msgpack_Value{values[:]}, 0)
		return packet
	}

	spike_k_packet :: proc(remotes: int, t: f64) -> []byte {
		records := make([]kproto.Krunker_Msgpack_Value, remotes * 13, context.temp_allocator)
		for i in 0 ..< remotes {
			r := records[i*13:]
			phase := t + f64(i)
			r[0] = i64(8 + i)
			r[1], r[2], r[3] = f64(100 + 20*math.cos(phase)), f64(30), f64(-80 + 20*math.sin(phase))
			r[4], r[5], r[6] = f64(math.mod(phase*40, 360)), f64(5), i64(0)
			r[7], r[8], r[9], r[10], r[11], r[12] = true, f64(0), i64(0), f64(1), i64(0), i64(60)
		}
		packet, _ := kproto.krunker_msgpack_encode_packet("k", []kproto.Krunker_Msgpack_Value{records, f64(30), f64(t * 1000)}, 0)
		return packet
	}

	spike_run :: proc(t: ^testing.T, client: ^Client, server: ^shared.Player, ping_ms: f64, spike_at, spike_seconds, duration: f64) -> (stats: Spike_Stats) {
		state := &client.krunker
		uplink, downlink: [dynamic]Spike_Packet
		defer {
			for p in uplink { delete(p.bytes) }
			for p in downlink { delete(p.bytes) }
			delete(uplink); delete(downlink)
		}
		one_way := ping_ms / 2000
		arrival :: proc(now, one_way, spike_at, spike_seconds: f64) -> f64 {
			at := now + one_way
			if at >= spike_at && now < spike_at + spike_seconds { at = max(at, spike_at + spike_seconds) }
			return at
		}
		server_ack: i32 = state.input_sequence - 1
		next_l, next_k := 0.5, 0.0
		dt := 1.0 / 144
		frames := int(duration / dt)
		spike_end := spike_at + spike_seconds
		for frame in 0 ..< frames {
			now := f64(frame) * dt
			// Authoritative peer: process arrived q, then emit l/k.
			for len(uplink) > 0 && uplink[0].at <= now {
				for &command in krunker_test_decode_commands(t, uplink[0].bytes) {
					shared.player_proc_input(server, &command, true, client.krunker_world.move_lock)
					server_ack = command.seq
				}
				delete(uplink[0].bytes)
				ordered_remove(&uplink, 0)
			}
			if now >= next_l {
				next_l += 1
				append(&downlink, Spike_Packet{arrival(now, one_way, spike_at, spike_seconds), spike_l_packet(server, server_ack, i32(ping_ms))})
			}
			if now >= next_k {
				next_k += 1.0 / 30
				append(&downlink, Spike_Packet{arrival(now, one_way, spike_at, spike_seconds), spike_k_packet(4, now)})
			}
			for len(downlink) > 0 && downlink[0].at <= now {
				append(&state.inbox, Krunker_WS_Event{kind = .MESSAGE, payload = downlink[0].bytes})
				ordered_remove(&downlink, 0)
			}

			// Client frame: network processing (measured), then input.
			replay_before := krunker_replay_profile
			log_before := kproto.network_log_profile_ns
			decode_ns: i64
			for event in state.inbox {
				d0 := time.tick_now()
				kproto.krunker_msgpack_decode_packet(event.payload)
				decode_ns += i64(time.tick_since(d0))
			}
			free_all(context.temp_allocator)
			messages := len(state.inbox)
			position_before := client.me.position
			start := time.tick_now()
			krunker_ws_process_inbox(client, spike_stub_send)
			elapsed := i64(time.tick_since(start))
			moved := client.me.position - position_before
			error := math.sqrt(moved.x*moved.x + moved.y*moved.y + moved.z*moved.z)
			if now > 1.5 && (now < spike_at || now > spike_end + 2) {
				if error > stats.steady_correction { stats.steady_correction, stats.steady_correction_frame = error, frame }
			} else if now >= spike_at { stats.spike_correction = max(stats.spike_correction, error) }
			stats.max_pending = max(stats.max_pending, len(client.predicted_inputs))
			stats.max_waiting = max(stats.max_waiting, len(state.inbox))
			stats.max_replays_per_frame = max(stats.max_replays_per_frame, krunker_replay_profile.replays - replay_before.replays)
			if now < spike_at && messages > 0 {
				stats.baseline_worst_ns = max(stats.baseline_worst_ns, elapsed)
				stats.baseline_total_ns += elapsed
				stats.baseline_frames += 1
			}
			if elapsed > stats.worst_ns {
				stats.worst_ns = elapsed
				stats.worst_replay_ns = krunker_replay_profile.ns - replay_before.ns
				stats.worst_replays = krunker_replay_profile.replays - replay_before.replays
				stats.worst_replay_commands = krunker_replay_profile.commands - replay_before.commands
				stats.worst_decode_ns = decode_ns
				stats.worst_log_ns = kproto.network_log_profile_ns - log_before
				stats.worst_messages = messages - len(state.inbox)
			}
			free_all(context.temp_allocator)

			theta := f32(now) * 0.7
			input := shared.Input{delta = f32(dt), move_dir = frame % 400 < 200 ? 0 : 4, x_dir = 0, y_dir = theta, jump = frame % 97 < 4}
			krunker_client_predict_input(client, &input, now)
			if state.send_elapsed >= KRUNKER_SEND_SECONDS && len(state.input_commands) > 0 {
				count := min(len(state.input_commands), kproto.KRUNKER_MAX_INPUT_BATCH)
				counter := kproto.krunker_msgpack_counter_next(state.ah_num, "q")
				packet, ok := krunker_ws_encode_input(state)
				if !testing.expect(t, ok) { return }
				append(&uplink, Spike_Packet{arrival(now, one_way, spike_at, spike_seconds), packet})
				krunker_ws_input_sent(state, count, counter)
			}
		}
		stats.snaps, stats.coalesced = krunker_replay_profile.snaps, krunker_replay_profile.coalesced
		return
	}

	spike_setup :: proc(t: ^testing.T, client: ^Client, config: ^shared.Gameplay_Config) -> bool {
		client.scene = scene_init()
		client.fps_scene = scene_init()
		client.camera.zoom = 1
		shared.game_configure(&client.game, &config.game, nil, nil, config.weapons, config.classes)
		shared.load_default_maps()
		kproto.krunker_world_reset(&client.krunker_world)
		client.krunker.connected = true
		world := &client.krunker_world
		world.ready, world.in_game = true, true
		world.map_index, world.mode_index, world.map_revision = 2, 4, 1
		world.has_game_config = true
		world.game_config = shared.DEFAULT_GAME_CONFIG
		world.game_config.fixed_movement = true
		world.local_sid = 7
		append(&world.players, kproto.Krunker_World_Player{sid = 7, class_index = 2, team = 2, position = {120, 30, -80},
			active = true, has_position = true, health = 100, max_health = 100, revision = 1})
		for i in 0 ..< 4 {
			append(&world.players, kproto.Krunker_World_Player{sid = i32(8 + i), class_index = i32(i % 4), team = 1, position = {100, 30, -80},
				active = true, has_position = true, health = 100, max_health = 100, revision = 1})
		}
		krunker_client_sync_world(client)
		client.selected_class = 2
		client.spawn_pending = true
		client.krunker.bootstrapped = true
		world.players[0].revision += 1
		krunker_client_sync_world(client)
		if !testing.expect(t, client.me != nil && client.krunker.spawned, "the synthetic lobby must spawn the local player") { return false }
		client.me.swap_timer = 0
		client.krunker.input_sequence = 13
		return true
	}

	spike_teardown :: proc(client: ^Client) {
		client_unload_map(client)
		client_clear_players(client)
		shared.game_destroy(&client.game)
		shared.unload_default_maps()
		kproto.krunker_world_reset(&client.krunker_world)
		krunker_ws_disconnect(&client.krunker)
		delete(client.join_status)
		delete(client.predicted_inputs)
		scene_fini(client.fps_scene)
		scene_fini(client.scene)
		resource_cache_fini()
	}

	spike_scenario :: proc(t: ^testing.T, window: glfw.WindowHandle, ping_ms, spike_seconds: f64) -> (stats: Spike_Stats, ok: bool) {
		client := Client{window = window}
		g_client = &client
		defer { g_client = nil }
		config := shared.config_load_gameplay("assets/config/game.toml")
		defer shared.config_destroy_gameplay(config)
		defer spike_teardown(&client)
		if !spike_setup(t, &client, config) { return }
		server := shared.player_init(&client.game)
		defer shared.player_destroy(server)
		shared.player_spawn(server, 2)
		server.swap_timer = 0
		server.position, server.last_position = client.me.position, client.me.position
		krunker_replay_profile = {}
		stats = spike_run(t, &client, server, ping_ms, 6, spike_seconds, 12)
		return stats, true
	}

	spike_ms :: proc(ns: i64) -> f64 { return f64(ns) / 1e6 }

	// Frame-time regression for a burst after a ping spike: the frame thread's
	// network work (decode, apply, replay, logging) stays within the apply
	// budget plus one replay, and a burst replays at most once per frame.
	@(test)
	krunker_ping_spike_frame_cost :: proc(t: ^testing.T) {
		if !testing.expect(t, bool(glfw.Init()), "GLFW initialization failed") do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(320, 240, "Krunker spike regression", nil, nil)
		if !testing.expect(t, window != nil, "hidden OpenGL window failed") do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		previous_path := kproto.network_log_path
		kproto.network_log_close()
		kproto.network_log_path = "logs/krunker-network-spike-test.log"
		defer { kproto.network_log_close(); kproto.network_log_path = previous_path }

		// Worst frame allowed: the apply budget, plus one replay of the full
		// history (about 0.75 ms at -o:speed, 3.6 ms at -o:none), plus margin
		// for a loaded test machine.
		limit_ms := ODIN_OPTIMIZATION_MODE == .None ? 12.0 : 4.0
		Case :: struct { name: string, ping, spike: f64, snaps: int }
		cases := []Case{
			{"80 ms ping, no spike", 80, 0, 0},
			{"80 ms ping, 1.5 s spike", 80, 1.5, 0},
			{"80 ms ping, 2 s spike", 80, 2, 1},
			{"250 ms ping, 2 s spike", 250, 2, 1},
		}
		for c in cases {
			stats, ok := spike_scenario(t, window, c.ping, c.spike)
			if !ok { return }
			fmt.printf("[spike] %s: worst frame %.3f ms (messages=%d decode=%.3f replay=%.3f ms in %d replays/%d commands, log=%.3f ms); baseline worst %.3f avg %.3f ms; max pending=%d waiting=%d; replays/frame<=%d coalesced=%d snaps=%d; correction steady=%.4f (frame %d) spike=%.3f\n",
				c.name, spike_ms(stats.worst_ns), stats.worst_messages, spike_ms(stats.worst_decode_ns), spike_ms(stats.worst_replay_ns), stats.worst_replays, stats.worst_replay_commands,
				spike_ms(stats.worst_log_ns), spike_ms(stats.baseline_worst_ns), spike_ms(stats.baseline_total_ns) / f64(max(stats.baseline_frames, 1)), stats.max_pending, stats.max_waiting,
				stats.max_replays_per_frame, stats.coalesced, stats.snaps, stats.steady_correction, stats.steady_correction_frame, stats.spike_correction)
			testing.expectf(t, spike_ms(stats.worst_ns) < limit_ms, "%s: worst network frame %.3f ms must stay under %.1f ms", c.name, spike_ms(stats.worst_ns), limit_ms)
			testing.expectf(t, stats.max_replays_per_frame <= 1, "%s: a burst must replay at most once per frame", c.name)
			testing.expectf(t, stats.snaps == c.snaps, "%s: expected %d snaps, got %d", c.name, c.snaps, stats.snaps)
			testing.expectf(t, stats.steady_correction < 0.01, "%s: a deterministic peer must not correct prediction outside the spike (%.4f)", c.name, stats.steady_correction)
			testing.expectf(t, stats.max_pending <= KRUNKER_MAX_PREDICTED_INPUTS, "%s: history must stay capped", c.name)
		}
	}

	Replay_Fixture :: struct {
		floor: shared.Object,
		map_inst: shared.Map,
		client: Client,
		server: ^shared.Player,
	}

	// Live prediction on a flat floor against a deterministic peer.
	replay_fixture_init :: proc(f: ^Replay_Fixture, config: ^shared.Gameplay_Config) {
		f.floor = shared.Object{active = true, collision_type = .BOX, position = {0, -1, 0}, scale = {10000, 1, 10000}}
		f.map_inst = shared.Map{death_y = -1000, config = {speed = {1, 1, 1}, air_accel = 1}}
		append(&f.map_inst.objects, &f.floor)
		client := &f.client
		shared.game_configure(&client.game, &config.game, []^shared.Map{&f.map_inst}, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, 0, false)
		client.me = shared.player_init(&client.game)
		shared.game_players_add(&client.game, client.me)
		shared.player_spawn(client.me, 2)
		client.me.is_you = true
		client.me.swap_timer = 0
		f.server = shared.player_init(&client.game)
		shared.player_spawn(f.server, 2)
		f.server.swap_timer = 0
		f.server.position, f.server.last_position = client.me.position, client.me.position
		client.krunker.spawned, client.krunker.bootstrapped = true, true
		client.krunker.input_sequence = 13
	}

	replay_fixture_destroy :: proc(f: ^Replay_Fixture) {
		shared.player_destroy(f.server)
		shared.game_destroy(&f.client.game)
		delete(f.client.predicted_inputs)
		krunker_ws_disconnect(&f.client.krunker)
		delete(f.map_inst.objects)
	}

	// Predicts seconds of 144 Hz input; the peer receives it when deliver is set.
	replay_fixture_play :: proc(t: ^testing.T, f: ^Replay_Fixture, seconds: f64, deliver: bool) -> (ack: i32) {
		ack = -1
		for elapsed := 0.0; elapsed < seconds; elapsed += 1.0 / 144 {
			frame := shared.Input{delta = 1.0 / 144, move_dir = 0, x_dir = 0.1, y_dir = f32(elapsed)}
			krunker_client_predict_input(&f.client, &frame, 0)
			if f.client.krunker.send_elapsed >= KRUNKER_SEND_SECONDS && len(f.client.krunker.input_commands) > 0 {
				if deliver { ack = krunker_test_deliver_commands(t, &f.client, f.server) }
				else { clear(&f.client.krunker.input_commands); f.client.krunker.send_elapsed = 0 }
			}
		}
		return
	}

	replay_fixture_snapshot :: proc(server: ^shared.Player, ack: i32, revision: u64, offset: shared.Vec3 = {}) -> kproto.Krunker_World_Player {
		return {position = server.position + offset, velocity = server.velocity, on_ground = server.on_ground, can_slide = server.can_slide,
			crouch_val = server.crouch_val, aim_val = server.aim_val, weapon_slot = server.loadout_index, has_ack = true, ack_seq = ack, sync_revision = revision}
	}

	Coalesce_Result :: struct { position: shared.Vec3, direction: shared.Vec2, replays, coalesced, pending: int }

	coalesce_run :: proc(t: ^testing.T, config: ^shared.Gameplay_Config, batched: bool) -> Coalesce_Result {
		f: Replay_Fixture
		replay_fixture_init(&f, config)
		defer replay_fixture_destroy(&f)
		first := replay_fixture_snapshot(f.server, replay_fixture_play(t, &f, 0.4, true), 1, {3, 0, 0})
		second := replay_fixture_snapshot(f.server, replay_fixture_play(t, &f, 0.4, true), 2, {5, 0, 1})
		replay_fixture_play(t, &f, 0.3, false)
		krunker_replay_profile = {}
		f.client.krunker.batching = batched
		krunker_client_apply_motion(&f.client, f.client.me, &first, false)
		krunker_client_apply_motion(&f.client, f.client.me, &second, false)
		f.client.krunker.batching = false
		krunker_client_finish_replay(&f.client)
		return {f.client.me.position, f.client.me.direction, krunker_replay_profile.replays, krunker_replay_profile.coalesced, len(f.client.predicted_inputs)}
	}

	// Two corrections inside one batch replay once, from the newer ACK, and
	// land exactly where two separate replays do.
	@(test)
	krunker_burst_corrections_replay_once :: proc(t: ^testing.T) {
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		separate := coalesce_run(t, config, false)
		batched := coalesce_run(t, config, true)
		testing.expectf(t, separate.replays == 2 && batched.replays == 1 && batched.coalesced == 1, "a batch must replay once (separate %d, batched %d)", separate.replays, batched.replays)
		delta := batched.position - separate.position
		testing.expectf(t, abs(delta.x) < 1e-4 && abs(delta.y) < 1e-4 && abs(delta.z) < 1e-4, "coalesced replay must match separate replays (%v vs %v)", batched.position, separate.position)
		testing.expect(t, batched.direction == separate.direction && batched.pending == separate.pending, "view state and history must match")
	}

	// The full history replays, however long; the server state is taken as it
	// is only when unacknowledged commands were dropped from the history.
	@(test)
	krunker_replay_snaps_only_after_truncated_history :: proc(t: ^testing.T) {
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		f: Replay_Fixture
		replay_fixture_init(&f, config)
		defer replay_fixture_destroy(&f)
		state := &f.client.krunker
		// 1.9 s without an ACK: long, but every command is still in the history.
		replay_fixture_play(t, &f, 1.9, false)
		testing.expect(t, !state.history_truncated && len(f.client.predicted_inputs) < KRUNKER_MAX_PREDICTED_INPUTS)
		krunker_replay_profile = {}
		early := replay_fixture_snapshot(f.server, 12, 1)
		krunker_client_apply_motion(&f.client, f.client.me, &early, false)
		testing.expect(t, krunker_replay_profile.replays == 1 && krunker_replay_profile.snaps == 0 && krunker_replay_profile.commands > 600,
			"an intact history replays in full")
		// Another 0.5 s: past two seconds, the cap drops unacknowledged commands.
		replay_fixture_play(t, &f, 0.5, false)
		if !testing.expect(t, state.history_truncated && len(f.client.predicted_inputs) == KRUNKER_MAX_PREDICTED_INPUTS, "the cap must record the dropped commands") do return
		first_kept := f.client.predicted_inputs[0].seq
		stale := replay_fixture_snapshot(f.server, 12, 2, {0, 0, 7})
		krunker_client_apply_motion(&f.client, f.client.me, &stale, false)
		testing.expect(t, krunker_replay_profile.snaps == 1 && krunker_replay_profile.replays == 1, "a truncated history must not replay")
		testing.expect(t, f.client.me.position == stale.position, "snapping keeps the authoritative position")
		testing.expect(t, len(f.client.predicted_inputs) == KRUNKER_MAX_PREDICTED_INPUTS && f.client.predicted_inputs[0].seq == first_kept,
			"snapping keeps the remaining commands for the next correction")
		// An ACK past the dropped commands replays again.
		caught_up := replay_fixture_snapshot(f.server, state.truncated_through + 10, 3)
		krunker_client_apply_motion(&f.client, f.client.me, &caught_up, false)
		testing.expect(t, krunker_replay_profile.replays == 2 && krunker_replay_profile.snaps == 1 && !state.history_truncated, "a later ACK past the gap replays normally")
		testing.expect(t, f.client.predicted_inputs[0].seq == caught_up.ack_seq + 1)
		// INPUT_FAILED clears the history; an older ACK then replays the new
		// commands as before, without a snap.
		krunker_client_reset_prediction(&f.client)
		replay_fixture_play(t, &f, 0.1, false)
		after_reset := replay_fixture_snapshot(f.server, caught_up.ack_seq, 4)
		krunker_client_apply_motion(&f.client, f.client.me, &after_reset, false)
		testing.expect(t, krunker_replay_profile.replays == 3 && krunker_replay_profile.snaps == 1, "a reset history is not a truncated one")
	}

	spike_push :: proc(state: ^Krunker_WS_State, packet: []byte) { append(&state.inbox, Krunker_WS_Event{kind = .MESSAGE, payload = packet}) }

	// Through krunker_ws_process_inbox: l, k, l replays once; any other
	// message runs the pending replay first.
	@(test)
	krunker_inbox_coalesces_local_corrections :: proc(t: ^testing.T) {
		if !testing.expect(t, bool(glfw.Init()), "GLFW initialization failed") do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(320, 240, "Krunker coalescing", nil, nil)
		if !testing.expect(t, window != nil, "hidden OpenGL window failed") do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		previous_path := kproto.network_log_path
		kproto.network_log_close()
		kproto.network_log_path = "logs/krunker-network-spike-test.log"
		defer { kproto.network_log_close(); kproto.network_log_path = previous_path }
		client := Client{window = window}
		g_client = &client
		defer { g_client = nil }
		config := shared.config_load_gameplay("assets/config/game.toml")
		defer shared.config_destroy_gameplay(config)
		defer spike_teardown(&client)
		if !spike_setup(t, &client, config) { return }
		state := &client.krunker
		for _ in 0 ..< 144 {
			input := shared.Input{delta = 1.0 / 144, move_dir = 0}
			krunker_client_predict_input(&client, &input, 0)
		}
		me := client.me
		krunker_replay_profile = {}
		spike_push(state, spike_l_packet(me, 20, 60))
		spike_push(state, spike_k_packet(4, 1))
		spike_push(state, spike_l_packet(me, 40, 60))
		krunker_ws_process_inbox(&client, spike_stub_send)
		testing.expectf(t, krunker_replay_profile.replays == 1 && krunker_replay_profile.coalesced == 1 && len(state.inbox) == 0,
			"l, k, l must replay once (replays %d)", krunker_replay_profile.replays)
		testing.expect(t, client.predicted_inputs[0].seq == 41, "the replay starts after the newest ACK")
		gmsg, _ := kproto.krunker_msgpack_encode_packet("gmsg", []kproto.Krunker_Msgpack_Value{"fixture"}, 0)
		spike_push(state, spike_l_packet(me, 60, 60))
		spike_push(state, gmsg)
		spike_push(state, spike_l_packet(me, 80, 60))
		krunker_ws_process_inbox(&client, spike_stub_send)
		testing.expectf(t, krunker_replay_profile.replays == 3 && krunker_replay_profile.coalesced == 1,
			"another message must run the pending replay first (replays %d)", krunker_replay_profile.replays)
		// A zero budget still makes progress, one message per frame, in order.
		for i in 0 ..< 3 { spike_push(state, spike_k_packet(4, f64(i))) }
		krunker_ws_process_inbox(&client, spike_stub_send, 0)
		testing.expect(t, len(state.inbox) == 2, "a spent budget leaves later messages for the next frame")
		krunker_ws_process_inbox(&client, spike_stub_send, 0)
		krunker_ws_process_inbox(&client, spike_stub_send, 0)
		testing.expect(t, len(state.inbox) == 0)
	}

	// Native server: of several local snapshots in one receive, only the
	// newest replays the unacknowledged inputs.
	@(test)
	native_receive_replays_newest_local_snapshot :: proc(t: ^testing.T) {
		buffer: [4096]byte
		size := 0
		offsets: [5]int
		states := [5]shared.Packet_Player_State{
			{player_id = 1, class_id = 0, team = 1, health = 100, max_health = 100, active = true, is_you = true, ack_seq = 10},
			{player_id = 2, class_id = 0, team = 2, health = 100, max_health = 100, active = true, ack_seq = 11},
			{player_id = 1, class_id = 0, team = 1, health = 100, max_health = 100, active = true, is_you = true, ack_seq = 12},
			{player_id = 1, class_id = 0, team = 1, health = 100, max_health = 100, active = false, is_you = true, ack_seq = 13},
			{player_id = 1, class_id = 0, team = 1, health = 100, max_health = 100, active = true, is_you = true, ack_seq = 14},
		}
		for &state, i in states {
			offsets[i] = size
			written := shared.packet_serialize_state(buffer[size:], &state)
			if !testing.expect(t, written > 0) do return
			size += written
		}
		// The last snapshot is still incomplete: the next receive finishes it.
		testing.expect(t, net_client_newest_local_state(buffer[:size - 1]) == offsets[2], "an incomplete or inactive snapshot is not the newest local one")
		testing.expect(t, net_client_newest_local_state(buffer[:size]) == offsets[4])
		testing.expect(t, net_client_newest_local_state(buffer[:offsets[2]]) == offsets[0])
		testing.expect(t, net_client_newest_local_state(buffer[offsets[1]:offsets[2]]) == -1, "remote snapshots never count")

		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		map_inst := shared.Map{death_y = -1000, config = {speed = {1, 1, 1}, air_accel = 1}}
		client: Client
		shared.game_configure(&client.game, &config.game, []^shared.Map{&map_inst}, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, 0, false)
		defer shared.game_destroy(&client.game)
		defer delete(client.predicted_inputs)
		player := shared.player_init(&client.game)
		shared.game_players_add(&client.game, player)
		shared.player_spawn(player, 0)
		player.noclip = true
		for seq in 10 ..< 20 { append(&client.predicted_inputs, shared.Input{seq = i32(seq), delta = 0.01, move_dir = 0}) }
		state := shared.Packet_Player_State{active = true, is_you = true, position = {10, 20, 30}, ack_seq = 12}
		client_reconcile_local_player(&client, player, &state, true, false)
		testing.expect(t, player.position == state.position && len(client.predicted_inputs) == 7, "a replaced snapshot applies its state and ACK without a replay")
		client_reconcile_local_player(&client, player, &state, true)
		testing.expect(t, player.position != state.position, "the newest snapshot replays the rest")
	}
}
