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
import kproto "../krunker"

when ODIN_TEST {
	@(private = "file")
	g_render_sent: int

	@(private = "file")
	spectate_render_send :: proc(state: ^Krunker_WS_State, opcode: string) -> bool { g_render_sent += 1; return true }

	// One spectator frame in the order client_tick runs it on a live socket:
	// remote interpolation, animation and meshes, then the spectator view.
	@(private = "file")
	spectate_render_frame :: proc(client: ^Client, now: f64, delta: f32, input: Spectator_Input) {
		krunker_client_interpolate_remotes(client, now, delta)
		for player in client.game.players {
			if !player.active { continue }
			player.idle_anim += shared.GAME_CONSTANTS.idle_anim_speed * delta
			shared.player_update_visual_animations(player, delta)
			shared.player_update_recoil(player, delta)
			if player.mesh != nil { player_update_meshes(player, false) }
		}
		spectator_update(client, input, now, delta)
	}

	@(private = "file")
	spectate_render_shot :: proc(t: ^testing.T, client: ^Client, name: string, w, h: i32, delta: f32) -> (spread: f64) {
		gl.Viewport(0, 0, w, h)
		client.viewport_width, client.viewport_height = w, h
		client_render_world(client)
		ui_update(client.ui, f32(w), f32(h))
		spectator_hud_render(client, delta)
		testing.expectf(t, gl.GetError() == gl.NO_ERROR, "%s renders without GL errors", name)
		pixels := make([]u8, int(w*h*3))
		defer delete(pixels)
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		ui_flush()
		gl.ReadPixels(0, 0, w, h, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
		os.make_directory("bin/spectator")
		path := fmt.ctprintf("bin/spectator/%s_%dx%d.png", name, w, h)
		testing.expect(t, stbi.write_png(path, w, h, 3, &pixels[(h - 1)*w*3], -w*3) != 0)
		// Brightness spread: a real frame, not a cleared or single-colour one.
		sum, sum2: f64
		count: f64
		for i := 0; i < len(pixels); i += 3*97 {
			v := f64(pixels[i]) + f64(pixels[i+1]) + f64(pixels[i+2])
			sum += v; sum2 += v*v; count += 1
		}
		mean := sum/count
		return math.sqrt(max(sum2/count - mean*mean, 0))
	}

	// Spectating three players on Burg from a live-shaped k stream (10 Hz,
	// whole-degree angles): first person, third-person chase, free cam and
	// the HUD with the scoreboard, at 1280x720 and 1920x1080. Writes
	// bin/spectator/{first_person,chase,free_cam,hud_scoreboard}_<W>x<H>.png.
	@(test)
	spectator_renders_first_person_chase_and_free_cam :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(640, 360, "Spectator", nil, nil)
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
		client.crosshair_settings = preferences.crosshair
		client.bindings = preferences.bindings
		client.spectator_settings = preferences.spectator
		client.render_batching = true
		client.camera.zoom = 1
		client.camera.fov = preferences.fov * math.PI / 180
		client.camera.near, client.camera.far = 0.1, 10000
		client_graphics_init(client)
		defer client_graphics_fini(client)
		client.scene = scene_init()
		client.fps_scene = scene_init()

		config := shared.config_load_gameplay("assets/config/game.toml")
		defer shared.config_destroy_gameplay(config)
		map_inst, ok := shared.map_load_from_file("assets/maps/burg.json")
		if !testing.expect(t, ok && map_inst != nil) do return
		maps := []^shared.Map{map_inst}
		shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, -1, true)
		client.ui = ui_init()
		spectator_send_control = spectate_render_send
		defer {
			spectator_send_control = krunker_ws_send
			spectator_proxy_release(client)
			overlay_fini()
			kill_feed_fini()
			menuui.fini(&client.menu); ui_fini(client.ui); client.ui = nil
			client_clear_players(client)
			client_unload_map(client)
			shadow_fini()
			scene_fini(client.fps_scene)
			scene_fini(client.scene)
			delete(client.krunker_world.players)
			delete(client.join_status)
			shared.game_destroy(&client.game)
			shared.map_destroy(map_inst)
			resource_cache_fini()
		}
		if !testing.expect(t, client.game.ready && menuui.init(&client.menu, menu_measure_text, client.ui)) do return
		client_load_current_map(client)

		// Find a Burg spawn with open, solid ground 55 units ahead.
		start, other_start: shared.Vec3
		yaw: f32
		found := false
		search: for spawn in map_inst.spawns {
			for quarter in 0 ..< 8 {
				try_yaw := f32(quarter) * math.PI / 4
				ahead := shared.Vec3{-math.sin(try_yaw), 0, -math.cos(try_yaw)}
				candidate := spawn.position + ahead * 55
				eye := spawn.position + {0, 9, 0}
				clear_view := shared.map_can_see(map_inst, eye, candidate + {0, 6, 0}) && shared.map_can_see(map_inst, eye, candidate + {0, 1, 0})
				grounded := !shared.map_can_see(map_inst, candidate + {0, 2, 0}, candidate - {0, 3, 0})
				if clear_view && grounded { start, other_start, yaw, found = spawn.position, candidate, try_yaw, true; break search }
			}
		}
		if !testing.expect(t, found, "Burg has an open spawn view") do return

		// Three players: 21 (followed), 22 ahead facing back, 23 behind.
		client.krunker.connected, client.krunker.spectate = true, true
		client.krunker_world.ready, client.krunker_world.spectating = true, true
		client.krunker_world.local_sid = 99
		client.krunker_world.mode_index = 0
		sids := [3]i32{21, 22, 23}
		names := [3]string{"Followed", "Opponent", "Teammate"}
		teams := [3]i32{1, 2, 1}
		classes := [3]i32{0, 1, 2}
		positions := [3]shared.Vec3{start, other_start, start - shared.Vec3{-math.sin(yaw), 0, -math.cos(yaw)}*20}
		yaws := [3]f32{yaw, yaw + math.PI, yaw}
		for i in 0 ..< 3 {
			player := shared.player_init(&client.game)
			player.uid, player.team = sids[i], teams[i]
			shared.game_players_add(&client.game, player)
			shared.player_spawn(player, classes[i], -1)
			shared.player_swap_weapon(player, 0, true, false, false)
			player.active, player.position, player.direction = true, positions[i], {0, yaws[i]}
			player_generate_meshes(player, false)
			if player.mesh != nil { scene_add_player_mesh(client.scene, cast(^Player_Mesh)player.mesh, int(player.loadout_size)) }
			append(&client.krunker_world.players, kproto.Krunker_World_Player{sid = sids[i], name = names[i], team = teams[i], class_index = classes[i],
				active = true, has_position = true, health = i == 0 ? 72 : 100, max_health = 100, kills = u32(3 - i), deaths = u32(i), position = positions[i], direction = {0, yaws[i]}, send_rate = 10})
		}

		// 3 s at 60 fps, a k every 6 frames: the followed player strafes
		// and sweeps the view across the opponent.
		now := 100.0
		delta: f32 = 1.0/60
		k_index := 0
		run := proc(client: ^Client, now: ^f64, k_index: ^int, frames: int, delta: f32, start: shared.Vec3, yaw: f32, input: Spectator_Input) {
			for frame in 0 ..< frames {
				if frame % 6 == 0 {
					server := f64(k_index^) * 0.1
					for &p in client.krunker_world.players {
						if p.sid != 21 { kproto.krunker_world_buffer_pose(&p, now^); continue }
						side := shared.Vec3{math.cos(yaw), 0, -math.sin(yaw)}
						p.position = start + side * f32(4*math.sin(server*1.3))
						sweep := yaw + f32(0.25*math.sin(server*0.9))
						p.direction = {f32(math.round(-3 + 2*math.sin(server)))*math.PI/180, f32(math.round(f64(sweep)*180/math.PI))*math.PI/180}
						kproto.krunker_world_buffer_pose(&p, now^)
						p.poses[p.pose_count-1].server_time, p.poses[p.pose_count-1].has_server_time = server, true
					}
					k_index^ += 1
				}
				spectate_render_frame(client, now^, delta, frame == 0 ? input : {})
				now^ += f64(delta)
			}
		}
		run(client, &now, &k_index, 180, delta, start, yaw, {})
		spec := &client.spectator
		if !testing.expectf(t, spec.active && spec.target_sid == 21 && spec.mode == .FIRST_PERSON && spec.view.valid, "following the first player in first person (active=%v target=%d mode=%v valid=%v)", spec.active, spec.target_sid, spec.mode, spec.view.valid) do return
		eye := spec.view.position + shared.Vec3{0, shared.GAME_CONSTANTS.player_height - shared.GAME_CONSTANTS.camera_height, 0}
		d := client.camera.position - eye
		testing.expectf(t, d.x*d.x + d.y*d.y + d.z*d.z < 0.01, "first person: camera at the followed eye (%v vs %v)", client.camera.position, eye)
		followed := client_find_player(client, 21)
		testing.expect(t, followed != nil && followed.mesh != nil && (cast(^Player_Mesh)followed.mesh).anchor.scale == {0, 0, 0}, "the followed body is hidden in first person")
		testing.expect(t, spec.proxy != nil && spec.proxy.mesh != nil && spec.proxy_in_scene, "the followed player's viewmodel is drawn")
		testing.expect(t, g_render_sent >= 1, "fpSp named the target")

		sizes := [2][2]i32{{1280, 720}, {1920, 1080}}
		for size in sizes {
			w, h := size[0], size[1]
			framebuffer, color, depth: u32
			gl.GenFramebuffers(1, &framebuffer)
			gl.GenTextures(1, &color)
			gl.GenRenderbuffers(1, &depth)
			gl.BindFramebuffer(gl.FRAMEBUFFER, framebuffer)
			gl.BindTexture(gl.TEXTURE_2D, color)
			gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGB8, w, h, 0, gl.RGB, gl.UNSIGNED_BYTE, nil)
			gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, color, 0)
			gl.BindRenderbuffer(gl.RENDERBUFFER, depth)
			gl.RenderbufferStorage(gl.RENDERBUFFER, gl.DEPTH24_STENCIL8, w, h)
			gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_STENCIL_ATTACHMENT, gl.RENDERBUFFER, depth)
			gl.BindTexture(gl.TEXTURE_2D, 0)
			g_active_texture = 0
			complete := gl.CheckFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE
			testing.expect(t, complete)
			client.render_target = Gpu_Render_Target(framebuffer) // a GL framebuffer name (GL-only test)
			if complete {
				// First person.
				spec.mode = .FIRST_PERSON
				// Past the hit grace after the last switch (F back at the end of the previous size).
				run(client, &now, &k_index, 30, delta, start, yaw, {})
				testing.expect(t, spectate_render_shot(t, client, "first_person", w, h, delta) > 8, "first person is a real frame")
				// The crosshair with Always Show while the followed player is
				// scoped in, and a hitmarker from his hit on the opponent (22).
				{
					saved_crosshair, saved_aim := client.crosshair_settings, spec.aim
					client.crosshair_settings.toggles[.ALWAYS_SHOW] = true
					client.hitmarker_settings = client_settings_defaults().hitmarker
					spectate_test_do_damage(client, now, 22, 60, headshot = true)
					spectate_render_frame(client, now, 0.03, {})
					testing.expect(t, client.spectator.hits_shown > 0 && client.hit_marker.active, "the followed player's hit shows a marker")
					spec.aim = 1
					testing.expect(t, spectator_crosshair_opacity(client, client_crosshair_values(client)) == 1, "Always Show keeps the crosshair while scoped")
					testing.expect(t, spectate_render_shot(t, client, "crosshair_hitmarker", w, h, 0.03) > 8)
					client.crosshair_settings, spec.aim = saved_crosshair, saved_aim
					client.hit_marker = {revision = client.hit_marker.revision}
				}
				// HUD with the scoreboard held.
				client.scoreboard_open = true
				testing.expect(t, spectate_render_shot(t, client, "hud_scoreboard", w, h, delta) > 8)
				client.scoreboard_open = false
				// Third-person chase (R).
				run(client, &now, &k_index, 12, delta, start, yaw, {toggle_first = true})
				testing.expect(t, spec.mode == .CHASE)
				chase_eye := spec.view.position + shared.Vec3{0, shared.GAME_CONSTANTS.player_height - spec.crouch*shared.GAME_CONSTANTS.crouch_distance - shared.GAME_CONSTANTS.camera_height, 0}
				offset := client.camera.position - chase_eye
				distance := math.sqrt(offset.x*offset.x + offset.y*offset.y + offset.z*offset.z)
				testing.expectf(t, distance > 3 && distance <= spec.follow_distance + 0.01, "chase camera behind the player (%v)", distance)
				testing.expect(t, (cast(^Player_Mesh)followed.mesh).anchor.scale == {1, 1, 1}, "the followed body shows in third person")
				testing.expect(t, spectate_render_shot(t, client, "chase", w, h, delta) > 8)
				// Free cam (F): fly up and back.
				run(client, &now, &k_index, 1, delta, start, yaw, {free = true})
				testing.expect(t, spec.mode == .FREE)
				before := client.camera.position
				for _ in 0 ..< 40 { spectate_render_frame(client, now, delta, {up = true, look = {0, 0.012}}); now += f64(delta) }
				moved := client.camera.position - before
				testing.expectf(t, moved.y > 5, "free cam flies (%v)", moved)
				testing.expect(t, spectate_render_shot(t, client, "free_cam", w, h, delta) > 8)
				// Back to the player for the next size.
				run(client, &now, &k_index, 1, delta, start, yaw, {free = true})
				testing.expect(t, spec.mode == .FIRST_PERSON && spec.target_sid == 21, "F again returns to the player")
			}
			client.render_target = 0
			gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
			gl.DeleteRenderbuffers(1, &depth)
			gl.DeleteTextures(1, &color)
			gl.DeleteFramebuffers(1, &framebuffer)
		}
	}
}
