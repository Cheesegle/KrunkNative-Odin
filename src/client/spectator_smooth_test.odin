package main

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:testing"
import shared "../shared"
import kproto "../krunker"

when ODIN_TEST {
	// Jerk of the first-person spectate view on recorded-shaped synthetic k
	// streams: a player strafing, jumping and flicking, sampled by the server
	// at `rate` Hz, yaw/pitch rounded to whole degrees as k sends them, and
	// received with network jitter at the next render frame.

	Spectate_Jerk :: struct {
		angle_jerk_rms, angle_accel_rms, angle_accel_max: f64, // deg/s^3, deg/s^2
		position_jerk_rms, position_accel_max: f64,            // units/s^3, units/s^2
		angle_error_rms: f64,                                  // deg vs the true path at the same delay
		delay: f64,                                            // seconds behind the true path
	}

	@(private = "file")
	truth :: proc(t: f64) -> (position: shared.Vec3, pitch, yaw: f32) {
		// Strafe left/right while running forward, jump every 1.3 s, sweep
		// the view with a slow pan plus flicks, look up and down.
		x := 45*math.sin(0.9*t) + 30*t
		z := 20*math.sin(0.37*t)
		phase := math.mod(t, 1.3)
		y := phase < 0.6 ? 60*phase - 100*phase*phase : 0
		position = {f32(x), f32(max(y, 0)), f32(z)}
		yaw_deg := 25*t + 35*math.sin(1.7*t) + 8*math.sin(5.3*t)
		pitch_deg := 12*math.sin(0.6*t) - 4
		return position, f32(pitch_deg*math.PI/180), f32(yaw_deg*math.PI/180)
	}

	Spectate_Packet :: struct { arrive, server: f64, position: shared.Vec3, pitch_deg, yaw_deg: f32, on_ground: bool }

	@(private = "file")
	make_stream :: proc(rate: f64, jitter: f64, seconds: f64, seed: u64) -> [dynamic]Spectate_Packet {
		r := rand.create(seed)
		gen := rand.default_random_generator(&r)
		out: [dynamic]Spectate_Packet
		for n := 0; f64(n)/rate < seconds; n += 1 {
			server := f64(n)/rate
			p, pitch, yaw := truth(server)
			// k rounds yaw/pitch to whole degrees (Math.round(dir*180/PI)).
			yaw_deg := f32(math.round(f64(yaw)*180/math.PI))
			pitch_deg := f32(math.round(f64(pitch)*180/math.PI))
			// Positions keep a little precision; k sends them as floats.
			p = {f32(math.round(f64(p.x)*100)/100), f32(math.round(f64(p.y)*100)/100), f32(math.round(f64(p.z)*100)/100)}
			delay := 0.04 + rand.float64(gen)*jitter
			// Occasionally a packet is held and arrives with the next one.
			if rand.float64(gen) < 0.05 { delay += 1/rate }
			append(&out, Spectate_Packet{server + delay, server, p, pitch_deg, yaw_deg, p.y <= 0})
		}
		// Arrival order follows the TCP stream: never earlier than the previous.
		for i in 1 ..< len(out) { out[i].arrive = max(out[i].arrive, out[i-1].arrive) }
		return out
	}

	@(private = "file")
	unwrap :: proc(previous, value: f64) -> f64 {
		return previous + (value - previous) - 360*math.round((value - previous)/360)
	}

	// mode 0: Krodin's current remote interpolation (krunker_world_buffer_pose
	// + krunker_display_time + linear blend, camera taken directly), which is
	// the browser's scheme. mode 1: the spectator filter at `strength`.
	spectate_measure :: proc(rate, jitter, fps: f64, strength: f32, mode: int, seed: u64 = 7) -> Spectate_Jerk {
		packets := make_stream(rate, jitter, 20, seed)
		defer delete(packets)
		source: kproto.Krunker_World_Player
		smoother := Spectator_Smoother{strength = strength}
		dt := 1/fps
		next := 0
		yaws, pitches: [dynamic]f64
		positions: [dynamic]shared.Vec3
		times: [dynamic]f64
		defer { delete(yaws); delete(pitches); delete(positions); delete(times) }
		previous_yaw: f64
		for frame := 0; f64(frame)*dt < 20; frame += 1 {
			now := 1 + f64(frame)*dt
			for next < len(packets) && 1 + packets[next].arrive <= now {
				p := packets[next]
				pitch := p.pitch_deg*math.PI/180
				yaw := p.yaw_deg*math.PI/180
				if mode == 0 {
					source.position, source.direction = p.position, {pitch, yaw}
					source.crouch_val, source.aim_val, source.on_ground, source.step_val = 0, 0, p.on_ground, 0
					kproto.krunker_world_buffer_pose(&source, now)
				} else {
					spectator_smoother_push(&smoother, now, 1 + p.server, true, f32(rate), p.position, pitch, yaw, 0, 0, p.on_ground)
				}
				next += 1
			}
			position: shared.Vec3
			pitch, yaw: f32
			if mode == 0 {
				if source.pose_count == 0 { continue }
				display := kproto.krunker_display_time(now, f32(rate))
				for source.pose_count >= 2 && source.poses[1].time <= display {
					copy(source.poses[:], source.poses[1:source.pose_count])
					source.pose_count -= 1
				}
				a, b := source.poses[0], source.poses[0]
				if source.pose_count > 1 { b = source.poses[1] }
				alpha: f32
				if b.time > a.time { alpha = clamp(f32((display-a.time)/(b.time-a.time)), 0, 1) }
				position = a.position + (b.position-a.position)*alpha
				pitch = a.direction.x + (b.direction.x-a.direction.x)*alpha
				yaw = a.direction.y + spectator_wrap_angle(b.direction.y-a.direction.y)*alpha
			} else {
				view := spectator_smoother_sample(&smoother, now, f32(rate))
				if !view.valid { continue }
				position, pitch, yaw = view.position, view.pitch, view.yaw
			}
			y := f64(yaw)*180/math.PI
			if len(yaws) > 0 { y = unwrap(previous_yaw, y) }
			previous_yaw = y
			append(&yaws, y); append(&pitches, f64(pitch)*180/math.PI)
			append(&positions, position); append(&times, now - 1)
		}
		result: Spectate_Jerk
		// Skip the first second (buffers filling) and measure the rest.
		start := int(fps)
		n := len(yaws)
		sum_j, sum_a, sum_pj, count := 0.0, 0.0, 0.0, 0.0
		for i in start+3 ..< n {
			for series in ([2][]f64{yaws[:], pitches[:]}) {
				a0 := (series[i-1] - 2*series[i-2] + series[i-3]) / (dt*dt)
				a1 := (series[i] - 2*series[i-1] + series[i-2]) / (dt*dt)
				j := (a1 - a0) / dt
				sum_j += j*j
				sum_a += a1*a1
				result.angle_accel_max = max(result.angle_accel_max, abs(a1))
			}
			for c in 0 ..< 3 {
				p := [4]f64{f64(positions[i-3][c]), f64(positions[i-2][c]), f64(positions[i-1][c]), f64(positions[i][c])}
				a0 := (p[2] - 2*p[1] + p[0]) / (dt*dt)
				a1 := (p[3] - 2*p[2] + p[1]) / (dt*dt)
				j := (a1 - a0) / dt
				sum_pj += j*j
				result.position_accel_max = max(result.position_accel_max, abs(a1))
			}
			count += 1
		}
		result.angle_jerk_rms = math.sqrt(sum_j / (2*count))
		result.angle_accel_rms = math.sqrt(sum_a / (2*count))
		result.position_jerk_rms = math.sqrt(sum_pj / (3*count))
		// Effective delay: the lag that best matches the true yaw path, then
		// the RMS error at that lag (accuracy, independent of latency).
		best_error: f64 = 1e9
		for lag_ms := 0; lag_ms <= 400; lag_ms += 2 {
			lag := f64(lag_ms)/1000
			sum, k := 0.0, 0.0
			for i in start ..< n {
				_, pitch_t, yaw_t := truth(times[i] - lag)
				ty := f64(yaw_t)*180/math.PI
				d := yaws[i] - ty
				d -= 360*math.round(d/360)
				dp := pitches[i] - f64(pitch_t)*180/math.PI
				sum += d*d + dp*dp; k += 2
			}
			if e := math.sqrt(sum/k); e < best_error { best_error, result.delay = e, lag }
		}
		result.angle_error_rms = best_error
		return result
	}

	@(test)
	spectate_jerk_is_lower_than_the_linear_view :: proc(t: ^testing.T) {
		Case :: struct { rate, jitter, fps: f64 }
		cases := [?]Case{{10, 0.03, 144}, {10, 0.06, 240}, {10, 0.01, 60}, {20, 0.03, 144}, {30, 0.02, 144}, {5, 0.03, 144}}
		fmt.println("[spectate-jerk] rate | jitter | render fps | mode | ang_jerk_rms deg/s3 | ang_acc_rms deg/s2 | ang_acc_max | pos_jerk_rms u/s3 | pos_acc_max | ang_err_rms deg | delay_ms")
		for c in cases {
			before := spectate_measure(c.rate, c.jitter, c.fps, 0, 0)
			half := spectate_measure(c.rate, c.jitter, c.fps, 0.5, 1)
			after := half
			strong := spectate_measure(c.rate, c.jitter, c.fps, 1, 1)
			rows := [3]Spectate_Jerk{before, after, strong}
			names := [3]string{"linear (browser/Krodin today)", "filter strength 0.5 (default)", "filter strength 1.0"}
			for r, i in rows {
				fmt.printf("[spectate-jerk] %v Hz | %v ms jitter | %v fps | %s | %v | %v | %v | %v | %v | %.3f | %v\n",
					int(c.rate), int(c.jitter*1000), int(c.fps), names[i], i64(r.angle_jerk_rms), i64(r.angle_accel_rms), i64(r.angle_accel_max), i64(r.position_jerk_rms), i64(r.position_accel_max), r.angle_error_rms, int(r.delay*1000+0.5))
			}
			testing.expectf(t, after.angle_jerk_rms < before.angle_jerk_rms*0.25, "%v Hz: angular jerk %v vs linear %v", c.rate, after.angle_jerk_rms, before.angle_jerk_rms)
			testing.expectf(t, after.position_jerk_rms < before.position_jerk_rms*0.5, "%v Hz: positional jerk %v vs linear %v", c.rate, after.position_jerk_rms, before.position_jerk_rms)
			// Smoothing must not cost accuracy or add more than a few frames of lag.
			testing.expectf(t, after.angle_error_rms <= before.angle_error_rms + 0.25, "%v Hz: angle error %v vs %v", c.rate, after.angle_error_rms, before.angle_error_rms)
			testing.expectf(t, after.delay <= before.delay + 0.05, "%v Hz: delay %v vs %v", c.rate, after.delay, before.delay)
		}
	}

	@(test)
	spectate_filter_tracks_a_steady_turn_without_lag :: proc(t: ^testing.T) {
		// A constant 90 deg/s turn sampled at 10 Hz with exact stamps: after
		// settling, the spring adds no lag beyond the playback delay.
		s := Spectator_Smoother{strength = 1}
		for n in 0 ..< 40 {
			time := f64(n) * 0.1
			yaw := f32(math.round(90*time)) * math.PI/180
			spectator_smoother_push(&s, time + 0.05, time, true, 10, {}, 0, yaw, 0, 0, true)
		}
		now := 3.9 + 0.05
		view: Spectator_View
		for frame in 0 ..< 30 { view = spectator_smoother_sample(&s, now - 0.5 + f64(frame)/60, 10) }
		played := now - 0.5 + 29.0/60 - s.delay - 0.05
		want := f32(90*played) * math.PI/180
		testing.expectf(t, abs(spectator_wrap_angle(view.yaw - want)) < 1.0*math.PI/180, "steady turn tracked: %v vs %v deg", view.yaw*180/math.PI, want*180/math.PI)
	}

	@(test)
	spectate_filter_resets_on_teleport :: proc(t: ^testing.T) {
		s := Spectator_Smoother{strength = 1}
		spectator_smoother_push(&s, 1.0, 0.0, true, 10, {0, 0, 0}, 0, 0, 0, 0, true)
		spectator_smoother_push(&s, 1.1, 0.1, true, 10, {1, 0, 0}, 0, 0, 0, 0, true)
		spectator_smoother_push(&s, 1.2, 0.2, true, 10, {500, 0, 0}, 0, 0, 0, 0, true)
		testing.expect(t, s.count == 1 && s.resets == 1, "a respawn or target switch starts a new path")
		view := spectator_smoother_sample(&s, 1.3, 10)
		testing.expect(t, view.valid && view.position.x == 500, "no sweep across the map")
	}
}
