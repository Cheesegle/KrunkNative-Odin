package main

import "core:math"
import shared "../shared"

// Remote players on a native server (protocol 12): a timestamped jitter
// buffer per player, rendered at view_time = server_time - interp_delay.
//
// Krunker draws remote players one send interval in the past, blended
// linearly between the two buffered snapshots around it (krunkbox
// game.min.js player update: `u=d.now-1e3/this.sendRateA`, `posBuffer`), with
// samples stamped by their arrival time. Krodin's native snapshots carry the
// server tick, so samples sit at their exact server time and arrival jitter
// only feeds the delay estimate:
//   1. Clock: local time - server time, the running minimum over snapshots
//      (the least-delayed one), relaxing slowly so a route change is followed.
//   2. Jitter: how late snapshots arrive beyond that minimum, an upper
//      envelope that decays.
//   3. Delay: 2 snapshot intervals + jitter by default, or the player's
//      Interpolation delay setting (like cl_interp). Changes are eased so the
//      view never jumps in time.
//   4. Pose: cubic Hermite through the samples (tangents from the neighbours,
//      Catmull-Rom with non-uniform steps) for position and pitch/yaw, linear
//      crouch and aim. Past the newest sample the path is extrapolated for at
//      most NATIVE_INTERP_MAX_EXTRAPOLATE, then held.
// The view time is also what commands report as view_tick/view_frac (the
// tick and fraction the player was looking at), for lag compensation.

NATIVE_INTERP_SAMPLES :: 64
NATIVE_INTERP_RESET_GAP :: 0.5 // server seconds without a sample: new path
NATIVE_INTERP_TELEPORT :: f32(64)
NATIVE_INTERP_MAX_EXTRAPOLATE :: 0.05
NATIVE_INTERP_OFFSET_RELAX :: 0.002 // s/s the clock offset minimum creeps up
NATIVE_INTERP_JITTER_DECAY :: 0.002 // s/s the jitter envelope decays (slowly, so the delay stays put)
NATIVE_INTERP_DELAY_SLEW :: 0.05 // the view clock runs at most 5% fast or slow
NATIVE_INTERP_MAX_DELAY :: 0.5

Native_Remote_Sample :: struct {
	time:       f64, // server seconds
	position:   shared.Vec3,
	pitch, yaw: f32, // yaw unwrapped against the previous sample
	crouch, aim: f32,
	on_ground:  bool,
}

Native_Remote_Track :: struct {
	samples: [NATIVE_INTERP_SAMPLES]Native_Remote_Sample,
	count:   int,
	resets:  int,
	server_on_ground: bool, // the newest snapshot's, for landing events
}

Native_View_Clock :: struct {
	tick_rate:  f64,
	interval:   f64, // seconds between snapshots
	offset:     f64, // local - server seconds, running minimum
	has_offset: bool,
	last_arrival: f64,
	jitter:     f64,
	delay:      f64, // effective delay: lag - offset
	lag:        f64, // local time - view time
	has_delay:  bool,
	view_time:  f64, // server seconds being rendered
	has_view:   bool,
	last_now:   f64,
	newest:     f64, // newest snapshot's server time
}

native_view_clock_reset :: proc(clock: ^Native_View_Clock) {
	clock^ = {}
}

// One snapshot for `server_time` arrived at local time `arrival`.
native_view_clock_observe :: proc(clock: ^Native_View_Clock, arrival, server_time, tick_rate, send_rate: f64) {
	if tick_rate > 0 { clock.tick_rate = tick_rate }
	if send_rate > 0 { clock.interval = 1 / send_rate }
	sample := arrival - server_time
	if !clock.has_offset || abs(sample - clock.offset) > 1 {
		clock.offset, clock.has_offset, clock.jitter = sample, true, 0
		clock.has_delay, clock.has_view = false, false
	} else {
		clock.offset += NATIVE_INTERP_OFFSET_RELAX * max(0, arrival - clock.last_arrival)
		clock.jitter = max(0, clock.jitter - NATIVE_INTERP_JITTER_DECAY * max(0, arrival - clock.last_arrival))
		if sample < clock.offset {
			clock.offset = sample
		} else {
			clock.jitter = max(clock.jitter, sample - clock.offset)
		}
	}
	clock.last_arrival = arrival
	clock.newest = max(clock.newest, server_time)
}

