package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import kproto "../krunker"
import menuui "../menu"
import shared "../shared"

when ODIN_TEST {
	@(private = "file") COLORS_W :: 1920
	@(private = "file") COLORS_H :: 1080
	@(private = "file") COLORS_BACKGROUND :: [3]u8{107, 128, 143}

	@(test)
	healthbar_colors_default_to_krunker_and_persist :: proc(t: ^testing.T) {
		testing.expect(t, menuui.DEFAULT_HEALTHBAR_COLORS == {enemy = 0xeb5656, team = 0x9eeb56}, "Krunker's healthColE and healthColT defaults")
		testing.expect(t, client_settings_default_values().hud.healthbar_colors == menuui.DEFAULT_HEALTHBAR_COLORS, "Reset and new installs use Krunker's colours")
		testing.expect(t, menuui.healthbar_colors_validate({}) == menuui.DEFAULT_HEALTHBAR_COLORS, "a zero value predates the setting")
		testing.expect(t, menuui.healthbar_colors_validate({enemy = 0xff123456, team = 0}) == {enemy = 0x123456, team = 0}, "colours are masked to RGB; one black colour is kept")

		path := "bin/client-settings-healthbar-colors-test.json"
		defer os.remove(path)
		legacy := `{"version":1,"hud":{"hide_timer":true,"hide_nametags":false,"hide_healthbars":false}}`
		testing.expect(t, os.write_entire_file(path, transmute([]u8)legacy) == nil)
		loaded := client_settings_load(path)
		testing.expect(t, loaded.hud.hide_timer && loaded.hud.healthbar_colors == menuui.DEFAULT_HEALTHBAR_COLORS, "older settings files get Krunker's colours")
		loaded.hud.healthbar_colors = {enemy = 0x3366ff, team = 0xffaa00}
		testing.expect(t, client_settings_save(loaded, path))
		again := client_settings_load(path)
		testing.expect(t, again.hud.healthbar_colors == {enemy = 0x3366ff, team = 0xffaa00} && again.hud.hide_timer, "custom colours persist")

		// The colour picker edits the draft; HUD Reset restores the defaults.
		state := menuui.State{settings_active = true}
		state.settings_draft.hud.healthbar_colors = menuui.DEFAULT_HEALTHBAR_COLORS
		testing.expect(t, menuui.settings_color_value(&state.settings_draft, menuui.HEALTHBAR_ENEMY_COLOR_FIELD) == &state.settings_draft.hud.healthbar_colors.enemy &&
			menuui.settings_color_value(&state.settings_draft, menuui.HEALTHBAR_TEAM_COLOR_FIELD) == &state.settings_draft.hud.healthbar_colors.team, "each picker edits its own colour")
		menuui.activate(&state, {action = {kind = .CROSSHAIR_COLOR, index = menuui.HEALTHBAR_TEAM_COLOR_FIELD}})
		testing.expect(t, state.color_edit == menuui.HEALTHBAR_TEAM_COLOR_FIELD && string(state.color_buffer[:state.color_length]) == "#9EEB56", "the picker opens on the current colour")
		state.color_length = copy(state.color_buffer[:], "#00ffcc")
		testing.expect(t, menuui.settings_color_commit(&state), "a typed colour commits")
		testing.expect(t, state.settings_draft.hud.healthbar_colors == {enemy = 0xeb5656, team = 0x00ffcc}, "only the team colour changes")
		menuui.settings_reset_tab(&state.settings_draft, client_settings_default_values(), .HUD)
		testing.expect(t, state.settings_draft.hud.healthbar_colors == menuui.DEFAULT_HEALTHBAR_COLORS, "Reset on the HUD tab restores Krunker's colours")
	}

	@(test)
	healthbar_colors_map_to_krunker_settings :: proc(t: ^testing.T) {
		values := client_settings_default_values()
		result, err := menuui.krunker_settings_import(&values, `{"healthColT":"#00ffff","healthColE":"#ff00ff"}`)
		testing.expect_value(t, err, "")
		testing.expect_value(t, result.imported, 2)
		testing.expect(t, values.hud.healthbar_colors == {enemy = 0xff00ff, team = 0x00ffff}, "healthColE and healthColT import")
		exported := menuui.krunker_settings_export(values, context.temp_allocator)
		testing.expect(t, strings.contains(exported, `"healthColT":"#00ffff"`) && strings.contains(exported, `"healthColE":"#ff00ff"`), "custom colours export under Krunker's keys")
		_, err = menuui.krunker_settings_import(&values, `{}`)
		testing.expect(t, values.hud.healthbar_colors == menuui.DEFAULT_HEALTHBAR_COLORS, "keys missing from an import reset to Krunker's defaults")
		testing.expect(t, !strings.contains(menuui.krunker_settings_export(values, context.temp_allocator), "healthCol"), "Krunker's defaults are not exported")
	}

	@(private = "file")
	colors_test_draw :: proc(client: ^Client, pixels: []u8) {
		healthbar_test_settle(client)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		scene_render(client.scene, &client.camera, f32(client.viewport_width), f32(client.viewport_height))
		player_healthbars_render(client)
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		gl.ReadPixels(0, 0, COLORS_W, COLORS_H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
	}

	@(private = "file")
	colors_test_pixel :: proc(pixels: []u8, x, y: int) -> [3]u8 {
		i := ((COLORS_H-1-y)*COLORS_W + x)*3
		return {pixels[i], pixels[i+1], pixels[i+2]}
	}

	@(private = "file")
	colors_test_layout :: proc(client: ^Client, player: ^shared.Player) -> Nameplate_Layout {
		anchor := player_nameplate_anchor(player)
		screen, _ := player_healthbar_project(client.camera.projection_matrix*client.camera.world_inverse_matrix, anchor, client.ui.width, client.ui.height)
		return player_nameplate_layout({screen.x, screen.y}, client.ui.scale*player_nameplate_scale(client.camera.position, anchor), 0, true)
	}

	// The bar fill colour, sampled inside the filled part.
	@(private = "file")
	colors_test_fill :: proc(pixels: []u8, layout: Nameplate_Layout) -> [3]u8 {
		return colors_test_pixel(pixels, int(layout.bar_left + layout.bar_width*0.25), int(layout.bar_top + layout.bar_height*0.5))
	}

	// Pixels of exactly `color` in the band above a bar, where its name is.
	@(private = "file")
	colors_test_name_pixels :: proc(pixels: []u8, layout: Nameplate_Layout, color: [3]u8) -> (count: int) {
		for y in int(layout.bar_top - 3*layout.bar_height) ..< int(layout.bar_top) {
			for x in int(layout.bar_left) ..< int(layout.bar_left + layout.bar_width) {
				if colors_test_pixel(pixels, x, y) == color { count += 1 }
			}
		}
		return
	}

	@(private = "file")
	colors_test_rgb :: proc(hex: u32) -> [3]u8 { return {u8(hex >> 16), u8(hex >> 8), u8(hex)} }

	// A 480x100 crop around the two plates, upscaled 2x for review.
	@(private = "file")
	colors_test_preview :: proc(pixels: []u8, name: string) -> bool {
		CROP_W, CROP_H, CROP_X, CROP_Y, ZOOM :: 480, 100, 720, 480, 2
		crop := make([]u8, CROP_W*CROP_H*3*ZOOM*ZOOM, context.temp_allocator)
		for y in 0 ..< CROP_H*ZOOM {
			for x in 0 ..< CROP_W*ZOOM {
				p := colors_test_pixel(pixels, CROP_X + x/ZOOM, CROP_Y + y/ZOOM)
				copy(crop[(y*CROP_W*ZOOM + x)*3:], p[:])
			}
		}
		os.make_directory("bin/healthbars")
		return stbi.write_png(fmt.ctprintf("bin/healthbars/%s.png", name), CROP_W*ZOOM, CROP_H*ZOOM, 3, raw_data(crop), CROP_W*ZOOM*3) != 0
	}

	// Team mode: an enemy at 60% and a teammate at 85%. Writes
	// bin/healthbars/colors-default.png and colors-custom.png.
	@(test)
	healthbar_colors_render_for_enemies_and_teammates :: proc(t: ^testing.T) {
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(COLORS_W, COLORS_H, "Healthbar colours", nil, nil)
		if !testing.expect(t, window != nil) { return }
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.Viewport(0, 0, COLORS_W, COLORS_H)
		gl.ClearColor(f32(COLORS_BACKGROUND[0])/255, f32(COLORS_BACKGROUND[1])/255, f32(COLORS_BACKGROUND[2])/255, 1)

		local := shared.Player{active = true, is_you = true, uid = 1, team = 1, height = 11, health = 100, max_health = 100}
		enemy := shared.Player{active = true, uid = 2, team = 2, position = {-12, 0, -45}, height = 11, health = 60, max_health = 100}
		ally := shared.Player{active = true, uid = 3, team = 1, position = {12, 0, -45}, height = 11, health = 85, max_health = 100}
		client := Client{in_game = true, viewport_width = COLORS_W, viewport_height = COLORS_H, me = &local}
		client.hud_settings.healthbar_colors = menuui.DEFAULT_HEALTHBAR_COLORS
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
		pixels := make([]u8, COLORS_W*COLORS_H*3, context.temp_allocator)

		colors_test_draw(&client, pixels)
		enemy_bar, ally_bar := colors_test_layout(&client, &enemy), colors_test_layout(&client, &ally)
		testing.expectf(t, enemy_bar.bar_width > 60 && enemy_bar.bar_height > 7, "the plate is large enough to inspect (%v)", enemy_bar)
		testing.expectf(t, colors_test_fill(pixels, enemy_bar) == colors_test_rgb(0xeb5656), "enemy bars default to Krunker's #EB5656 (%v)", colors_test_fill(pixels, enemy_bar))
		testing.expectf(t, colors_test_fill(pixels, ally_bar) == colors_test_rgb(0x9eeb56), "teammate bars default to Krunker's #9EEB56 (%v)", colors_test_fill(pixels, ally_bar))
		testing.expect(t, colors_test_name_pixels(pixels, enemy_bar, colors_test_rgb(0xeb5656)) > 10, "enemy names take the enemy healthbar colour in team modes")
		testing.expect(t, colors_test_name_pixels(pixels, ally_bar, {255, 255, 255}) > 10, "teammate names stay white")
		testing.expect(t, colors_test_preview(pixels, "colors-default"))

		// A zero value (older settings) draws Krunker's colours too.
		client.hud_settings.healthbar_colors = {}
		colors_test_draw(&client, pixels)
		testing.expect(t, colors_test_fill(pixels, enemy_bar) == colors_test_rgb(0xeb5656) && colors_test_fill(pixels, ally_bar) == colors_test_rgb(0x9eeb56), "unset colours render as Krunker's")

		client.hud_settings.healthbar_colors = {enemy = 0x3366ff, team = 0xffaa00}
		colors_test_draw(&client, pixels)
		testing.expectf(t, colors_test_fill(pixels, enemy_bar) == colors_test_rgb(0x3366ff), "a custom enemy colour fills enemy bars (%v)", colors_test_fill(pixels, enemy_bar))
		testing.expectf(t, colors_test_fill(pixels, ally_bar) == colors_test_rgb(0xffaa00), "a custom team colour fills teammate bars (%v)", colors_test_fill(pixels, ally_bar))
		testing.expect(t, colors_test_name_pixels(pixels, enemy_bar, colors_test_rgb(0x3366ff)) > 10, "enemy names follow the custom enemy colour")
		testing.expect(t, colors_test_name_pixels(pixels, ally_bar, {255, 255, 255}) > 10, "teammate names stay white")
		testing.expect(t, colors_test_preview(pixels, "colors-custom"))

		// FFA: everyone is an enemy; names stay white as in Krunker.
		local.team, enemy.team, ally.team = 0, 0, 0
		colors_test_draw(&client, pixels)
		testing.expect(t, colors_test_fill(pixels, enemy_bar) == colors_test_rgb(0x3366ff) && colors_test_fill(pixels, ally_bar) == colors_test_rgb(0x3366ff), "in FFA every bar uses the enemy colour")
		testing.expect(t, colors_test_name_pixels(pixels, enemy_bar, colors_test_rgb(0x3366ff)) == 0, "FFA names are white, not the enemy colour")
		testing.expect(t, gl.GetError() == gl.NO_ERROR)
	}
}

// A first run (no settings file) and a corrupt file must show Krunker's red
// in the colour pickers, not the stored 0 as black.
@(test)
healthbar_colors_default_without_a_settings_file :: proc(t: ^testing.T) {
	missing := client_settings_load("logs/__no_such_settings_file__.json")
	testing.expect_value(t, missing.hud.healthbar_colors, menuui.DEFAULT_HEALTHBAR_COLORS)
	testing.expect_value(t, missing.hud.nametag_colors, menuui.DEFAULT_NAMETAG_COLORS)
	testing.expect_value(t, missing.hud.nametag_scale, f32(1))
	path := "__corrupt_settings_test__.json"
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string("{not json")) == nil)
	defer os.remove(path)
	corrupt := client_settings_load(path)
	testing.expect_value(t, corrupt.hud.healthbar_colors, menuui.DEFAULT_HEALTHBAR_COLORS)
	testing.expect_value(t, corrupt.hud.nametag_colors, menuui.DEFAULT_NAMETAG_COLORS)
}
