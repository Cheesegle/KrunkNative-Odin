package main

import glfw "vendor:glfw"
import menuui "../menu"

// Game FPS limit (Krunker's Frame Cap, settings key updateRate).
//
// Only the render loop is paced. Live Krunker input is sampled into fixed
// 1/360 s commands and sent at 30 Hz from accumulated frame time
// (krunker_prediction.odin), so a lower frame rate builds more commands per
// frame rather than fewer per second. The raw input thread keeps reading the
// mouse and the audio device mixes on its own thread. The native server
// samples the latest held input on its own fixed tick, so its simulation rate
// does not change either; the client simply sends one input per rendered frame.
//
// Pacing targets a deadline schedule (client_idle_frame_deadline) measured from
// each frame's start, not "sleep 1/fps after the frame", so frame work and
// wakeup jitter do not drift the rate. The wait itself avoids
// glfw.WaitEventsTimeout: its coarse Windows timing is what made the old
// in-game idle cap hitch (commit 60e1dae). Instead a high-resolution waitable
// timer sleeps until FRAME_LIMIT_SPIN_MARGIN before the deadline and the rest
// yields on the clock.
//
// With V-Sync also on, SwapBuffers already blocks to the display refresh, so
// the lower of the two rates wins: a cap above the refresh never waits, and a
// cap below it waits on top of the swap. Caps that do not divide the refresh
// alternate between one and two refreshes per frame; turn V-Sync off for an
// even cap below the refresh.

// The last stretch before a deadline that yields instead of sleeping. A high
// resolution timer wakes within a few hundred microseconds; without one (before
// Windows 10 1803) the 1 ms timer period can overshoot by up to about 2 ms.
FRAME_LIMIT_SPIN_MARGIN :: 0.001
FRAME_LIMIT_SPIN_MARGIN_COARSE :: 0.002
// Sleeps shorter than this are not worth arming a timer for; yield instead.
FRAME_LIMIT_MIN_SLEEP :: 0.0001

// A clock the pacer waits on; tests substitute a fake one.
Frame_Clock :: struct {
	data: rawptr,
	now: proc(data: rawptr) -> f64,
	sleep: proc(data: rawptr, seconds: f64), // May overshoot; never far short.
	yield: proc(data: rawptr),
	spin_margin: f64,
}

// Waits until deadline: sleeps through all but the spin margin, then yields.
frame_limit_wait :: proc(deadline: f64, clock: Frame_Clock) {
	for {
		remaining := deadline - clock.now(clock.data)
		if remaining <= 0 { return }
		if remaining > clock.spin_margin + FRAME_LIMIT_MIN_SLEEP {
			clock.sleep(clock.data, remaining - clock.spin_margin)
		} else {
			clock.yield(clock.data)
		}
	}
}

// Seconds per frame while playing, or 0 when uncapped. The limit applies only
// while the cursor is captured for play, decided by capture alone like the
// menu limit (readiness flags clear during warmup while the player moves).
// While the window is unfocused or minimised nothing extra is capped.
client_game_frame_interval :: proc(client: ^Client) -> f64 {
	if !client.mouse_state.locked { return 0 }
	limit := menuui.game_fps_limit_validate(client.game_fps_limit)
	if limit == menuui.GAME_FPS_LIMIT_UNLIMITED { return 0 }
	if client.window != nil && (glfw.GetWindowAttrib(client.window, glfw.FOCUSED) == 0 || glfw.GetWindowAttrib(client.window, glfw.ICONIFIED) != 0) { return 0 }
	return 1 / f64(limit)
}

// Schedules this frame's deadline and waits for it on clock. An interval of 0
// resets the schedule so the next capped frame starts a fresh one.
client_frame_limit :: proc(deadline: ^f64, frame_start, interval: f64, clock: Frame_Clock) {
	if interval <= 0 { deadline^ = 0; return }
	deadline^ = client_idle_frame_deadline(deadline^, frame_start, interval)
	frame_limit_wait(deadline^, clock)
}

client_pace_game_frame :: proc(client: ^Client, frame_start, interval: f64) {
	client_frame_limit(&client.game_frame_deadline, frame_start, interval, client_frame_clock())
}

// The game clock: glfw.GetTime, which frame_start comes from.
client_frame_clock :: proc() -> Frame_Clock {
	return {
		now = proc(data: rawptr) -> f64 { return glfw.GetTime() },
		sleep = proc(data: rawptr, seconds: f64) { client_precise_sleep(seconds) },
		yield = proc(data: rawptr) { client_timer_yield() },
		spin_margin = client_precise_sleep_high_resolution() ? FRAME_LIMIT_SPIN_MARGIN : FRAME_LIMIT_SPIN_MARGIN_COARSE,
	}
}
