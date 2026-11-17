package main

import "core:math"
import shared "../shared"

// Native server input (protocol 11): fixed-duration commands at the player's
// netRate, predicted locally and sent in batches. This mirrors the live
// Krunker path (krunker_prediction.odin): commands are sampled independently
// of the render frame, durations are whole ms with the fraction carried, and
// the camera blends between the previous and current predicted command.
//
// Every frame sends all commands built since the last send plus the last
// NATIVE_REDUNDANT_COMMANDS already-sent, still-unacked ones. TCP never loses
// them; the tail is there for the UDP transport and costs 14 bytes.
NATIVE_REDUNDANT_COMMANDS :: 2
NATIVE_MAX_PREDICTED_INPUTS :: 2 * 360
// Corrections up to this far (world units) are smoothed out over a few
// frames; larger ones (respawn, teleport) snap.
NATIVE_CORRECTION_SNAP :: 4.0
NATIVE_CORRECTION_HALF_LIFE :: 0.05 // seconds

Native_Command_State :: struct {
	next_seq:        i32,
	input_elapsed:   f64, // seconds since the last command was built
	remainder_ms:    f64, // fractional ms carried into the next duration
	sent_through:    i32, // newest seq already sent
	has_sent:        bool,
	// Presses seen since the last command: each reaches at least one command
	// even when a frame builds none (render rate above netRate).
	latch_shoot, latch_jump, latch_reload: bool,
	latch_swap:      u8,
	render_previous: shared.Vec3,
	render_current:  shared.Vec3,
	render_ready:    bool,
	command_direction: shared.Vec2,
	// Camera-only offset that hides a small server correction and decays.
	visual_offset:   shared.Vec3,
	corrections:     int,
	last_correction: shared.Vec3,
	last_correction_ack: i32,
}

native_client_net_rate :: proc(client: ^Client) -> i32 {
	return shared.net_rate_validate(client.net_rate)
}

native_client_reset_prediction :: proc(client: ^Client) {
	state := &client.net.commands
	clear(&client.predicted_inputs)
	state.input_elapsed, state.remainder_ms = 0, 0
	state.latch_shoot, state.latch_jump, state.latch_reload, state.latch_swap = false, false, false, 0
	state.render_ready = false
	state.visual_offset = {}
}

// One display frame of native input. after_scroll is the frame's command
// without its Scroll press, used for every command after the first. Returns
// true when the frame built no command, so a Scroll press waits for the next
// frame instead of being dropped (as on the live path).
native_client_predict_frame :: proc(client: ^Client, frame: ^shared.Input, after_scroll: shared.Input) -> (scroll_pending: bool) {
	state := &client.net.commands
	me := client.me
	step := 1 / f64(native_client_net_rate(client))
	state.latch_shoot ||= frame.shoot
	state.latch_jump ||= frame.jump
	state.latch_reload ||= frame.reload
	if frame.swap != 0 { state.latch_swap = frame.swap }
	look := shared.Vec2{clamp(frame.x_dir, -math.PI / 2, math.PI / 2), frame.y_dir}
	if !state.render_ready {
		state.render_previous, state.render_current = me.position, me.position
		state.command_direction = me.direction
		state.input_elapsed = 0
		state.render_ready = true
	}
	frame_delta := f64(clamp(frame.delta, 0, 0.1))
	state.visual_offset *= f32(math.pow(0.5, frame_delta / NATIVE_CORRECTION_HALF_LIFE))
	state.input_elapsed += frame_delta
	commands := 0
	// Frame deltas are f32; tolerate their rounding at an exact boundary.
	for state.input_elapsed + 1e-7 >= step {
		command := commands > 0 ? after_scroll : frame^
		command.seq = state.next_seq
		command.delta = shared.input_command_duration_ms(1 / step, client.game.config.delta_mlt, &state.remainder_ms) / 1000
		command.x_dir, command.y_dir = look.x, look.y
		shared.input_command_quantize(&command)
		if commands == 0 {
			command.shoot ||= state.latch_shoot
			command.jump ||= state.latch_jump
			command.reload ||= state.latch_reload
			command.swap = state.latch_swap
			state.latch_shoot, state.latch_jump, state.latch_reload, state.latch_swap = false, false, false, 0
		} else {
			command.swap = 0
		}
		command.view_stamped = false
		state.render_previous = me.position
		me.direction = state.command_direction
		shared.player_proc_input(me, &command, true, client.game.move_lock, true)
		command.predicted_ramp_fix, command.predicted_has_ramp_fix = me.ramp_fix, me.has_ramp_fix
		append(&client.predicted_inputs, command)
		client_cap_predicted_inputs(client, NATIVE_MAX_PREDICTED_INPUTS)
		state.command_direction = me.direction
		state.render_current = me.position
		state.next_seq += 1
		state.input_elapsed = max(0, state.input_elapsed - step)
		commands += 1
	}
	// Mouse look stays responsive on every display frame.
	me.direction = look
	return commands == 0
}

// The camera position: blended between the last two predicted commands, plus
// the decaying correction offset.
native_client_render_position :: proc(client: ^Client) -> shared.Vec3 {
	state := &client.net.commands
	if !state.render_ready || client.me == nil { return client.me != nil ? client.me.position : {} }
	alpha := f32(clamp(state.input_elapsed * f64(native_client_net_rate(client)), 0, 1))
	return state.render_previous + (state.render_current - state.render_previous) * alpha + state.visual_offset
}

// Sends every command not sent yet, with a short redundant tail of unacked
// ones, in batches of at most INPUT_BATCH_MAX_COMMANDS.
native_client_send_commands :: proc(client: ^Client) {
	state := &client.net.commands
	pending := client.predicted_inputs[:]
	first_new := 0
	if state.has_sent {
		for first_new < len(pending) && pending[first_new].seq <= state.sent_through { first_new += 1 }
	}
	if first_new >= len(pending) { return }
	start := max(0, first_new - NATIVE_REDUNDANT_COMMANDS)
	buf: [shared.INPUT_BATCH_MAX_PACKET]byte
	for start < len(pending) {
		end := min(len(pending), start + shared.INPUT_BATCH_MAX_COMMANDS)
		size := shared.packet_serialize_input_batch(buf[:], pending[start:end])
		if size == 0 || !net_client_send(&client.net, buf[:size]) {
			client.net.connected = false
			return
		}
		start = end
	}
	state.sent_through, state.has_sent = pending[len(pending) - 1].seq, true
}

// Applies a correction found by reconciliation to the camera: small ones are
// absorbed by the offset and decay, large ones snap.
native_client_apply_correction :: proc(client: ^Client, correction: shared.Vec3, ack: i32) {
	state := &client.net.commands
	error := math.sqrt(correction.x * correction.x + correction.y * correction.y + correction.z * correction.z)
	if error == 0 { return }
	state.corrections += 1
	state.last_correction, state.last_correction_ack = correction, ack
	// Keep blending inside the current command, as the live path does.
	state.render_previous += correction
	state.render_current += correction
	if error <= NATIVE_CORRECTION_SNAP {
		state.visual_offset -= correction
	} else {
		state.visual_offset = {}
		state.render_previous = state.render_current
	}
}
