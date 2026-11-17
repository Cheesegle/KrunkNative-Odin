package main

import "core:math"
import shared "../shared"

// Spectator view filter (Krodin-only; Krunker has no equivalent).
//
// A followed player arrives as Krunker `k` records: ~10 Hz by default (`snf`),
// stamped when the frame is received (network jitter included), with yaw and
// pitch rounded to whole degrees. Krunker's browser, and Krodin's normal
// remote interpolation (krunker_client_interpolate_remotes), place a camera
// straight on the linear blend between the two snapshots around
// now - 1/sendRate. Each snapshot boundary is a velocity step, each late or
// bunched packet a jump in progress, and a slow turn becomes a 1-degree
// staircase. That is the stutter of first-person spectating.
//
// This filter keeps the follow camera at render rate:
//   1. Sample time: the server's k timestamp shifted onto the local clock by
//      the smallest observed receive delay (a running minimum that slowly
//      relaxes), so arrival jitter does not move samples in time. Without a
//      server stamp the receive time is used.
//   2. Playback delay: one send interval plus a jitter margin measured from
//      the samples, eased so it never jumps.
//   3. Position and angles: cubic Hermite through the samples, with tangents
//      from the neighbouring samples' non-uniform time steps, so velocity is
//      continuous across snapshots. A late snapshot is bridged by a short,
//      bounded extrapolation from the last segment's velocity.
//   4. Angles: a critically damped spring with velocity feed-forward toward
//      the Hermite target removes the integer-degree steps. The feed-forward
//      means a steady turn has no steady-state lag; only the quantisation
//      noise (and its own short time constant) is filtered.
// Strength 0 disables steps 3-4's smoothing (linear, no spring) and keeps the
// browser's fixed delay, which is what the jerk tests compare against.

SPECTATOR_SMOOTH_SAMPLES :: 32
// A gap longer than this (or a teleport) starts a new path.
SPECTATOR_SMOOTH_RESET_GAP :: 0.5
SPECTATOR_SMOOTH_TELEPORT :: f32(64)
// Most a late snapshot is bridged before the view holds still.
SPECTATOR_SMOOTH_MAX_EXTRAPOLATE :: 0.1
// The clock offset's running minimum relaxes this much per second, so a route
// change that adds delay is followed within a few seconds.
SPECTATOR_SMOOTH_OFFSET_RELAX :: 0.004
// Angle spring time constant at strength 1 (seconds).
SPECTATOR_SMOOTH_ANGLE_TAU :: f32(0.06)
// Position spring time constant at strength 1 (seconds).
SPECTATOR_SMOOTH_POSITION_TAU :: f32(0.035)

Spectator_Sample :: struct {
	time: f64, // On the local clock, de-jittered.
	position: shared.Vec3,
	pitch, yaw: f32, // Radians; yaw unwrapped against the previous sample.
	crouch, aim: f32,
	on_ground: bool,
}

Spectator_Smoother :: struct {
	samples: [SPECTATOR_SMOOTH_SAMPLES]Spectator_Sample,
	count: int,
	clock_offset: f64, // local receive time - server time, running minimum.
	has_offset: bool,
	last_offset_time: f64,
	interval: f64, // Smoothed time between samples.
	jitter: f64,   // Smoothed |interval error|.
	delay: f64,    // Current playback delay.
	// Spring state of the presented view, channels x, y, z, pitch, yaw
	// (yaw unwrapped).
	value: [5]f32,
	value_vel: [5]f32,
	target_vel: [5]f32, // The Hermite target's velocity this frame.
	last_target: [5]f32,
	feed_velocity: [5]f32,
	has_value: bool,
	last_present: f64,
	strength: f32, // 0..1
	resets: int,
}

Spectator_View :: struct {
	position: shared.Vec3,
	velocity: shared.Vec3,
	pitch, yaw: f32,
	crouch, aim: f32,
	on_ground: bool,
	valid: bool,
	extrapolating: bool,
}

spectator_smoother_reset :: proc(s: ^Spectator_Smoother) {
	strength := s.strength
	resets := s.resets + 1
	s^ = {}
	s.strength, s.resets = strength, resets
}

spectator_wrap_angle :: proc(a: f32) -> f32 {
	return a - 2*math.PI*math.floor((a + math.PI) / (2*math.PI))
}

