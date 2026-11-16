package main

import "core:math"
import "core:fmt"
import "core:time"
import shared "../shared"
import kproto "../krunker"
import glfw "vendor:glfw"

// Sample independently of rendering and sending; wire durations use whole ms.
KRUNKER_INPUT_RATE :: 360
KRUNKER_INPUT_SECONDS :: 1.0 / KRUNKER_INPUT_RATE
KRUNKER_SEND_SECONDS :: 1.0 / 30.0
// Also the replay bound: the full history replays in about 0.75 ms at
// -o:speed (krunker_ping_spike_frame_cost). Krunker replays its whole backlog.
KRUNKER_MAX_PREDICTED_INPUTS :: 2 * KRUNKER_INPUT_RATE

// A local correction in progress. The authoritative l state is applied at
// once; the replay of unacknowledged commands runs in
// krunker_client_finish_replay, so several l in one frame replay only once,
// from the newest acknowledgement. The predicted view state is saved before
// the first of them, and restored after the replay.
Krunker_Deferred_Replay :: struct {
	saved, pending, respawned: bool,
	player: ^shared.Player,
	ack: i32,
	server_position: shared.Vec3,
	aim, aim_time: f32,
	direction: shared.Vec2,
	position: shared.Vec3,
	weapon: ^shared.Weapon,
	reload_timer, swap_timer: f32,
	did_shoot: bool,
	burst_count: i32,
}

// Replay cost, kept for the [prediction] log line and the frame-cost tests.
Krunker_Replay_Profile :: struct { ns: i64, replays, commands, coalesced, snaps: int }
krunker_replay_profile: Krunker_Replay_Profile

Krunker_Render_Sample :: struct {
	position: shared.Vec3,
	aim: f32,
}

krunker_client_render_sample :: proc(client: ^Client) -> Krunker_Render_Sample {
	state := &client.krunker
	if !state.render_sample_ready { return {client.me.position, client.me.aim_val} }
	alpha := clamp(f32(state.input_elapsed / KRUNKER_INPUT_SECONDS), 0, 1)
	return {
		state.render_previous.position + (state.render_current.position - state.render_previous.position) * alpha,
		state.render_previous.aim + (state.render_current.aim - state.render_previous.aim) * alpha,
	}
}

krunker_client_reset_prediction :: proc(client: ^Client) {
	clear(&client.predicted_inputs)
	clear(&client.krunker.input_commands)
	client.krunker.input_elapsed = 0
	client.krunker.input_duration_remainder_ms = 0
	client.krunker.send_elapsed = 0
	client.krunker.input_swap = 0
	client.krunker.render_sample_ready = false
	client.krunker.acked_has_ramp_fix = false
	client.krunker.history_truncated = false
	// A deferred replay has nothing left to replay, and its player may be
	// about to be respawned or removed.
	client.krunker.replay = {}
}

// One display frame of live input. after_scroll is the frame's command
// without its Scroll press. Returns true when the frame built no command, so
// a Scroll press must wait for the next frame instead of being dropped.
krunker_client_predict_frame :: proc(client: ^Client, frame: ^shared.Input, after_scroll: shared.Input, now: f64 = -1) -> (scroll_pending: bool) {
	rest := after_scroll
	rest.seq, rest.delta, rest.x_dir, rest.y_dir, rest.scope = frame.seq, frame.delta, frame.x_dir, frame.y_dir, frame.scope
	commands := krunker_client_predict_input(client, frame, now, &rest)
	return commands == 0 && client.krunker.bootstrapped && client.krunker.spawned
}

