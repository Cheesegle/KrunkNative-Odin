package krunker

import "core:math"
import shared "../shared"

// CHANGE_HEALTH(health, sid?, hitX?, hitZ?, silent?, resetMax?). An omitted
// SID addresses the local player; remote health changes carry a numeric SID.
krunker_world_apply_health :: proc(state: ^Krunker_World_State, packet: []Krunker_Msgpack_Value) -> bool {
	if len(packet) < 2 { return false }
	health, valid := krunker_world_number(packet[1])
	if !valid || math.is_nan(health) || math.is_inf(health) || health < 0 || health > 10000 { return false }
	sid := state.local_sid
	if len(packet) > 2 {
		if _, absent := packet[2].(Krunker_Msgpack_Nil); !absent { sid = krunker_world_i32(packet[2], -1) }
	}
	if sid < 0 { return false }
	player := krunker_world_upsert_player(state, sid)
	// h is (health, sid, x, z, silent, reset max). A local drop that is not
	// silent and names a position adds a hit indicator toward it.
	silent := len(packet) > 5 && krunker_world_bool(packet[5])
	// Krunker's CHANGE_HEALTH plays takedmg on every non-silent local drop.
	if sid == state.local_sid && f32(health) < player.health && !silent { state.health_drop_revision += 1 }
	if sid == state.local_sid && f32(health) < player.health && len(packet) > 4 && !silent {
		x, x_ok := krunker_world_number(packet[3])
		z, z_ok := krunker_world_number(packet[4])
		if x_ok && z_ok && !math.is_nan(x) && !math.is_nan(z) && !math.is_inf(x) && !math.is_inf(z) {
			state.damage_source = {f32(x), f32(z)}
			state.damage_revision += 1
		}
	}
	player.health = f32(health)
	if player.health > player.max_health || len(packet) > 6 && krunker_world_bool(packet[6]) {
		player.max_health = max(1, player.health)
	}
	player.revision += 1
	return true
}

// Death and disconnect messages must stop stale overhead bars immediately.
krunker_world_apply_player_gone :: proc(state: ^Krunker_World_State, packet: []Krunker_Msgpack_Value) -> bool {
	if len(packet) < 2 { return false }
	sid := krunker_world_i32(packet[1], -1)
	for &player in state.players {
		if player.sid != sid { continue }
		opcode, _ := packet[0].(string)
		numeric, _ := packet[0].(i64)
		if sid == state.local_sid && !player.life_ended && (opcode == "3" || numeric == 3) {
			// Browser deathDelay: 0xaf0 ms. Disconnects and round switches
			// do not impose a death cooldown; duplicate deaths do not extend it.
			state.respawn_available_at = state.received_at + 2.8
		}
		player.health = 0
		player.active = false
		player.life_ended = true
		if sid == state.local_sid { state.in_game = false }
		// REMOVE_PLAYER(2) has no death count; KILL_PLAYER(3) does.
		if (opcode == "3" || numeric == 3) && len(packet) > 2 {
			if deaths, ok := krunker_world_bounded_number(packet[2], 0, 2147483647); ok { player.deaths = u32(deaths) }
			if sid == state.local_sid {
				state.local_killer_sid = -1
				if len(packet) > 3 {
					if killer, ok := krunker_world_bounded_number(packet[3], 0, 2147483647); ok { state.local_killer_sid = i32(killer) }
				}
				state.local_death = {}
				if len(packet) > 4 { state.local_death = krunker_world_death_info(packet[4]) }
				state.local_death_revision += 1
			}
			krunker_world_record_kill(state, sid, packet)
		}
		player.pose_count = 0
		player.revision += 1
		return true
	}
	return false
}

// One KILL_PLAYER killfeed line. weapon_id is -1 when the info object has no
// wId; the browser then shows the killer's currently equipped weapon.
Krunker_World_Kill :: struct {
	victim_sid, killer_sid, weapon_id, streak: i32,
	headshot, wallbang, fists, thrown: bool,
}

KRUNKER_WORLD_MAX_KILLS :: 32

