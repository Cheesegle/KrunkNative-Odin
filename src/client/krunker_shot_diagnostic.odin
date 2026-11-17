package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import shared "../shared"
import kproto "../krunker"

// Developer builds only (the call is `when KRODIN_DEV`): one network-log line
// per predicted live shot, to check whether what this client showed matches
// what Krunker's server rewinds to. Krodin's own diagnostic; the browser has
// no equivalent. It contains timings, sids and positions, never tokens.
//
// The server (game.js fetchState) picks the newest stateHistory entry at or
// before inputSTime + startTime (its k send time, servTim) and lerps toward
// the entry before it by inputSTPrg, clamped to [0, 1.2] and kept from the
// previous shot when the new value is falsy. Those two entries are the
// newest two k poses in this client's buffer, so "rewound" below is the
// server's target pose as far as the client can know it; "shown" is where the
// target was drawn on the frame the trigger was pulled.

Krunker_Shot_Diagnostic :: struct {
	server_progress: f64, // inputSTPrg the server holds after this shot.
}

@(private="file")
krunker_shot_diagnostic_state: Krunker_Shot_Diagnostic

krunker_shot_diagnostic_line :: proc(client: ^Client, command: ^shared.Input, now: f64, diag: ^Krunker_Shot_Diagnostic) -> string {
	world := &client.krunker_world
	me := client.me
	if command.krunker_shot_progress != 0 { diag.server_progress = clamp(command.krunker_shot_progress, 0, 1.2) }
	eye := me.position + shared.Vec3{0, me.height - shared.GAME_CONSTANTS.camera_height, 0}
	pitch, yaw := f32(command.x_dir), f32(command.y_dir)
	aim := shared.Vec3{math.sin(yaw + math.PI) * math.cos(pitch), math.sin(pitch), math.cos(yaw + math.PI) * math.cos(pitch)}

	// The remote player nearest the crosshair, by angle to their body centre.
	best_angle := f32(math.PI)
	target: ^kproto.Krunker_World_Player
	shown: shared.Vec3
	for &source in world.players {
		if source.sid == world.local_sid || source.pose_count == 0 { continue }
		player := client_find_player(client, source.sid)
		if player == nil || !player.active { continue }
		centre := player.position + shared.Vec3{0, player.height * 0.5, 0}
		to := centre - eye
		if linalg.length2(to) < 1e-6 { continue }
		angle := math.acos(clamp(linalg.dot(linalg.normalize(to), aim), -1, 1))
		if angle < best_angle { best_angle, target, shown = angle, &source, player.position }
	}
	timing := fmt.tprintf("shot seq=%d serv=%.0f prg=%.2f server_prg=%.2f display_lag_ms=%.1f k_age_ms=%.1f k_span_ms=%.1f rate=%.0f ping=%d aim=(%.3f,%.3f)",
		command.seq, command.krunker_shot_time, command.krunker_shot_progress, diag.server_progress,
		1000 / f64(world.send_rate > 0 ? world.send_rate : 10), (now - world.sync_received_at) * 1000,
		(world.sync_received_at - world.previous_sync_received_at) * 1000, world.send_rate, world.ping, pitch, yaw)
	if target == nil { return fmt.tprintf("%s target=none", timing) }
	newest := target.poses[target.pose_count - 1]
	in_latest := abs(newest.time - world.sync_received_at) < 1e-9
	rewound := newest.position
	previous := "missing"
	if target.pose_count >= 2 {
		older := target.poses[target.pose_count - 2]
		rewound = newest.position + (older.position - newest.position) * f32(diag.server_progress)
		previous = "ok"
	}
	error := rewound - shown
	// Angle the server's pose sits from the shown one, seen from the eye.
	a, b := shown + {0, 5, 0} - eye, rewound + {0, 5, 0} - eye
	offset_mrad: f32
	if linalg.length2(a) > 1e-6 && linalg.length2(b) > 1e-6 {
		offset_mrad = math.acos(clamp(linalg.dot(linalg.normalize(a), linalg.normalize(b)), -1, 1)) * 1000
	}
	return fmt.tprintf("%s target=%d aim_off_mrad=%.1f shown=(%.2f,%.2f,%.2f) rewound=(%.2f,%.2f,%.2f) error=%.3f offset_mrad=%.2f in_latest_k=%v previous_k=%s",
		timing, target.sid, best_angle * 1000, shown.x, shown.y, shown.z, rewound.x, rewound.y, rewound.z,
		linalg.length(error), offset_mrad, in_latest, previous)
}

krunker_shot_diagnostic_log :: proc(client: ^Client, command: ^shared.Input, now: f64) {
	kproto.network_log("shot", krunker_shot_diagnostic_line(client, command, now, &krunker_shot_diagnostic_state))
}
