package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import kproto "../krunker"
import menuui "../menu"
import shared "../shared"

when ODIN_TEST {
	@(private = "file") BORDER_W :: 1920
	@(private = "file") BORDER_H :: 1080
	@(private = "file") BORDER_BACKGROUND :: [3]u8{107, 128, 143}

	@(test)
	healthbar_border_defaults_off_and_persists :: proc(t: ^testing.T) {
		testing.expect(t, !client_settings_defaults().hud.healthbar_border, "healthbars have no border by default, as in Krunker")
		path := "bin/client-settings-healthbar-border-test.json"
		defer os.remove(path)
		legacy := `{"version":1,"hud":{"hide_timer":true,"hide_nametags":false,"hide_healthbars":false}}`
		testing.expect(t, os.write_entire_file(path, transmute([]u8)legacy) == nil)
		loaded := client_settings_load(path)
		testing.expect(t, loaded.hud.hide_timer && !loaded.hud.healthbar_border, "older settings files get no border")
		loaded.hud.healthbar_border = true
		testing.expect(t, client_settings_save(loaded, path))
		again := client_settings_load(path)
		testing.expect(t, again.hud.healthbar_border && again.hud.hide_timer, "the border toggle persists")

		state := menuui.State{settings_active = true}
		menuui.activate(&state, {action = {kind = .HUD_TOGGLE, index = 7}})
		testing.expect(t, state.settings_draft.hud.healthbar_border && !state.settings_draft.hud.hide_healthbars && !state.settings_draft.hud.hide_nametags,
			"Healthbar border toggles only the border")
		menuui.settings_reset_tab(&state.settings_draft, client_settings_default_values(), .HUD)
		testing.expect(t, !state.settings_draft.hud.healthbar_border, "Reset on the HUD tab turns the border off again")
	}

	@(private = "file")
	border_test_draw :: proc(client: ^Client, pixels: []u8) {
		healthbar_test_settle(client)
		ui_flush()
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		scene_render(client.scene, &client.camera, f32(client.viewport_width), f32(client.viewport_height))
		player_healthbars_render(client)
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		ui_flush()
		gl.ReadPixels(0, 0, BORDER_W, BORDER_H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
	}

	// Screen pixel (top-left origin) from a bottom-up ReadPixels buffer.
	@(private = "file")
	border_test_pixel :: proc(pixels: []u8, x, y: int) -> [3]u8 {
		i := ((BORDER_H-1-y)*BORDER_W + x)*3
		return {pixels[i], pixels[i+1], pixels[i+2]}
	}

	@(private = "file")
	border_test_layout :: proc(client: ^Client, player: ^shared.Player) -> Nameplate_Layout {
		anchor := player_nameplate_anchor(player)
		screen, _ := player_healthbar_project(client.camera.projection_matrix*client.camera.world_inverse_matrix, anchor, client.ui.width, client.ui.height)
		return player_nameplate_layout({screen.x, screen.y}, client.ui.scale*player_nameplate_scale(client.camera.position, anchor), 0, true)
	}

	// Pixels within 3 px outside the bar's left, right and bottom edges that
	// differ from the background. The top edge is skipped: name descenders
	// may reach it.
	@(private = "file")
	border_test_outline :: proc(pixels: []u8, layout: Nameplate_Layout) -> (count: int) {
		left, right := int(layout.bar_left), int(layout.bar_left + layout.bar_width)
		top, bottom := int(layout.bar_top), int(layout.bar_top + layout.bar_height)
		differs :: proc(p: [3]u8) -> bool {
			background := BORDER_BACKGROUND
			for c, i in p { if abs(int(c) - int(background[i])) > 8 { return true } }
			return false
		}
		for y in top + 2 ..< bottom + 3 {
			for x in left - 3 ..< left { if differs(border_test_pixel(pixels, x, y)) { count += 1 } }
			for x in right + 1 ..< right + 4 { if differs(border_test_pixel(pixels, x, y)) { count += 1 } }
		}
		for y in bottom + 1 ..< bottom + 4 {
			for x in left + 2 ..< right - 2 { if differs(border_test_pixel(pixels, x, y)) { count += 1 } }
		}
		return
	}

	// A 480x100 crop around the two plates, upscaled 2x for review.
	@(private = "file")
	border_test_preview :: proc(pixels: []u8, name: string) -> bool {
		CROP_W, CROP_H, CROP_X, CROP_Y, ZOOM :: 480, 100, 720, 480, 2
		crop := make([]u8, CROP_W*CROP_H*3*ZOOM*ZOOM, context.temp_allocator)
		for y in 0 ..< CROP_H*ZOOM {
			for x in 0 ..< CROP_W*ZOOM {
				p := border_test_pixel(pixels, CROP_X + x/ZOOM, CROP_Y + y/ZOOM)
				copy(crop[(y*CROP_W*ZOOM + x)*3:], p[:])
			}
		}
		os.make_directory("bin/healthbars")
		return stbi.write_png(fmt.ctprintf("bin/healthbars/%s.png", name), CROP_W*ZOOM, CROP_H*ZOOM, 3, raw_data(crop), CROP_W*ZOOM*3) != 0
	}

	// Team mode: an enemy at 60% and a teammate at 85%. Writes
	// bin/healthbars/border-default.png (no border) and border-on.png.
	@(test)
	healthbar_border_renders_only_when_enabled :: proc(t: ^testing.T) {
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(BORDER_W, BORDER_H, "Healthbar border", nil, nil)
		if !testing.expect(t, window != nil) { return }
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.Viewport(0, 0, BORDER_W, BORDER_H)
		gl.ClearColor(f32(BORDER_BACKGROUND[0])/255, f32(BORDER_BACKGROUND[1])/255, f32(BORDER_BACKGROUND[2])/255, 1)

		local := shared.Player{active = true, is_you = true, uid = 1, team = 1, height = 11, health = 100, max_health = 100}
		enemy := shared.Player{active = true, uid = 2, team = 2, position = {-12, 0, -45}, height = 11, health = 60, max_health = 100}
		ally := shared.Player{active = true, uid = 3, team = 1, position = {12, 0, -45}, height = 11, health = 85, max_health = 100}
		client := Client{in_game = true, viewport_width = BORDER_W, viewport_height = BORDER_H, me = &local}
		client.mouse_state.locked = true
		client.krunker.connected = true
		append(&client.krunker_world.players, kproto.Krunker_World_Player{sid = 2, name = "Enemy"}, kproto.Krunker_World_Player{sid = 3, name = "Teammate"})
		client.camera = camera_init(math.PI/2)
		client.camera.position = {0, 12.8, 0}
		client.scene, client.ui = scene_init(), ui_init()
		append(&client.game.players, &local, &enemy, &ally)
		defer {
			delete(client.game.players)
			delete(client.krunker_world.players)
			ui_fini(client.ui)
			scene_fini(client.scene)
			resource_cache_fini()
		}
		pixels := make([]u8, BORDER_W*BORDER_H*3, context.temp_allocator)

		border_test_draw(&client, pixels)
		enemy_bar, ally_bar := border_test_layout(&client, &enemy), border_test_layout(&client, &ally)
		testing.expect(t, border_test_pixel(pixels, 4, 4) == BORDER_BACKGROUND, "the background is the clear colour")
		testing.expectf(t, enemy_bar.bar_width > 60 && enemy_bar.bar_height > 7, "the plate is large enough to inspect (%v)", enemy_bar)
		off_enemy, off_ally := border_test_outline(pixels, enemy_bar), border_test_outline(pixels, ally_bar)
		testing.expectf(t, off_enemy == 0 && off_ally == 0, "by default nothing is drawn outside the bar (%d, %d pixels)", off_enemy, off_ally)
		fill_x, fill_y := int(enemy_bar.bar_left + enemy_bar.bar_width*0.3), int(enemy_bar.bar_top + enemy_bar.bar_height*0.5)
		fill_off := border_test_pixel(pixels, fill_x, fill_y)
		testing.expect(t, border_test_preview(pixels, "border-default"))

		client.hud_settings.healthbar_border = true
		border_test_draw(&client, pixels)
		on_enemy, on_ally := border_test_outline(pixels, enemy_bar), border_test_outline(pixels, ally_bar)
		testing.expectf(t, on_enemy > 100 && on_ally > 100, "the border outlines both bars when enabled (%d, %d pixels)", on_enemy, on_ally)
		edge := 765
		for x in int(enemy_bar.bar_left) - 2 ..= int(enemy_bar.bar_left) - 1 {
			p := border_test_pixel(pixels, x, fill_y)
			edge = min(edge, int(p[0]) + int(p[1]) + int(p[2]))
		}
		testing.expectf(t, edge < 120, "the border is dark (channel sum %d)", edge)
		testing.expect(t, border_test_pixel(pixels, fill_x, fill_y) == fill_off, "the border leaves the fill unchanged")
		testing.expect(t, border_test_preview(pixels, "border-on"))
		testing.expect(t, gl.GetError() == gl.NO_ERROR)
	}
}