// The delay the view aims for: setting_ms when set, else 2 snapshot
// intervals plus the measured jitter.
native_view_clock_target_delay :: proc(clock: ^Native_View_Clock, setting_ms: i32) -> f64 {
	if setting_ms > 0 { return f64(setting_ms) / 1000 }
	interval := clock.interval > 0 ? clock.interval : 1.0 / 64
	return min(NATIVE_INTERP_MAX_DELAY, 2 * interval + clock.jitter)
}

// Advances the view time to local time `now`. The view runs `lag` (clock
// offset + delay) behind local time; lag eases toward its target, so a new
// offset minimum or a delay change speeds the view up or slows it down by at
// most NATIVE_INTERP_DELAY_SLEW instead of jumping.
native_view_clock_update :: proc(clock: ^Native_View_Clock, now: f64, setting_ms: i32) {
	if !clock.has_offset { return }
	target := clock.offset + native_view_clock_target_delay(clock, setting_ms)
	if !clock.has_delay {
		clock.lag, clock.has_delay = target, true
	} else {
		step := max(0, now - clock.last_now) * NATIVE_INTERP_DELAY_SLEW
		clock.lag += clamp(target - clock.lag, -step, step)
	}
	clock.delay = clock.lag - clock.offset
	view := now - clock.lag
	// Never run backwards: the offset and delay only move it by a few
	// percent of real time, which this absorbs.
	if clock.has_view && view < clock.view_time { view = clock.view_time }
	clock.view_time, clock.has_view = view, true
	clock.last_now = now
}

// The server tick and fraction toward the next tick the view shows.
native_view_clock_tick :: proc(clock: ^Native_View_Clock) -> (tick: u32, frac: f32, ok: bool) {
	if !clock.has_view || clock.tick_rate <= 0 || clock.view_time < 0 { return 0, 0, false }
	ticks := clock.view_time * clock.tick_rate
	whole := math.floor(ticks)
	frac = f32(ticks - whole)
	if frac >= 1 { frac = 0; whole += 1 }
	return u32(u64(whole) & 0xffffffff), frac, true
}

native_remote_reset :: proc(track: ^Native_Remote_Track) {
	track.count = 0
	track.resets += 1
}

native_remote_push :: proc(track: ^Native_Remote_Track, sample: Native_Remote_Sample) {
	sample := sample
	if track.count > 0 {
		last := track.samples[track.count - 1]
		d := sample.position - last.position
		if sample.time - last.time > NATIVE_INTERP_RESET_GAP || d.x * d.x + d.y * d.y + d.z * d.z > NATIVE_INTERP_TELEPORT * NATIVE_INTERP_TELEPORT {
			native_remote_reset(track)
		} else {
			sample.yaw = last.yaw + shared.normalize_angle(sample.yaw - last.yaw)
			if sample.time <= last.time {
				track.samples[track.count - 1] = sample
				return
			}
		}
	}
	if track.count == len(track.samples) {
		copy(track.samples[:], track.samples[1:])
		track.count -= 1
	}
	track.samples[track.count] = sample
	track.count += 1
}

@(private = "file")
tangent :: proc(samples: []Native_Remote_Sample, i: int) -> (position: shared.Vec3, pitch, yaw: f32) {
	lo, hi := max(0, i - 1), min(len(samples) - 1, i + 1)
	if hi == lo { return }
	a, b := samples[lo], samples[hi]
	dt := f32(b.time - a.time)
	if dt <= 0 { return }
	position = (b.position - a.position) / dt
	// A grounded sample next to an airborne one is a landing or take-off:
	// no vertical tangent there, so the path does not dip below the floor.
	if samples[i].on_ground && (!samples[lo].on_ground || !samples[hi].on_ground) { position.y = 0 }
	return position, (b.pitch - a.pitch) / dt, (b.yaw - a.yaw) / dt
}

