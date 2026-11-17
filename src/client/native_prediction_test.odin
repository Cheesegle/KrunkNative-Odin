package main

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import shared "../shared"
import menuui "../menu"
import ded "../server/dedicated"

when ODIN_TEST {
	Native_Test_World :: struct {
		config:        ^shared.Gameplay_Config,
		map_inst:      shared.Map,
		objects:       [3]shared.Object,
		client:        Client,
		server_game:   shared.Game,
		server_player: ^shared.Player,
	}

	// A client predicting with the real native path and an authoritative game
	// running the server's command stream, on the same small map (floor, a
	// wall and a step).
	native_test_world_init :: proc(w: ^Native_Test_World, rate: i32) {
		w.config = shared.config_load_gameplay()
		w.objects[0] = {active = true, collision_type = .BOX, position = {0, 0, 0}, scale = {400, 1, 400}}
		w.objects[1] = {active = true, collision_type = .BOX, position = {30, 1, 0}, scale = {2, 30, 400}}
		w.objects[2] = {active = true, collision_type = .BOX, position = {-12, 1, -12}, scale = {8, 3, 8}}
		w.map_inst = shared.Map{death_y = -100, config = {speed = {1, 1, 1}, air_accel = 1, ladder_accel = 1, slide_time = 1, slide_accel = 1}}
		for &o in w.objects { append(&w.map_inst.objects, &o) }
		maps := []^shared.Map{&w.map_inst}
		shared.game_configure(&w.client.game, &w.config.game, maps, nil, w.config.weapons, w.config.classes)
		shared.game_init(&w.client.game, 0, 0, false)
		shared.game_configure(&w.server_game, &w.config.game, maps, nil, w.config.weapons, w.config.classes)
		shared.game_init(&w.server_game, 0, 0, false)
		w.server_game.server = rawptr(&w.server_game)
		w.client.net_rate = rate
		w.client.me = shared.player_init(&w.client.game)
		shared.game_players_add(&w.client.game, w.client.me)
		shared.player_spawn(w.client.me, 0)
		w.client.me.is_you, w.client.me.render_you = true, true
		w.server_player = shared.player_init(&w.server_game)
		shared.game_players_add(&w.server_game, w.server_player)
		shared.player_spawn(w.server_player, 0)
		for p in ([2]^shared.Player{w.client.me, w.server_player}) {
			p.swap_timer = 0
			p.position, p.last_position = {-6, 1, 0}, {-6, 1, 0}
			p.velocity, p.direction = {}, {}
		}
	}

	native_test_world_destroy :: proc(w: ^Native_Test_World) {
		shared.game_destroy(&w.client.game)
		shared.game_destroy(&w.server_game)
		delete(w.client.predicted_inputs)
		delete(w.map_inst.objects)
		shared.config_destroy_gameplay(w.config)
	}

	native_test_length :: proc(v: shared.Vec3) -> f32 { return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) }

	Native_Replay_Result :: struct {
		commands, snapshots, corrections: int,
		max_correction: f32,
		exact: bool,
	}

	// Commands go through the wire codec to a server command stream that runs
	// at tick_rate; snapshots go back through the SNAPSHOT codec (delta against
	// the acknowledged one, the local player unquantised) and the real
	// client_reconcile_local_player. 40 ms each way.
	native_test_replay :: proc(t: ^testing.T, rate: i32, tick_rate: int) -> (result: Native_Replay_Result) {
		w: Native_Test_World
		native_test_world_init(&w, rate)
		defer native_test_world_destroy(&w)
		client := &w.client
		cs: ded.Command_Stream
		ded.command_stream_init(&cs, 0)
		defer ded.command_stream_destroy(&cs)
		link: Native_Test_Snapshots
		native_test_snapshots_init(&link)
		defer native_test_snapshots_destroy(&link)

		Packet :: struct { at: f64, data: [shared.INPUT_BATCH_MAX_PACKET]byte, size: int }
		to_server, to_client: [dynamic]Packet
		defer { delete(to_server); delete(to_client) }
		LATENCY :: 0.04
		frame_times := [4]f64{1.0 / 144, 1.0 / 165, 1.0 / 240, 1.0 / 90}
		tick_dt := 1.0 / f64(tick_rate)
		now, server_now: f64
		server_ticks := 0
		for frame in 0 ..< 700 {
			dt := frame_times[frame % len(frame_times)]
			now += dt
			tf := f32(now)
			input := shared.Input{delta = f32(dt), move_dir = i32(frame / 60) % 8, x_dir = 0.3 * math.sin(tf), y_dir = 0.9 * tf,
				jump = frame % 85 < 4, crouch = frame % 160 > 125, shoot = frame % 37 < 5}
			before := len(client.predicted_inputs)
			native_client_predict_frame(client, &input, input)
			result.commands += len(client.predicted_inputs) - before
			// The send path, minus the socket: new commands plus the redundant tail.
			if len(client.predicted_inputs) > before {
				state := &client.net.commands
				start := max(0, before - NATIVE_REDUNDANT_COMMANDS)
				for start < len(client.predicted_inputs) {
					end := min(len(client.predicted_inputs), start + shared.INPUT_BATCH_MAX_COMMANDS)
					p := Packet{at = now + LATENCY}
					p.size = shared.packet_serialize_input_batch(p.data[:], client.predicted_inputs[start:end])
					testing.expect(t, p.size > 0, "every batch must encode")
					append(&to_server, p)
					start = end
				}
				state.sent_through = client.predicted_inputs[len(client.predicted_inputs) - 1].seq
			}
			for server_now + tick_dt <= now {
				server_now += tick_dt
				server_ticks += 1
				out: [shared.INPUT_BATCH_MAX_COMMANDS]shared.Input
				for len(to_server) > 0 && to_server[0].at <= server_now {
					count, ok := shared.packet_deserialize_input_batch(to_server[0].data[:to_server[0].size], out[:])
					testing.expect(t, ok, "batches must decode")
					for c in out[:count] { ded.command_stream_push(&cs, c) }
					ordered_remove(&to_server, 0)
				}
				w.server_game.now = f32(server_now)
				ded.command_stream_run(&cs, w.server_player, &w.server_game, server_now)
				shared.game_tick(&w.server_game, f32(server_now), f32(tick_dt))
				clear(&w.server_game.impacts)
				p := Packet{at = server_now + LATENCY}
				p.size = native_test_snapshot_encode(&link, u32(server_ticks), w.server_player, p.data[:])
				testing.expect(t, p.size > 0, "every snapshot must encode")
				append(&to_client, p)
			}
			for len(to_client) > 0 && to_client[0].at <= now {
				state, ok := native_test_snapshot_decode(&link, to_client[0].data[:to_client[0].size])
				ordered_remove(&to_client, 0)
				if !testing.expect(t, ok, "snapshots must decode") { continue }
				corrections := client.net.commands.corrections
				client_reconcile_local_player(client, client.me, &state, true)
				result.snapshots += 1
				if client.net.commands.corrections != corrections {
					result.corrections += 1
					result.max_correction = max(result.max_correction, native_test_length(client.net.commands.last_correction))
				}
			}
		}
		// Deliver what is still in flight, then reconcile once more: with every
		// command acked, the client must sit exactly where the server is.
		for len(to_server) > 0 {
			server_now += tick_dt
			out: [shared.INPUT_BATCH_MAX_COMMANDS]shared.Input
			for len(to_server) > 0 && to_server[0].at <= server_now {
				count, _ := shared.packet_deserialize_input_batch(to_server[0].data[:to_server[0].size], out[:])
				for c in out[:count] { ded.command_stream_push(&cs, c) }
				ordered_remove(&to_server, 0)
			}
			ded.command_stream_run(&cs, w.server_player, &w.server_game, server_now)
			shared.game_tick(&w.server_game, f32(server_now), f32(tick_dt))
		}
		final_buf: [shared.INPUT_BATCH_MAX_PACKET]byte
		final_size := native_test_snapshot_encode(&link, u32(server_ticks + 1), w.server_player, final_buf[:])
		final, final_ok := native_test_snapshot_decode(&link, final_buf[:final_size])
		testing.expect(t, final_ok, "the final snapshot decodes")
		corrections := client.net.commands.corrections
		client_reconcile_local_player(client, client.me, &final, true)
		if client.net.commands.corrections != corrections { result.corrections += 1 }
		testing.expect(t, len(client.predicted_inputs) == 0, "every command is acked at the end")
		result.exact = client.me.position == w.server_player.position && client.me.velocity == w.server_player.velocity && w.server_player.shot_seq > 0
		fmt.printf("  native replay %3d Hz commands, %3d tick: %d commands, %d snapshots reconciled (%d full, %d delta, %.1f B avg), %d corrections (max %.9f), server shots %d, |dpos| %.9f\n",
			rate, tick_rate, result.commands, result.snapshots, link.full, link.delta, f64(link.bytes) / f64(max(1, link.full + link.delta)), result.corrections, result.max_correction, w.server_player.shot_seq,
			native_test_length(client.me.position - w.server_player.position))
		return
	}

	@(test)
	native_prediction_replay_matches_the_server :: proc(t: ^testing.T) {
		for tick_rate in ([2]int{64, 128}) {
			for rate in ([4]i32{60, 144, 240, 360}) {
				r := native_test_replay(t, rate, tick_rate)
				testing.expectf(t, r.snapshots > 50 && r.corrections == 0 && r.exact,
					"%d Hz commands at %d tick: replaying the unacked commands over each snapshot must land exactly on the prediction (%d corrections, max %f, exact %v)",
					rate, tick_rate, r.corrections, r.max_correction, r.exact)
				expected := f64(rate) * 175 * (1.0 / 144 + 1.0 / 165 + 1.0 / 240 + 1.0 / 90)
				testing.expectf(t, abs(f64(r.commands) - expected) <= 1, "%d Hz must build one command per 1/%d s of frame time (got %d, want %.1f)", rate, rate, r.commands, expected)
			}
		}
	}

	@(test)
	native_commands_keep_short_presses_and_real_time :: proc(t: ^testing.T) {
		for rate in shared.NET_RATES {
			w: Native_Test_World
			native_test_world_init(&w, rate)
			defer native_test_world_destroy(&w)
			client := &w.client
			// 300 FPS: above every rate but 360, so most frames build no command.
			total_ms: f32
			shots, jumps, swaps, scroll_waits := 0, 0, 0, 0
			for frame in 0 ..< 300 {
				input := shared.Input{delta = 1.0 / 300, move_dir = -1, shoot = frame == 1, jump = frame == 101, swap = frame == 201 ? 2 : 0}
				before := len(client.predicted_inputs)
				if native_client_predict_frame(client, &input, input) { scroll_waits += 1 }
				for c in client.predicted_inputs[before:] {
					total_ms += c.delta * 1000
					if c.shoot { shots += 1 }
					if c.jump { jumps += 1 }
					if c.swap != 0 { swaps += 1 }
					testing.expect(t, c.delta * 1000 == math.round(c.delta * 1000) && c.delta <= 0.033, "durations are whole ms, at most 33")
				}
			}
			// Krunker clamps a command to 33 ms, so 30 Hz commands carry 33 ms, not 33.3.
			want_ms := f32(min(1000, 33 * rate))
			testing.expectf(t, client.net.commands.next_seq == rate && total_ms == want_ms, "%d Hz: one second of frames must give %d commands and %.0f ms (got %d, %.0f ms)", rate, rate, want_ms, client.net.commands.next_seq, total_ms)
			testing.expectf(t, shots == 1 && jumps == 1 && swaps == 1, "%d Hz: a one-frame click, jump and swap each reach exactly one command (%d, %d, %d)", rate, shots, jumps, swaps)
			if rate < 300 {
				testing.expectf(t, scroll_waits > 0, "%d Hz: frames without a command keep a Scroll press for the next frame", rate)
			}
		}
	}

	@(test)
	native_corrections_are_smoothed :: proc(t: ^testing.T) {
		w: Native_Test_World
		native_test_world_init(&w, 144)
		defer native_test_world_destroy(&w)
		client := &w.client
		for _ in 0 ..< 20 {
			input := shared.Input{delta = 1.0 / 144, move_dir = 0}
			native_client_predict_frame(client, &input, input)
		}
		// The server disagrees by 0.5 units in x after the 10th command.
		ack := client.predicted_inputs[9].seq
		for i in 0 ..= 9 { shared.player_proc_input(w.server_player, &client.predicted_inputs[i], false, false) }
		w.server_player.input_seq = ack
		w.server_player.position.x += 0.5
		state := ded.net_server_player_state(w.server_player, true)
		camera, predicted := native_client_render_position(client), client.me.position
		client_reconcile_local_player(client, client.me, &state, true)
		testing.expectf(t, abs(client.me.position.x - (predicted.x + 0.5)) < 1e-4 && abs(client.me.position.z - predicted.z) < 1e-4,
			"the simulation takes the server's correction at once (%v -> %v)", predicted, client.me.position)
		testing.expect(t, native_test_length(native_client_render_position(client) - camera) < 1e-4, "the camera does not jump on a small correction")
		for _ in 0 ..< 60 {
			input := shared.Input{delta = 1.0 / 144, move_dir = -1}
			native_client_predict_frame(client, &input, input)
		}
		testing.expect(t, native_test_length(client.net.commands.visual_offset) < 0.01, "the visual offset decays within a few hundred ms")
		// A large correction (respawn, teleport) snaps.
		w.server_player.input_seq = client.predicted_inputs[len(client.predicted_inputs) - 1].seq
		w.server_player.position = client.me.position + {20, 0, 0}
		state = ded.net_server_player_state(w.server_player, true)
		client_reconcile_local_player(client, client.me, &state, true)
		testing.expect(t, client.net.commands.visual_offset == {} && native_test_length(native_client_render_position(client) - client.me.position) < 1e-4, "a large correction snaps")
	}

	@(test)
	net_rate_setting :: proc(t: ^testing.T) {
		defaults := client_settings_validate(client_settings_defaults())
		testing.expect(t, defaults.net_rate == 144 && client_settings_default_values().net_rate == 144, "Krunker's desktop default is 144")
		odd := client_settings_defaults()
		odd.net_rate = 77
		testing.expect(t, client_settings_validate(odd).net_rate == 144, "unknown rates fall back to the default")
		old := client_settings_defaults()
		old.net_rate = 0 // a settings file from before the key existed
		testing.expect(t, client_settings_validate(old).net_rate == 144, "older files get the default")

		values := client_settings_default_values()
		_, error := menuui.krunker_settings_import(&values, `{"netRate":5}`)
		testing.expect(t, len(error) == 0 && values.net_rate == 360, "Krunker's netRate index 5 imports as 360 Hz")
		_, _ = menuui.krunker_settings_import(&values, `{"netRate":0}`)
		testing.expect(t, values.net_rate == 30, "index 0 is 30 Hz")
		_, _ = menuui.krunker_settings_import(&values, `{"fov":100}`)
		testing.expect(t, values.net_rate == 144, "a missing netRate resets to Krunker's default")
		values.net_rate = 240
		text := menuui.krunker_settings_export(values, context.temp_allocator)
		testing.expectf(t, strings.contains(text, `"netRate":4`), "export writes Krunker's option index: %s", text)
		values.net_rate = 144
		text = menuui.krunker_settings_export(values, context.temp_allocator)
		testing.expect(t, !strings.contains(text, "netRate"), "export omits the default, as Krunker does")

		draft := client_settings_default_values()
		draft.net_rate = 360
		menuui.settings_reset_tab(&draft, client_settings_default_values(), .GAMEPLAY)
		testing.expect(t, draft.net_rate == 144, "Gameplay reset restores the net rate")
	}
}
