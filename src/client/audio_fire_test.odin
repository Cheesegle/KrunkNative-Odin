package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import ma "vendor:miniaudio"
import shared "../shared"
import kproto "../krunker"

when ODIN_TEST {
	audio_fire_weapon :: proc(weapons: []^shared.Weapon, name: string) -> (id: i32, weapon: ^shared.Weapon) {
		for w, i in weapons { if w != nil && w.name == name { return i32(i), w } }
		return -1, nil
	}

	// Seconds between rounds when the trigger is held (or spammed at the cap).
	audio_fire_interval :: proc(weapon: ^shared.Weapon, round: int) -> f32 {
		if weapon.burst && weapon.burst_count > 1 {
			return round % int(weapon.burst_count) == int(weapon.burst_count) - 1 ? weapon.rate : weapon.burst_rate
		}
		return weapon.rate
	}

	@(test)
	audio_every_weapon_sound_exists :: proc(t: ^testing.T) {
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		missing := 0
		for weapon in config.weapons {
			if weapon == nil { continue }
			paths := []string{audio_weapon_path(weapon)}
			if weapon.melee && len(weapon.sound) == 0 {
				paths = []string{fmt.tprintf("%ssound/swsh_def_0.mp3", shared.assets_path()), fmt.tprintf("%ssound/swsh_def_1.mp3", shared.assets_path())}
			}
			for path in paths {
				if !os.exists(path) { missing += 1; testing.expectf(t, false, "%s resolves to missing %s", weapon.name, path) }
			}
		}
		for name in ([]string{"reload_1", "takedmg_0", "takedmg_1", "hit_0", "crit_0", "headshot_0", "step_0", "step_1", "explosion"}) {
			testing.expectf(t, os.exists(fmt.tprintf("%ssound/%s.mp3", shared.assets_path(), name)), "%s.mp3 must exist", name)
		}
		testing.expect(t, missing == 0)
	}

	Fire_Case :: struct { name: string, spam: bool }
	AUDIO_FIRE_CASES := [?]Fire_Case{
		{"Submachine Gun", false}, {"Auto Pistol", false}, {"Akimbo Uzi", false},
		{"Semi Auto", true}, {"Revolver", true}, {"Famas", true},
	}

	@(test)
	audio_rapid_fire_plays_every_round :: proc(t: ^testing.T) {
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		for c in AUDIO_FIRE_CASES {
			id, weapon := audio_fire_weapon(config.weapons, c.name)
			if !testing.expectf(t, weapon != nil, "%s exists", c.name) { continue }
			// Offline / local: every FIRE event starts its own voice, nothing is cut.
			audio := audio_create(config.weapons, DEFAULT_AUDIO_SETTINGS, true)
			if !testing.expect(t, audio != nil) { return }
			defer audio_destroy(audio)
			client := Client{audio = audio}
			client.game.weapons = config.weapons
			me := shared.Player{uid = 1}
			client.me = &me
			rounds, elapsed := 0, f32(0)
			buffer: [480*2]f32
			for elapsed < 1 {
				before := audio.serial
				client_audio_present(&client, {kind = .FIRE, uid = 1, weapon_id = id})
				testing.expectf(t, audio.serial == before + 1, "%s round %d must start a voice", c.name, rounds)
				rounds += 1
				gap := audio_fire_interval(weapon, rounds - 1)
				frames := int(gap * 48000)
				for frames > 0 { n := min(frames, 480); ma.engine_read_pcm_frames(&audio.engine, &buffer[0], u64(n), nil); frames -= n }
				elapsed += gap
			}
			testing.expectf(t, audio.steals == 0, "%s: no round may cut an earlier one short (%d steals)", c.name, audio.steals)
		}
		// Native snapshots that batch rounds schedule them at the fire interval.
		audio := audio_create(config.weapons, DEFAULT_AUDIO_SETTINGS, true)
		defer audio_destroy(audio)
		client := Client{audio = audio}
		client.game.weapons = config.weapons
		me := shared.Player{uid = 1}
		client.me = &me
		id, _ := audio_fire_weapon(config.weapons, "Submachine Gun")
		client_audio_present(&client, {kind = .FIRE, uid = 1, weapon_id = id})
		client_audio_present(&client, {kind = .FIRE, uid = 1, weapon_id = id, delay = 0.095})
		delayed: ^Audio_Voice
		for &v in audio.voices { if v.serial == audio.serial { delayed = &v } }
		now := ma.engine_get_time_in_pcm_frames(&audio.engine)
		testing.expect(t, delayed != nil && delayed.starts_at == now + 4560 && audio_voice_busy(audio, delayed), "a delayed round waits 95 ms and keeps its voice")
		client_audio_present(&client, {kind = .FIRE, uid = 1, weapon_id = id})
		testing.expect(t, audio.steals == 0 && delayed.starts_at == now + 4560, "a scheduled voice is not reused before it starts")
	}

	// Feeds a remote player's shot packets through the live presentation path,
	// arriving with up to +-15 ms of network jitter, and counts sounds started.
	// `gated` replays the pre-fix rule (sound only when the local fire-rate
	// cooldown had elapsed) to measure what was lost.
	audio_live_fire_sounds :: proc(t: ^testing.T, weapons: []^shared.Weapon, name: string, gated: bool, render: []f32 = nil) -> (rounds, sounds: int) {
		client: Client
		map_inst: shared.Map
		krunker_presentation_fixture(&client, &map_inst)
		defer krunker_presentation_cleanup(&client)
		client.game.weapons = weapons
		client.game.presentation_enabled = true
		client.audio = audio_create(weapons, DEFAULT_AUDIO_SETTINGS, true)
		defer audio_destroy(client.audio)
		id, weapon := audio_fire_weapon(weapons, name)
		remote := shared.player_init(&client.game)
		shared.game_players_add(&client.game, remote)
		shared.player_spawn(remote, 0)
		remote.uid, remote.position, remote.active = 42, {0, 0, -20}, true
		remote.loadout[0], remote.loadout_index, remote.weapon = id, 0, weapon
		remote.ammo[0] = weapon.ammo
		state: u32 = 12345
		next_shot, time := f32(0.05), f32(0)
		step := f32(1.0 / 144)
		written := 0
		for time < 1 {
			for time >= next_shot && next_shot < 1 {
				pellets := max(weapon.shots, 1)
				for _ in 0 ..< pellets { append(&client.krunker_world.shots, kproto.Krunker_World_Shot{sid = 42, origin = remote.position, position = {0, 0, -100}}) }
				rounds += 1
				state = state*1664525 + 1013904223
				jitter := (f32(state >> 8) / f32(1 << 24) - 0.5) * 0.03
				next_shot += audio_fire_interval(weapon, rounds - 1) + jitter
			}
			before := client.audio.serial
			if gated {
				// Pre-fix behaviour: FIRE only when the remote cooldown was zero.
				for _ in client.krunker_world.shots {
					if remote.reloads[0] <= 0 {
						shared.player_emit_presentation(remote, .FIRE)
						remote.reloads[0] = weapon.rate * client.game.config.fire_rate
					}
				}
				clear(&client.krunker_world.shots)
			} else {
				krunker_client_present_shots(&client)
			}
			for event in client.game.presentation_events { if event.kind == .FIRE { client_audio_present(&client, event) } }
			clear(&client.game.presentation_events)
			sounds += int(client.audio.serial - before)
			remote.reloads[0] = max(0, remote.reloads[0] - step)
			target := int((time + step) * 48000)
			if render != nil && target*2 <= len(render) {
				ma.engine_read_pcm_frames(&client.audio.engine, &render[written*2], u64(target - written), nil)
				written = target
			} else {
				buffer: [700*2]f32
				ma.engine_read_pcm_frames(&client.audio.engine, &buffer[0], u64(target - written), nil)
				written = target
			}
			time += step
		}
		testing.expectf(t, client.audio.steals == 0, "%s live: no voice may be cut short", name)
		return
	}

	@(test)
	audio_live_remote_fire_plays_every_round :: proc(t: ^testing.T) {
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		for c in AUDIO_FIRE_CASES {
			rounds, after := audio_live_fire_sounds(t, config.weapons, c.name, false)
			_, before := audio_live_fire_sounds(t, config.weapons, c.name, true)
			fmt.printf("[Audio fire] %s: %d rounds in 1 s, live sounds before %d, after %d\n", c.name, rounds, before, after)
			testing.expectf(t, after == rounds, "%s: every remote round must sound (%d of %d)", c.name, after, rounds)
		}
		// A shotgun's pellets are one trigger pull: one sound, not five.
		rounds, sounds := audio_live_fire_sounds(t, config.weapons, "Shotgun", false)
		testing.expectf(t, sounds == rounds, "shotgun pellets must sound once per shot (%d sounds, %d shots)", sounds, rounds)
	}

	@(test)
	audio_damage_sound_matches_krunker :: proc(t: ^testing.T) {
		audio := audio_create(nil, audio_test_settings(), true)
		if !testing.expect(t, audio != nil) { return }
		defer audio_destroy(audio)
		client := Client{audio = audio}
		me := shared.Player{uid = 1}
		client.me = &me
		count_damage :: proc(audio: ^Audio_System) -> (n: int) {
			for &v in audio.voices { if v.sample != nil && bool(ma.sound_is_playing(&v.sound)) && v.gain == 0.45 { n += 1 } }
			return
		}
		// Offline/native: every local DAMAGE event, throttled like Krunker.
		client_audio_tick(&client, 1)
		client.game.presentation_enabled = true
		shared.game_emit_presentation(&client.game, {kind = .DAMAGE, uid = 1})
		client_audio_tick(&client, 0.1)
		testing.expect(t, count_damage(audio) == 1, "a local health drop plays takedmg at 0.45")
		for _ in 0 ..< 5 {
			shared.game_emit_presentation(&client.game, {kind = .DAMAGE, uid = 1})
			client_audio_tick(&client, 0.1)
		}
		testing.expect(t, count_damage(audio) == 1, "drops less than 500 ms apart stay silent (sustained fire sounds once)")
		client_audio_tick(&client, 0.6)
		shared.game_emit_presentation(&client.game, {kind = .DAMAGE, uid = 1})
		client_audio_tick(&client, 0.01)
		testing.expect(t, count_damage(audio) == 2, "after a 500 ms pause the next drop sounds again")
		shared.game_emit_presentation(&client.game, {kind = .DAMAGE, uid = 2})
		client_audio_tick(&client, 1)
		testing.expect(t, count_damage(audio) <= 2 && audio.last_health_drop < audio.clock - 0.9, "other players' damage is not yours")
		// Live: CHANGE_HEALTH ("h") drives it, including drops without a hit position; silent drops do not.
		audio_stop_all(audio)
		client.krunker.connected = true
		world := &client.krunker_world
		world.local_sid = 1
		kproto.krunker_world_upsert_player(world, 1).health = 100
		testing.expect(t, kproto.krunker_world_apply_health(world, []kproto.Krunker_Msgpack_Value{"h", i64(80)}))
		client_audio_tick(&client, 1)
		testing.expect(t, count_damage(audio) == 1, "a live health drop plays the damage sound")
		testing.expect(t, kproto.krunker_world_apply_health(world, []kproto.Krunker_Msgpack_Value{"h", i64(60), kproto.Krunker_Msgpack_Nil{}, i64(0), i64(0), true}))
		client_audio_tick(&client, 1)
		testing.expect(t, count_damage(audio) == 1, "silent drops make no sound")
		shared.game_emit_presentation(&client.game, {kind = .DAMAGE, uid = 1})
		client_audio_tick(&client, 1)
		testing.expect(t, count_damage(audio) == 1, "live lobbies do not double the sound from roster metadata")
		kproto.krunker_world_reset(world)
		delete(client.game.presentation_events)
	}

	@(test)
	audio_remote_reload_is_quiet_and_positional :: proc(t: ^testing.T) {
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		audio := audio_create(config.weapons, audio_test_settings(), true)
		if !testing.expect(t, audio != nil) { return }
		defer audio_destroy(audio)
		client := Client{audio = audio}
		client.game.weapons = config.weapons
		me := shared.Player{uid = 1}
		client.me = &me
		camera := camera_init(1)
		audio_update_listener(audio, &camera)
		last_voice :: proc(audio: ^Audio_System) -> ^Audio_Voice {
			for &v in audio.voices { if v.serial == audio.serial { return &v } }
			return nil
		}
		client_audio_present(&client, {kind = .RELOAD, uid = 1})
		local := last_voice(audio)
		testing.expect(t, local != nil && !local.spatial && local.gain == 0.7 && local.channel == .WEAPONS, "the local reload is unchanged")
		client_audio_present(&client, {kind = .RELOAD, uid = 9, position = {30, 0, 0}})
		remote := last_voice(audio)
		if !testing.expect(t, remote != nil && remote.spatial && remote.position == {30, 0, 0} && remote.channel == .WEAPONS, "a remote reload plays at the reloader") { return }
		reload_gain := remote.node.pending.gain * remote.gain
		id, _ := audio_fire_weapon(config.weapons, "Submachine Gun")
		client_audio_present(&client, {kind = .FIRE, uid = 9, weapon_id = id, position = {30, 0, 0}})
		shot := last_voice(audio)
		testing.expectf(t, reload_gain < 0.5 * shot.node.pending.gain * shot.gain, "a remote reload is well below a gunshot at the same distance (%.3f vs %.3f)", reload_gain, shot.node.pending.gain * shot.gain)
		before := audio.serial
		client_audio_present(&client, {kind = .RELOAD, uid = 9, position = {0, 0, -200}})
		testing.expect(t, audio.serial == before, "remote reloads beyond 170 units are culled")
		// Live lobbies stay silent, as in Krunker: no packet reports another
		// player's reload (k has no reload state; the only reload-sound
		// playSound is reload_3 for ammo pickups), so shot packets never start one.
		fixture: Client
		map_inst: shared.Map
		krunker_presentation_fixture(&fixture, &map_inst)
		defer krunker_presentation_cleanup(&fixture)
		fixture.game.presentation_enabled = true
		remote_player := shared.player_init(&fixture.game)
		shared.game_players_add(&fixture.game, remote_player)
		shared.player_spawn(remote_player, 0)
		remote_player.uid, remote_player.active = 42, true
		reloads := 0
		for _ in 0 ..< int(remote_player.weapon.ammo) + 2 {
			append(&fixture.krunker_world.shots, kproto.Krunker_World_Shot{sid = 42, position = {0, 0, -50}})
			krunker_client_present_shots(&fixture)
			for e in fixture.game.presentation_events { if e.kind == .RELOAD { reloads += 1 } }
			clear(&fixture.game.presentation_events)
			clear(&fixture.game.impacts)
		}
		testing.expect(t, reloads == 0, "live remote reloads are not invented")
	}

	// Before/after listening files: 1 s of a remote SMG and Revolver.
	when #config(AUDIO_SPATIAL_DEMO, false) {
		@(test)
		audio_fire_demo_render :: proc(t: ^testing.T) {
			config := shared.config_load_gameplay()
			defer shared.config_destroy_gameplay(config)
			os.make_directory("bin/spatial-audio")
			for name in ([]string{"Submachine Gun", "Revolver"}) {
				for gated in ([]bool{true, false}) {
					pcm := make([]f32, 48000*2)
					defer delete(pcm)
					audio_live_fire_sounds(t, config.weapons, name, gated, pcm)
					peak: f32
					for v in pcm { peak = max(peak, abs(v)) }
					bytes := make([]u8, 44 + len(pcm)*2)
					defer delete(bytes)
					put_u32 :: proc(b: []u8, at: int, v: u32) { b[at], b[at+1], b[at+2], b[at+3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24) }
					put_u16 :: proc(b: []u8, at: int, v: u16) { b[at], b[at+1] = u8(v), u8(v >> 8) }
					copy(bytes[0:], "RIFF"); put_u32(bytes, 4, u32(36 + len(pcm)*2)); copy(bytes[8:], "WAVEfmt ")
					put_u32(bytes, 16, 16); put_u16(bytes, 20, 1); put_u16(bytes, 22, 2)
					put_u32(bytes, 24, 48000); put_u32(bytes, 28, 48000*4); put_u16(bytes, 32, 4); put_u16(bytes, 34, 16)
					copy(bytes[36:], "data"); put_u32(bytes, 40, u32(len(pcm)*2))
					scale := 0.89 / max(peak, 1e-6)
					for v, i in pcm { put_u16(bytes, 44 + i*2, transmute(u16)i16(clamp(v * scale, -1, 1) * 32767)) }
					file := name == "Revolver" ? "revolver" : "smg"
					out := fmt.tprintf("bin/spatial-audio/remote_%s_%s.wav", file, gated ? "before" : "after")
					testing.expect(t, os.write_entire_file(out, bytes) == nil)
					fmt.printf("[Audio demo] wrote %s\n", out)
				}
			}
		}
	}
}
