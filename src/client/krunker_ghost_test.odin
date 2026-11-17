package main

import "core:math"
import "core:testing"
import shared "../shared"
import kproto "../krunker"

when ODIN_TEST {
	krunker_ghost_test_start :: proc(t: ^testing.T, client: ^Client) -> bool {
		start, ok := kproto.krunker_msgpack_encode_packet("start", []kproto.Krunker_Msgpack_Value{"2:00", i64(2), false, kproto.Krunker_Msgpack_Nil{}, i64(0), i64(1), kproto.Krunker_Msgpack_Nil{}, i64(3)}, 0)
		if !testing.expect(t, ok, "start must encode") { return false }
		defer delete(start)
		krunker_ws_apply_world(client, start)
		return true
	}

	krunker_ghost_test_q :: proc(t: ^testing.T, state: ^Krunker_WS_State) -> (reset: i64, ids: []i32) {
		packet, ok := krunker_ws_encode_input(state)
		if !testing.expect(t, ok, "queued commands must encode as one q") { return }
		defer delete(packet)
		messages, _, error_text := kproto.krunker_msgpack_decode_packet(packet)
		if !testing.expect(t, len(error_text) == 0 && len(messages) == 1) { return }
		reset = messages[0].([]kproto.Krunker_Msgpack_Value)[1].(i64)
		commands := krunker_test_decode_commands(t, packet)
		ids = make([]i32, len(commands), context.temp_allocator)
		for command, i in commands { ids[i] = command.seq }
		return
	}

	// Krunker's START handler (u3e) runs St.reset(): isn=0, tmpInpts cleared,
	// reset flag eR=0 and first id M7=null. A new life must not inherit the
	// previous life's ids, unsent batch, or pending reset.
	@(test)
	krunker_start_restarts_input_ids_at_zero :: proc(t: ^testing.T) {
		client: Client
		map_inst: shared.Map
		krunker_presentation_fixture(&client, &map_inst)
		defer krunker_presentation_cleanup(&client)
		state := &client.krunker
		state.connected = true
		state.input_sequence = 82000
		for seq in i32(81990) ..< 82000 {
			append(&state.input_commands, shared.Input{seq = seq, delta = 0.003})
			append(&client.predicted_inputs, shared.Input{seq = seq, delta = 0.003})
		}
		state.input_reset, state.input_blocked = true, true
		state.input_elapsed, state.input_duration_remainder_ms = 0.002, 0.3
		state.ah_num = 77
		state.ghost_stalled_syncs, state.ghost_fired_at, state.ghost_ack, state.ghost_ack_seen = 5, 4, 81000, true
		state.sync_sent, state.sync_sent_ms, state.life_syncs = true, 900, 7
		if !krunker_ghost_test_start(t, &client) { return }
		testing.expect(t, state.input_sequence == 0 && len(state.input_commands) == 0 && len(client.predicted_inputs) == 0,
			"start must restart input ids at 0 and drop the previous life's unsent and predicted inputs")
		testing.expect(t, !state.input_reset && !state.input_blocked && state.input_elapsed == 0 && state.input_duration_remainder_ms == 0,
			"start must clear the reset flag and pending input timing, as Krunker sets eR=0")
		testing.expect(t, state.ah_num == 77, "start resets input state only; the packet counter continues")
		testing.expect(t, state.ghost_stalled_syncs == 0 && state.ghost_fired_at == 0 && !state.ghost_ack_seen && !state.sync_sent && state.sync_sent_ms == 0 && state.life_syncs == 0,
			"start must restart the ghost watchdog for the new life")
	}

	// Hazard of restarting at 0: an ACK from before the restart (the server's
	// pre-input ACK, or the previous life's) is at or above input_sequence.
	// Accepting it moved input_sequence past queued commands, so the next
	// batch was not consecutive and could not be encoded.
	@(test)
	krunker_stale_ack_after_start_keeps_consecutive_ids :: proc(t: ^testing.T) {
		for stale in ([]i32{5, 80000}) {
			client: Client
			map_inst: shared.Map
			krunker_presentation_fixture(&client, &map_inst)
			defer krunker_presentation_cleanup(&client)
			state := &client.krunker
			state.connected = true
			state.input_sequence = 80001
			if !krunker_ghost_test_start(t, &client) { return }
			frame := shared.Input{delta = 0.01, move_dir = 0}
			krunker_client_predict_input(&client, &frame, 1)
			queued := len(state.input_commands)
			if !testing.expect(t, queued == 3 && state.input_commands[0].seq == 0 && state.input_sequence == 3, "10 ms must queue ids 0, 1, 2") { return }
			source := kproto.Krunker_World_Player{position = client.me.position, weapon_slot = 0, has_ack = true, ack_seq = stale, sync_revision = 1}
			krunker_client_apply_motion(&client, client.me, &source, false)
			testing.expectf(t, state.input_sequence == 3 && len(client.predicted_inputs) == 3 && state.stale_ack_logged,
				"stale ACK %d must neither move the sequence nor discard this life's predictions", stale)
			testing.expect(t, !state.ghost_ack_seen, "a stale ACK is not ACK progress")
			krunker_client_predict_input(&client, &frame, 1)
			reset, ids := krunker_ghost_test_q(t, state)
			if !testing.expectf(t, len(ids) == len(state.input_commands) && len(ids) >= 5, "stale ACK %d: every queued command must encode", stale) { continue }
			for id, i in ids { testing.expectf(t, id == i32(i), "stale ACK %d: q must carry consecutive ids from 0, got %v", stale, ids) }
			testing.expect(t, reset == 0, "a fresh life's first q does not carry the reset flag")
			// A real ACK for this life still retires acknowledged predictions.
			source.ack_seq, source.sync_revision = 1, 2
			krunker_client_apply_motion(&client, client.me, &source, false)
			testing.expect(t, len(client.predicted_inputs) > 0 && client.predicted_inputs[0].seq == 2 && state.ghost_ack_seen && state.ghost_ack == 1,
				"an ACK below input_sequence must discard acknowledged predictions and count as progress")
		}
	}

	// One fresh l (SYNC_PLAYER) for the local player carrying ack.
	krunker_ghost_test_sync :: proc(client: ^Client, ack: i32, revision: ^u64) {
		revision^ += 1
		source := kproto.Krunker_World_Player{position = client.me.position, weapon_slot = client.me.loadout_index, has_ack = true, ack_seq = ack, sync_revision = revision^}
		krunker_client_apply_motion(client, client.me, &source, false)
	}

	// Krodin's own watchdog counts l syncs: only two consecutive syncs
	// without ACK progress, each after q went out, request a reset.
	@(test)
	krunker_ghost_watchdog_counts_stalled_syncs :: proc(t: ^testing.T) {
		client: Client
		map_inst: shared.Map
		krunker_presentation_fixture(&client, &map_inst)
		defer krunker_presentation_cleanup(&client)
		state := &client.krunker
		state.connected = true
		state.input_sequence = 100
		if !testing.expect(t, client.me.active, "fixture player must be alive") { return }
		krunker_ws_ghost_note_sent(state, 30)
		krunker_ws_ghost_note_sync(state, 50, krunker_ws_accept_ack(state, 50), 10)
		testing.expect(t, state.ghost_stalled_syncs == 0, "the first ACK of a life is progress")
		// Long gaps with no l at all are network lag, not a stall.
		testing.expect(t, !krunker_ws_ghost_watchdog(&client, 20) && !state.input_reset, "time alone must never fire")
		krunker_ws_ghost_note_sync(state, 50, true, 21)
		testing.expect(t, state.ghost_stalled_syncs == 0, "a sync with no q sent since the last is not a stall")
		krunker_ws_ghost_note_sent(state, 30)
		krunker_ws_ghost_note_sync(state, 50, true, 22)
		testing.expect(t, state.ghost_stalled_syncs == 1 && !krunker_ws_ghost_watchdog(&client, 22), "one stalled sync must not fire")
		krunker_ws_ghost_note_sent(state, 30)
		krunker_ws_ghost_note_sync(state, 50, true, 23)
		testing.expect(t, krunker_ws_ghost_watchdog(&client, 23) && state.input_reset, "two stalled syncs must request a reset")
		append(&state.input_commands, shared.Input{seq = 100, delta = 0.003})
		reset, ids := krunker_ghost_test_q(t, state)
		testing.expect(t, reset == 1 && len(ids) == 1 && ids[0] == 100, "the next q must carry the reset flag without rewinding ids")
		krunker_ws_input_sent(state, 1, 0)
		testing.expect(t, !state.input_reset, "a sent q consumes the reset request")
		for now in ([]f64{24, 25}) {
			krunker_ws_ghost_note_sent(state, 30)
			krunker_ws_ghost_note_sync(state, 50, true, now)
		}
		testing.expect(t, !krunker_ws_ghost_watchdog(&client, 25.5) && !state.input_reset, "a second reset within 3 s must be rate-limited")
		testing.expect(t, krunker_ws_ghost_watchdog(&client, 26.0) && state.input_reset, "the watchdog may fire again after the cooldown")
		// A stale ACK (not below input_sequence) is no progress either.
		state.input_reset = false
		for now in ([]f64{40, 41}) {
			krunker_ws_ghost_note_sent(state, 30)
			krunker_ws_ghost_note_sync(state, 5000, krunker_ws_accept_ack(state, 5000), now)
		}
		testing.expect(t, krunker_ws_ghost_watchdog(&client, 41) && state.input_reset, "syncs that only carry stale ACKs must count as stalled")
	}

	@(test)
	krunker_ghost_watchdog_ignores_progress_and_death :: proc(t: ^testing.T) {
		client: Client
		map_inst: shared.Map
		krunker_presentation_fixture(&client, &map_inst)
		defer krunker_presentation_cleanup(&client)
		state := &client.krunker
		state.connected = true
		state.input_sequence = 10000
		for step in 0 ..< 20 {
			krunker_ws_ghost_note_sent(state, 1000)
			krunker_ws_ghost_note_sync(state, i32(step * 360), true, f64(step))
			testing.expect(t, !krunker_ws_ghost_watchdog(&client, f64(step) + 0.5), "advancing ACKs must not trigger the watchdog")
		}
		testing.expect(t, !state.input_reset && state.ghost_fired_at == 0)
		for now in ([]f64{30, 31, 32}) {
			krunker_ws_ghost_note_sent(state, 1000)
			krunker_ws_ghost_note_sync(state, 7000, true, now)
		}
		client.me.active = false
		testing.expect(t, !krunker_ws_ghost_watchdog(&client, 33) && !state.input_reset && state.ghost_stalled_syncs == 0, "a dead player must not trigger the watchdog")
		client.me.active = true
		for now in ([]f64{40, 41, 42}) {
			krunker_ws_ghost_note_sent(state, 1000)
			krunker_ws_ghost_note_sync(state, 7000, true, now)
		}
		state.spawned = false
		testing.expect(t, !krunker_ws_ghost_watchdog(&client, 43) && !state.input_reset, "an unspawned player must not trigger the watchdog")
	}

	Krunker_Respawn_Sim :: struct {
		fired: int,
		first_reset_at: f64,
		sent_ms: f64,
		wall: f64,
		encode_failures: int,
		gaps: int,
	}

	// Drive one live life after a respawn as the log shows it: start, then
	// 144 Hz frames, q every 1/30 s, and l once per second with up to 45 ms
	// of jitter. The modelled server processes each q 80 ms after it is sent
	// until stall_at (seconds after start), then stops acknowledging.
	krunker_respawn_sim :: proc(t: ^testing.T, stall_at: f64) -> (sim: Krunker_Respawn_Sim) {
		client: Client
		map_inst: shared.Map
		krunker_presentation_fixture(&client, &map_inst)
		defer krunker_presentation_cleanup(&client)
		state := &client.krunker
		state.connected = true
		state.input_sequence = 10560 // previous life, as in the log
		client.game.config.delta_mlt = 1
		if !krunker_ghost_test_start(t, &client) { return }
		Arrival :: struct { at: f64, last: i32 }
		arrivals: [dynamic]Arrival
		defer delete(arrivals)
		server_ack: i32 = 0 // the server's inputSN restarts at 0 on spawn
		revision: u64
		next_sync := 1.0
		expected_seq: i32 = 0
		frame_dt := 1.0 / 144
		now := 0.0
		sync_index := 0
		for frame in 0 ..< 144 * 8 {
			now = f64(frame + 1) * frame_dt
			input := shared.Input{delta = f32(frame_dt), move_dir = 0}
			krunker_client_predict_input(&client, &input, now)
			if krunker_ws_ghost_watchdog(&client, now) {
				sim.fired += 1
				if sim.first_reset_at == 0 { sim.first_reset_at = now }
			}
			if state.send_elapsed >= KRUNKER_SEND_SECONDS && len(state.input_commands) > 0 {
				count := min(len(state.input_commands), kproto.KRUNKER_MAX_INPUT_BATCH)
				_, ids := krunker_ghost_test_q(t, state)
				if len(ids) != count { sim.encode_failures += 1; return }
				for id in ids {
					if id != expected_seq { sim.gaps += 1 }
					expected_seq = id + 1
				}
				sent_ms: f64
				for command in state.input_commands[:count] { sent_ms += f64(math.round(command.delta * 1000)) }
				sim.sent_ms += sent_ms
				append(&arrivals, Arrival{now + 0.08, ids[len(ids)-1]})
				krunker_ws_input_sent(state, count, 0)
				krunker_ws_ghost_note_sent(state, sent_ms)
			}
			for len(arrivals) > 0 && arrivals[0].at <= now {
				if arrivals[0].at < stall_at { server_ack = arrivals[0].last }
				ordered_remove(&arrivals, 0)
			}
			if now >= next_sync {
				krunker_ghost_test_sync(&client, server_ack, &revision)
				sync_index += 1
				// The log's l spacing: a few ms either side of 1 s.
				next_sync = f64(sync_index + 1) + (sync_index % 2 == 0 ? 0.045 : 0.0)
			}
		}
		sim.wall = now
		return
	}

	// Regression for the base client's [ghost] lines: every one was ACK
	// 421 commands behind (1 s + latency), i.e. the 1 Hz l arriving a few ms
	// after the 1 s wall-clock watchdog. A healthy respawned life must never
	// request a reset, must send consecutive ids from 0, and must never send
	// more input time than real time.
	@(test)
	krunker_respawn_healthy_life_never_resets :: proc(t: ^testing.T) {
		sim := krunker_respawn_sim(t, 1e9)
		testing.expect(t, sim.encode_failures == 0 && sim.gaps == 0, "every q after start must encode consecutive ids from 0")
		testing.expectf(t, sim.fired == 0, "a healthy life with jittery 1 Hz syncs must not trigger the watchdog (fired %d)", sim.fired)
		testing.expectf(t, sim.sent_ms <= sim.wall * 1000 + 1 && sim.sent_ms >= sim.wall * 1000 - 60,
			"input time sent (%.0f ms) must track wall time (%.0f ms) without exceeding it", sim.sent_ms, sim.wall * 1000)
	}

	@(test)
	krunker_respawn_stalled_server_resets_once :: proc(t: ^testing.T) {
		sim := krunker_respawn_sim(t, 2.5)
		testing.expect(t, sim.encode_failures == 0 && sim.gaps == 0, "every q after start must encode consecutive ids from 0")
		testing.expectf(t, sim.fired >= 1 && sim.first_reset_at > 4 && sim.first_reset_at < 6,
			"a server that stops acknowledging at 2.5 s must get a reset after two stalled syncs (fired %d at %.2f s)", sim.fired, sim.first_reset_at)
		testing.expectf(t, sim.fired <= 2, "resets must be rate-limited (fired %d in 8 s)", sim.fired)
	}
}
