package shared

import "core:encoding/endian"
import "core:math"

// Native input commands (protocol 11), modelled on Krunker's input stream:
// the client samples one command every 1000/netRate ms, each with its own
// duration in whole milliseconds, and the server runs the movement step once
// per command with that duration (krunkbox game.min.js: `_7=[St.getISN(),
// Math.round(A7*Q.config.deltaMlt),...]`, player `Bum0tq` clamps the duration
// to [deltaMlt, Math.round(1000/30)] ms). The ack in each player snapshot is
// the last command the server simulated (Krunker's SYNC_PLAYER `l`, index 0 =
// inputSN, set inside Bum0tq).
//
// PLAYER_INPUT payload (little endian):
//   u8  count               1..INPUT_BATCH_MAX_COMMANDS
//   i32 first_seq           commands carry first_seq, first_seq+1, ...
//   count x command:
//     u8  duration_ms       the server clamps it to [1, 33] like Krunker
//     i16 pitch_milli       round(x_dir * 1000)  (Krunker sends yDr*1000)
//     i16 yaw_milli         round(normalize(y_dir) * 1000)
//     i8  move_dir          -1 (none) or 0..7
//     u8  buttons           shoot 1, scope 2, jump 4, crouch 8, reload 16,
//                           swap << 5 (2 bits), INPUT_BUTTON_STAMP 128
//     [u32 view_tick, u16 view_frac]   only with INPUT_BUTTON_STAMP
//
// The stamp is the server tick (and 0..65535 progress to the next one) the
// client was looking at; lag compensation (phase 5) fills it in. Nothing sets
// it yet, but the server already decodes it so the wire format can stay.
INPUT_BATCH_MAX_COMMANDS :: 64
INPUT_COMMAND_MIN_MS :: 1
INPUT_COMMAND_MAX_MS :: 33 // Krunker: Math.round(1000 / 30)
INPUT_ANGLE_SCALE :: 1000
INPUT_COMMAND_WIRE_SIZE :: 7
INPUT_STAMP_WIRE_SIZE :: 6
INPUT_BATCH_HEADER_SIZE :: 5
INPUT_BATCH_MAX_PAYLOAD :: INPUT_BATCH_HEADER_SIZE + INPUT_BATCH_MAX_COMMANDS * (INPUT_COMMAND_WIRE_SIZE + INPUT_STAMP_WIRE_SIZE)
INPUT_BATCH_MAX_PACKET :: PACKET_HEADER_SIZE + INPUT_BATCH_MAX_PAYLOAD

INPUT_BUTTON_SHOOT :: 1
INPUT_BUTTON_SCOPE :: 2
INPUT_BUTTON_JUMP :: 4
INPUT_BUTTON_CROUCH :: 8
INPUT_BUTTON_RELOAD :: 16
INPUT_BUTTON_SWAP_SHIFT :: 5
INPUT_BUTTON_STAMP :: 128

// Krunker's netRate setting (game.deob.js `'netRate': {`): options 30, 60,
// 120, 144, 240 and 360 commands per second, default index 3 (144) on desktop.
NET_RATES := [6]i32{30, 60, 120, 144, 240, 360}
NET_RATE_DEFAULT :: 144

// Unknown rates fall back to Krunker's desktop default.
net_rate_validate :: proc(rate: i32) -> i32 {
	for value in NET_RATES { if value == rate { return rate } }
	return NET_RATE_DEFAULT
}

// Angles travel as whole milliradians. Both ends use this to get the exact
// same f32, so prediction and the server steer with identical values.
input_angle_quantize :: proc(angle: f32) -> f32 {
	return f32(math.round(angle * INPUT_ANGLE_SCALE)) / INPUT_ANGLE_SCALE
}

// The next fixed command's duration in whole ms. The fraction is carried, so
// 360 commands still add up to one second instead of 360 x 3 ms = 1.08 s.
input_command_duration_ms :: proc(rate: f64, delta_mlt: f32, remainder_ms: ^f64) -> f32 {
	duration := clamp(1000 / rate * f64(delta_mlt), INPUT_COMMAND_MIN_MS, INPUT_COMMAND_MAX_MS) + remainder_ms^
	rounded := math.round(duration)
	remainder_ms^ = duration - rounded
	return f32(rounded)
}

