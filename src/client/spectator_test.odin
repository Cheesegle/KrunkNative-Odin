package main

import "core:math"
import "core:testing"
import shared "../shared"
import kproto "../krunker"

when ODIN_TEST {
	@(private = "file")
	g_spectate_sent: [dynamic]i32

	@(private = "file")
	spectate_record_send :: proc(state: ^Krunker_WS_State, opcode: string) -> bool {
		if opcode == "fpSp" { append(&g_spectate_sent, state.spectate_target) }
		else { append(&g_spectate_sent, -1000) } // Anything else must never be sent here.
		return true
	}

	// A spectating client with players 11 (team 1), 12 (team 2) and 13
	// (team 1) on Burg, without a window. Caller frees with spectate_test_fini.
	spectate_test_client :: proc(t: ^testing.T, config: ^shared.Gameplay_Config, map_inst: ^shared.Map) -> ^Client {
		client := new(Client)
		maps := []^shared.Map{map_inst}
		shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, -1, true)
		client.krunker.connected = true
		client.krunker.spectate = true
		client.krunker_world.ready = true
		client.krunker_world.spectating = true
		client.krunker_world.local_sid = 99
		client.spectator_settings = client_settings_defaults().spectator
		client.spectator.target_sid = -1
		client.spectator.follow_distance, client.spectator.free_speed = SPECTATOR_FOLLOW_DEFAULT, 1
		names := [3]string{"Alpha", "Bravo", "Charlie"}
		teams := [3]i32{1, 2, 1}
		for i in 0 ..< 3 {
			sid := i32(11 + i)
			player := shared.player_init(&client.game)
			player.uid, player.team = sid, teams[i]
			shared.game_players_add(&client.game, player)
			shared.player_spawn(player, 0, -1)
			player.active = true
			position := map_inst.spawns[i % len(map_inst.spawns)].position
			player.position = position
			append(&client.krunker_world.players, kproto.Krunker_World_Player{sid = sid, name = names[i], team = teams[i], active = true, has_position = true, health = 100, max_health = 100, position = position, send_rate = 10})
		}
		// The local spectator's own record: never followed, never a body.
		append(&client.krunker_world.players, kproto.Krunker_World_Player{sid = 99, name = "Me", active = true, has_position = true, position = {0, 0, 0}})
		return client
	}

	spectate_test_fini :: proc(client: ^Client) {
		spectator_proxy_release(client)
		client_clear_players(client)
		delete(client.krunker_world.players)
		delete(client.krunker_world.kills)
		delete(client.join_status)
		shared.game_destroy(&client.game)
		free(client)
	}

	// One 10 Hz k record for every remote player, walking along +x and turning.
	spectate_test_k :: proc(client: ^Client, now, server: f64) {
		for &p in client.krunker_world.players {
			if p.sid == client.krunker_world.local_sid || !p.active { continue }
			p.position.x += 2
			p.direction = {f32(math.round(5*math.sin(server)))*math.PI/180, f32(math.round(40*server))*math.PI/180}
			kproto.krunker_world_buffer_pose(&p, now)
			p.poses[p.pose_count-1].server_time, p.poses[p.pose_count-1].has_server_time = server, true
		}
	}

	@(test)
	spectator_switches_targets_like_krunker :: proc(t: ^testing.T) {
		config := shared.config_load_gameplay("assets/config/game.toml")
		defer shared.config_destroy_gameplay(config)
		map_inst, ok := shared.map_load_from_file("assets/maps/burg.json")
		if !testing.expect(t, ok) { return }
		defer shared.map_destroy(map_inst)
		client := spectate_test_client(t, config, map_inst)
		defer spectate_test_fini(client)
		spectator_send_control = spectate_record_send
		defer { spectator_send_control = krunker_ws_send; delete(g_spectate_sent); g_spectate_sent = nil }

		list: [dynamic; 64]i32
		spectator_candidates(client, &list)
		testing.expectf(t, len(list) == 3 && list[0] == 11 && list[1] == 13 && list[2] == 12, "team 1 then team 2, never yourself: %v", list[:])

		now := 10.0
		for n in 0 ..< 4 { spectate_test_k(client, now, f64(n)*0.1); now += 0.1 }
		// The first frame picks a player (Krunker follows someone on entry).
		spectator_update(client, {}, now, 1.0/60)
		testing.expect(t, client.spectator.active && client.spectator.target_sid == 11 && client.spectator.mode == .FIRST_PERSON)
		testing.expect(t, client.spectator.view.valid, "the buffered poses show the new target at once")
		// Right click: next, left click: previous, wrapping (spectMode(+-1)).
		spectator_update(client, {next = true}, now, 1.0/60)
		testing.expect(t, client.spectator.target_sid == 13)
		spectator_update(client, {}, now, 1.0/60)
		spectator_update(client, {next = true}, now, 1.0/60)
		testing.expect(t, client.spectator.target_sid == 12)
		spectator_update(client, {}, now, 1.0/60)
		spectator_update(client, {next = true}, now, 1.0/60)
		testing.expect(t, client.spectator.target_sid == 11, "next wraps to the first")
		spectator_update(client, {}, now, 1.0/60)
		spectator_update(client, {previous_target = true}, now, 1.0/60)
		testing.expect(t, client.spectator.target_sid == 12, "previous wraps to the last")
		// Number keys pick from the list.
		spectator_update(client, {pick = 2}, now, 1.0/60)
		testing.expect(t, client.spectator.target_sid == 13)
		// F: free cam (fpSp with null), F again: back to a player.
		spectator_update(client, {free = true}, now, 1.0/60)
		testing.expect(t, client.spectator.mode == .FREE)
		spectator_update(client, {}, now, 1.0/60)
		spectator_update(client, {free = true}, now, 1.0/60)
		testing.expect(t, client.spectator.mode == .FIRST_PERSON)
		// R: first/third person; the wheel changes the follow distance.
		spectator_update(client, {toggle_first = true}, now, 1.0/60)
		testing.expect(t, client.spectator.mode == .CHASE)
		distance := client.spectator.follow_distance
		spectator_update(client, {scroll = -1}, now, 1.0/60)
		testing.expect(t, client.spectator.follow_distance == distance + SPECTATOR_FOLLOW_STEP, "wheel back moves the camera out by 3")
		for _ in 0 ..< 100 { spectator_update(client, {scroll = -1}, now, 1.0/60) }
		testing.expect(t, client.spectator.follow_distance == SPECTATOR_FOLLOW_MAX, "follow distance stops at Krunker's maxD")
		want := []i32{11, 13, 12, 11, 12, 13, -1, 13}
		testing.expectf(t, len(g_spectate_sent) == len(want), "one fpSp per switch: %v", g_spectate_sent[:])
		for sid, i in want { if i < len(g_spectate_sent) { testing.expectf(t, g_spectate_sent[i] == sid, "fpSp %d names %d (%v)", i, sid, g_spectate_sent[:]) } }

		// The followed player (13) dies to 12: after the delay, follow 12.
		for &p in client.krunker_world.players { if p.sid == 13 { p.active, p.life_ended = false, true } }
		if player := client_find_player(client, 13); player != nil { player.active = false }
		append(&client.krunker_world.kills, kproto.Krunker_World_Kill{victim_sid = 13, killer_sid = 12})
		spectator_update(client, {}, now, 1.0/60)
		clear(&client.krunker_world.kills)
		testing.expect(t, client.spectator.target_sid == 13, "the view stays on the body briefly")
		spectator_update(client, {}, now + SPECTATOR_RETARGET_DELAY + 0.01, 1.0/60)
		testing.expect(t, client.spectator.target_sid == 12, "then follows the killer")

		// A new match (INIT) ends spectating and the view resets.
		client.krunker_world.spectating = false
		spectator_update(client, {}, now + 2, 1.0/60)
		testing.expect(t, !client.spectator.active && client.spectator.target_sid == -1 && client.spectator.rejoin, "INIT resets the spectator and re-enters")
		for sent in g_spectate_sent { testing.expect(t, sent != -1000, "only fpSp is sent by the spectator view") }
	}

	@(test)
	spectator_never_sends_gameplay_input :: proc(t: ^testing.T) {
		// ENTER_GAME carries Krunker's spectate flag at en[6].
		counter: u8
		for spectate in ([2]bool{false, true}) {
			encoded := krunker_ws_message("en", &counter, 0, 1, 5, 13, spectate)
			messages, _, err := kproto.krunker_msgpack_decode_packet(encoded[:])
			if testing.expect(t, len(err) == 0 && len(messages) == 1) {
				packet, _ := messages[0].([]kproto.Krunker_Msgpack_Value)
				loadout, _ := packet[1].([]kproto.Krunker_Msgpack_Value)
				testing.expect(t, len(loadout) == 35 && kproto.krunker_world_i32(loadout[5], -1) == 13, "the rest of the entry is unchanged")
				testing.expectf(t, kproto.krunker_world_i32(loadout[6], -1) == (spectate ? 1 : 0), "en[6] is the spectate switch (%v)", spectate)
			}
			delete(encoded)
		}
		// fpSp names the target, or null for free cam.
		for target in ([2]i32{7, -1}) {
			encoded := krunker_ws_message("fpSp", &counter, 0, spectate_target = target)
			messages, _, err := kproto.krunker_msgpack_decode_packet(encoded[:])
			if testing.expect(t, len(err) == 0 && len(messages) == 1) {
				packet, _ := messages[0].([]kproto.Krunker_Msgpack_Value)
				opcode, _ := packet[0].(string)
				_, is_nil := packet[1].(kproto.Krunker_Msgpack_Nil)
				testing.expect(t, len(packet) == 2 && opcode == "fpSp" && (target < 0 ? is_nil : kproto.krunker_world_i32(packet[1], -1) == 7))
			}
			delete(encoded)
		}

		// With the spectate flag the input path is shut, even with queued
		// commands and a socket that looks spawned: nothing is consumed and
		// the packet counter does not move (no socket is touched: the
		// handle is nil and would fail any send).
		client: Client
		client.krunker.connected, client.krunker.spawned, client.krunker.bootstrapped = true, true, true
		client.krunker.spectate = true
		client.krunker.send_elapsed = 10
		client.krunker.ah_num = 42
		append(&client.krunker.input_commands, shared.Input{seq = 1}, shared.Input{seq = 2}, shared.Input{seq = 3})
		defer delete(client.krunker.input_commands)
		krunker_ws_send_input(&client)
		testing.expect(t, len(client.krunker.input_commands) == 3 && client.krunker.ah_num == 42 && client.krunker.input_logged == 0, "no q batch is sent")
		testing.expect(t, krunker_ws_send(&client.krunker, "q") && client.krunker.ah_num == 42 && client.krunker.q_index == 0, "a control q is refused before the socket")
		// The world flag alone (START said spectating) also shuts it.
		client.krunker.spectate = false
		client.krunker_world.spectating = true
		krunker_ws_send_input(&client)
		testing.expect(t, len(client.krunker.input_commands) == 3 && client.krunker.ah_num == 42, "no q batch while the server says spectating")

		// START(timer, team, spectating=1): the local player is not revived.
		world: kproto.Krunker_World_State
		world.local_sid = 5
		append(&world.players, kproto.Krunker_World_Player{sid = 5, active = false, life_ended = true})
		defer delete(world.players)
		start := []kproto.Krunker_Msgpack_Value{kproto.krunker_msgpack_string("start"), kproto.krunker_msgpack_string("4:00"), kproto.krunker_msgpack_int(0), kproto.krunker_msgpack_bool(true)}
		testing.expect(t, kproto.krunker_world_apply_start(&world, start))
		testing.expect(t, world.spectating && world.in_game && !world.players[0].active, "START with spectating keeps you out of the match")
		start[3] = kproto.krunker_msgpack_bool(false)
		testing.expect(t, kproto.krunker_world_apply_start(&world, start))
		testing.expect(t, !world.spectating && world.players[0].active, "a normal START still spawns you")
		delete(world.timer_text)
	}

	@(test)
	spectator_settings_default_and_validate :: proc(t: ^testing.T) {
		defaults := client_settings_validate(client_settings_defaults())
		testing.expect(t, defaults.spectator.smoothing == 0.5 && !defaults.spectator.hide_viewmodel && !defaults.spectator.no_follow_killer)
		bad := client_settings_defaults()
		bad.spectator.smoothing = 7
		testing.expect(t, client_settings_validate(bad).spectator.smoothing == 1, "smoothing is clamped to 0..1")
		bad.spectator.smoothing = math.nan_f32()
		testing.expect(t, client_settings_validate(bad).spectator.smoothing == 0.5, "NaN falls back to the default")
	}
}
