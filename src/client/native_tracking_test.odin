package main

import "core:fmt"
import "core:math"
import "core:testing"
import shared "../shared"
import ded "../server/dedicated"

// Reproduction of "I tracked a strafing bot at point blank with a full AR
// magazine and the server confirmed almost no hits" on Krodin's native server.
//
// Client side, the real native path a frame at a time: a scripted human aims
// at the chest of the enemy as it is drawn (the remote player after
// player_interpolate, as client_tick runs it), from the camera
// (native_client_render_position + height - cameraHeight, the crosshair's
// recoil compensated), and holds fire; native_client_predict_frame builds the
// commands, which go through the input batch codec with latency. Server side:
// the command stream, player_proc_input / player_shoot, game_tick at 64 tick,
// GAME_STATE through the codec every second tick. The enemy moves like
// tools/netbot (a new strafe direction every 0.3-1.2 s, 2% jump chance per
// command) and stays at point blank.
//
// Every server shot is recorded with the client's camera ray for the same shot
// and the enemy where the client drew it versus where the server tested it.
//
// Finding: the shot origin and direction agree to float precision; the target
// does not. The server tested the enemy where it is now, while the client
// draws it a snapshot interval + interpolation + latency in the past: 2.5 units
// apart at 2 ms one-way, 5 at 30 ms, 8 at 60 ms, so a perfectly tracked
// strafing target is mostly missed. Krunker's server rewinds every target to
// the shooter's view (fetchState with the command's inputSTime/inputSTPrg);
// the native server now does too, from the command's view stamp
// (Input.view_tick/view_frac). The `stamped` runs stamp each command with the
// tick the human's view showed, as the native client's remote-player clock
// does; unstamped commands keep the old, unrewound test.
when ODIN_TEST {
	Track_Shot :: struct {
		client_origin, client_dir: shared.Vec3,
		server_origin, server_dir: shared.Vec3,
		drawn_target:  shared.Vec3, // the enemy where the client drew it when the shot was aimed
		server_target: shared.Player, // the server's enemy (current state) when it tested the shot
		tested_target: shared.Vec3, // where the server's shot test put it (rewound when stamped)
		client_hit, server_hit: bool,
	}

	Track_Result :: struct {
		shots, server_hits, client_hits: int,
		legacy_hits: int, // the old two boxes at the server's current target, re-tested offline
		mean_offset, max_offset, mean_vertical: f32, // tested target - drawn target
		max_origin_error, max_dir_error: f32,
	}

	Track_Packet :: struct { at: f64, tick: int, data: [shared.PACKET_HEADER_SIZE + shared.PACKET_PLAYER_STATE_PAYLOAD_SIZE]byte, size: int }

	Track_Session :: struct {
		s:            Native_Session,
		server_bot:   ^shared.Player,
		client_bot:   ^shared.Player,
		bot_packets:  [dynamic]Track_Packet,
		bot_rng:      u64,
		bot_move:     i32,
		bot_next:     f64,
		stamp:        bool,
		// The server time the drawn enemy shows: the remote lerp runs from the
		// drawn pose at a snapshot's arrival to that snapshot, so its time
		// moves the same way.
		view_start, view_end, view_time: f64,
		shots:        [dynamic]Track_Shot,
		client_shots: [dynamic]Track_Shot, // the client half, paired by order
		aim_target:   shared.Vec3,
	}

	TRACK_ARENA :: shared.Vec3{-100, 1, 100}

	track_rand :: proc(state: ^u64) -> f64 {
		state^ ~= state^ << 13; state^ ~= state^ >> 7; state^ ~= state^ << 17
		return f64(state^ >> 11) / f64(u64(1) << 53)
	}

	// The old native boxes (before Krunker's hurtboxes): two upright boxes, body
	// 2 x scale wide up to 72% of the height, head 1.6 x scale wide above it.
	track_legacy_hit :: proc(target: ^shared.Player, origin, segment: shared.Vec3) -> bool {
		body_height := max(0.1, target.height * 0.72)
		_, _, body := shared.ray_box_hit(origin, segment, target.position, {target.scale * 2, body_height, target.scale * 2})
		_, _, head := shared.ray_box_hit(origin, segment, target.position + {0, body_height, 0}, {target.scale * 1.6, max(0.1, target.height - body_height), target.scale * 1.6})
		return body || head
	}

	// The rendered chest: the centre of the torso box of the drawn pose.
	track_chest :: proc(player: ^shared.Player) -> shared.Vec3 {
		boxes: [shared.KRUNKER_HURTBOX_MAX]shared.Krunker_Hurtbox
		count := shared.krunker_player_hurtboxes(shared.krunker_hurtbox_pose(player, false), &boxes)
		for box in boxes[:count] { if box.part == .TORSO { return shared.krunker_hurtbox_center(box) } }
		return player.position + {0, player.height * 0.6, 0}
	}

	track_aim :: proc(from, to: shared.Vec3) -> shared.Vec2 {
		d := to - from
		// Shot direction: (-sin(yaw)cos(pitch), sin(pitch), -cos(yaw)cos(pitch)).
		return {math.atan2(d.y, math.sqrt(d.x * d.x + d.z * d.z)), math.atan2(-d.x, -d.z)}
	}

	track_session_init :: proc(ts: ^Track_Session, latency: f64, seed: u64, stamp: bool) {
		s := &ts.s
		native_session_init(s, 144, 64, latency)
		ts.bot_rng, ts.stamp = seed, stamp
		w := &s.w
		w.server_game.config.tick_rate = 64
		ts.server_bot = shared.player_init(&w.server_game)
		shared.game_players_add(&w.server_game, ts.server_bot)
		shared.player_spawn(ts.server_bot, 0)
		ts.client_bot = shared.player_init(&w.client.game)
		shared.game_players_add(&w.client.game, ts.client_bot)
		shared.player_spawn(ts.client_bot, 0)
		ts.server_bot.uid, ts.client_bot.uid = 2, 2
		w.client.me.uid, w.server_player.uid = 1, 1
		for p in ([2]^shared.Player{w.client.me, w.server_player}) { p.team = 1; p.position, p.last_position = TRACK_ARENA, TRACK_ARENA }
		for p in ([2]^shared.Player{ts.server_bot, ts.client_bot}) {
			p.team = 2
			p.swap_timer = 0
			p.position, p.last_position = TRACK_ARENA + {0, 0, -10}, TRACK_ARENA + {0, 0, -10}
			p.velocity, p.direction = {}, {0, 0}
		}
		ts.client_bot.interpolate = true
		ts.client_bot.interp_pos_start, ts.client_bot.interp_pos_end = ts.client_bot.position, ts.client_bot.position
		ts.client_bot.send_rate = 32
		ts.aim_target = track_chest(ts.client_bot)
	}

	track_session_destroy :: proc(ts: ^Track_Session) {
		delete(ts.shots)
		delete(ts.client_shots)
		delete(ts.bot_packets)
		native_session_destroy(&ts.s)
	}

	// netbot's movement (tools/netbot bot_input): a fresh direction every
	// 0.3-1.2 s (a stop 15% of the time), a 2% jump chance on every command,
	// closing in (forward or a forward diagonal) when it drifts away; here it
	// closes in beyond 14 units so the fight stays at point blank.
	track_bot_command :: proc(ts: ^Track_Session, now: f64, dt: f32) -> shared.Input {
		bot := ts.server_bot
		human := ts.s.w.server_player
		d := human.position - bot.position
		distance := math.sqrt(d.x * d.x + d.z * d.z)
		if now >= ts.bot_next || distance > 14 && ts.bot_move != 0 && ts.bot_move != 1 && ts.bot_move != 7 {
			if distance > 14 {
				forward := [3]i32{0, 1, 7}
				ts.bot_move = forward[int(track_rand(&ts.bot_rng) * 3) % 3]
			} else {
				ts.bot_move = track_rand(&ts.bot_rng) < 0.15 ? -1 : i32(track_rand(&ts.bot_rng) * 8) % 8
			}
			ts.bot_next = now + 0.3 + track_rand(&ts.bot_rng) * 0.9
		}
		input := shared.Input{move_dir = ts.bot_move, delta = dt}
		input.jump = track_rand(&ts.bot_rng) < 0.02
		aim := track_aim(bot.position, human.position)
		input.x_dir, input.y_dir = 0, aim.y
		return input
	}

	// One display frame of the scripted human, then whatever the server and
	// network do until then (Native_Session's frame, with the enemy added).
	track_frame :: proc(t: ^testing.T, ts: ^Track_Session, dt: f32, fire: bool) {
		s := &ts.s
		client := &s.w.client
		me := client.me
		// Aim from the camera of the last drawn frame at the chest drawn in it.
		camera := native_client_render_position(client) + {0, me.height - shared.GAME_CONSTANTS.camera_height, 0}
		aim := track_aim(camera, ts.aim_target)
		frame := shared.Input{delta = dt, move_dir = -1, shoot = fire}
		// The crosshair is the camera, which adds the recoil kick; a human
		// pulls the mouse down by it to stay on target.
		frame.x_dir = aim.x - me.recoil_anim_y * shared.GAME_CONSTANTS.recoil_mlt
		frame.y_dir = aim.y
		drawn := ts.client_bot.position

		s.now += f64(dt)
		before := len(client.predicted_inputs)
		impacts_before := len(client.game.impacts)
		native_client_predict_frame(client, &frame, frame)
		if ts.stamp && ts.view_time > 0 {
			// The tick the aimed-at frame showed (what the native client's
			// remote clock reports in view_tick/view_frac).
			ticks := ts.view_time * 64
			for &command in client.predicted_inputs[before:] {
				command.view_stamped, command.view_tick, command.view_frac = true, u32(ticks), f32(ticks - math.floor(ticks))
			}
		}
		for impact in client.game.impacts[impacts_before:] {
			if impact.shooter_uid != me.uid { continue }
			append(&ts.client_shots, Track_Shot{client_origin = impact.origin, client_dir = impact.position - impact.origin, drawn_target = drawn, client_hit = impact.kind == .Player})
		}
		clear(&client.game.impacts)
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
			game := &s.w.server_game
			game.now = f32(s.server_now)
			// The enemy's commands (netbot runs at 64 Hz like the tick).
			bot_input := track_bot_command(ts, s.server_now, f32(s.tick_dt))
			shared.player_proc_input(ts.server_bot, &bot_input, false, false)
			out: [shared.INPUT_BATCH_MAX_COMMANDS]shared.Input
			for len(s.to_server) > 0 && s.to_server[0].at <= s.server_now {
				count, ok := shared.packet_deserialize_input_batch(s.to_server[0].data[:s.to_server[0].size], out[:])
				testing.expect(t, ok, "batches must decode")
				for c in out[:count] { ded.command_stream_push(&s.cs, c) }
				ordered_remove(&s.to_server, 0)
			}
			impacts_before := len(game.impacts)
			ded.command_stream_run(&s.cs, s.w.server_player, game, s.server_now)
			for impact in game.impacts[impacts_before:] {
				if impact.shooter_uid != s.w.server_player.uid { continue }
				tested := shared.player_shot_target(s.w.server_player, ts.server_bot, true)
				append(&ts.shots, Track_Shot{server_origin = impact.origin, server_dir = impact.position - impact.origin, server_target = ts.server_bot^, tested_target = tested.pose.position, server_hit = impact.kind == .Player})
			}
			shared.game_tick(game, f32(s.server_now), f32(s.tick_dt))
			clear(&game.impacts)
			ts.server_bot.health = f32(ts.server_bot.max_health) // never dies, keeps strafing
			if s.ticks % shared.SNAPSHOT_RATE_DIVISOR == 0 {
				state := ded.net_server_player_state(s.w.server_player, true)
				p := Native_Test_Packet{at = s.server_now + s.latency}
				p.size = shared.packet_serialize_state(p.data[:], &state)
				append(&s.to_client, p)
				bot_state := ded.net_server_player_state(ts.server_bot, false)
				bp := Track_Packet{at = s.server_now + s.latency, tick = s.ticks}
				bp.size = shared.packet_serialize_state(bp.data[:], &bot_state)
				append(&ts.bot_packets, bp)
			}
		}
		for len(s.to_client) > 0 && s.to_client[0].at <= s.now {
			state, ok := shared.packet_deserialize_state(s.to_client[0].data[:s.to_client[0].size])
			ordered_remove(&s.to_client, 0)
			if !testing.expect(t, ok, "snapshots must decode") { continue }
			was_active, previous_shot_seq := me.active, me.shot_seq
			client_reconcile_local_player(client, me, &state, was_active)
			client_apply_weapon_state(client, me, &state, was_active, previous_shot_seq)
			s.snapshots += 1
		}
		for len(ts.bot_packets) > 0 && ts.bot_packets[0].at <= s.now {
			packet := ts.bot_packets[0]
			ordered_remove(&ts.bot_packets, 0)
			state, ok := shared.packet_deserialize_state(packet.data[:packet.size])
			if !testing.expect(t, ok, "snapshots must decode") { continue }
			// client_apply_player_state's remote branch.
			bot := ts.client_bot
			bot.interpolate = true
			bot.dt = 0
			bot.send_rate = 32
			bot.interp_pos_start = bot.position
			bot.interp_pos_end = state.position
			bot.interp_dir_start = bot.direction
			bot.interp_dir_end = {state.x_dir, state.y_dir}
			bot.velocity = state.velocity
			client_apply_movement_state(bot, &state)
			ts.view_start = ts.view_time > 0 ? ts.view_time : f64(packet.tick) / 64
			ts.view_end = f64(packet.tick) / 64
		}
		// client_tick's remote update, then the frame is drawn.
		shared.player_update_recoil(me, dt)
		shared.player_update_visual_animations(ts.client_bot, dt)
		shared.player_interpolate(ts.client_bot, dt)
		bot := ts.client_bot
		progress := clamp(f64(bot.dt * bot.send_rate / shared.GAME_CONSTANTS.interpolation / client.game.config.delta_mlt), 0, 1)
		if ts.view_end > 0 { ts.view_time = ts.view_start + (ts.view_end - ts.view_start) * progress }
		ts.aim_target = track_chest(ts.client_bot)
	}

	track_run :: proc(t: ^testing.T, latency: f64, seed: u64, seconds: f64, stamp: bool) -> (r: Track_Result) {
		ts: Track_Session
		track_session_init(&ts, latency, seed, stamp)
		defer track_session_destroy(&ts)
		dt := f32(1.0 / 144)
		for ts.s.now < 0.5 { track_frame(t, &ts, dt, false) }
		// Hold fire (the gun reloads itself when the magazine runs dry).
		for ts.s.now < 0.5 + seconds { track_frame(t, &ts, dt, true) }
		for ts.s.now < 1.0 + seconds { track_frame(t, &ts, dt, false) }

		r.shots = min(len(ts.shots), len(ts.client_shots))
		testing.expectf(t, len(ts.shots) == len(ts.client_shots), "every predicted shot reaches the server (%d client, %d server)", len(ts.client_shots), len(ts.shots))
		for i in 0 ..< r.shots {
			shot := ts.shots[i]
			c := ts.client_shots[i]
			if shot.server_hit { r.server_hits += 1 }
			if c.client_hit { r.client_hits += 1 }
			target := shot.server_target
			if track_legacy_hit(&target, shot.server_origin, shot.server_dir) { r.legacy_hits += 1 }
			offset := shot.tested_target - c.drawn_target
			r.mean_offset += native_test_length(offset)
			r.mean_vertical += abs(offset.y)
			r.max_offset = max(r.max_offset, native_test_length(offset))
			r.max_origin_error = max(r.max_origin_error, native_test_length(shot.server_origin - c.client_origin))
			cd := c.client_dir / native_test_length(c.client_dir)
			sd := shot.server_dir / native_test_length(shot.server_dir)
			r.max_dir_error = max(r.max_dir_error, native_test_length(cd - sd))
		}
		if r.shots > 0 { r.mean_offset /= f32(r.shots); r.mean_vertical /= f32(r.shots) }
		return
	}

	track_pct :: proc(a, b: int) -> f64 { return b > 0 ? 100 * f64(a) / f64(b) : 0 }

	track_print :: proc(label: string, r: Track_Result) {
		fmt.printf("  %-30s %3d shots | server confirmed %5.1f%% | client saw %5.1f%% | old boxes, unrewound %5.1f%% | tested-vs-drawn target mean %.2f (vertical %.2f) max %.2f u | origin err %.3f u, dir err %.4f\n",
			label, r.shots, track_pct(r.server_hits, r.shots), track_pct(r.client_hits, r.shots), track_pct(r.legacy_hits, r.shots),
			r.mean_offset, r.mean_vertical, r.max_offset, r.max_origin_error, r.max_dir_error)
	}

	@(test)
	native_tracking_strafing_bot_repro :: proc(t: ^testing.T) {
		seeds := [2]u64{0x9e3779b97f4a7c15, 0x2545f4914f6cdd1d}
		for latency in ([3]f64{0.002, 0.03, 0.06}) {
			for stamp in ([2]bool{false, true}) {
				total: Track_Result
				for seed in seeds {
					r := track_run(t, latency, seed, 4, stamp)
					track_print(fmt.tprintf("%2.0f ms one-way, %s, seed %02x", latency * 1000, stamp ? "rewound" : "unstamped", seed & 0xff), r)
					// The aim reaches the server intact: same origin, same direction.
					testing.expectf(t, r.max_origin_error < 0.01 && r.max_dir_error < 0.001, "the server's shot ray is the client's (origin %.4f, direction %.5f)", r.max_origin_error, r.max_dir_error)
					total.shots += r.shots
					total.server_hits += r.server_hits
					total.client_hits += r.client_hits
					if stamp {
						// Rewound to the shooter's view, the server tests the
						// enemy where it was drawn.
						testing.expectf(t, r.mean_offset < 0.25, "%.0f ms: the rewound target sits where it was drawn (mean %.2f u off)", latency * 1000, r.mean_offset)
					}
				}
				testing.expectf(t, total.shots >= 60, "the magazine is emptied (%d shots)", total.shots)
				if stamp {
					testing.expectf(t, track_pct(total.server_hits, total.shots) >= 90, "%.0f ms: tracking the drawn chest is confirmed (%d of %d)", latency * 1000, total.server_hits, total.shots)
				}
			}
		}
	}
}