// A command as it will reach the server: whole-ms duration and quantized
// angles. Clients predict with exactly this.
input_command_quantize :: proc(command: ^Input) {
	command.x_dir = input_angle_quantize(clamp(command.x_dir, -math.PI / 2, math.PI / 2))
	command.y_dir = input_angle_quantize(normalize_angle(command.y_dir))
	command.delta = f32(math.round(command.delta * 1000)) / 1000
}

packet_serialize_input_batch :: proc(buf: []byte, commands: []Input) -> int {
	count := len(commands)
	if count == 0 || count > INPUT_BATCH_MAX_COMMANDS {
		return 0
	}
	payload := INPUT_BATCH_HEADER_SIZE
	for &command, i in commands {
		if command.seq != commands[0].seq + i32(i) { return 0 } // must be consecutive
		payload += INPUT_COMMAND_WIRE_SIZE + (command.view_stamped ? INPUT_STAMP_WIRE_SIZE : 0)
	}
	if len(buf) < PACKET_HEADER_SIZE + payload {
		return 0
	}
	endian.put_u32(buf[0:4], .Little, PACKET_MAGIC)
	buf[4] = u8(Packet_Type.PLAYER_INPUT)
	endian.put_u16(buf[5:7], .Little, u16(payload))
	o := PACKET_HEADER_SIZE
	buf[o] = u8(count)
	endian.put_i32(buf[o + 1:o + 5], .Little, commands[0].seq)
	o += INPUT_BATCH_HEADER_SIZE
	for &command in commands {
		ms := command.delta * 1000
		buf[o] = u8(clamp(math.round(ms) if ms == ms else 0, 0, 255))
		endian.put_i16(buf[o + 1:o + 3], .Little, input_angle_wire(command.x_dir))
		endian.put_i16(buf[o + 3:o + 5], .Little, input_angle_wire(normalize_angle(command.y_dir)))
		buf[o + 5] = u8(i8(clamp(command.move_dir, -128, 127)))
		buttons: u8
		if command.shoot { buttons |= INPUT_BUTTON_SHOOT }
		if command.scope { buttons |= INPUT_BUTTON_SCOPE }
		if command.jump { buttons |= INPUT_BUTTON_JUMP }
		if command.crouch { buttons |= INPUT_BUTTON_CROUCH }
		if command.reload { buttons |= INPUT_BUTTON_RELOAD }
		buttons |= (command.swap & 0x3) << INPUT_BUTTON_SWAP_SHIFT
		if command.view_stamped { buttons |= INPUT_BUTTON_STAMP }
		buf[o + 6] = buttons
		o += INPUT_COMMAND_WIRE_SIZE
		if command.view_stamped {
			endian.put_u32(buf[o:o + 4], .Little, command.view_tick)
			endian.put_u16(buf[o + 4:o + 6], .Little, u16(clamp(math.round(command.view_frac * 65535), 0, 65535)))
			o += INPUT_STAMP_WIRE_SIZE
		}
	}
	return o
}

@(private = "file")
input_angle_wire :: proc(angle: f32) -> i16 {
	if angle != angle { return 0 }
	return i16(clamp(math.round(angle * INPUT_ANGLE_SCALE), -32768, 32767))
}