// Feeds one received k record. `server_time` is the k packet's stamp in
// seconds (has_server false when absent); `rate` the k send rate.
spectator_smoother_push :: proc(s: ^Spectator_Smoother, received_at: f64, server_time: f64, has_server: bool, rate: f32, position: shared.Vec3, pitch, yaw: f32, crouch, aim: f32, on_ground: bool) {
	time := received_at
	if has_server {
		offset := received_at - server_time
		if !s.has_offset || abs(offset - s.clock_offset) > 1 {
			s.clock_offset, s.has_offset = offset, true
		} else {
			s.clock_offset += SPECTATOR_SMOOTH_OFFSET_RELAX * max(0, received_at - s.last_offset_time)
			s.clock_offset = min(s.clock_offset, offset)
		}
		s.last_offset_time = received_at
		time = server_time + s.clock_offset
	}
	nominal := 1 / f64(rate > 0 ? rate : 10)
	sample := Spectator_Sample{time = time, position = position, pitch = pitch, yaw = yaw, crouch = crouch, aim = aim, on_ground = on_ground}
	if s.count > 0 {
		last := s.samples[s.count-1]
		d := position - last.position
		if time - last.time > SPECTATOR_SMOOTH_RESET_GAP || d.x*d.x + d.y*d.y + d.z*d.z > SPECTATOR_SMOOTH_TELEPORT*SPECTATOR_SMOOTH_TELEPORT {
			spectator_smoother_reset(s)
		} else {
			sample.yaw = last.yaw + spectator_wrap_angle(yaw - last.yaw)
			if time <= last.time {
				// Bunched into the same instant: keep the newest values.
				sample.time = last.time
				s.samples[s.count-1] = sample
				return
			}
			step := time - last.time
			if s.interval <= 0 { s.interval = nominal }
			s.jitter += (abs(step - s.interval) - s.jitter) * 0.1
			s.interval += (step - s.interval) * 0.1
		}
	}
	if s.interval <= 0 { s.interval = nominal }
	if s.count == len(s.samples) {
		copy(s.samples[:], s.samples[1:])
		s.count -= 1
	}
	s.samples[s.count] = sample
	s.count += 1
}

// The playback delay the filter aims for at this strength.
spectator_smoother_target_delay :: proc(s: ^Spectator_Smoother, rate: f32) -> f64 {
	nominal := 1 / f64(rate > 0 ? rate : 10)
	if s.strength <= 0 { return nominal }
	// One interval to have the next sample, plus room for measured jitter
	// (de-jittered stamps keep it near zero), plus a small margin so the
	// Hermite segment after the current one is usually known.
	return max(nominal, s.interval) + min(2.5*s.jitter, 0.08) + 0.012*f64(s.strength)
}

@(private = "file")
hermite :: proc(p0, p1, m0, m1: f32, t, h: f32) -> f32 {
	t2 := t*t; t3 := t2*t
	return (2*t3 - 3*t2 + 1)*p0 + (t3 - 2*t2 + t)*h*m0 + (-2*t3 + 3*t2)*p1 + (t3 - t2)*h*m1
}

@(private = "file")
hermite_d :: proc(p0, p1, m0, m1: f32, t, h: f32) -> f32 {
	t2 := t*t
	return ((6*t2 - 6*t)*p0 + (3*t2 - 4*t + 1)*h*m0 + (-6*t2 + 6*t)*p1 + (3*t2 - 2*t)*h*m1) / h
}

// Non-uniform Catmull-Rom tangent of channel `c` at sample i.
@(private = "file")
tangent :: proc(s: ^Spectator_Smoother, i: int, c: int) -> f32 {
	channel :: proc(x: Spectator_Sample, c: int) -> f32 {
		switch c {
		case 0: return x.position.x
		case 1: return x.position.y
		case 2: return x.position.z
		case 3: return x.pitch
		case: return x.yaw
		}
	}
	lo, hi := max(i-1, 0), min(i+1, s.count-1)
	if hi == lo { return 0 }
	dt := f32(s.samples[hi].time - s.samples[lo].time)
	if dt <= 0 { return 0 }
	m := (channel(s.samples[hi], c) - channel(s.samples[lo], c)) / dt
	// Vertical motion is ballistic and stops dead on landing: never let the
	// tangent overshoot a sample the player is standing on.
	if c == 1 && (s.samples[i].on_ground) && (i == 0 || s.samples[i-1].on_ground != s.samples[i].on_ground) { return 0 }
	return m
}

