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
NATIVE_RENDER_HISTORY :: 4
// The view runs one command plus the half-ms duration rounding behind the
// newest prediction, so it always sits inside a predicted segment.
NATIVE_RENDER_LAG_EXTRA :: 0.0006

// Predicted position at the end of a command, at its simulated time.
Native_Render_Sample :: struct {
	time:     f64, // seconds of simulated command time
	position: shared.Vec3,
}

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
	// The view is placed along the predicted path by simulated time. Command
	// durations are whole ms (7, 7, 7, 6 ms at 144 Hz), so blending by command
	// count instead would play the 6 ms ones 1/7 slower: visible as stutter.
	render_clock:    f64, // real seconds since prediction started
	render_sim_time: f64, // simulated seconds, the sum of command durations
	render_history:  [NATIVE_RENDER_HISTORY]Native_Render_Sample,
	render_count:    int,
	render_ready:    bool,
	command_direction: shared.Vec2,
	// Camera-only offset that hides a small server correction and decays.
	visual_offset:   shared.Vec3,
	corrections:     int,
	last_correction: shared.Vec3,
	last_correction_ack: i32,
	// Ammo predicted after the newest acknowledged command (set by reconcile).
	acked_slot:      i32,
	acked_ammo:      u32,
	has_acked_ammo:  bool,
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
	state.has_acked_ammo = false
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
		state.command_direction = me.direction
		state.input_elapsed = 0
		state.render_clock, state.render_sim_time = 0, 0
		state.render_history[0], state.render_count = {0, me.position}, 1
		state.render_ready = true
	}
	frame_delta := f64(clamp(frame.delta, 0, 0.1))
	state.visual_offset *= f32(math.pow(0.5, frame_delta / NATIVE_CORRECTION_HALF_LIFE))
	state.input_elapsed += frame_delta
	state.render_clock += frame_delta
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
		me.direction = state.command_direction
		// Predict combat too, as the live path does: reload, swap and fire
		// timers, ammo and the shot's presentation run locally at once. Hits
		// stay the server's; the boost a shot gives is recorded for replay.
		shared.player_proc_input(me, &command, true, client.game.move_lock, true, true)
		command.predicted_slot, command.predicted_ammo = me.loadout_index, me.ammo[me.loadout_index]
		command.predicted_ramp_fix, command.predicted_has_ramp_fix = me.ramp_fix, me.has_ramp_fix
		append(&client.predicted_inputs, command)
		client_cap_predicted_inputs(client, NATIVE_MAX_PREDICTED_INPUTS)
		state.command_direction = me.direction
		state.render_sim_time += f64(command.delta)
		native_render_push(state, {state.render_sim_time, me.position})
		state.next_seq += 1
		state.input_elapsed = max(0, state.input_elapsed - step)
		commands += 1
	}
	// Mouse look stays responsive on every display frame.
	me.direction = look
	return commands == 0
}

native_render_push :: proc(state: ^Native_Command_State, sample: Native_Render_Sample) {
	if state.render_count == NATIVE_RENDER_HISTORY {
		copy(state.render_history[:], state.render_history[1:])
		state.render_count -= 1
	}
	state.render_history[state.render_count] = sample
	state.render_count += 1
}

// The camera (and first-person model) position: the predicted path one
// command behind real time, interpolated by simulated time, plus the decaying
// correction offset.
native_client_render_position :: proc(client: ^Client) -> shared.Vec3 {
	state := &client.net.commands
	if !state.render_ready || client.me == nil || state.render_count == 0 { return client.me != nil ? client.me.position : {} }
	t := state.render_clock - 1 / f64(native_client_net_rate(client)) - NATIVE_RENDER_LAG_EXTRA
	history := state.render_history[:state.render_count]
	position := history[0].position
	if t >= history[len(history) - 1].time {
		position = history[len(history) - 1].position
	} else {
		for i in 1 ..< len(history) {
			a, b := history[i - 1], history[i]
			if t <= b.time {
				alpha := b.time > a.time ? f32(clamp((t - a.time) / (b.time - a.time), 0, 1)) : 1
				position = a.position + (b.position - a.position) * alpha
				break
			}
		}
	}
	return position + state.visual_offset
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

// True while the local player predicts on a native server: its shots, ammo,
// weapon and combat timers are then the client's until the server acks them.
native_client_predicts :: proc(client: ^Client, player: ^shared.Player) -> bool {
	return client.net.connected && player != nil && player == client.me && player.is_you
}

// The ammo to show after a snapshot: the predicted count, moved by however
// far the server's count differs from the one predicted for the acknowledged
// command. Agreeing prediction leaves it alone, so neither unacked shots nor
// a reload that finished in an unacked command are undone. The difference is
// also carried into the unacked commands' records, so the next ack does not
// apply it a second time.
native_client_reconcile_ammo :: proc(client: ^Client, player: ^shared.Player, slot: i32, server_ammo, capacity: u32) -> u32 {
	state := &client.net.commands
	current := player.ammo[slot]
	// Nothing comparable acknowledged yet: the prediction is the best count.
	if !state.has_acked_ammo || state.acked_slot != slot || player.loadout_index != slot {
		return current
	}
	difference := i64(server_ammo) - i64(state.acked_ammo)
	state.acked_ammo = server_ammo
	if difference == 0 { return current }
	for &input in client.predicted_inputs {
		if input.predicted_slot == slot {
			input.predicted_ammo = u32(clamp(i64(input.predicted_ammo) + difference, 0, i64(capacity)))
		}
	}
	return u32(clamp(i64(current) + difference, 0, i64(capacity)))
}

// A weapon swap in an unacknowledged command: the snapshot's weapon is stale.
native_client_unacked_swap :: proc(client: ^Client) -> bool {
	for input in client.predicted_inputs { if input.swap != 0 { return true } }
	return false
}

// Applies a correction found by reconciliation to the camera: small ones are
// absorbed by the offset and decay, large ones snap.
native_client_apply_correction :: proc(client: ^Client, correction: shared.Vec3, ack: i32) {
	state := &client.net.commands
	error := math.sqrt(correction.x * correction.x + correction.y * correction.y + correction.z * correction.z)
	if error == 0 { return }
	state.corrections += 1
	state.last_correction, state.last_correction_ack = correction, ack
	// Keep blending along the path, as the live path shifts its samples.
	for &sample in state.render_history[:state.render_count] { sample.position += correction }
	if error <= NATIVE_CORRECTION_SNAP {
		state.visual_offset -= correction
	} else {
		state.visual_offset = {}
		newest := state.render_history[max(0, state.render_count - 1)].position
		for &sample in state.render_history[:state.render_count] { sample.position = newest }
	}
}