// The pose at server time `t`. Drops samples the view has passed.
native_remote_sample :: proc(track: ^Native_Remote_Track, t: f64) -> (s: Native_Remote_Sample, ok, extrapolating: bool) {
	if track.count == 0 { return {}, false, false }
	// Keep one sample before the current segment for its tangent.
	for track.count >= 3 && track.samples[2].time <= t {
		copy(track.samples[:], track.samples[1:track.count])
		track.count -= 1
	}
	samples := track.samples[:track.count]
	first, last := samples[0], samples[len(samples) - 1]
	if t <= first.time || len(samples) == 1 { return t <= first.time ? first : last, true, t > last.time }
	if t >= last.time {
		ahead := f32(min(t - last.time, NATIVE_INTERP_MAX_EXTRAPOLATE))
		prev := samples[len(samples) - 2]
		dt := f32(last.time - prev.time)
		s = last
		if dt > 0 {
			s.position += (last.position - prev.position) / dt * ahead
			s.pitch = clamp(s.pitch + (last.pitch - prev.pitch) / dt * ahead, -math.PI / 2, math.PI / 2)
			s.yaw += (last.yaw - prev.yaw) / dt * ahead
		}
		return s, true, true
	}
	i := 0
	for i + 1 < len(samples) && samples[i + 1].time <= t { i += 1 }
	a, b := samples[i], samples[i + 1]
	h := f32(b.time - a.time)
	u := f32((t - a.time) / f64(h))
	ma, pa, ya := tangent(samples, i)
	mb, pb, yb := tangent(samples, i + 1)
	u2, u3 := u * u, u * u * u
	h00, h10, h01, h11 := 2 * u3 - 3 * u2 + 1, u3 - 2 * u2 + u, -2 * u3 + 3 * u2, u3 - u2
	s.time = t
	s.position = a.position * h00 + ma * (h10 * h) + b.position * h01 + mb * (h11 * h)
	s.pitch = clamp(a.pitch * h00 + pa * h10 * h + b.pitch * h01 + pb * h11 * h, -math.PI / 2, math.PI / 2)
	s.yaw = a.yaw * h00 + ya * h10 * h + b.yaw * h01 + yb * h11 * h
	s.crouch = a.crouch + (b.crouch - a.crouch) * u
	s.aim = a.aim + (b.aim - a.aim) * u
	s.on_ground = u < 0.5 ? a.on_ground : b.on_ground
	return s, true, false
}

native_remote_sample_from_state :: proc(state: ^shared.Packet_Player_State, server_time: f64) -> Native_Remote_Sample {
	return {time = server_time, position = state.position, pitch = state.x_dir, yaw = state.y_dir, crouch = state.crouch_val, aim = state.aim_val, on_ground = state.on_ground}
}

native_client_track :: proc(client: ^Client, uid: i32) -> ^Native_Remote_Track {
	nc := &client.net
	if track, ok := &nc.remotes[uid]; ok { return track }
	nc.remotes[uid] = {}
	return &nc.remotes[uid]
}

// Server time of the snapshot being applied; outside a snapshot (tests that
// apply states directly) one send interval after the newest sample.
native_client_sample_time :: proc(client: ^Client, track: ^Native_Remote_Track) -> f64 {
	nc := &client.net
	if nc.applying_snapshot { return nc.applying_time }
	rate := client.snapshot_send_rate > 0 ? f64(client.snapshot_send_rate) : 64
	return track.count > 0 ? track.samples[track.count - 1].time + 1 / rate : 0
}

// Places every interpolated remote player at the view time. Walking
// animation follows the rendered path (player_step on the ground), so the
// stride stays in phase with what is drawn.
native_client_interpolate_remotes :: proc(client: ^Client, delta: f32) {
	nc := &client.net
	for player in client.game.players {
		if player == client.me || !player.active || !player.interpolate { continue }
		track, found := &nc.remotes[player.uid]
		if !found || track.count == 0 { continue }
		t := nc.view.has_view ? nc.view.view_time : track.samples[track.count - 1].time
		s, ok, _ := native_remote_sample(track, t)
		if !ok { continue }
		previous := player.position
		player.last_position = previous
		player.position = s.position
		player.direction = {s.pitch, shared.normalize_angle(s.yaw)}
		player.crouch_val, player.aim_val = s.crouch, s.aim
		player.on_ground = s.on_ground
		shared.player_update_height(player)
		moved := player.position - previous
		if delta > 0 { player.velocity = moved / (delta * 1000) } // units per ms, like the sim
		distance := math.sqrt(moved.x * moved.x + moved.z * moved.z)
		if player.on_ground && distance < NATIVE_INTERP_TELEPORT { shared.player_step(player, distance) }
	}
}