// Samples the filtered view at local time `now` (render rate) and advances
// the angle spring by the time since the previous call.
spectator_smoother_sample :: proc(s: ^Spectator_Smoother, now: f64, rate: f32) -> Spectator_View {
	view: Spectator_View
	if s.count == 0 { return view }
	view.valid = true
	s.target_vel = {}
	target_delay := spectator_smoother_target_delay(s, rate)
	if s.delay <= 0 { s.delay = target_delay }
	frame := s.last_present > 0 ? clamp(now - s.last_present, 0, 0.1) : 0
	// Ease the delay (at most 5% of real time) so playback speed changes
	// stay invisible.
	s.delay += clamp(target_delay - s.delay, -0.05*frame, 0.05*frame)
	if s.strength <= 0 { s.delay = target_delay }
	t := now - s.delay
	smooth := s.strength > 0

	// Find the segment [i, i+1] containing t.
	i := 0
	for i+1 < s.count && s.samples[i+1].time <= t { i += 1 }
	a := s.samples[i]
	pitch, yaw: f32
	if i+1 >= s.count || t < a.time {
		// Before the first or after the last sample.
		view.position, pitch, yaw = a.position, a.pitch, a.yaw
		view.crouch, view.aim, view.on_ground = a.crouch, a.aim, a.on_ground
		if t > a.time && s.count >= 2 && smooth {
			prev := s.samples[s.count-2]
			span := f32(a.time - prev.time)
			ahead := f32(min(t - a.time, SPECTATOR_SMOOTH_MAX_EXTRAPOLATE*f64(s.strength)))
			if span > 0 && ahead > 0 {
				v := (a.position - prev.position) / span
				if a.on_ground { v.y = 0 }
				view.position += v * ahead
				view.velocity = v
				pitch += (a.pitch - prev.pitch) / span * ahead
				yaw += (a.yaw - prev.yaw) / span * ahead
				s.target_vel = {v.x, v.y, v.z, (a.pitch - prev.pitch) / span, (a.yaw - prev.yaw) / span}
				view.extrapolating = true
			}
		}
	} else {
		b := s.samples[i+1]
		h := f32(b.time - a.time)
		u := clamp(f32(t - a.time) / h, 0, 1)
		if smooth {
			p0 := [5]f32{a.position.x, a.position.y, a.position.z, a.pitch, a.yaw}
			p1 := [5]f32{b.position.x, b.position.y, b.position.z, b.pitch, b.yaw}
			out, vel: [5]f32
			for c in 0 ..< 5 {
				m0, m1 := tangent(s, i, c), tangent(s, i+1, c)
				out[c] = hermite(p0[c], p1[c], m0, m1, u, h)
				vel[c] = hermite_d(p0[c], p1[c], m0, m1, u, h)
			}
			view.position, pitch, yaw = {out[0], out[1], out[2]}, out[3], out[4]
			view.velocity = {vel[0], vel[1], vel[2]}
			// Feed-forward velocity for the spring.
			s.target_vel = vel
		} else {
			view.position = a.position + (b.position - a.position) * u
			view.velocity = (b.position - a.position) / h
			pitch = a.pitch + (b.pitch - a.pitch) * u
			yaw = a.yaw + (b.yaw - a.yaw) * u
		}
		view.crouch = a.crouch + (b.crouch - a.crouch) * u
		view.aim = a.aim + (b.aim - a.aim) * u
		view.on_ground = u < 0.5 ? a.on_ground : b.on_ground
	}
	pitch = clamp(pitch, -math.PI/2, math.PI/2)

	target := [5]f32{view.position.x, view.position.y, view.position.z, pitch, yaw}
	if !smooth || !s.has_value {
		s.value, s.value_vel, s.has_value = target, s.target_vel, true
		s.feed_velocity = s.target_vel
	} else if frame > 0 {
		// Keep the spring and the previous target on this target's yaw branch.
		s.value[4] = target[4] + spectator_wrap_angle(s.value[4] - target[4])
		s.last_target[4] = target[4] + spectator_wrap_angle(s.last_target[4] - target[4])
		dt := f32(frame)
		// Critically damped spring with velocity feed-forward. Within the frame
		// the reference moves from the previous target at the (low-passed)
		// target velocity, so the error e = x - g follows e'' = -w^2 e - 2w e'
		// exactly. The new target only enters through that error on the next
		// frame, so its whole-degree steps (and snapshot-boundary kinks) are
		// filtered, while steady motion is tracked with no steady-state lag.
		for k in 0 ..< 5 {
			tau := (k < 3 ? SPECTATOR_SMOOTH_POSITION_TAU : SPECTATOR_SMOOTH_ANGLE_TAU) * s.strength
			omega := 1 / max(tau, 1e-3)
			decay := math.exp(-omega*dt)
			s.feed_velocity[k] += (s.target_vel[k] - s.feed_velocity[k]) * (1 - decay)
			gv := s.feed_velocity[k]
			e0 := s.value[k] - s.last_target[k]
			ev0 := s.value_vel[k] - gv
			c2 := ev0 + omega*e0
			e := (e0 + c2*dt) * decay
			ev := (c2 - omega*(e0 + c2*dt)) * decay
			s.value[k] = s.last_target[k] + gv*dt + e
			s.value_vel[k] = gv + ev
		}
		// Never drift far from the path (a respawn inside the window, a
		// mis-estimated velocity): 4 units / 6 degrees at most.
		for k in 0 ..< 5 {
			limit: f32 = k < 3 ? 4 : 6*math.PI/180
			s.value[k] = clamp(s.value[k], target[k] - limit, target[k] + limit)
		}
	}
	s.last_target = target
	s.last_present = now
	view.position = {s.value[0], s.value[1], s.value[2]}
	view.pitch = clamp(s.value[3], -math.PI/2, math.PI/2)
	view.yaw = spectator_wrap_angle(s.value[4])
	return view
}