// Store and predict exactly the commands that q will transmit. Rendering frames
// never acquire sequence numbers or enter the authoritative replay history.
// after_scroll, when set, replaces frame for every command after the first:
// a Scroll press is held for one command, as Krunker releases key 20000
// right after the input packet that read it. Returns the commands built.
krunker_client_predict_input :: proc(client: ^Client, frame: ^shared.Input, now: f64 = -1, after_scroll: ^shared.Input = nil) -> (commands: int) {
	state := &client.krunker
	shot_time := now < 0 ? glfw.GetTime() : now
	if frame.swap != 0 { state.input_swap = frame.swap }
	look := shared.Vec2{clamp(frame.x_dir, -math.PI/2, math.PI/2), frame.y_dir}
	if !state.bootstrapped || !state.spawned {
		client.me.direction = look
		return
	}
	if !state.render_sample_ready {
		state.render_previous = {client.me.position, client.me.aim_val}
		state.render_current = state.render_previous
		state.command_direction = client.me.direction
		state.render_sample_ready = true
	}
	// Bound catch-up after a paused/stalled window, as the browser bounds delta.
	state.input_elapsed += f64(clamp(frame.delta, 0, 0.1))
	state.send_elapsed += f64(clamp(frame.delta, 0, 0.1))
	// Frame delta originates as f32; tolerate its sub-microsecond rounding at
	// an exact command boundary without losing an entire input command.
	for state.input_elapsed + 1e-7 >= KRUNKER_INPUT_SECONDS {
		command := commands > 0 && after_scroll != nil ? after_scroll^ : frame^
		command.seq = state.input_sequence
		// Carry fractional milliseconds so 360 commands advance one second,
		// rather than 1.08 seconds from rounding every command to 3 ms.
		duration_ms := clamp(KRUNKER_INPUT_SECONDS * 1000 * f64(client.game.config.delta_mlt), 1, 33) + state.input_duration_remainder_ms
		rounded_ms := math.round(duration_ms)
		state.input_duration_remainder_ms = duration_ms - rounded_ms
		command.delta = f32(rounded_ms) / 1000
		command.x_dir = math.round(look.x * 1000) / 1000
		command.y_dir = math.round(shared.normalize_angle(look.y) * 1000) / 1000
		command.swap = state.input_swap
		state.input_swap = 0
		if client.krunker_world.move_lock { command.move_dir = -1; command.jump = false }
		command.krunker_shot_timed = false
		command.krunker_shot_time, command.krunker_shot_progress = 0, 0
		state.render_previous = {client.me.position, client.me.aim_val}
		client.me.direction = state.command_direction
		shot_seq := client.me.shot_seq
		shared.player_proc_input(client.me, &command, true, client.krunker_world.move_lock, true, true)
		if client.me.shot_seq != shot_seq { kproto.krunker_input_stamp_shot(&client.krunker_world, &command, shot_time) }
		command.predicted_ramp_fix, command.predicted_has_ramp_fix = client.me.ramp_fix, client.me.has_ramp_fix
		append(&state.input_commands, command)
		// Keep client-only impulse metadata produced by prediction for replay.
		append(&client.predicted_inputs, command)
		if excess := len(client.predicted_inputs) - KRUNKER_MAX_PREDICTED_INPUTS; excess > 0 {
			// The server will still process these, but replay no longer can.
			state.truncated_through, state.history_truncated = client.predicted_inputs[excess-1].seq, true
		}
		client_cap_predicted_inputs(client, KRUNKER_MAX_PREDICTED_INPUTS)
		state.command_direction = client.me.direction
		state.render_current = {client.me.position, client.me.aim_val}
		state.input_sequence += 1
		state.input_elapsed = max(0, state.input_elapsed - KRUNKER_INPUT_SECONDS)
		commands += 1
	}
	// Mouse look remains responsive on every display frame.
	client.me.direction = look
	return
}

krunker_client_apply_motion :: proc(client: ^Client, player: ^shared.Player, source: ^kproto.Krunker_World_Player, respawned: bool) {
	state := &client.krunker
	is_you := player.is_you
	if is_you && source.position_revision != state.local_position_revision {
		// lm is an explicit server reset, not an ACK to replay past inputs over.
		krunker_client_finish_replay(client)
		krunker_client_reset_prediction(client)
		state.input_reset = true
		state.local_position_revision = source.position_revision
		state.local_sync_revision = source.sync_revision
		player.position, player.velocity, player.direction = source.position, source.velocity, source.direction
		player.crouch_val, player.on_ground, player.on_ladder = source.crouch_val, source.on_ground, source.on_ladder
		shared.player_update_height(player)
		state.command_direction = source.direction
		return
	}
	if !is_you {
		// Remote poses are sampled from their timestamped buffer each display
		// frame. Metadata and shot packets must never snap them to the latest k.
		if respawned {
			player.position, player.direction = source.position, source.direction
			player.crouch_val, player.aim_val = source.crouch_val, source.aim_val
			player.on_ground = source.on_ground
			shared.player_update_height(player)
		}
		player.interpolate = false
		if player.loadout_index != source.weapon_slot { shared.player_swap_weapon(player, source.weapon_slot, true, true, true) }
		return
	}
	fresh_sync := source.has_ack && source.sync_revision != state.local_sync_revision
	// Roster/remote updates cannot replay an old local l snapshot.
	if is_you && !respawned && !fresh_sync { return }
	// Only a plain l can join a deferred replay; anything else replays first.
	deferred := state.batching && fresh_sync && !respawned
	if !deferred { krunker_client_finish_replay(client) }
	replay := &state.replay
	if !replay.saved {
		replay^ = {saved = true, player = player, aim = player.aim_val, aim_time = player.aim_time, direction = player.direction,
			position = player.position, weapon = player.weapon, reload_timer = player.reload_timer, swap_timer = player.swap_timer,
			did_shoot = player.did_shoot, burst_count = player.burst_count}
	} else {
		krunker_replay_profile.coalesced += 1
	}
	replay.respawned = replay.respawned || respawned
	player.position = source.position
	player.velocity = source.velocity
	if respawned { player.direction = source.direction }
	player.on_ground = source.on_ground
	player.on_ladder = source.on_ladder
	player.on_terrain = source.on_terrain
	player.did_jump = source.did_jump
	player.did_wall_jump = source.did_wall_jump
	player.wall_jump_count = max(source.wall_jump_count, 0)
	player.on_wall = u8(clamp(source.on_wall, 0, 255))
	player.slide_timer = source.slide_timer
	player.can_slide = source.can_slide
	player.can_slide_timer = source.can_slide_timer
	player.x_vel_cylinder, player.z_vel_cylinder = source.cylinder_velocity.x, source.cylinder_velocity.y
	player.crouch_val = clamp(source.crouch_val, 0, 1)
	player.aim_val = clamp(source.aim_val, 0, 1)
	// k/l transmit a loadout slot, not a weapon registry ID. Selecting the
	// wrong weapon also gives prediction the wrong movement multiplier.
	if player.loadout_index != source.weapon_slot { shared.player_swap_weapon(player, source.weapon_slot, true, true, true) }
	shared.player_update_height(player)
	replay.server_position = source.position
	if source.has_ack {
		state.local_sync_revision = source.sync_revision
		// l omits rampFix, the snap target that ramp contact leaves for the next
		// tick. Replaying with the newest prediction's value instead snaps a
		// player who has just left a ramp back onto it and grounds them, so a
		// held jump fires early and the next correction undoes it in Y. Use the
		// value predicted after the acknowledged command.
		for input in client.predicted_inputs {
			if input.seq > source.ack_seq { break }
			state.acked_ramp_fix, state.acked_has_ramp_fix = input.predicted_ramp_fix, input.predicted_has_ramp_fix
		}
		player.ramp_fix, player.has_ramp_fix = state.acked_ramp_fix, state.acked_has_ramp_fix
		client_discard_acked_inputs(client, source.ack_seq)
		state.input_sequence = max(state.input_sequence, source.ack_seq + 1)
		replay.pending, replay.ack = true, source.ack_seq
	}
	if !deferred { krunker_client_finish_replay(client) }
}

