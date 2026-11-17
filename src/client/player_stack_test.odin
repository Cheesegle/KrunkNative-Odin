package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import shared "../shared"

when ODIN_TEST {
	STACK_SHOT_W :: 480
	STACK_SHOT_H :: 360

	@(private = "file")
	Stack_Fixture :: struct {
		config:   ^shared.Gameplay_Config,
		floor:    shared.Object,
		map_inst: shared.Map,
		client:   Client,
		me, other: ^shared.Player,
	}

	// A flat floor (top at y = 0), you and one other player standing at the origin.
	@(private = "file")
	stack_fixture_init :: proc(f: ^Stack_Fixture, player_collision: bool) {
		f.config = shared.config_load_gameplay()
		f.config.game.player_collision = player_collision
		f.floor = {active = true, collision_type = .BOX, position = {0, -10, 0}, scale = {2000, 10, 2000}}
		f.map_inst = {death_y = -1000, config = shared.DEFAULT_MAP_CONFIG}
		append(&f.map_inst.objects, &f.floor)
		shared.game_configure(&f.client.game, &f.config.game, []^shared.Map{&f.map_inst}, nil, f.config.weapons, f.config.classes)
		shared.game_init(&f.client.game, 0, 0, true)
		f.other = shared.player_init(&f.client.game)
		shared.game_players_add(&f.client.game, f.other)
		shared.player_spawn(f.other, 0)
		f.other.uid, f.other.active, f.other.swap_timer = 2, true, 0
		f.other.position, f.other.last_position, f.other.direction = {}, {}, {0, 0}
		f.me = shared.player_init(&f.client.game)
		shared.game_players_add(&f.client.game, f.me)
		shared.player_spawn(f.me, 0)
		f.me.uid, f.me.active, f.me.is_you, f.me.render_you = 1, true, true, true
		f.client.me = f.me
	}

	@(private = "file")
	stack_fixture_fini :: proc(f: ^Stack_Fixture) {
		client_clear_players(&f.client)
		shared.game_destroy(&f.client.game)
		delete(f.map_inst.objects)
		shared.config_destroy_gameplay(f.config)
	}

	@(private = "file")
	stack_tick :: proc(player: ^shared.Player, move_dir: i32 = -1, move_lock := false) {
		input := shared.Input{delta = 1.0 / 60.0, move_dir = move_dir, x_dir = player.direction.x, y_dir = player.direction.y}
		shared.player_proc_input(player, &input, false, move_lock)
	}

	// Drop you from above onto the other player's head.
	@(private = "file")
	stack_drop :: proc(f: ^Stack_Fixture) -> int {
		f.me.position, f.me.last_position, f.me.velocity, f.me.on_ground = {0.5, 30, 0.5}, {0.5, 30, 0.5}, {}, false
		for tick in 0 ..< 600 {
			stack_tick(f.me)
			if f.me.on_ground { return tick }
		}
		return -1
	}

	// The first-person eye, as client_tick places the camera.
	@(private = "file")
	stack_eye :: proc(player: ^shared.Player) -> f32 {
		return player.position.y + player.height - shared.GAME_CONSTANTS.camera_height
	}

	// Krunker's playerCollision (Player Collision, pColl): you land on the
	// other player's head and your eye stays above it; Krodin's prediction
	// used to let you sink into them, with the camera inside their head.
	@(test)
	player_stack_lands_on_head :: proc(t: ^testing.T) {
		f: Stack_Fixture
		stack_fixture_init(&f, true)
		defer stack_fixture_fini(&f)
		head := f.other.position.y + f.other.height
		testing.expect(t, stack_drop(&f) > 0)
		testing.expectf(t, f.me.position.y == head && f.me.velocity.y == 0, "you stand on the head at y %v, got %v", head, f.me.position.y)
		testing.expectf(t, stack_eye(f.me) - head > 8, "your eye is well above their head (%v vs %v)", stack_eye(f.me), head)
		for _ in 0 ..< 120 { stack_tick(f.me) }
		testing.expect(t, f.me.position.y == head && f.me.on_ground, "you stay on top")

		// Intermission locks movement: you stay where you stood.
		for _ in 0 ..< 120 { stack_tick(f.me, move_lock = true) }
		testing.expect(t, f.me.position.y == head, "a frozen intermission keeps you on top")

		// The other player crouches: you come down onto the lower head.
		f.other.crouch_val = 1
		shared.player_update_height(f.other)
		for _ in 0 ..< 120 { stack_tick(f.me) }
		lower := f.other.position.y + f.other.height
		testing.expectf(t, lower < head && math.abs(f.me.position.y - lower) < 0.001, "you follow a crouch down to %v, got %v", lower, f.me.position.y)

		// Walking off the head drops you to the floor beside them.
		for _ in 0 ..< 300 { stack_tick(f.me, 0) }
		testing.expectf(t, f.me.position.y == 0 && f.me.on_ground, "walked off onto the floor, y %v", f.me.position.y)

		// Walking into them from the side stops you at their edge.
		f.other.crouch_val = 0
		shared.player_update_height(f.other)
		f.me.position, f.me.last_position, f.me.velocity = {12, 0, 0}, {12, 0, 0}, {}
		f.me.direction = {}
		for _ in 0 ..< 240 { stack_tick(f.me, 6) } // move_dir 6 walks toward -x at yaw 0.
		edge := f.other.scale + f.me.scale
		testing.expectf(t, f.me.position.x >= edge - 0.001, "you stop at x %v beside them, got %v", edge, f.me.position.x)
	}

	// Krunker pubs leave Player Collision off: players pass through each other.
	@(test)
	player_stack_off_by_default :: proc(t: ^testing.T) {
		testing.expect(t, !shared.DEFAULT_GAME_CONFIG.player_collision, "Krunker's pColl defaults to false")
		f: Stack_Fixture
		stack_fixture_init(&f, false)
		defer stack_fixture_fini(&f)
		testing.expect(t, stack_drop(&f) > 0)
		testing.expectf(t, f.me.position.y == 0, "without Player Collision you fall through to the floor, y %v", f.me.position.y)
	}

	// An interpolated player is tested at their newest pose, as Krunker's
	// collidesP uses x2/y2/z2.
	@(test)
	player_stack_uses_newest_pose :: proc(t: ^testing.T) {
		game := shared.Game{}
		game.config.player_collision = true
		me := shared.Player{game = &game, active = true, scale = 1.6, height = 11, position = {0, 11, 0}}
		other := shared.Player{game = &game, active = true, scale = 1.6, height = 11, position = {20, 0, 0}, interpolate = true, interp_pos_end = {0, 0, 0}}
		testing.expect(t, shared.player_collides_player(&me, &other))
		other.interp_pos_end = {20, 0, 0}
		testing.expect(t, !shared.player_collides_player(&me, &other))
	}

	@(private = "file")
	stack_shot :: proc(f: ^Stack_Fixture, camera: ^Camera, pixels: []u8, name: string) -> (top_half_covered: int) {
		gl.ClearColor(0.75, 0.8, 0.85, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		camera_update_projection_matrix(camera, f32(STACK_SHOT_W) / f32(STACK_SHOT_H))
		camera_update_world_inverse_matrix(camera)
		scene_render(f.client.scene, camera, STACK_SHOT_W, STACK_SHOT_H)
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		gl.ReadPixels(0, 0, STACK_SHOT_W, STACK_SHOT_H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
		// Rows are bottom-up: the top half is the second half of the buffer.
		for i := STACK_SHOT_W * STACK_SHOT_H / 2; i < STACK_SHOT_W * STACK_SHOT_H; i += 1 {
			p := pixels[i * 3:]
			if math.abs(int(p[0]) - 191) + math.abs(int(p[1]) - 204) + math.abs(int(p[2]) - 217) > 12 { top_half_covered += 1 }
		}
		when #config(STACK_PREVIEW, false) {
			os.make_directory("bin/player-stack")
			stbi.write_png(fmt.ctprintf("bin/player-stack/%s.png", name), STACK_SHOT_W, STACK_SHOT_H, 3, &pixels[(STACK_SHOT_H - 1) * STACK_SHOT_W * 3], -STACK_SHOT_W * 3)
		}
		return
	}

	// First-person view from on top of another player, looking ahead: their
	// model stays below the view. The old prediction's eye (sunk to the floor,
	// inside their head) is drawn for comparison.
	// -define:STACK_PREVIEW=true writes bin/player-stack/{on_head,sunk_old,on_head_down}.png.
	@(test)
	player_stack_render_first_person :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(STACK_SHOT_W, STACK_SHOT_H, "Player stack", nil, nil)
		if !testing.expect(t, window != nil) { return }
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.Viewport(0, 0, STACK_SHOT_W, STACK_SHOT_H)

		f: Stack_Fixture
		f.client.window, f.client.scene, f.client.fps_scene = window, scene_init(), scene_init()
		g_client = &f.client
		defer { g_client = nil }
		stack_fixture_init(&f, true)
		defer {
			stack_fixture_fini(&f)
			scene_fini(f.client.fps_scene)
			scene_fini(f.client.scene)
			resource_cache_fini()
		}
		player_generate_meshes(f.other, false)
		scene_add_player_mesh(f.client.scene, cast(^Player_Mesh)f.other.mesh, int(f.other.loadout_size))
		player_update_meshes(f.other, false)
		testing.expect(t, stack_drop(&f) > 0)

		pixels := make([]u8, STACK_SHOT_W * STACK_SHOT_H * 3)
		defer delete(pixels)
		camera := camera_init(DEFAULT_WEAPON_FOV)
		camera.position = {f.me.position.x, stack_eye(f.me), f.me.position.z}
		on_head := stack_shot(&f, &camera, pixels, "on_head")
		testing.expectf(t, on_head == 0, "standing on their head, nothing of their model reaches the upper view (%d pixels)", on_head)

		sunk := camera
		sunk.position.y = stack_eye(f.me) - f.other.height
		sunk_covered := stack_shot(&f, &sunk, pixels, "sunk_old")
		fmt.printfln("[player stack] upper-view pixels covered by the other model: on head %d, sunk (old prediction) %d", on_head, sunk_covered)

		down := camera
		down.rotation.x = -1.2
		stack_shot(&f, &down, pixels, "on_head_down")
		testing.expect(t, gl.GetError() == gl.NO_ERROR)
	}
}
