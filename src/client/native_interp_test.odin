package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import shared "../shared"
import menuui "../menu"

when ODIN_TEST {
	// Remote player interpolation on a native server (native_interp.odin),
	// measured the way the spectator smoothing was: a player strafing,
	// jumping and flicking, sampled by the server every tick, quantised as the
	// snapshot codec does, received with network jitter at the next render
	// frame, and drawn by (before) the protocol 11 two-point lerp toward the
	// newest snapshot over 1.1 send intervals, or (after) the jitter buffer.

	Interp_Jerk :: struct {
		angle_jerk_rms, angle_accel_max: f64, // deg/s^3, deg/s^2
		position_jerk_rms, position_accel_max: f64, // units/s^3, units/s^2
		angle_error_rms, position_error_rms: f64, // vs the true path at the best-fitting lag
		delay: f64, // that lag, seconds
	}

	@(private = "file")
	interp_truth :: proc(t: f64) -> (position: shared.Vec3, pitch, yaw: f32) {
		x := 45 * math.sin(0.9 * t) + 30 * t
		z := 20 * math.sin(0.37 * t)
		phase := math.mod(t, 1.3)
		y := phase < 0.6 ? 60 * phase - 100 * phase * phase : 0
		position = {f32(x), f32(max(y, 0)), f32(z)}
		yaw_deg := 25 * t + 35 * math.sin(1.7 * t) + 8 * math.sin(5.3 * t)
		pitch_deg := 12 * math.sin(0.6 * t) - 4
		return position, f32(pitch_deg * math.PI / 180), shared.normalize_angle(f32(yaw_deg * math.PI / 180))
	}

	Interp_Packet :: struct { arrive, server: f64, state: shared.Packet_Player_State }

	// One snapshot per tick through the real quantisation, arriving after a
	// base latency plus jitter, 5% of them held for an extra interval, in order.
	@(private = "file")
	interp_stream :: proc(rate, jitter, seconds: f64, seed: u64) -> [dynamic]Interp_Packet {
		r := rand.create(seed)
		gen := rand.default_random_generator(&r)
		out: [dynamic]Interp_Packet
		for n := 0; f64(n) / rate < seconds; n += 1 {
			server := f64(n) / rate
			p, pitch, yaw := interp_truth(server)
			state := shared.Packet_Player_State{player_id = 7, active = true, position = p, x_dir = shared.input_angle_quantize(pitch), y_dir = shared.input_angle_quantize(yaw), on_ground = p.y <= 0, max_health = 100, health = 100}
			e := shared.snapshot_entity_from_state(&state, false)
			state = shared.snapshot_entity_to_state(&e, false)
			delay := 0.03 + rand.float64(gen) * jitter
			if rand.float64(gen) < 0.05 { delay += 1 / rate }
			append(&out, Interp_Packet{server + delay, server, state})
		}
		for i in 1 ..< len(out) { out[i].arrive = max(out[i].arrive, out[i - 1].arrive) }
		return out
	}

	@(private = "file")
	interp_unwrap :: proc(previous, value: f64) -> f64 {
		return previous + (value - previous) - 360 * math.round((value - previous) / 360)
	}

	// mode 0: protocol 11's player_interpolate; mode 1: the jitter buffer.
	interp_measure :: proc(rate, jitter, fps: f64, mode: int, seed: u64 = 7) -> Interp_Jerk {
		packets := interp_stream(rate, jitter, 20, seed)
		defer delete(packets)
		game: shared.Game
		game.config.delta_mlt = 1
		player := shared.Player{game = &game}
		clock: Native_View_Clock
		track: Native_Remote_Track
		dt := 1 / fps
		next := 0
		have := false
		yaws, pitches: [dynamic]f64
		positions: [dynamic]shared.Vec3
		times: [dynamic]f64
		defer { delete(yaws); delete(pitches); delete(positions); delete(times) }
		previous_yaw: f64
		for frame := 0; f64(frame) * dt < 20; frame += 1 {
			now := 1 + f64(frame) * dt
			for next < len(packets) && 1 + packets[next].arrive <= now {
				p := packets[next]
				if mode == 0 {
					// client_apply_player_state before this change.
					if !have { player.position, player.direction = p.state.position, {p.state.x_dir, p.state.y_dir} }
					player.interpolate, player.dt, player.send_rate = true, 0, f32(rate)
					player.interp_pos_start, player.interp_pos_end = player.position, p.state.position
					player.interp_dir_start, player.interp_dir_end = player.direction, {p.state.x_dir, p.state.y_dir}
				} else {
					state := p.state
					native_view_clock_observe(&clock, now, p.server, rate, rate)
					native_remote_push(&track, native_remote_sample_from_state(&state, p.server))
				}
				have = true
				next += 1
			}
			if !have { continue }
			position: shared.Vec3
			pitch, yaw: f32
			if mode == 0 {
				shared.player_interpolate(&player, f32(dt))
				position, pitch, yaw = player.position, player.direction.x, player.direction.y
			} else {
				native_view_clock_update(&clock, now, 0)
				s, ok, _ := native_remote_sample(&track, clock.view_time)
				if !ok { continue }
				position, pitch, yaw = s.position, s.pitch, s.yaw
			}
			y := f64(yaw) * 180 / math.PI
			if len(yaws) > 0 { y = interp_unwrap(previous_yaw, y) }
			previous_yaw = y
			append(&yaws, y); append(&pitches, f64(pitch) * 180 / math.PI)
			append(&positions, position); append(&times, now - 1)
		}
		result: Interp_Jerk
		start := int(fps)
		n := len(yaws)
		sum_j, sum_pj, count := 0.0, 0.0, 0.0
		for i in start + 3 ..< n {
			for series in ([2][]f64{yaws[:], pitches[:]}) {
				a0 := (series[i - 1] - 2 * series[i - 2] + series[i - 3]) / (dt * dt)
				a1 := (series[i] - 2 * series[i - 1] + series[i - 2]) / (dt * dt)
				sum_j += ((a1 - a0) / dt) * ((a1 - a0) / dt)
				result.angle_accel_max = max(result.angle_accel_max, abs(a1))
			}
			for c in 0 ..< 3 {
				p := [4]f64{f64(positions[i - 3][c]), f64(positions[i - 2][c]), f64(positions[i - 1][c]), f64(positions[i][c])}
				a0 := (p[2] - 2 * p[1] + p[0]) / (dt * dt)
				a1 := (p[3] - 2 * p[2] + p[1]) / (dt * dt)
				sum_pj += ((a1 - a0) / dt) * ((a1 - a0) / dt)
				result.position_accel_max = max(result.position_accel_max, abs(a1))
			}
			count += 1
		}
		result.angle_jerk_rms = math.sqrt(sum_j / (2 * count))
		result.position_jerk_rms = math.sqrt(sum_pj / (3 * count))
		best: f64 = 1e9
		for lag_ms := 0; lag_ms <= 300; lag_ms += 1 {
			lag := f64(lag_ms) / 1000
			sum, k, psum := 0.0, 0.0, 0.0
			for i in start ..< n {
				tp, pitch_t, yaw_t := interp_truth(times[i] - lag)
				d := yaws[i] - f64(yaw_t) * 180 / math.PI
				d -= 360 * math.round(d / 360)
				dp := pitches[i] - f64(pitch_t) * 180 / math.PI
				sum += d * d + dp * dp; k += 2
				e := positions[i] - tp
				psum += f64(e.x * e.x + e.y * e.y + e.z * e.z)
			}
			if err := math.sqrt(sum / k); err < best {
				best, result.delay = err, lag
				result.position_error_rms = math.sqrt(psum / (k / 2))
			}
		}
		result.angle_error_rms = best
		return result
	}

	@(test)
	native_interp_jerk_is_lower_than_the_two_point_lerp :: proc(t: ^testing.T) {
		Case :: struct { rate, jitter, fps: f64 }
		cases := [?]Case{{64, 0.005, 144}, {64, 0.015, 144}, {64, 0.03, 240}, {128, 0.005, 240}, {128, 0.015, 144}, {32, 0.015, 144}}
		fmt.println("[interp-jerk] snapshots | jitter | fps | mode | ang_jerk_rms deg/s3 | ang_acc_max deg/s2 | pos_jerk_rms u/s3 | pos_acc_max u/s2 | ang_err_rms deg | pos_err_rms u | delay ms")
		for c in cases {
			before := interp_measure(c.rate, c.jitter, c.fps, 0)
			after := interp_measure(c.rate, c.jitter, c.fps, 1)
			names := [2]string{"two-point lerp (protocol 11)", "jitter buffer (protocol 12)"}
			for r, i in ([2]Interp_Jerk{before, after}) {
				fmt.printf("[interp-jerk] %v Hz | %v ms | %v | %s | %v | %v | %v | %v | %.3f | %.3f | %v\n",
					int(c.rate), int(c.jitter * 1000), int(c.fps), names[i], i64(r.angle_jerk_rms), i64(r.angle_accel_max), i64(r.position_jerk_rms), i64(r.position_accel_max), r.angle_error_rms, r.position_error_rms, int(r.delay * 1000 + 0.5))
			}
			testing.expectf(t, after.angle_jerk_rms < before.angle_jerk_rms * 0.5, "%v Hz %v ms: angular jerk %v vs %v", c.rate, c.jitter, after.angle_jerk_rms, before.angle_jerk_rms)
			testing.expectf(t, after.position_jerk_rms < before.position_jerk_rms * 0.5, "%v Hz %v ms: positional jerk %v vs %v", c.rate, c.jitter, after.position_jerk_rms, before.position_jerk_rms)
			// The buffer follows the true path at least as closely, and its
			// delay is the configured 2 intervals plus jitter, not more.
			testing.expectf(t, after.angle_error_rms <= before.angle_error_rms + 0.05, "%v Hz: angle error %v vs %v", c.rate, after.angle_error_rms, before.angle_error_rms)
			testing.expectf(t, after.delay <= 0.03 + 2 / c.rate + c.jitter + 2 / c.rate + 0.02, "%v Hz: delay %v", c.rate, after.delay)
		}
	}

	// A dry buffer extrapolates for at most NATIVE_INTERP_MAX_EXTRAPOLATE,
	// then holds; a teleport or a long gap starts a new path.
	@(test)
	native_interp_extrapolation_is_clamped :: proc(t: ^testing.T) {
		track: Native_Remote_Track
		for i in 0 ..< 10 {
			native_remote_push(&track, {time = f64(i) / 64, position = {f32(i), 0, 0}})
		}
		last := 9.0 / 64
		s, ok, extrapolating := native_remote_sample(&track, last + 0.02)
		testing.expectf(t, ok && extrapolating && abs(s.position.x - (9 + 0.02 * 64)) < 1e-3, "short extrapolation follows the last velocity (%v)", s.position)
		s, ok, extrapolating = native_remote_sample(&track, last + 2)
		want := 9 + f32(NATIVE_INTERP_MAX_EXTRAPOLATE) * 64
		testing.expectf(t, ok && extrapolating && abs(s.position.x - want) < 1e-3, "then holds (%v, want %v)", s.position.x, want)
		// Between samples: exact on a straight line.
		track = {}
		for i in 0 ..< 10 { native_remote_push(&track, {time = f64(i) / 64, position = {f32(i) * 2, 1, 0}, yaw = 0.1 * f32(i)}) }
		s, ok, extrapolating = native_remote_sample(&track, 4.5 / 64)
		testing.expectf(t, ok && !extrapolating && abs(s.position.x - 9) < 1e-4 && abs(s.yaw - 0.45) < 1e-5, "Hermite reproduces a straight line (%v %v)", s.position, s.yaw)
		resets := track.resets
		native_remote_push(&track, {time = 10.0 / 64, position = {500, 1, 0}})
		testing.expect(t, track.count == 1 && track.resets == resets + 1, "a teleport starts a new path")
		native_remote_push(&track, {time = 2, position = {500, 1, 0}})
		testing.expect(t, track.count == 1 && track.resets == resets + 2, "a gap starts a new path")
		// Yaw is unwrapped across +-PI, so the path turns the short way.
		track = {}
		native_remote_push(&track, {time = 0, yaw = 3.1})
		native_remote_push(&track, {time = 1.0 / 64, yaw = -3.1})
		s, _, _ = native_remote_sample(&track, 0.5 / 64)
		testing.expectf(t, abs(shared.normalize_angle(s.yaw - math.PI)) < 0.01, "crossing +-PI turns through PI (%v)", s.yaw)
	}

	// The view clock: Auto delay is 2 intervals plus jitter, a set delay is
	// eased in, view time never runs backwards, and view_tick/view_frac name
	// the server time the remote is drawn at.
	@(test)
	native_view_time_and_stamps :: proc(t: ^testing.T) {
		RATE :: 64.0
		clock: Native_View_Clock
		track: Native_Remote_Track
		latency := 0.04
		previous_view := -1.0
		max_error: f32
		backwards := false
		next_tick := 0
		for frame in 0 ..< 144 * 4 {
			now := 5 + f64(frame) / 144
			// Deliver every tick whose snapshot has arrived by now, in order.
			for 5 + f64(next_tick) / RATE + latency <= now {
				server := f64(next_tick) / RATE
				native_view_clock_observe(&clock, 5 + server + latency, server, RATE, RATE)
				native_remote_push(&track, {time = server, position = {f32(30 * server), 0, 0}})
				next_tick += 1
			}
			if track.count == 0 { continue }
			native_view_clock_update(&clock, now, 0)
			if clock.view_time < previous_view { backwards = true }
			previous_view = clock.view_time
			tick, frac, ok := native_view_clock_tick(&clock)
			s, _, _ := native_remote_sample(&track, clock.view_time)
			if frame > 144 && ok {
				// The stamp names the server time of what is drawn.
				stamped := (f64(tick) + f64(frac)) / RATE
				max_error = max(max_error, abs(s.position.x - f32(30 * stamped)))
			}
		}
		want_delay := 2 / RATE
		testing.expectf(t, abs(clock.delay - want_delay) < 0.002, "Auto delay is 2 snapshot intervals without jitter (%v)", clock.delay)
		testing.expectf(t, abs((5 + 4 - 1.0 / 144) - clock.offset - clock.delay - clock.view_time) < 1e-9, "view time = now - offset - delay")
		testing.expect(t, !backwards, "view time never runs backwards")
		testing.expectf(t, max_error < 0.01, "the drawn position matches the stamped tick + fraction (max error %v units)", max_error)
		fmt.printf("  view clock: offset %.4f s (latency %.3f), delay %.4f s, stamp vs drawn max error %.5f u\n", clock.offset - 5, latency, clock.delay, max_error)

		// A set delay (like cl_interp) is eased in at NATIVE_INTERP_DELAY_SLEW.
		start_delay := clock.delay
		for frame in 0 ..< 144 { native_view_clock_update(&clock, 9 + f64(frame) / 144, 100) }
		testing.expectf(t, clock.delay > start_delay && clock.delay < 0.1 && abs(clock.delay - (start_delay + 143.0 / 144 * NATIVE_INTERP_DELAY_SLEW)) < 1e-3, "a set delay is eased in (%v)", clock.delay)
		for frame in 0 ..< 144 * 3 { native_view_clock_update(&clock, 10 + f64(frame) / 144, 100) }
		testing.expectf(t, abs(clock.delay - 0.1) < 1e-9, "and then held (%v)", clock.delay)
		testing.expect(t, native_view_clock_target_delay(&clock, 0) == 2 * clock.interval + clock.jitter, "Auto: 2 intervals + jitter")
		clock.jitter = 0.012
		testing.expect(t, abs(native_view_clock_target_delay(&clock, 0) - (2.0 / 64 + 0.012)) < 1e-12, "measured jitter is added")

		// Late snapshots raise the jitter envelope; it decays afterwards.
		jc: Native_View_Clock
		native_view_clock_observe(&jc, 1.04, 1.0, 64, 64)
		native_view_clock_observe(&jc, 1.04 + 1.0 / 64 + 0.02, 1.0 + 1.0 / 64, 64, 64)
		testing.expectf(t, abs(jc.jitter - 0.02) < 1e-3, "a snapshot 20 ms late (%v)", jc.jitter)
		native_view_clock_observe(&jc, 3.04, 3.0, 64, 64)
		testing.expectf(t, jc.jitter < 0.02 - 0.0035 && jc.jitter > 0, "the envelope decays (%v)", jc.jitter)

		// view_tick is the floor, view_frac the rest, through the wire.
		vc := Native_View_Clock{has_view = true, tick_rate = 64, view_time = 12.3456}
		tick, frac, ok := native_view_clock_tick(&vc)
		testing.expectf(t, ok && tick == 790 && abs(frac - f32(12.3456 * 64 - 790)) < 1e-4, "view tick %v frac %v", tick, frac)
		empty: Native_View_Clock
		_, _, unset := native_view_clock_tick(&empty)
		testing.expect(t, !unset, "no stamp before the first snapshot")
	}

	// Commands carry the view stamp from native_client_predict_frame; the
	// server decodes it within the u16 fraction's precision.
	@(test)
	native_commands_carry_view_stamps :: proc(t: ^testing.T) {
		w: Native_Test_World
		native_test_world_init(&w, 144)
		defer native_test_world_destroy(&w)
		client := &w.client
		frame := shared.Input{delta = 1.0 / 144, move_dir = 0}
		native_client_predict_frame(client, &frame, frame)
		testing.expect(t, len(client.predicted_inputs) == 1 && !client.predicted_inputs[0].view_stamped, "no stamp before any snapshot")
		client.net.view = {has_view = true, tick_rate = 128, view_time = 33.3333}
		frame = {delta = 1.0 / 144, move_dir = 0, shoot = true}
		native_client_predict_frame(client, &frame, frame)
		command := client.predicted_inputs[len(client.predicted_inputs) - 1]
		want_tick := u32(math.floor(33.3333 * 128))
		testing.expectf(t, command.view_stamped && command.view_tick == want_tick, "stamped with tick %v (want %v)", command.view_tick, want_tick)
		buf: [shared.INPUT_BATCH_MAX_PACKET]byte
		size := shared.packet_serialize_input_batch(buf[:], client.predicted_inputs[:])
		out: [shared.INPUT_BATCH_MAX_COMMANDS]shared.Input
		count, ok := shared.packet_deserialize_input_batch(buf[:size], out[:])
		testing.expect(t, ok && count == 2 && !out[0].view_stamped && out[1].view_stamped && out[1].view_tick == want_tick, "the stamp survives the wire")
		testing.expectf(t, abs(out[1].view_frac - command.view_frac) <= 1.0 / 65535, "fraction %v vs %v", out[1].view_frac, command.view_frac)
		testing.expect(t, shared.input_command_sanitize(&out[1]) == .NONE && out[1].view_tick == want_tick, "the server keeps the stamp")
	}

	@(test)
	net_interp_setting :: proc(t: ^testing.T) {
		defaults := client_settings_defaults()
		testing.expect(t, client_settings_validate(defaults).net_interp == 0 && client_settings_default_values().net_interp == 0, "Auto by default")
		odd := defaults
		odd.net_interp = 77
		testing.expect(t, client_settings_validate(odd).net_interp == 0, "unknown values become Auto")
		odd.net_interp = 100
		testing.expect(t, client_settings_validate(odd).net_interp == 100, "a listed value is kept")
		draft := client_settings_default_values()
		draft.net_interp = 150
		menuui.settings_reset_tab(&draft, client_settings_default_values(), .GAMEPLAY)
		testing.expect(t, draft.net_interp == 0, "Gameplay reset restores Auto")
		testing.expect(t, menuui.net_interp_index(150) == 7 && menuui.NET_INTERP_LABELS[0] == "Auto", "dropdown index and label")
	}

	// Through the real client path (decode, apply, mesh): a remote beyond
	// view distance is hidden, and when it comes back it snaps to its new
	// position and starts a new interpolation path instead of sweeping there.
	@(test)
	native_culled_players_hide_and_reappear :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(64, 64, "Cull", nil, nil)
		if !testing.expect(t, window != nil) { return }
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		map_inst := shared.Map{death_y = -1000, config = shared.DEFAULT_MAP_CONFIG}
		client := new(Client)
		defer free(client)
		client.window, client.scene, client.fps_scene = window, scene_init(), scene_init()
		g_client = client
		defer { g_client = nil }
		shared.game_configure(&client.game, &config.game, []^shared.Map{&map_inst}, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, 0, true)
		client.game.is_local = false
		client.map_loaded = true
		defer {
			client_clear_players(client)
			net_client_disconnect(&client.net)
			shared.game_destroy(&client.game)
			scene_fini(client.fps_scene)
			scene_fini(client.scene)
			resource_cache_fini()
		}
		probe := shared.player_init(&client.game)
		shared.player_spawn(probe, 0)
		weapon := u8(probe.loadout[0])
		shared.player_destroy(probe)

		server_ring := new(shared.Snapshot_Ring)
		defer free(server_ring)
		frame := new(shared.Snapshot_Frame)
		defer free(frame)
		buf := make([]byte, shared.SNAPSHOT_MAX_PACKET)
		defer delete(buf)
		acked: u32
		send :: proc(client: ^Client, server_ring: ^shared.Snapshot_Ring, frame: ^shared.Snapshot_Frame, buf: []byte, acked: ^u32, tick: u32, states: []shared.Packet_Player_State) -> bool {
			frame^ = {}
			frame.tick = tick
			frame.match = {phase = 1, map_index = client.game.current_map_index, tick_rate = 64, send_rate = 64, time_ds = 600}
			lobby := shared.Lobby_State{local_id = 1, team = 0, capacity = 4, team_names = {"A", "B"}, count = len(states)}
			for &s, i in states {
				lobby.players[i] = {id = s.player_id, team = s.team, class_id = 0}
				frame.entities[i] = shared.snapshot_entity_from_state(&s, false)
			}
			frame.count = len(states)
			frame.lobby_len = shared.packet_serialize_lobby(frame.lobby[:], &lobby)
			size := shared.snapshot_encode(buf, frame, acked^ != 0 ? shared.snapshot_ring_find(server_ring, acked^) : nil)
			shared.snapshot_ring_store(server_ring, frame)
			result := net_client_receive_snapshot(client, buf[:size], f64(tick) / 64 + 0.05)
			if client.net.ack_pending && !client.net.ack_reset { acked^ = client.net.last_tick }
			return result == .OK
		}
		near := shared.Packet_Player_State{player_id = 5, active = true, team = 1, position = {10, 0, 0}, health = 100, max_health = 100, weapon_id = weapon}
		far := shared.Packet_Player_State{player_id = 6, culled = true, team = 2, health = 100, max_health = 100, weapon_id = weapon}
		testing.expect(t, send(client, server_ring, frame, buf, &acked, 1, {near, far}), "snapshot 1 applies")
		a, b := client_find_player(client, 5), client_find_player(client, 6)
		if !testing.expect(t, a != nil && b != nil) { return }
		testing.expect(t, a.active && a.mesh != nil && !b.active, "the near player is shown, the culled one is known but hidden")
		testing.expect(t, b.team == 2, "a culled player still carries its team")

		far = {player_id = 6, active = true, team = 2, position = {20, 0, 0}, health = 100, max_health = 100, weapon_id = weapon}
		testing.expect(t, send(client, server_ring, frame, buf, &acked, 2, {near, far}), "snapshot 2 applies")
		testing.expect(t, b.active && b.mesh != nil && b.position == {20, 0, 0}, "entering view: shown at its position")
		for i in 3 ..= 5 {
			far.position.x += 1
			send(client, server_ring, frame, buf, &acked, u32(i), {near, far})
		}
		track := &client.net.remotes[6]
		testing.expectf(t, track.count == 4, "moving within view is buffered (%d samples)", track.count)
		resets := track.resets
		far.culled, far.active = true, false
		send(client, server_ring, frame, buf, &acked, 6, {near, far})
		testing.expect(t, !b.active, "leaving view hides the player")
		far = {player_id = 6, active = true, team = 2, position = {200, 0, 50}, health = 100, max_health = 100, weapon_id = weapon}
		send(client, server_ring, frame, buf, &acked, 7, {near, far})
		track = &client.net.remotes[6]
		testing.expectf(t, b.active && b.position == {200, 0, 50} && track.count == 1 && track.resets > resets,
			"coming back snaps to the new position and starts a new path (%v, %d samples)", b.position, track.count)
		native_view_clock_update(&client.net.view, 7.0 / 64 + 0.05 + 0.1, 0)
		native_client_interpolate_remotes(client, 1.0 / 144)
		testing.expectf(t, b.position == {200, 0, 50}, "no sweep from the old position (%v)", b.position)
		testing.expect(t, client.net.snapshot_stats.received == 7 && client.net.snapshot_stats.full == 1, "one full snapshot, then deltas")
		testing.expect(t, client.net.last_tick == 7 && client.net.ack_pending, "the newest snapshot is waiting to be acknowledged")
		// A delta against a baseline the client never had asks for a full one.
		frame.tick = 9
		size := shared.snapshot_encode(buf, frame, shared.snapshot_ring_find(server_ring, 7))
		client.net.snapshots.frames[7 % shared.SNAPSHOT_RING].valid = false
		testing.expect(t, net_client_receive_snapshot(client, buf[:size], 1) == .NO_BASELINE && client.net.ack_reset, "a lost baseline requests a full snapshot")
	}
}
