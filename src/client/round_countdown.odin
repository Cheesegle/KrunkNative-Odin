package main

import "core:fmt"
import "core:math"
import shared "../shared"

// The big centre-screen countdown before play starts.
//
// Krunker (krunkbox game.deob.js line ~227286, the UPDATE_GAME_MESSAGE
// handler `gmsg`): when its third argument (a countdown number) is truthy it
// plays "cntd_" + N at volume 0.2 and calls
//   animateText(timerText, N, 300, 1.2, 700, 100, 0, cb, null, 15)
// on the 2D overlay canvas (line ~161941): the number starts at 300px
// GameFont, shrinks by 1.2px per ms down to 0.4x (120px, reached after
// 150 ms), lives 700 ms and fades over its last 100 ms. timerText is white,
// centred at left 50%, top 26% (textBaseline middle) and stroked #363636 at
// lineWidth 15 (the `shadow` argument). Canvas units are scaled by the UI
// scale, as everywhere on the overlay.
//
// Live lobbies show exactly what the server sends. Krodin also counts the
// last ROUND_COUNTDOWN_SECONDS of a timer down itself, in the same style:
//   - native server and Local Practice: the warmup (phase WARMUP,
//     match.phase_remaining) before the match goes live. That build of the
//     native server has no intermission; it goes straight from round to round.
//   - live lobbies, when the server has sent no number of its own for this
//     second: the end of the gmsg warmup, "match starting in" and
//     intermission timers.
ROUND_COUNTDOWN_SIZE    :: f32(300)  // animateText fontSize
ROUND_COUNTDOWN_MIN     :: f32(0.4)  // minScale factor
ROUND_COUNTDOWN_SHRINK  :: f32(1.2)  // px per ms
ROUND_COUNTDOWN_LIFE    :: f32(0.7)  // 0x2bc ms
ROUND_COUNTDOWN_FADE    :: f32(0.1)  // 0x64 ms
ROUND_COUNTDOWN_TOP     :: f32(0.26) // timerText top: 26%
ROUND_COUNTDOWN_STROKE  :: f32(15)   // shadow lineWidth
ROUND_COUNTDOWN_VOLUME  :: f32(0.2)
ROUND_COUNTDOWN_STROKE_COLOR :: shared.Vec4{0x36 / 255.0, 0x36 / 255.0, 0x36 / 255.0, 1}
// Krodin: how many final seconds of a timer it counts down itself.
ROUND_COUNTDOWN_SECONDS :: 3
// Krodin: a server number this recent suppresses the timer-derived one.
ROUND_COUNTDOWN_SERVER_HOLD :: 1.5

Round_Countdown :: struct {
	number: i32,
	started: f64,
	visible: bool,
	// Last consumed krunker_world.countdown_number_revision.
	live_revision: u64,
	server_at: f64,
	// The timer-derived number last shown, so each second fires once.
	derived: i32,
}

// The number the timers ask for now, 0 for none.
client_round_countdown_derived :: proc(client: ^Client, now: f64) -> i32 {
	remaining: f32 = -1
	if client.krunker.connected {
		world := &client.krunker_world
		#partial switch world.countdown {
		case .WARMUP, .STARTING, .INTERMISSION:
			remaining = world.countdown_remaining - f32(max(0, now - world.countdown_received_at))
		}
	} else if (client.net.connected || client.local_practice) && client.game.ready && client.game.match.phase == .WARMUP {
		remaining = client.game.match.phase_remaining
	}
	return round_countdown_number(remaining)
}

// ceil(remaining) during the last ROUND_COUNTDOWN_SECONDS, otherwise 0.
round_countdown_number :: proc(remaining: f32) -> i32 {
	if remaining <= 0 || remaining > ROUND_COUNTDOWN_SECONDS { return 0 }
	return i32(math.ceil(remaining))
}

round_countdown_show :: proc(client: ^Client, number: i32, now: f64) {
	cd := &client.round_countdown
	cd.number, cd.started, cd.visible = number, now, true
	// Krunker ships cntd_1 .. cntd_5.
	if number >= 1 && number <= 5 { audio_play_effect(client.audio, fmt.tprintf("cntd_%d", number), .UI, ROUND_COUNTDOWN_VOLUME) }
}

// Once per frame, after the session's packets and the local sim.
client_round_countdown_update :: proc(client: ^Client, now: f64) {
	cd := &client.round_countdown
	if client.krunker.connected {
		world := &client.krunker_world
		if world.countdown_number_revision < cd.live_revision { cd.live_revision = world.countdown_number_revision }
		if world.countdown_number_revision != cd.live_revision {
			cd.live_revision = world.countdown_number_revision
			cd.server_at = now
			cd.derived = world.countdown_number
			round_countdown_show(client, world.countdown_number, now)
		}
	}
	derived := client_round_countdown_derived(client, now)
	if derived != cd.derived {
		cd.derived = derived
		server_recent := client.krunker.connected && cd.server_at > 0 && now - cd.server_at < ROUND_COUNTDOWN_SERVER_HOLD
		if derived > 0 && !server_recent { round_countdown_show(client, derived, now) }
	}
	if cd.visible && f32(now - cd.started) >= ROUND_COUNTDOWN_LIFE { cd.visible = false }
}

// animateText's size and opacity t seconds into a number's life.
round_countdown_style :: proc(t: f32) -> (size, opacity: f32) {
	ms := max(t, 0) * 1000
	size = max(ROUND_COUNTDOWN_SIZE * ROUND_COUNTDOWN_MIN, ROUND_COUNTDOWN_SIZE - ROUND_COUNTDOWN_SHRINK * ms)
	life := ROUND_COUNTDOWN_LIFE - max(t, 0)
	opacity = life <= ROUND_COUNTDOWN_FADE ? clamp(life / ROUND_COUNTDOWN_FADE, 0, 1) : 1
	return
}

round_countdown_render :: proc(client: ^Client, now: f64) {
	cd := &client.round_countdown
	if !cd.visible { return }
	t := f32(now - cd.started)
	if t < 0 || t >= ROUND_COUNTDOWN_LIFE { return }
	ui := client.ui
	size, opacity := round_countdown_style(t)
	size *= ui.scale
	text := fmt.tprintf("%d", cd.number)
	width := ui_measure_text(ui, text, size)
	// textBaseline "middle": the digits centre on the anchor.
	x := ui.width * 0.5 - width * 0.5
	baseline := overlay_numeric_baseline(ui.height * ROUND_COUNTDOWN_TOP - size * 0.5, size, size)
	// strokeText at lineWidth 15, one unit right: half the line outside the glyph.
	radius := ROUND_COUNTDOWN_STROKE * 0.5 * ui.scale
	stroke := ROUND_COUNTDOWN_STROKE_COLOR
	stroke.w = opacity
	STEPS :: 16
	for i in 0..<STEPS {
		angle := f32(i) * 2 * math.PI / STEPS
		ui_fill_text(ui, stroke, text, x + ui.scale + math.cos(angle) * radius, baseline + math.sin(angle) * radius, size)
	}
	ui_fill_text(ui, {1, 1, 1, opacity}, text, x, baseline, size)
}