// Decodes a PLAYER_INPUT batch into out. Malformed packets (wrong type or
// length, a count of 0 or over the cap, more commands than out holds, or a
// payload that does not end exactly after the last command) are rejected
// whole. Values are not range-checked here; see input_command_sanitize.
packet_deserialize_input_batch :: proc(buf: []byte, out: []Input) -> (count: int, ok: bool) {
	header, header_ok := packet_deserialize_header(buf)
	if !header_ok || header.packet_type != .PLAYER_INPUT || len(buf) != PACKET_HEADER_SIZE + int(header.payload_len) || int(header.payload_len) < INPUT_BATCH_HEADER_SIZE {
		return 0, false
	}
	o := PACKET_HEADER_SIZE
	count = int(buf[o])
	if count == 0 || count > INPUT_BATCH_MAX_COMMANDS || count > len(out) {
		return 0, false
	}
	first_seq, _ := endian.get_i32(buf[o + 1:o + 5], .Little)
	o += INPUT_BATCH_HEADER_SIZE
	for i in 0 ..< count {
		if o + INPUT_COMMAND_WIRE_SIZE > len(buf) { return 0, false }
		pitch, _ := endian.get_i16(buf[o + 1:o + 3], .Little)
		yaw, _ := endian.get_i16(buf[o + 3:o + 5], .Little)
		buttons := buf[o + 6]
		command := Input{
			seq      = first_seq + i32(i),
			delta    = f32(buf[o]) / 1000,
			x_dir    = f32(pitch) / INPUT_ANGLE_SCALE,
			y_dir    = f32(yaw) / INPUT_ANGLE_SCALE,
			move_dir = i32(i8(buf[o + 5])),
			shoot    = buttons & INPUT_BUTTON_SHOOT != 0,
			scope    = buttons & INPUT_BUTTON_SCOPE != 0,
			jump     = buttons & INPUT_BUTTON_JUMP != 0,
			crouch   = buttons & INPUT_BUTTON_CROUCH != 0,
			reload   = buttons & INPUT_BUTTON_RELOAD != 0,
			swap     = (buttons >> INPUT_BUTTON_SWAP_SHIFT) & 0x3,
		}
		o += INPUT_COMMAND_WIRE_SIZE
		if buttons & INPUT_BUTTON_STAMP != 0 {
			if o + INPUT_STAMP_WIRE_SIZE > len(buf) { return 0, false }
			command.view_stamped = true
			command.view_tick, _ = endian.get_u32(buf[o:o + 4], .Little)
			frac, _ := endian.get_u16(buf[o + 4:o + 6], .Little)
			command.view_frac = f32(frac) / 65535
			o += INPUT_STAMP_WIRE_SIZE
		}
		out[i] = command
	}
	if o != len(buf) {
		return 0, false
	}
	return count, true
}

Input_Command_Error :: enum {
	NONE,
	NON_FINITE, // NaN or infinite angle or duration
	MOVE_DIR,   // outside -1..7
	SWAP,       // outside 0..3
}

// Server-side check of one received command. Bad values reject the command;
// in-range values are normalised the way Krunker's Bum0tq does: the duration
// is clamped to [1, 33] ms (0 becomes 1 ms) and pitch to +-90 degrees; a yaw
// beyond +-2PI is wrapped. Client-only fields are cleared.
input_command_sanitize :: proc(command: ^Input) -> Input_Command_Error {
	finite :: proc(v: f32) -> bool { return v == v && v - v == 0 }
	if !finite(command.x_dir) || !finite(command.y_dir) || !finite(command.delta) || command.view_stamped && !finite(command.view_frac) {
		return .NON_FINITE
	}
	if command.move_dir < -1 || command.move_dir > 7 {
		return .MOVE_DIR
	}
	if command.swap > 3 {
		return .SWAP
	}
	ms := clamp(math.round(command.delta * 1000), INPUT_COMMAND_MIN_MS, INPUT_COMMAND_MAX_MS)
	command.delta = ms / 1000
	command.x_dir = clamp(command.x_dir, -math.PI / 2, math.PI / 2)
	// A client sends yaw already wrapped to +-PI (as milliradians, so up to
	// 3.142). Re-wrapping that would change the float it predicted with.
	if abs(command.y_dir) > 2 * math.PI { command.y_dir = normalize_angle(command.y_dir) }
	command.view_frac = clamp(command.view_frac, 0, 1)
	command.predicted_weapon_impulse = {}
	command.predicted_ramp_fix, command.predicted_has_ramp_fix = 0, false
	command.krunker_shot_timed, command.krunker_shot_time, command.krunker_shot_progress = false, 0, 0
	return .NONE
}
