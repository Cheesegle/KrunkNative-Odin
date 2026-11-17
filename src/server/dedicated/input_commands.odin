package dedicated

import "core:fmt"
import shared "../../shared"

// Per-client input command stream. Every received command is queued in order
// and simulated as one player_proc_input step with its own duration, in the
// network phase of a server tick, before the world update (projectiles,
// timers, objectives), which stays on the fixed tick. This is Krunker's model:
// player.update runs Bum0tq once per queued input and the movement does not
// depend on the server tick rate (krunkbox game.deob.js `this["update"]`, the
// `this['inputs']` loop). The ack sent back is the last command handled.
//
// Idle clients: with no commands the player is not stepped at all (no
// gravity, no invented movement), as in Krunker, whose update only calls
// Bum0tq while `this.inputs.length` is non-zero.
//
// Speedhack guard (Krodin's own; Krunker's server code is not in the client
// bundle): a time bank that real time fills and command durations drain. It
// starts full and holds at most COMMAND_TIME_BANK_MS, so a client's command
// time can never run ahead of real time by more than that, and an idle client
// cannot save up time for a later burst.
COMMAND_QUEUE_LIMIT :: 256
COMMAND_TIME_BANK_MS :: 250.0
COMMAND_LOG_INTERVAL :: 5.0 // seconds between a client's rejection log lines

Command_Push_Result :: enum {
	QUEUED,
	DUPLICATE, // seq at or before the last one received (redundant resend)
	INVALID,   // failed input_command_sanitize
	OVERFLOW,  // the queue is full
}

Command_Stats :: struct {
	simulated, duplicates, invalid, overflow, speed_rejected, inactive: int,
	speed_rejected_ms: f64,
}

Command_Stream :: struct {
	queue:     [dynamic]shared.Input,
	last_seq:  i32, // newest seq received (queued or dropped)
	has_seq:   bool,
	bank_ms:   f64,
	bank_time: f64, // real seconds when the bank was last filled
	stats:     Command_Stats,
	logged:    Command_Stats, // stats at the last log line
	next_log:  f64,
}

command_stream_init :: proc(cs: ^Command_Stream, now: f64) {
	cs.bank_ms = COMMAND_TIME_BANK_MS
	cs.bank_time = now
}

command_stream_destroy :: proc(cs: ^Command_Stream) {
	delete(cs.queue)
	cs.queue = nil
}

// Wrap-safe "a is after b" for command sequence numbers.
command_seq_after :: proc(a, b: i32) -> bool {
	return i32(u32(a) - u32(b)) > 0
}

// Takes one decoded command. Each seq is handled at most once: redundant
// copies of commands already received are ignored.
command_stream_push :: proc(cs: ^Command_Stream, command: shared.Input) -> Command_Push_Result {
	if cs.has_seq && !command_seq_after(command.seq, cs.last_seq) {
		cs.stats.duplicates += 1
		return .DUPLICATE
	}
	cs.last_seq, cs.has_seq = command.seq, true
	command := command
	if shared.input_command_sanitize(&command) != .NONE {
		cs.stats.invalid += 1
		return .INVALID
	}
	if len(cs.queue) >= COMMAND_QUEUE_LIMIT {
		cs.stats.overflow += 1
		return .OVERFLOW
	}
	append(&cs.queue, command)
	return .QUEUED
}

command_stream_refill :: proc(cs: ^Command_Stream, now: f64) {
	if now > cs.bank_time {
		cs.bank_ms = min(COMMAND_TIME_BANK_MS, cs.bank_ms + (now - cs.bank_time) * 1000)
	}
	cs.bank_time = max(cs.bank_time, now)
}

// Simulates every queued command in order on `player` and sets the ack
// (player.input_seq) to the newest command handled, including dropped ones,
// so the client stops replaying them (-1 before any command). Commands for a dead player are dropped.
command_stream_run :: proc(cs: ^Command_Stream, player: ^shared.Player, game: ^shared.Game, now: f64) -> (simulated: int) {
	command_stream_refill(cs, now)
	for &command in cs.queue {
		if player == nil || !player.active {
			cs.stats.inactive += 1
			continue
		}
		ms := f64(command.delta) * 1000
		if cs.bank_ms + 1e-6 < ms {
			cs.stats.speed_rejected += 1
			cs.stats.speed_rejected_ms += ms
			continue
		}
		cs.bank_ms -= ms
		shared.player_proc_input(player, &command, false, game != nil && game.move_lock)
		simulated += 1
	}
	cs.stats.simulated += simulated
	clear(&cs.queue)
	// -1 until the first command arrives: client seqs start at 0, so an ack
	// of 0 would wrongly drop the first command from the client's replay.
	if player != nil {
		player.input_seq = cs.has_seq ? cs.last_seq : -1
	}
	return
}

// One line every COMMAND_LOG_INTERVAL seconds at most, and only when
// something was rejected since the last line.
command_stream_log :: proc(cs: ^Command_Stream, client_id: u32, now: f64) {
	if now < cs.next_log { return }
	s, l := cs.stats, cs.logged
	if s.speed_rejected == l.speed_rejected && s.invalid == l.invalid && s.overflow == l.overflow { return }
	fmt.printf("[Net Server] Client #%d input: dropped %d commands (%.0f ms) running ahead of real time, %d invalid, %d over the queue limit\n",
		client_id, s.speed_rejected - l.speed_rejected, s.speed_rejected_ms - l.speed_rejected_ms, s.invalid - l.invalid, s.overflow - l.overflow)
	cs.logged = s
	cs.next_log = now + COMMAND_LOG_INTERVAL
}
