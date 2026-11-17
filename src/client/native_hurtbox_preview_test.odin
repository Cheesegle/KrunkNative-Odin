package main

import "base:runtime"
import "core:math"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import shared "../shared"

when ODIN_TEST {
	// Hidden-window preview of the developer overlay on a native game: two
	// enemy bots, one standing and one strafing (velocity non-zero, mid
	// stride), drawn over their models with "Player hitboxes" on. The solid
	// boxes are exactly what player_shoot tests (Krunker's hurtboxes, +1 per
	// side on the moving bot), the dim ones the other size and leg set.
	// Preview: bin/debug_hitboxes/native_server_hurtboxes.png.
	@(test)
	native_server_hurtboxes_preview :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init()), "GLFW initialization failed") do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(HITBOX_SHOT_W, HITBOX_SHOT_H, "Native server hurtboxes", nil, nil)
		if !testing.expect(t, window != nil, "hidden OpenGL window failed") do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.Viewport(0, 0, HITBOX_SHOT_W, HITBOX_SHOT_H)

		client := Client{window = window, scene = scene_init(), fps_scene = scene_init(), viewport_width = HITBOX_SHOT_W, viewport_height = HITBOX_SHOT_H}
		g_client = &client
		defer { g_client = nil }
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		map_inst := shared.Map{death_y = -1000}
		maps := []^shared.Map{&map_inst}
		shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, 0, true)
		defer {
			debug_render_fini(&client.debug_render)
			client_clear_players(&client)
			shared.game_destroy(&client.game)
			scene_fini(client.fps_scene)
			scene_fini(client.scene)
			resource_cache_fini()
		}
		me := shared.player_init(&client.game)
		shared.game_players_add(&client.game, me)
		shared.player_spawn(me, 0)
		me.uid, me.active, me.is_you, me.position = 1, true, true, {0, 0, 0}
		client.me = me
		bots: [2]^shared.Player
		for &bot, i in bots {
			bot = shared.player_init(&client.game)
			shared.game_players_add(&client.game, bot)
			shared.player_spawn(bot, 0)
			bot.uid, bot.active, bot.swap_timer = i32(2 + i), true, 0
			x: f32 = i == 0 ? -5 : 5
			bot.position, bot.last_position, bot.direction = {x, 0, -15}, {x, 0, -15}, {0, math.PI} // Facing the camera.
		}
		standing, moving := bots[0], bots[1]
		moving.velocity = {0.04, 0, 0}
		moving.step_val, moving.step_chase = 0.9, 0.8
		for bot in bots {
			player_generate_meshes(bot, false)
			scene_add_player_mesh(client.scene, cast(^Player_Mesh)bot.mesh, int(bot.loadout_size))
			player_update_meshes(bot, false)
		}

		camera := camera_init(math.PI / 2)
		camera.position = {0, 6, 0}
		camera_update_projection_matrix(&camera, f32(HITBOX_SHOT_W) / f32(HITBOX_SHOT_H))
		camera_update_world_inverse_matrix(&camera)
		client.camera = camera
		view_projection := camera.projection_matrix * camera.world_inverse_matrix
		pixels := make([]u8, HITBOX_SHOT_W * HITBOX_SHOT_H * 3)
		defer delete(pixels)

		dr := &client.debug_render
		dr.player_hitboxes = true
		debug_render_build(&client, 0)
		testing.expect(t, debug_hitbox_model(&client) == .KRODIN, "a native game draws the native server's boxes")
		gl.ClearColor(0.55, 0.62, 0.7, 1)
		ui_flush()
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		scene_render(client.scene, &camera, HITBOX_SHOT_W, HITBOX_SHOT_H)
		debug_render_lines(dr, view_projection, false)
		err := gl.GetError()
		testing.expectf(t, err == gl.NO_ERROR, "preview must draw without OpenGL errors (0x%x)", err)
		debug_test_read(pixels)
		debug_test_save(pixels, "bin/debug_hitboxes/native_server_hurtboxes.png")

		// The solid head edge sits at the tested size: 2 wide standing,
		// 4 wide (+1 per side) on the moving bot.
		yellow :: proc(r, g, b: u8) -> bool { return r > 200 && g > 200 && b < 90 }
		for bot in bots {
			boxes: [shared.KRUNKER_HURTBOX_MAX]shared.Krunker_Hurtbox
			shared.krunker_player_hurtboxes(shared.krunker_target_pose(bot), &boxes)
			head := boxes[0]
			// The top edge's midpoint on the face toward the camera.
			edge := (head.transform * shared.Vec4{0, 0.5, -0.5, 1}).xyz
			pixel, visible := debug_test_project(view_projection, edge)
			testing.expect(t, visible, "the bots are in view")
			testing.expectf(t, debug_test_pixel_near(pixels, pixel, 2, yellow), "the %s bot's tested head edge is drawn solid at %v", bot == moving ? "moving" : "standing", pixel)
			size := shared.Vec3{linalg_length(head.transform[0].xyz), linalg_length(head.transform[1].xyz), linalg_length(head.transform[2].xyz)}
			want: f32 = bot == moving ? 4 : 2
			testing.expectf(t, abs(size.x - want) < 1e-3, "the %s bot's tested head is %v wide (want %v)", bot == moving ? "moving" : "standing", size.x, want)
		}
	}

	@(private="file")
	linalg_length :: proc(v: shared.Vec3) -> f32 { return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) }
}
