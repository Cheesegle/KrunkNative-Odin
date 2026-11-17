package main

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
		state.ghost_armed_at, state.ghost_fired_at, state.ghost_ack, state.ghost_ack_seen = 5, 4, 81000, true
		if !krunker_ghost_test_start(t, &client) { return }
		testing.expect(t, state.input_sequence == 0 && len(state.input_commands) == 0 && len(client.predicted_inputs) == 0,
			"start must restart input ids at 0 and drop the previous life's unsent and predicted inputs")
		testing.expect(t, !state.input_reset && !state.input_blocked && state.input_elapsed == 0 && state.input_duration_remainder_ms == 0,
			"start must clear the reset flag and pending input timing, as Krunker sets eR=0")
		testing.expect(t, state.ah_num == 77, "start resets input state only; the packet counter continues")
		testing.expect(t, state.ghost_armed_at == 0 && state.ghost_fired_at == 0 && !state.ghost_ack_seen,
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

	// Krodin's own watchdog: sending for ~1 s with no ACK progress while alive
	// forces the next q to carry the reset flag, at most once per 2 s.
	@(test)
	krunker_ghost_watchdog_resets_stalled_acks :: proc(t: ^testing.T) {
		client: Client
		map_inst: shared.Map
		krunker_presentation_fixture(&client, &map_inst)
		defer krunker_presentation_cleanup(&client)
		state := &client.krunker
		state.connected = true
		state.input_sequence = 100
		if !testing.expect(t, client.me.active, "fixture player must be alive") { return }
		testing.expect(t, krunker_ws_accept_ack(state, 0), "the respawn ACK of 0 is below input_sequence")
		krunker_ws_ghost_note_sent(state, 10)
		testing.expect(t, !krunker_ws_ghost_watchdog(&client, 10.9) && !state.input_reset, "under 1 s without progress must not fire")
		krunker_ws_accept_ack(state, 0)
		testing.expect(t, krunker_ws_ghost_watchdog(&client, 11.0) && state.input_reset, "1 s of sends with a stuck ACK must request a reset")
		append(&state.input_commands, shared.Input{seq = 100, delta = 0.003})
		reset, ids := krunker_ghost_test_q(t, state)
		testing.expect(t, reset == 1 && len(ids) == 1 && ids[0] == 100, "the next q must carry the reset flag without rewinding ids")
		krunker_ws_input_sent(state, 1, 0)
		krunker_ws_ghost_note_sent(state, 11.1)
		testing.expect(t, !state.input_reset, "a sent q consumes the reset request")
		testing.expect(t, !krunker_ws_ghost_watchdog(&client, 12.5) && !state.input_reset, "a second reset within 2 s must be rate-limited")
		testing.expect(t, krunker_ws_ghost_watchdog(&client, 13.0) && state.input_reset, "the watchdog may fire again after the cooldown")
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
		// ACKs advancing every 0.25 s for 5 s: never a reset.
		for step in 0 ..< 20 {
			now := 20 + f64(step) * 0.25
			krunker_ws_ghost_note_sent(state, now)
			krunker_ws_accept_ack(state, i32(step * 90))
			testing.expect(t, !krunker_ws_ghost_watchdog(&client, now + 0.2), "advancing ACKs must not trigger the watchdog")
		}
		testing.expect(t, !state.input_reset && state.ghost_fired_at == 0)
		// Dead (or between lives): no reset, however long ACKs stall.
		krunker_ws_ghost_note_sent(state, 30)
		client.me.active = false
		testing.expect(t, !krunker_ws_ghost_watchdog(&client, 40) && !state.input_reset, "a dead player must not trigger the watchdog")
		client.me.active = true
		state.spawned = false
		krunker_ws_ghost_note_sent(state, 40)
		testing.expect(t, !krunker_ws_ghost_watchdog(&client, 50) && !state.input_reset, "an unspawned player must not trigger the watchdog")
		state.spawned = true
		krunker_ws_ghost_note_sent(state, 50)
		testing.expect(t, krunker_ws_ghost_watchdog(&client, 51.5) && state.input_reset, "a respawned player still stuck after 1 s must reset")
	}
}
