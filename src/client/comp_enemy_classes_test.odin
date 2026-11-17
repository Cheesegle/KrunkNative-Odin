package main

import "core:strings"
import "core:testing"
import kproto "../krunker"
import menuui "../menu"

when ODIN_TEST {
	@(test)
	competitive_roster_hides_only_enemy_classes :: proc(t: ^testing.T) {
		players := []menuui.Player{
			{name = "You", class_name = "Hunter", team = 1, is_you = true},
			{name = "Mate", class_name = "Rocketeer", team = 1},
			{name = "Enemy", class_name = "Triggerman", team = 2},
			{name = "Picking", class_name = "Choosing class", team = 2},
		}
		menuui.competitive_roster_hide_enemy_classes(players, 0)
		testing.expect(t, players[0].class_name == "Hunter" && players[1].class_name == "Rocketeer", "you and your teammates keep your classes")
		testing.expect(t, players[2].class_name == "???" && players[3].class_name == "???", "the other team's classes read ??? as in Krunker's comp lobby")

		// Your own row decides the team; without one the lobby team does.
		others := []menuui.Player{{name = "A", class_name = "Hunter", team = 2}, {name = "B", class_name = "Detective", team = 1}}
		menuui.competitive_roster_hide_enemy_classes(others, 2)
		testing.expect(t, others[0].class_name == "Hunter" && others[1].class_name == "???", "the lobby team stands in before your row arrives")

		// Spectating (Krunker's `e.t||0`): every player is on another team.
		spectating := []menuui.Player{{name = "A", class_name = "Hunter", team = 1}, {name = "B", class_name = "Detective", team = 2}}
		menuui.competitive_roster_hide_enemy_classes(spectating, 0)
		testing.expect(t, spectating[0].class_name == "???" && spectating[1].class_name == "???", "without a team every class is hidden")
	}

	@(test)
	competitive_menu_view_hides_enemy_classes :: proc(t: ^testing.T) {
		client := Client{krunker = {connected = true}}
		defer kproto.krunker_world_reset(&client.krunker_world)
		defer { delete(menu_portraits); menu_portraits = nil }
		config := []kproto.Krunker_Msgpack_Map_Entry{{"maxPlayers", i64(10)}, {"tmSize", i64(1)}}
		packet: [18]kproto.Krunker_Msgpack_Value
		packet[0], packet[1], packet[2], packet[7], packet[16] = "init", i64(2), i64(2), config, true
		if !testing.expect(t, kproto.krunker_world_apply_init(&client.krunker_world, packet[:])) do return
		client.krunker_world.local_connection_uid = strings.clone("me")
		append(&client.krunker_world.lobby_players,
			kproto.Krunker_Lobby_Player{id = strings.clone("me"), name = strings.clone("Me"), team = 1, class_index = -1, active = true},
			kproto.Krunker_Lobby_Player{id = strings.clone("mate"), name = strings.clone("Mate"), team = 1, class_index = -1, active = true},
			kproto.Krunker_Lobby_Player{id = strings.clone("enemy"), name = strings.clone("Enemy"), team = 2, class_index = -1, active = true})
		view := menu_view(&client)
		if !testing.expect(t, view.presentation == .COMPETITIVE && len(view.players) == 3) do return
		testing.expect(t, view.players[0].is_you && view.players[0].class_name != "???" && view.players[1].class_name != "???", "your team's classes stay visible in comp")
		testing.expect(t, view.players[2].class_name == "???", "the enemy team's class is hidden in comp")

		// Outside comp/ranked the lobby keeps showing every class.
		client.krunker_world.is_comp, client.krunker_world.is_ranked = false, false
		view = menu_view(&client)
		testing.expect(t, view.presentation == .STANDARD && view.players[2].class_name != "???", "standard lobbies keep enemy classes")
	}
}
