package main

import "core:fmt"
import "core:math"
import "core:testing"
import shared "../shared"
import ded "../server/dedicated"

when ODIN_TEST {
	Native_Test_Packet :: struct { at: f64, data: [shared.INPUT_BATCH_MAX_PACKET]byte, size: int }

	// The real per-frame native path, as client_tick runs it: predict the
	// frame, send its batch, then run any server ticks that fell due (command
	// stream, then game_tick, then every second tick a GAME_STATE through the
	// codec) and apply the snapshots that arrived, in client_apply_player_state's
	// order: reconcile, then the weapon and ammo state.
	Native_Session :: struct {
		w:           Native_Test_World,
		cs:          ded.Command_Stream,
		to_server:   [dynamic]Native_Test_Packet,
		to_client:   [dynamic]Native_Test_Packet,
		now, server_now, tick_dt, latency: f64,
		ticks:       int,
		snapshots:   int,
		corrections: int,
	}

	native_session_init :: proc(s: ^Native_Session, rate: i32, tick_rate: int, latency: f64) {
		native_test_world_init(&s.w, rate)
		ded.command_stream_init(&s.cs, 0)
		s.tick_dt, s.latency = 1 / f64(tick_rate), latency
		s.w.client.net.connected = true // only selects the native path; nothing touches a socket
	}

	native_session_destroy :: proc(s: ^Native_Session) {
		s.w.client.net.connected = false
		ded.command_stream_destroy(&s.cs)
		delete(s.to_server)
		delete(s.to_client)
		native_test_world_destroy(&s.w)
	}

	native_session_frame :: proc(t: ^testing.T, s: ^Native_Session, input: shared.Input) {
		client := &s.w.client
		frame := input
		s.now += f64(frame.delta)
		before := len(client.predicted_inputs)
		native_client_predict_frame(client, &frame, frame)
		if len(client.predicted_inputs) > before {
			start := max(0, before - NATIVE_REDUNDANT_COMMANDS)
			for start < len(client.predicted_inputs) {
				end := min(len(client.predicted_inputs), start + shared.INPUT_BATCH_MAX_COMMANDS)
				p := Native_Test_Packet{at = s.now + s.latency}
				p.size = shared.packet_serialize_input_batch(p.data[:], client.predicted_inputs[start:end])
				append(&s.to_server, p)
				start = end
			}
		}
		for s.server_now + s.tick_dt <= s.now {
			s.server_now += s.tick_dt
			s.ticks += 1
			out: [shared.INPUT_BATCH_MAX_COMMANDS]shared.Input
			for len(s.to_server) > 0 && s.to_server[0].at <= s.server_now {
				count, ok := shared.packet_deserialize_input_batch(s.to_server[0].data[:s.to_server[0].size], out[:])
				testing.expect(t, ok, "batches must decode")
				for c in out[:count] { ded.command_stream_push(&s.cs, c) }
				ordered_remove(&s.to_server, 0)
			}
			s.w.server_game.now = f32(s.server_now)
			ded.command_stream_run(&s.cs, s.w.server_player, &s.w.server_game, s.server_now)
			shared.game_tick(&s.w.server_game, f32(s.server_now), f32(s.tick_dt))
			clear(&s.w.server_game.impacts)
			if s.ticks % shared.SNAPSHOT_RATE_DIVISOR == 0 {
				state := ded.net_server_player_state(s.w.server_player, true)
				p := Native_Test_Packet{at = s.server_now + s.latency}
				p.size = shared.packet_serialize_state(p.data[:], &state)
				append(&s.to_client, p)
			}
		}
		for len(s.to_client) > 0 && s.to_client[0].at <= s.now {
			state, ok := shared.packet_deserialize_state(s.to_client[0].data[:s.to_client[0].size])
			ordered_remove(&s.to_client, 0)
			if !testing.expect(t, ok, "snapshots must decode") { continue }
			me := client.me
			was_active, previous_shot_seq := me.active, me.shot_seq
			corrections := client.net.commands.corrections
			client_reconcile_local_player(client, me, &state, was_active)
			testing.expect(t, client_apply_weapon_state(client, me, &state, was_active, previous_shot_seq), "the snapshot's weapon state applies")
			s.snapshots += 1
			if client.net.commands.corrections != corrections { s.corrections += 1 }
		}
		clear(&client.game.impacts)
	}

	native_speed_spread :: proc(speeds: []f64) -> (mean, worst: f64) {
		for v in speeds { mean += v }
		mean /= f64(max(1, len(speeds)))
		for v in speeds { worst = max(worst, abs(v - mean) / mean) }
		return
	}

	// Strafing at constant speed, the camera and the first-person gun must move
	// smoothly every display frame, also at frame rates far above the net rate
	// where most frames build no command.
	@(test)
	native_render_is_smooth_at_high_frame_rates :: proc(t: ^testing.T) {
		for fps in ([2]f64{240, 1000}) {
			s: Native_Session
			native_session_init(&s, 144, 64, 0.03)
			defer native_session_destroy(&s)
			me := s.w.client.me
			start := shared.Vec3{-6, 1, 150}
			me.position, me.last_position, s.w.server_player.position, s.w.server_player.last_position = start, start, start, start
			previous_camera, previous_gun_old: shared.Vec3
			camera_speeds, gun_old_speeds: [dynamic]f64
			defer { delete(camera_speeds); delete(gun_old_speeds) }
			max_gun_offset: f32
			frames := 0
			for s.now < 2.5 {
				dt := f32(1 / fps * (1 + 0.3 * math.sin(f64(frames) * 1.7)))
				frames += 1
				native_session_frame(t, &s, {delta = dt, move_dir = 0})
				camera := native_client_render_position(&s.w.client) // the camera, and now the gun
				gun_old := me.position                               // where the gun was drawn before the fix
				if s.now > 1.0 {
					append(&camera_speeds, f64(native_test_length(camera - previous_camera) / dt))
					append(&gun_old_speeds, f64(native_test_length(gun_old - previous_gun_old) / dt))
					max_gun_offset = max(max_gun_offset, native_test_length(gun_old - camera))
				}
				previous_camera, previous_gun_old = camera, gun_old
			}
			camera_mean, camera_jitter := native_speed_spread(camera_speeds[:])
			_, gun_old_jitter := native_speed_spread(gun_old_speeds[:])
			fmt.printf("  smoothness %4.0f fps, 144 Hz commands: camera/gun %.2f u/s, worst frame deviation %.4f%%; old gun (player.position) worst deviation %.0f%%, up to %.3f u off the camera; %d snapshots, %d corrections\n",
				fps, camera_mean, camera_jitter * 100, gun_old_jitter * 100, max_gun_offset, s.snapshots, s.corrections)
			testing.expectf(t, camera_mean > 10 && camera_jitter < 0.02 && s.corrections == 0,
				"%.0f fps: the rendered position moves at a steady speed (worst %.3f%%, %d corrections)", fps, camera_jitter * 100, s.corrections)
		}
	}

	// Reload is predicted: the timer starts on the press, counts down without
	// being restarted or cut short by snapshots, and the magazine stays full
	// afterwards even while the server's acknowledged state lags behind.
	@(test)
	native_reload_plays_through :: proc(t: ^testing.T) {
		s: Native_Session
		native_session_init(&s, 144, 64, 0.04)
		defer native_session_destroy(&s)
		me := s.w.client.me
		capacity := me.weapon.ammo
		reload_time := me.weapon.reload_time * s.w.client.game.config.reload_speed
		dt := f32(1.0 / 240)
		shots_before := me.shot_seq
		for me.shot_seq == shots_before && s.now < 0.05 { native_session_frame(t, &s, {delta = dt, move_dir = -1, shoot = true}) }
		testing.expect(t, me.shot_seq > shots_before && s.snapshots == 0, "a click fires in prediction before any snapshot")
		for s.now < 0.3 { native_session_frame(t, &s, {delta = dt, move_dir = -1, shoot = true}) }
		for s.now < 0.6 { native_session_frame(t, &s, {delta = dt, move_dir = -1}) }
		after_shooting := me.ammo[me.loadout_index]
		testing.expectf(t, after_shooting < capacity && after_shooting > 0, "shooting spent ammo (%d of %d)", after_shooting, capacity)
		testing.expectf(t, s.w.server_player.ammo[s.w.server_player.loadout_index] == after_shooting, "the server spent the same ammo (%d vs %d)",
			s.w.server_player.ammo[s.w.server_player.loadout_index], after_shooting)

		native_session_frame(t, &s, {delta = dt, move_dir = -1, reload = true})
		for me.reload_timer == 0 && s.now < 0.7 { native_session_frame(t, &s, {delta = dt, move_dir = -1}) }
		started := s.now - f64(dt)
		testing.expect(t, me.reload_timer > 0, "the reload press starts the reload at once")
		previous := me.reload_timer
		finished := -1.0
		monotonic, flicker := true, false
		for s.now < started + f64(reload_time) + 0.6 {
			native_session_frame(t, &s, {delta = dt, move_dir = -1})
			if me.reload_timer > previous + 1e-6 { monotonic = false }
			if finished < 0 && me.reload_timer == 0 { finished = s.now }
			if finished >= 0 && me.ammo[me.loadout_index] != capacity { flicker = true }
			previous = me.reload_timer
		}
		took := finished - started
		fmt.printf("  reload: %.3f s predicted (weapon %.3f s), %d snapshots so far, ammo %d -> %d, server ammo %d\n",
			took, reload_time, s.snapshots, after_shooting, me.ammo[me.loadout_index], s.w.server_player.ammo[s.w.server_player.loadout_index])
		testing.expect(t, monotonic, "snapshots never restart the reload timer")
		testing.expectf(t, abs(took - f64(reload_time)) < 0.03, "the reload runs its full length (%.3f s of %.3f s)", took, reload_time)
		testing.expect(t, !flicker && me.ammo[me.loadout_index] == capacity, "the magazine stays full after the predicted reload")
		testing.expect(t, s.w.server_player.ammo[s.w.server_player.loadout_index] == capacity, "the server reloaded too")
	}
}