// KILL_PLAYER(3) is [3, victim sid, deaths, killer sid, death-screen data,
// kill info, hide]. The browser handler (game.deob.js iiïîîìî) adds a
// killfeed line unless the last argument is set; killer null means the
// victim "committed" a suicide. The info object carries wId (weapon), hs
// (headshot), wb (wallbang), fs (fists), pj (thrown melee) and stk (streak).
krunker_world_record_kill :: proc(state: ^Krunker_World_State, victim_sid: i32, packet: []Krunker_Msgpack_Value) {
	if len(packet) > 6 && krunker_world_bool(packet[6]) { return }
	kill := Krunker_World_Kill{victim_sid = victim_sid, killer_sid = -1, weapon_id = -1, streak = -1}
	if len(packet) > 3 {
		if sid, ok := krunker_world_bounded_number(packet[3], 0, 2147483647); ok { kill.killer_sid = i32(sid) }
	}
	if len(packet) > 5 {
		if entries, ok := packet[5].([]Krunker_Msgpack_Map_Entry); ok {
			for entry in entries {
				key, textual := entry.key.(string); if !textual { continue }
				switch key {
				case "wId":
					if id, valid := krunker_world_bounded_number(entry.value, 0, f64(len(shared.WEAPONS_LIST)-1)); valid && shared.WEAPONS_LIST[int(id)] != nil { kill.weapon_id = i32(id) }
				case "hs": kill.headshot = krunker_world_bool(entry.value)
				case "wb": kill.wallbang = krunker_world_bool(entry.value)
				case "fs": kill.fists = krunker_world_bool(entry.value)
				case "pj": kill.thrown = krunker_world_bool(entry.value)
				case "stk":
					if streak, valid := krunker_world_bounded_number(entry.value, 0, 1000); valid { kill.streak = i32(streak) }
				}
			}
		}
	}
	if len(state.kills) >= KRUNKER_WORLD_MAX_KILLS { ordered_remove(&state.kills, 0) }
	append(&state.kills, kill)
}

// One value of KILL_PLAYER's death-screen data. The browser prints numbers
// and strings as they come and "Unknown" for a missing stat.
Krunker_Death_Value :: struct {
	known: bool,
	number: f64,
	is_text: bool,
	text: [24]u8,
	text_len: int,
}

// KILL_PLAYER(3)'s fourth argument, read by the browser's death UI builder
// (krunkbox game.deob.js line ~227456, `iìÏïîíì`):
//   [0] the weapon id that killed you ("death-row-weapon-text"/-img)
//   [1] the killer's class XP: lvl = max(1, floor(0.03*sqrt(xp)) + 1)
//   [2] [value, index] of one killer career stat, index into SPK, Kills,
//       Deaths, KDR, KPG, Games Played, Wins, W/L, Nukes
//   [3] Time Survived (ms), Shots Fired, Accuracy, Kills, Score
Krunker_Death_Info :: struct {
	weapon_id: i32,
	killer_xp: Krunker_Death_Value,
	stat: Krunker_Death_Value,
	stat_index: i32,
	stats: [5]Krunker_Death_Value,
	has_stats: bool,
}

KRUNKER_DEATH_STAT_NAMES := [?]string{"SPK", "Kills", "Deaths", "KDR", "KPG", "Games Played", "Wins", "W/L", "Nukes"}

krunker_world_death_value :: proc(value: Krunker_Msgpack_Value) -> (result: Krunker_Death_Value) {
	#partial switch typed in value {
	case string:
		result.known, result.is_text = true, true
		result.text_len = copy(result.text[:], typed)
		// Never split a UTF-8 code point.
		for result.text_len > 0 && result.text_len < len(typed) && typed[result.text_len] & 0xc0 == 0x80 { result.text_len -= 1 }
	case:
		if number, ok := krunker_world_number(value); ok && !math.is_nan(number) && !math.is_inf(number) {
			result.known, result.number = true, number
		}
	}
	return
}

krunker_world_death_info :: proc(value: Krunker_Msgpack_Value) -> (info: Krunker_Death_Info) {
	info.weapon_id, info.stat_index = -1, -1
	items, ok := value.([]Krunker_Msgpack_Value)
	if !ok { return }
	if len(items) > 0 {
		if id, valid := krunker_world_bounded_number(items[0], 0, f64(len(shared.WEAPONS_LIST)-1)); valid && shared.WEAPONS_LIST[int(id)] != nil { info.weapon_id = i32(id) }
	}
	if len(items) > 1 { info.killer_xp = krunker_world_death_value(items[1]) }
	if len(items) > 2 {
		if pair, is_pair := items[2].([]Krunker_Msgpack_Value); is_pair && len(pair) > 1 {
			if index, valid := krunker_world_bounded_number(pair[1], 0, f64(len(KRUNKER_DEATH_STAT_NAMES)-1)); valid {
				info.stat_index = i32(index)
				info.stat = krunker_world_death_value(pair[0])
			}
		}
	}
	if len(items) > 3 {
		if stats, is_list := items[3].([]Krunker_Msgpack_Value); is_list {
			info.has_stats = true
			for i in 0..<min(len(stats), len(info.stats)) { info.stats[i] = krunker_world_death_value(stats[i]) }
		}
	}
	return
}

krunker_death_value_text :: proc(value: ^Krunker_Death_Value) -> string { return string(value.text[:value.text_len]) }