// Replays the commands the newest l has not acknowledged, then restores the
// predicted view state saved before the first l of the batch.
krunker_client_finish_replay :: proc(client: ^Client) {
	state := &client.krunker
	if !state.replay.saved { return }
	saved := state.replay
	state.replay = {}
	player := saved.player
	snapped := false
	replay_ns: i64
	if saved.pending {
		if state.history_truncated && saved.ack < state.truncated_through {
			// More than KRUNKER_MAX_PREDICTED_INPUTS went unacknowledged and the
			// oldest were dropped, so no replay can reproduce the server. Keep
			// the server state and the remaining commands; the next l replays them.
			snapped = true
			krunker_replay_profile.snaps += 1
		} else {
			state.history_truncated = false
			start := time.tick_now()
			for &input in client.predicted_inputs {
				shared.player_proc_input(player, &input, true, client.krunker_world.move_lock)
				input.predicted_ramp_fix, input.predicted_has_ramp_fix = player.ramp_fix, player.has_ramp_fix
			}
			replay_ns = i64(time.tick_since(start))
			krunker_replay_profile.ns += replay_ns
			krunker_replay_profile.replays += 1
			krunker_replay_profile.commands += len(client.predicted_inputs)
		}
	}
	if !saved.respawned {
		player.direction = saved.direction
		// View ADS follows current input, without restarting on a delayed ACK.
		if player.weapon == saved.weapon && !player.weapon.no_aim {
			player.aim_val, player.aim_time = saved.aim, saved.aim_time
		}
		if player.weapon == saved.weapon {
			player.reload_timer, player.swap_timer = saved.reload_timer, saved.swap_timer
			player.did_shoot, player.burst_count = saved.did_shoot, saved.burst_count
		}
	}
	if saved.respawned || !state.render_sample_ready {
		state.render_previous = {player.position, player.aim_val}
		state.render_current = state.render_previous
		state.command_direction = player.direction
		state.render_sample_ready = true
	} else {
		// Preserve interpolation within the current command after a correction.
		correction := player.position - saved.position
		state.render_previous.position += correction
		state.render_current.position += correction
		state.prediction_corrections += 1
		error := math.sqrt(correction.x*correction.x + correction.y*correction.y + correction.z*correction.z)
		if error >= 2 || snapped || state.prediction_corrections <= 3 || state.prediction_corrections % 30 == 0 {
			pending_ms: f32
			for input in client.predicted_inputs { pending_ms += input.delta * 1000 }
			kproto.network_log("prediction", fmt.tprintf("ack=%d correction=%.3f delta=%v server_position=%v pending_commands=%d pending_ms=%.0f unsent=%d next_seq=%d replay_ms=%.3f%s", saved.ack, error, correction, saved.server_position, len(client.predicted_inputs), pending_ms, len(state.input_commands), state.input_sequence, f64(replay_ns) / 1e6, snapped ? " snapped: history truncated after 2 s unacknowledged" : ""))
		}
	}
}
