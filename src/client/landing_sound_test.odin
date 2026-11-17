package main

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import shared "../shared"

when ODIN_TEST {
	@(private = "file")
	land_test_game :: proc(client: ^Client, config: ^shared.Gameplay_Config, map_inst: ^shared.Map) {
		shared.game_configure(&client.game, &config.game, []^shared.Map{map_inst}, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, 0, true)
		client.game.presentation_enabled = true
	}

	@(private = "file")
	land_test_count :: proc(game: ^shared.Game, kind: shared.Presentation_Kind) -> int {
		count := 0
		for event in game.presentation_events { if event.kind == kind { count += 1 } }
		clear(&game.presentation_events)
		return count
	}

	// Krunker's resetStep runs when a player who was off the ground comes down
	// onto something; a jump lands once, walking and standing never do, and a
	// reconciliation replay never repeats a landing.
	@(test)
	landing_triggers_once_per_landing :: proc(t: ^testing.T) {
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		floor := shared.Object{active = true, collision_type = .BOX, position = {0, -10, 0}, scale = {2000, 10, 2000}}
		map_inst := shared.Map{death_y = -1000, config = shared.DEFAULT_MAP_CONFIG}
		append(&map_inst.objects, &floor)
		defer delete(map_inst.objects)
		client: Client
		land_test_game(&client, config, &map_inst)
		defer { client_clear_players(&client); shared.game_destroy(&client.game) }
		player := shared.player_init(&client.game)
		shared.game_players_add(&client.game, player)
		shared.player_spawn(player, 0)
		player.uid, player.active, player.is_you, player.render_you = 1, true, true, true
		player.position, player.last_position, player.on_ground = {}, {}, true

		tick :: proc(player: ^shared.Player, jump: bool, move_dir: i32, recon := false, predict := false) {
			input := shared.Input{delta = 1.0 / 60.0, move_dir = move_dir, jump = jump, x_dir = player.direction.x, y_dir = player.direction.y}
			shared.player_proc_input(player, &input, recon, false, predict)
		}
		for _ in 0 ..< 60 { tick(player, false, -1) }
		testing.expect(t, land_test_count(&client.game, .LAND) == 0 && player.on_ground, "standing still never lands")
		for _ in 0 ..< 120 { tick(player, false, 0) }
		testing.expect(t, land_test_count(&client.game, .LAND) == 0, "walking on flat ground never lands")

		tick(player, true, -1)
		testing.expect(t, !player.on_ground && land_test_count(&client.game, .JUMP) == 1)
		airborne := 0
		for _ in 0 ..< 240 {
			tick(player, false, -1)
			if player.on_ground { break }
			airborne += 1
		}
		testing.expectf(t, player.on_ground && airborne > 5, "the jump comes back down (%d ticks in the air)", airborne)
		testing.expect(t, land_test_count(&client.game, .LAND) == 1, "a jump lands exactly once")
		for _ in 0 ..< 30 { tick(player, false, -1) }
		testing.expect(t, land_test_count(&client.game, .LAND) == 0, "no landing while staying on the ground")

		// A fall from a height, as a reconciliation replay and as fresh prediction.
		for predict in ([2]bool{false, true}) {
			player.position, player.last_position, player.velocity, player.on_ground = {0, 30, 0}, {0, 30, 0}, {}, false
			for _ in 0 ..< 240 {
				tick(player, false, -1, true, predict)
				if player.on_ground { break }
			}
			testing.expect(t, player.on_ground)
			testing.expectf(t, land_test_count(&client.game, .LAND) == (predict ? 1 : 0), "replay without effects stays silent, fresh prediction lands (predict %v)", predict)
		}
	}

	@(test)
	landing_condition_rules :: proc(t: ^testing.T) {
		testing.expect(t, shared.player_landed(false, true, -0.07), "a jump's landing speed")
		testing.expect(t, !shared.player_landed(true, true, -0.07), "already on the ground")
		testing.expect(t, !shared.player_landed(false, false, -0.07), "still in the air")
		testing.expect(t, !shared.player_landed(false, true, 0.01), "moving up onto a ledge is not a landing")
		testing.expect(t, !shared.player_landed(false, true, -0.005), "a single tick off the ground is not a landing")
		testing.expect(t, shared.player_remote_landed(false, true) && !shared.player_remote_landed(true, true) && !shared.player_remote_landed(false, false))
	}

	// Native snapshots: a remote player returning to the ground lands once.
	@(test)
	landing_native_remote_snapshots :: proc(t: ^testing.T) {
		// Snapshots build the remote's meshes, so this needs a GL context.
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(64, 64, "Landing", nil, nil)
		if !testing.expect(t, window != nil) { return }
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		map_inst := shared.Map{death_y = -1000, config = shared.DEFAULT_MAP_CONFIG}
		client := Client{window = window, scene = scene_init(), fps_scene = scene_init()}
		g_client = &client
		defer { g_client = nil }
		land_test_game(&client, config, &map_inst)
		client.game.is_local = false
		defer {
			client_clear_players(&client)
			shared.game_destroy(&client.game)
			scene_fini(client.fps_scene)
			scene_fini(client.scene)
			resource_cache_fini()
		}
		state := shared.Packet_Player_State{player_id = 5, team = 1, health = 100, max_health = 100, active = true, position = {10, 20, 0}}
		client_apply_player_state(&client, &state)
		remote := client_find_player(&client, 5)
		if !testing.expect(t, remote != nil) { return }
		state.weapon_id = auto_cast remote.loadout[0]
		clear(&client.game.presentation_events)
		state.position.y = 10
		client_apply_player_state(&client, &state)
		testing.expect(t, land_test_count(&client.game, .LAND) == 0, "still falling")
		state.position.y, state.on_ground = 0, true
		client_apply_player_state(&client, &state)
		events := len(client.game.presentation_events)
		landed := land_test_count(&client.game, .LAND)
		testing.expectf(t, landed == 1, "the snapshot that grounds the remote lands once (%d of %d events)", landed, events)
		client_apply_player_state(&client, &state)
		testing.expect(t, land_test_count(&client.game, .LAND) == 0, "staying on the ground does not land again")
	}

	// Krunker plays a Default footstep (step_0, step_1, step_0) at 0.7: yours
	// unpositioned, a remote one at their feet within the footstep range.
	@(test)
	landing_sound_matches_krunker :: proc(t: ^testing.T) {
		audio := audio_create(nil, audio_test_settings(spatial = .STEREO), true)
		if !testing.expect(t, audio != nil) { return }
		defer audio_destroy(audio)
		client := Client{audio = audio}
		me := shared.Player{uid = 1}
		client.me = &me
		camera := camera_init(1)
		audio_update_listener(audio, &camera)
		last_voice :: proc(audio: ^Audio_System) -> ^Audio_Voice {
			for &v in audio.voices { if v.serial == audio.serial { return &v } }
			return nil
		}
		picks: [2]int
		for _ in 0 ..< 300 {
			client_audio_present(&client, {kind = .LAND, uid = 1})
			voice := last_voice(audio)
			if !testing.expect(t, voice != nil && voice.sample != nil) { return }
			testing.expect(t, !voice.spatial && voice.gain == KRUNKER_LAND_GAIN && voice.channel == .FOOTSTEPS, "your landing is an unpositioned 0.7 footstep")
			path := string(voice.sample.path)
			switch {
			case strings.has_suffix(path, "step_0.mp3"): picks[0] += 1
			case strings.has_suffix(path, "step_1.mp3"): picks[1] += 1
			case: testing.expectf(t, false, "unexpected landing sound %s", path)
			}
		}
		testing.expectf(t, picks[0] > picks[1] && picks[1] > 50, "Default's ids favour step_0 two to one (%v)", picks)

		client_audio_present(&client, {kind = .LAND, uid = 9, position = {30, 0, 0}})
		remote := last_voice(audio)
		testing.expect(t, remote != nil && remote.spatial && remote.position == {30, 0, 0} && remote.gain == KRUNKER_LAND_GAIN && remote.channel == .FOOTSTEPS, "a remote landing plays at their feet")
		before := audio.serial
		client_audio_present(&client, {kind = .LAND, uid = 9, position = {0, 0, -200}})
		testing.expect(t, audio.serial == before, "remote landings beyond the 170 unit footstep range are culled")
	}

	// The landing steps ship: they are on disk, preloaded and packaged by the
	// Linux packager from sound-assets.txt (the Windows sweep plays them).
	@(test)
	landing_sounds_are_packaged :: proc(t: ^testing.T) {
		manifest, err := os.read_entire_file_from_path(strings.concatenate({shared.assets_path(), "config/sound-assets.txt"}, context.temp_allocator), context.allocator)
		if !testing.expect(t, err == nil) { return }
		defer delete(manifest)
		for name in KRUNKER_LAND_STEPS {
			rel := strings.concatenate({"sound/", name, ".mp3"}, context.temp_allocator)
			testing.expectf(t, strings.contains(string(manifest), rel), "%s is preloaded and packaged", rel)
			testing.expectf(t, os.exists(strings.concatenate({shared.assets_path(), rel}, context.temp_allocator)), "%s exists", rel)
		}
	}
}
