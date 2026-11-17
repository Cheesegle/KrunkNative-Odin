package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import glfw "vendor:glfw"
import shared "../shared"
import kproto "../krunker"
import menuui "../menu"

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
		delete(client.krunker_world.shots)
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

		// On death = Killer: the followed player (13) dies to 12; after the
		// delay, follow 12.
		client.spectator_settings.on_death = i32(menuui.Spectator_On_Death.KILLER)
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
		testing.expect(t, defaults.spectator.smoothing == 0.5 && !defaults.spectator.hide_viewmodel && defaults.spectator.on_death == i32(menuui.Spectator_On_Death.RANDOM), "Random player is the On death default")
		bad := client_settings_defaults()
		bad.spectator.smoothing = 7
		testing.expect(t, client_settings_validate(bad).spectator.smoothing == 1, "smoothing is clamped to 0..1")
		bad.spectator.smoothing = math.nan_f32()
		testing.expect(t, client_settings_validate(bad).spectator.smoothing == 0.5, "NaN falls back to the default")
		bad.spectator.on_death = 9
		testing.expect(t, client_settings_validate(bad).spectator.on_death == i32(menuui.Spectator_On_Death.RANDOM), "an unknown On death falls back to Random")

		// The first spectator build's follow-killer toggle migrates to Random
		// (see client_settings_migrate_spectator); a saved On death is kept.
		path := "bin/spectator-settings-migration-test.json"
		defer os.remove(path)
		for old in ([2]string{"false", "true"}) {
			// Concatenated: fmt would read the JSON braces as format syntax.
			text := strings.concatenate({`{"version":1,"spectator":{"smoothing":0.3,"hide_viewmodel":false,"no_follow_killer":`, old, `}}`}, context.temp_allocator)
			testing.expect(t, os.write_entire_file(path, transmute([]byte)text) == nil)
			loaded := client_settings_load(path)
			testing.expectf(t, loaded.spectator.on_death == i32(menuui.Spectator_On_Death.RANDOM) && abs(loaded.spectator.smoothing - 0.3) < 1e-6, "no_follow_killer=%s migrates to Random (%v)", old, loaded.spectator)
		}
		kept := `{"version":1,"spectator":{"smoothing":0.5,"on_death":2}}`
		testing.expect(t, os.write_entire_file(path, transmute([]byte)kept) == nil)
		testing.expect(t, client_settings_load(path).spectator.on_death == i32(menuui.Spectator_On_Death.STAY), "a saved On death survives a restart")
		saved := client_settings_defaults()
		saved.spectator.on_death = i32(menuui.Spectator_On_Death.KILLER)
		testing.expect(t, client_settings_save(saved, path))
		testing.expect(t, client_settings_load(path).spectator.on_death == i32(menuui.Spectator_On_Death.KILLER), "Save then load keeps the choice")
		written, _ := os.read_entire_file_from_path(path, context.allocator)
		defer delete(written)
		testing.expect(t, !strings.contains(string(written), "no_follow_killer"), "the old key is never written again")
	}

	// Marks a player dead the way KILL_PLAYER does, in the world and the client.
	@(private = "file")
	spectate_test_kill :: proc(client: ^Client, sid: i32, killer: i32 = -1) {
		for &p in client.krunker_world.players { if p.sid == sid { p.active, p.life_ended, p.health = false, true, 0 } }
		if player := client_find_player(client, sid); player != nil { player.active = false }
		if killer >= 0 { append(&client.krunker_world.kills, kproto.Krunker_World_Kill{victim_sid = sid, killer_sid = killer}) }
	}

	@(private = "file")
	spectate_test_revive :: proc(client: ^Client, sid: i32) {
		for &p in client.krunker_world.players { if p.sid == sid { p.active, p.life_ended, p.health = true, false, 100 } }
		if player := client_find_player(client, sid); player != nil { player.active = true }
	}

	@(test)
	spectator_on_death_picks_another_living_player :: proc(t: ^testing.T) {
		config := shared.config_load_gameplay("assets/config/game.toml")
		defer shared.config_destroy_gameplay(config)
		map_inst, ok := shared.map_load_from_file("assets/maps/burg.json")
		if !testing.expect(t, ok) { return }
		defer shared.map_destroy(map_inst)
		spectator_send_control = spectate_record_send
		defer { spectator_send_control = krunker_ws_send; delete(g_spectate_sent); g_spectate_sent = nil }

		// Random (the default), many times: never the one who died, never
		// yourself, always someone alive; the ~1.2 s delay is kept.
		seen: [3]bool
		for round in 0 ..< 40 {
			client := spectate_test_client(t, config, map_inst)
			now := 10.0
			spectate_test_k(client, now, 0)
			spectator_update(client, {}, now, 1.0/60)
			first := client.spectator.target_sid
			spectate_test_kill(client, first, killer = first == 12 ? 11 : 12)
			spectator_update(client, {}, now + 0.5, 1.0/60)
			clear(&client.krunker_world.kills)
			testing.expect(t, client.spectator.target_sid == first, "still on them before the delay")
			spectator_update(client, {}, now + SPECTATOR_RETARGET_DELAY + 0.6, 1.0/60)
			next := client.spectator.target_sid
			testing.expectf(t, next != first && next != 99 && next >= 11 && next <= 13, "round %d: random pick %d after %d died", round, next, first)
			for &p in client.krunker_world.players { if p.sid == next { testing.expect(t, p.active && !p.life_ended, "the pick is alive") } }
			if next >= 11 && next <= 13 { seen[next-11] = true }
			spectate_test_fini(client)
		}
		testing.expect(t, (seen[1] ? 1 : 0) + (seen[2] ? 1 : 0) == 2, "Random varies its pick between the two living players")

		// Nobody else alive: keep watching, then pick the first to spawn.
		{
			client := spectate_test_client(t, config, map_inst)
			defer spectate_test_fini(client)
			now := 10.0
			spectate_test_k(client, now, 0)
			spectator_update(client, {}, now, 1.0/60)
			testing.expect(t, client.spectator.target_sid == 11)
			spectate_test_kill(client, 12); spectate_test_kill(client, 13)
			spectator_update(client, {}, now + 0.1, 1.0/60)
			spectate_test_kill(client, 11, killer = 12)
			spectator_update(client, {}, now + 0.2, 1.0/60)
			clear(&client.krunker_world.kills)
			spectator_update(client, {}, now + 2, 1.0/60)
			spectator_update(client, {}, now + 3, 1.0/60)
			testing.expect(t, client.spectator.target_sid == 11, "nobody alive: the view stays")
			spectate_test_revive(client, 13)
			spectator_update(client, {}, now + 3.1, 1.0/60)
			testing.expect(t, client.spectator.target_sid == 13, "then follows the first player to spawn")
		}

		// Stay on them: no switch while they are dead; following continues
		// after their respawn; a player who leaves the lobby is replaced.
		{
			client := spectate_test_client(t, config, map_inst)
			defer spectate_test_fini(client)
			client.spectator_settings.on_death = i32(menuui.Spectator_On_Death.STAY)
			now := 10.0
			spectate_test_k(client, now, 0)
			spectator_update(client, {}, now, 1.0/60)
			spectate_test_kill(client, 11, killer = 12)
			spectator_update(client, {}, now + 0.1, 1.0/60)
			clear(&client.krunker_world.kills)
			spectator_update(client, {}, now + 5, 1.0/60)
			testing.expect(t, client.spectator.target_sid == 11, "Stay keeps the view on them")
			spectate_test_revive(client, 11)
			spectator_update(client, {}, now + 6, 1.0/60)
			testing.expect(t, client.spectator.target_sid == 11)
			ordered_remove(&client.krunker_world.players, 0) // 11 leaves.
			spectator_update(client, {}, now + 6.1, 1.0/60)
			spectator_update(client, {}, now + 6.1 + SPECTATOR_RETARGET_DELAY + 0.1, 1.0/60)
			testing.expect(t, client.spectator.target_sid == 12 || client.spectator.target_sid == 13, "someone who left is replaced")
		}

		// Killer, when the killer is dead too: a random living player.
		{
			client := spectate_test_client(t, config, map_inst)
			defer spectate_test_fini(client)
			client.spectator_settings.on_death = i32(menuui.Spectator_On_Death.KILLER)
			now := 10.0
			spectate_test_k(client, now, 0)
			spectator_update(client, {}, now, 1.0/60)
			spectate_test_kill(client, 11, killer = 12)
			spectate_test_kill(client, 12)
			spectator_update(client, {}, now + 0.1, 1.0/60)
			clear(&client.krunker_world.kills)
			spectator_update(client, {}, now + 2, 1.0/60)
			testing.expect(t, client.spectator.target_sid == 13, "a dead killer falls back to someone alive")
		}
	}

	// A DO_DAMAGE as the server sends it to a socket whose fpSp stream is the
	// attacker: (victim sid, damage, headshot), right after the victim's h.
	spectate_test_do_damage :: proc(client: ^Client, now: f64, victim: i32, health: f32, headshot := false) {
		world := &client.krunker_world
		world.received_at = now
		h := []kproto.Krunker_Msgpack_Value{kproto.krunker_msgpack_string("h"), kproto.krunker_msgpack_float(f64(health)), kproto.krunker_msgpack_int(i64(victim))}
		kproto.krunker_world_apply_packet(world, h)
		damage := []kproto.Krunker_Msgpack_Value{kproto.krunker_msgpack_string("4"), kproto.krunker_msgpack_int(i64(victim)), kproto.krunker_msgpack_int(25), kproto.krunker_msgpack_bool(headshot)}
		kproto.krunker_world_apply_packet(world, damage)
	}

	@(test)
	spectator_hitmarkers_only_for_the_followed_player :: proc(t: ^testing.T) {
		config := shared.config_load_gameplay("assets/config/game.toml")
		defer shared.config_destroy_gameplay(config)
		map_inst, ok := shared.map_load_from_file("assets/maps/burg.json")
		if !testing.expect(t, ok) { return }
		defer shared.map_destroy(map_inst)
		spectator_send_control = spectate_record_send
		defer { spectator_send_control = krunker_ws_send; delete(g_spectate_sent); g_spectate_sent = nil }
		client := spectate_test_client(t, config, map_inst)
		defer spectate_test_fini(client)
		client.hitmarker_settings = client_settings_defaults().hitmarker
		now := 10.0
		spectate_test_k(client, now, 0)
		spectator_update(client, {}, now, 1.0/60)
		testing.expect(t, client.spectator.target_sid == 11)

		// In flight from the stream we just left (the server still had the
		// previous specStream): no marker.
		spectate_test_do_damage(client, now + 0.1, 12, 75)
		spectator_update(client, {}, now + 0.1, 1.0/60)
		testing.expect(t, client.spectator.hits_shown == 0 && !client.hit_marker.active, "nothing within the switch grace")

		// The followed player (11) hits 12: a body-hit marker.
		spectate_test_do_damage(client, now + 1, 12, 50)
		spectator_update(client, {}, now + 1, 1.0/60)
		testing.expect(t, client.spectator.hits_shown == 1 && client.hit_marker.active, "the followed player's hit shows a marker")
		testing.expect(t, client.hit_marker.color == client.hitmarker_settings.colors[.NORMAL])
		// A headshot that kills (the victim's h said 0): the kill colour.
		spectate_test_do_damage(client, now + 1.2, 13, 0, headshot = true)
		spectator_update(client, {}, now + 1.2, 1.0/60)
		testing.expect(t, client.spectator.hits_shown == 2 && client.hit_marker.color == client.hitmarker_settings.colors[.KILL], "a lethal hit uses the kill colour")
		spectate_test_revive(client, 13)

		// Someone else's hits. The followed player being hit (a DO_DAMAGE
		// naming him):
		spectate_test_do_damage(client, now + 2, 11, 60)
		spectator_update(client, {}, now + 2, 1.0/60)
		testing.expect(t, client.spectator.hits_shown == 2, "the followed player taking damage is not his hit")
		// Another player's tracer ending on 13, with 13's health dropping:
		client.krunker_world.received_at = now + 2.5
		tracer := []kproto.Krunker_Msgpack_Value{kproto.krunker_msgpack_string("9"), kproto.krunker_msgpack_array([]kproto.Krunker_Msgpack_Value{
			kproto.krunker_msgpack_int(12), kproto.krunker_msgpack_float(1), kproto.krunker_msgpack_float(2), kproto.krunker_msgpack_float(3), kproto.krunker_msgpack_nil(), kproto.krunker_msgpack_nil(),
			kproto.krunker_msgpack_int(0), kproto.krunker_msgpack_float(0), kproto.krunker_msgpack_float(0), kproto.krunker_msgpack_float(10), kproto.krunker_msgpack_float(0)})}
		kproto.krunker_world_apply_packet(&client.krunker_world, tracer)
		h := []kproto.Krunker_Msgpack_Value{kproto.krunker_msgpack_string("h"), kproto.krunker_msgpack_float(40), kproto.krunker_msgpack_int(13)}
		kproto.krunker_world_apply_packet(&client.krunker_world, h)
		spectator_update(client, {}, now + 2.5, 1.0/60)
		clear(&client.krunker_world.shots)
		testing.expect(t, client.spectator.hits_shown == 2, "another player's tracer and the victim's health drop are not our hit")
		// Free cam has no stream (fpSp null):
		spectator_update(client, {free = true}, now + 3, 1.0/60)
		spectate_test_do_damage(client, now + 4, 12, 30)
		spectator_update(client, {}, now + 4, 1.0/60)
		testing.expect(t, client.spectator.hits_shown == 2, "no markers in free cam")
	}

	@(test)
	spectator_crosshair_always_show_while_scoped :: proc(t: ^testing.T) {
		client: Client
		client.crosshair_settings = client_settings_defaults().crosshair
		client.spectator.aim = 1 // The followed player is fully aimed in (scoped).
		settings := menuui.crosshair_settings_validate(client.crosshair_settings)
		testing.expect(t, spectator_crosshair_opacity(&client, settings) == 0, "by default the followed player's ADS hides it, as in Krunker")
		settings.toggles[.ALWAYS_SHOW] = true
		testing.expect(t, spectator_crosshair_opacity(&client, settings) == 1, "Always Show keeps it while the followed player is scoped")
		client.spectator.aim = 0.4
		testing.expect(t, spectator_crosshair_opacity(&client, settings) == 1)
	}

	@(private = "file")
	g_spectate_held: [dynamic]i32

	@(private = "file")
	spectate_test_read :: proc(window: glfw.WindowHandle, code: i32) -> bool {
		for held in g_spectate_held { if held == code { return true } }
		return false
	}

	@(test)
	spectator_free_cam_ctrl_moves_down_like_q :: proc(t: ^testing.T) {
		defer { delete(g_spectate_held); g_spectate_held = nil }
		client: Client
		client.bindings = menuui.default_bindings()
		client.mouse_state.locked = true
		testing.expect(t, client.bindings[.SPECTATOR_DOWN] == ([2]i32{glfw.KEY_LEFT_CONTROL, glfw.KEY_RIGHT_CONTROL}), "free cam down defaults to Left/Right Ctrl")
		testing.expect(t, menuui.binding_visible(.SPECTATOR_DOWN) == KRODIN_SPECTATOR, "the bind is listed only in the spectator build")
		testing.expect(t, client.bindings[.CROUCH][0] != glfw.KEY_LEFT_CONTROL && client.bindings[.CROUCH][1] != glfw.KEY_LEFT_CONTROL, "Ctrl is not the crouch bind")

		// Height after one second of free cam with these keys held.
		fly := proc(client: ^Client, keys: []i32) -> f32 {
			clear(&g_spectate_held)
			append(&g_spectate_held, ..keys)
			client.spectator.mode, client.spectator.free_speed, client.spectator.free_position = .FREE, 1, {0, 100, 0}
			for _ in 0 ..< 60 { spectator_free_camera(client, spectator_read_input(client, {}, spectate_test_read), 1.0/60) }
			return client.camera.position.y - 100
		}
		q := fly(&client, {glfw.KEY_Q})
		left_ctrl := fly(&client, {glfw.KEY_LEFT_CONTROL})
		right_ctrl := fly(&client, {glfw.KEY_RIGHT_CONTROL})
		space := fly(&client, {glfw.KEY_SPACE})
		e := fly(&client, {glfw.KEY_E})
		ctrl_shift := fly(&client, {glfw.KEY_LEFT_CONTROL, glfw.KEY_LEFT_SHIFT})
		q_shift := fly(&client, {glfw.KEY_Q, glfw.KEY_LEFT_SHIFT})
		testing.expectf(t, q < -50 && abs(left_ctrl - q) < 1e-3 && abs(right_ctrl - q) < 1e-3, "Ctrl lowers the camera as fast as Q (%v, %v, %v)", q, left_ctrl, right_ctrl)
		testing.expectf(t, abs(space + q) < 1e-3 && abs(e + q) < 1e-3, "Space and E rise at the same speed (%v, %v)", space, e)
		testing.expectf(t, abs(ctrl_shift - 2.5*q) < 1e-2 && abs(q_shift - ctrl_shift) < 1e-3, "Shift still speeds descent up (%v vs %v)", ctrl_shift, q)
		// A rebind is honoured.
		client.bindings[.SPECTATOR_DOWN] = {glfw.KEY_C, 0}
		testing.expect(t, fly(&client, {glfw.KEY_LEFT_CONTROL}) == 0 && abs(fly(&client, {glfw.KEY_C}) - q) < 1e-3, "rebinding moves descent to the new key")
		// Holding Ctrl reads no gameplay bind (spectators build no input anyway).
		client.bindings = menuui.default_bindings()
		clear(&g_spectate_held); append(&g_spectate_held, glfw.KEY_LEFT_CONTROL)
		held, _ := client_gameplay_bound_input(&client, spectate_test_read)
		testing.expect(t, !held.crouch && !held.jump && held.move_dir < 0, "Ctrl presses no gameplay bind")

		// Older settings files without the bind get Ctrl.
		path := "bin/spectator-bind-migration-test.json"
		defer os.remove(path)
		testing.expect(t, os.write_entire_file(path, `{"version":1,"bindings":{"LEADERBOARD":[76,0]}}`) == nil)
		migrated := client_settings_load(path)
		testing.expect(t, migrated.bindings[.SPECTATOR_DOWN] == ([2]i32{glfw.KEY_LEFT_CONTROL, glfw.KEY_RIGHT_CONTROL}), "older preferences get Ctrl")
	}
}
