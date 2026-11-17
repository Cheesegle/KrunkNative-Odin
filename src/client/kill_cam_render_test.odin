package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import menuui "../menu"
import shared "../shared"

when ODIN_TEST {
	KILL_CAM_SHOT_W :: 640
	KILL_CAM_SHOT_H :: 360

	@(private = "file")
	kill_cam_shot :: proc(name: string, pixels: []u8) {
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		ui_flush()
		gl.ReadPixels(0, 0, KILL_CAM_SHOT_W, KILL_CAM_SHOT_H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
		os.make_directory("bin/kill-cam")
		stbi.write_png(fmt.ctprintf("bin/kill-cam/%s.png", name), KILL_CAM_SHOT_W, KILL_CAM_SHOT_H, 3, &pixels[(KILL_CAM_SHOT_H - 1) * KILL_CAM_SHOT_W * 3], -KILL_CAM_SHOT_W * 3)
	}

	// Where `point` lands on screen, as a fraction from the centre (0 = centre).
	@(private = "file")
	kill_cam_screen_offset :: proc(client: ^Client, point: shared.Vec3) -> (offset: shared.Vec2, visible: bool) {
		camera := client.camera
		camera.fov = client_world_fov(client)
		camera_update_projection_matrix(&camera, f32(KILL_CAM_SHOT_W) / f32(KILL_CAM_SHOT_H))
		camera_update_world_inverse_matrix(&camera)
		clip := camera.projection_matrix * camera.world_inverse_matrix * shared.Vec4{point.x, point.y, point.z, 1}
		if clip.w <= 0 { return {}, false }
		return {clip.x / clip.w, clip.y / clip.w}, true
	}

	// The game frame (client_tick) in Local Practice on Burg: alive, killed by
	// a second player, the kill cam panning to them, then respawned. Writes
	// bin/kill-cam/{1_before_death,2_kill_cam_start,3_kill_cam,3_kill_cam_world,4_after_respawn}.png.
	@(test)
	kill_cam_renders_in_the_game_path :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(KILL_CAM_SHOT_W, KILL_CAM_SHOT_H, "Kill cam", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

		preferences := client_settings_defaults()
		client := new(Client)
		defer free(client)
		g_client = client
		defer g_client = nil
		client.window = window
		client.visual_settings, client.quality_settings = preferences.visuals, preferences.quality
		client.viewmodel_settings = preferences.viewmodel
		client.bindings = preferences.bindings
		client.render_batching = true
		client.camera.zoom = 1
		client.camera.fov = preferences.fov * math.PI / 180
		client.camera.near, client.camera.far = 0.1, 10000
		client.viewport_width, client.viewport_height = KILL_CAM_SHOT_W, KILL_CAM_SHOT_H
		client.selected_secondary = 2
		client_graphics_init(client)
		defer client_graphics_fini(client)
		client.scene = scene_init()
		client.fps_scene = scene_init()

		config := shared.config_load_gameplay("assets/config/game.toml")
		defer shared.config_destroy_gameplay(config)
		testing.expect(t, config.game.kill_cams, "game.toml keeps Krunker's Kill Cams default (on)")
		map_inst, ok := shared.map_load_from_file("assets/maps/burg.json")
		if !testing.expect(t, ok && map_inst != nil) do return
		maps := []^shared.Map{map_inst}
		shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, -1, true)
		client.ui = ui_init()
		defer {
			// The HUD caches icons in globals bound to this context.
			overlay_fini()
			menuui.fini(&client.menu); ui_fini(client.ui); client.ui = nil
			client_clear_players(client)
			client_unload_map(client)
			shadow_fini()
			scene_fini(client.fps_scene)
			scene_fini(client.scene)
			shared.game_destroy(&client.game)
			shared.map_destroy(map_inst)
			resource_cache_fini()
		}
		if !testing.expect(t, client.game.ready && menuui.init(&client.menu, menu_measure_text, client.ui)) do return
		client_load_current_map(client)
		client.local_practice = true
		client.lobby_team = 1
		client_enter_game(client)
		me := client.me
		if !testing.expect(t, me != nil && me.mesh != nil, "Local Practice must spawn you") do return

		// The killer: a second player 55 units ahead, facing you.
		killer := shared.player_init(&client.game)
		killer.uid = 7
		shared.game_players_add(&client.game, killer)
		shared.player_spawn(killer, 0, -1)
		shared.player_swap_weapon(killer, 0, true, false, false)
		player_generate_meshes(killer, false)
		if !testing.expect(t, killer.mesh != nil) do return
		scene_add_player_mesh(client.scene, cast(^Player_Mesh)killer.mesh, int(killer.loadout_size))

		// Stand at the first Burg spawn and direction with open, solid ground
		// 55 units ahead for the killer; both settle under the simulation.
		map_inst_loaded := client.game.map_inst
		start, killer_start: shared.Vec3
		yaw: f32
		found := false
		search: for spawn in map_inst_loaded.spawns {
			for quarter in 0 ..< 8 {
				try_yaw := f32(quarter) * math.PI / 4
				ahead := shared.Vec3{-math.sin(try_yaw), 0, -math.cos(try_yaw)}
				candidate := spawn.position + ahead * 55
				eye := spawn.position + {0, 9, 0}
				clear_view := shared.map_can_see(map_inst_loaded, eye, candidate + {0, 6, 0}) && shared.map_can_see(map_inst_loaded, eye, candidate + {0, 1, 0})
				grounded := !shared.map_can_see(map_inst_loaded, candidate + {0, 2, 0}, candidate - {0, 3, 0})
				headroom := shared.map_can_see(map_inst_loaded, candidate + {0, 1, 0}, candidate + {0, 12, 0})
				if clear_view && grounded && headroom {
					start, killer_start, yaw, found = spawn.position, candidate, try_yaw, true
					break search
				}
			}
		}
		if !testing.expect(t, found, "Burg has an open spawn view") do return
		me.position, me.velocity, me.direction = start + {0, 1, 0}, {}, {0, yaw}
		killer.position, killer.velocity = killer_start + {0, 1, 0}, {}
		killer.direction = {0, yaw + math.PI}
		idle := proc(killer: ^shared.Player) {
			input := shared.Input{move_dir = -1, delta = 1.0 / 60, x_dir = killer.direction.x, y_dir = killer.direction.y}
			shared.player_queue_input(killer, &input)
		}
		pixels := make([]u8, KILL_CAM_SHOT_W * KILL_CAM_SHOT_H * 3)
		defer delete(pixels)

		// 1. Alive, mouse captured: the normal first-person frame, looking at
		// the killer's chest.
		glfw.SetInputMode(window, glfw.CURSOR, glfw.CURSOR_DISABLED)
		for frame in 0 ..< 150 {
			if frame >= 140 {
				eye := me.position + shared.Vec3{0, me.height - shared.GAME_CONSTANTS.camera_height, 0}
				chest := killer.position + shared.Vec3{0, killer.height * 0.6, 0}
				me.direction = {kill_cam_pitch_to(eye, chest), kill_cam_yaw_to(eye, chest)}
			}
			idle(killer)
			client_tick(client, f32(glfw.GetTime()), 1.0 / 60)
			player_update_meshes(killer, false)
		}
		testing.expect(t, client.mouse_state.locked && me.active)
		kill_cam_shot("1_before_death", pixels)
		eye := client.camera.position
		testing.expect(t, !client.kill_cam.active)

		// 2. Killed by the second player: the kill cam starts from the eye.
		killer_pose := killer.position
		testing.expect(t, shared.player_apply_damage(me, killer, 500, killer.loadout[killer.loadout_index], true))
		client_tick(client, f32(glfw.GetTime()), 1.0 / 60)
		player_update_meshes(killer, false)
		if !testing.expect(t, client.kill_cam.active && client.kill_cam.killer_uid == 7, "a kill by another player starts the kill cam") do return
		point := killer_pose + shared.Vec3{0, killer.height / 1.5, 0}
		want := kill_cam_look_at(eye, point)
		testing.expectf(t, abs(client.kill_cam.target.yaw - want.yaw) < 1e-3 && abs(client.kill_cam.target.pitch - want.pitch) < 1e-3,
			"aimed at 2/3 of the killer's height: %v vs %v", client.kill_cam.target, want)
		testing.expect(t, client.mouse_state.locked && client.death_screen.active, "Krunker keeps the pointer through the death screen (death_screen.odin)")
		kill_cam_shot("2_kill_cam_start", pixels)

		// A native snapshot moving the killer is ignored while the cam shows.
		state := shared.Packet_Player_State{
			player_id = u32(killer.uid), active = true, class_id = killer.class_index, secondary_id = killer.secondary_id,
			position = killer.position + {30, 0, 0}, x_dir = killer.direction.x, y_dir = killer.direction.y, on_ground = true,
			health = killer.health, max_health = killer.max_health, weapon_id = u8(killer.loadout[killer.loadout_index]),
			active_ammo = killer.ammo[killer.loadout_index],
		}
		frozen := killer.position
		client_apply_player_state(client, &state)
		testing.expect(t, killer.position == frozen && !killer.interpolate, "the killer's pose stays frozen")

		// 3. ~2.8 s later (Krunker's deathDelay): the camera has panned in.
		for _ in 0 ..< 168 {
			client_tick(client, f32(glfw.GetTime()), 1.0 / 60)
			player_update_meshes(killer, false)
		}
		testing.expect(t, client.kill_cam.active, "the kill cam lasts until you respawn")
		travelled := client.camera.position - eye
		testing.expectf(t, travelled.x*travelled.x + travelled.y*travelled.y + travelled.z*travelled.z > 4, "the camera moved toward the killer (%v)", travelled)
		offset, visible := kill_cam_screen_offset(client, point)
		testing.expectf(t, visible && abs(offset.x) < 0.1 && abs(offset.y) < 0.1, "the killer is centred on screen (%v)", offset)
		kill_cam_shot("3_kill_cam", pixels)
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		gl.Viewport(0, 0, KILL_CAM_SHOT_W, KILL_CAM_SHOT_H)
		client_render_world(client)
		player_healthbars_update_visibility(client, f32(glfw.GetTime()))
		player_healthbars_render(client)
		kill_cam_shot("3_kill_cam_world", pixels)
		testing.expect(t, killer.nameplate_alpha == 1, "the killer's nametag is forced on")

		// 4. Respawn: the camera returns to your eye, the cam ends.
		client_enter_game(client)
		testing.expect(t, me.active)
		glfw.SetInputMode(window, glfw.CURSOR, glfw.CURSOR_DISABLED)
		client.mouse_state.locked = true
		for _ in 0 ..< 4 {
			client_tick(client, f32(glfw.GetTime()), 1.0 / 60)
			player_update_meshes(killer, false)
		}
		testing.expect(t, !client.kill_cam.active, "respawn ends the kill cam")
		want_eye := me.position + shared.Vec3{0, me.height - shared.GAME_CONSTANTS.camera_height, 0}
		testing.expectf(t, client.camera.position == want_eye && client.camera.rotation.y == me.direction.y, "the camera follows you again (%v vs %v)", client.camera.position, want_eye)
		kill_cam_shot("4_after_respawn", pixels)
		// Next native snapshot: the killer moves (interpolates) again.
		client_apply_player_state(client, &state)
		testing.expect(t, killer.interpolate, "interpolation is restored")
		testing.expect(t, gl.GetError() == gl.NO_ERROR)
	}
}
