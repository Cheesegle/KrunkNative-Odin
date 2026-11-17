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
	@(private = "file") NAMETAG_W :: 1920
	@(private = "file") NAMETAG_H :: 1080
	@(private = "file") NAMETAG_BACKGROUND :: [3]u8{107, 128, 143}

	@(test)
	nametag_size_scales_only_the_name :: proc(t: ^testing.T) {
		testing.expect(t, menuui.nametag_scale({}) == 1, "unset size is 100%")
		testing.expect(t, menuui.nametag_scale({nametag_scale = math.nan_f32()}) == 1, "NaN is 100%")
		testing.expect(t, menuui.nametag_scale({nametag_scale = 0.1}) == 0.75 && menuui.nametag_scale({nametag_scale = 9}) == 2, "size is clamped to 75-200%")
		testing.expect(t, menuui.nametag_scale({nametag_scale = 1.5}) == 1.5, "sizes in range are kept")

		screen := shared.Vec2{500, 300}
		normal := player_nameplate_layout(screen, 2, 40, true)
		for scale in ([2]f32{0.75, 2}) {
			scaled := player_nameplate_layout(screen, 2, 40, true, scale)
			testing.expect(t, scaled.name_size == normal.name_size*scale, "the name size scales")
			testing.expect(t, scaled.bar_left == normal.bar_left && scaled.bar_top == normal.bar_top && scaled.bar_width == normal.bar_width && scaled.bar_height == normal.bar_height, "the bar keeps Krunker's size")
			testing.expect(t, scaled.name_x == scaled.bar_left && scaled.name_baseline == normal.name_baseline, "the name stays left-aligned with the bar on the same baseline")
		}
		centred := player_nameplate_layout(screen, 2, 40, false, 2)
		testing.expect(t, centred.name_x == 500 - 80 && centred.name_size == 80, "without a bar the scaled name stays centred")
		long := player_nameplate_layout(screen, 1, 300, true, 2)
		testing.expect(t, abs(long.name_size - 20*425.0/300) < 1e-3, "the 425-unit width cap holds at any size")
	}

	@(test)
	nametag_style_defaults_and_persists :: proc(t: ^testing.T) {
		defaults := client_settings_default_values()
		testing.expect(t, defaults.hud.nametag_scale == 1 && defaults.hud.nametag_colors == {enemy = 0xeb5656, team = 0xffffff}, "defaults are 100%, white names and Krunker's #EB5656 for enemies")
		testing.expect(t, menuui.nametag_colors_validate({}) == menuui.DEFAULT_NAMETAG_COLORS, "a zero value predates the setting")
		testing.expect(t, menuui.nametag_colors_validate({enemy = 0xff123456}) == {enemy = 0x123456}, "colours are masked to RGB; one black colour is kept")

		path := "bin/client-settings-nametag-style-test.json"
		defer os.remove(path)
		legacy := `{"version":1,"hud":{"hide_timer":true,"hide_nametags":false,"hide_healthbars":false}}`
		testing.expect(t, os.write_entire_file(path, transmute([]u8)legacy) == nil)
		loaded := client_settings_load(path)
		testing.expect(t, loaded.hud.hide_timer && loaded.hud.nametag_scale == 1 && loaded.hud.nametag_colors == menuui.DEFAULT_NAMETAG_COLORS, "older settings files get the defaults")
		loaded.hud.nametag_scale, loaded.hud.nametag_colors = 1.5, {enemy = 0x3366ff, team = 0xffcc00}
		testing.expect(t, client_settings_save(loaded, path))
		again := client_settings_load(path)
		testing.expect(t, again.hud.nametag_scale == 1.5 && again.hud.nametag_colors == {enemy = 0x3366ff, team = 0xffcc00}, "size and colours persist")
		again.hud.nametag_scale = 7
		testing.expect(t, client_settings_validate(again).hud.nametag_scale == 2, "an out-of-range file value is clamped")

		state := menuui.State{settings_active = true}
		state.settings_draft.hud = defaults.hud
		menuui.activate(&state, {action = {kind = .NAMETAG_SIZE, value = 1.75}})
		testing.expect(t, state.settings_draft.hud.nametag_scale == 1.75 && menuui.settings_slider_value(&state, {}, {kind = .NAMETAG_SIZE}) == 1.75, "the slider sets the draft size")
		menuui.activate(&state, {action = {kind = .NAMETAG_SIZE, value = 5}})
		testing.expect(t, state.settings_draft.hud.nametag_scale == 2, "the slider is capped at 200%")
		menuui.activate(&state, {action = {kind = .NAMETAG_SIZE, value = 0.01}})
		testing.expect(t, state.settings_draft.hud.nametag_scale == 0.75, "the slider stops at 75%")
		testing.expect(t, menuui.settings_percent_action(.NAMETAG_SIZE), "the size shows as a percentage")
		testing.expect(t, menuui.settings_color_value(&state.settings_draft, menuui.NAMETAG_ENEMY_COLOR_FIELD) == &state.settings_draft.hud.nametag_colors.enemy &&
			menuui.settings_color_value(&state.settings_draft, menuui.NAMETAG_TEAM_COLOR_FIELD) == &state.settings_draft.hud.nametag_colors.team, "each picker edits its own colour")
		menuui.activate(&state, {action = {kind = .CROSSHAIR_COLOR, index = menuui.NAMETAG_ENEMY_COLOR_FIELD}})
		testing.expect(t, string(state.color_buffer[:state.color_length]) == "#EB5656", "the picker opens on the current colour")
		state.color_length = copy(state.color_buffer[:], "#00ffcc")
		testing.expect(t, menuui.settings_color_commit(&state) && state.settings_draft.hud.nametag_colors == {enemy = 0x00ffcc, team = 0xffffff}, "a typed colour changes only the enemy name colour")
		menuui.settings_reset_tab(&state.settings_draft, defaults, .HUD)
		testing.expect(t, state.settings_draft.hud.nametag_scale == 1 && state.settings_draft.hud.nametag_colors == menuui.DEFAULT_NAMETAG_COLORS, "Reset on the HUD tab restores size and colours")
	}

	@(private = "file")
	nametag_test_draw :: proc(client: ^Client, pixels: []u8) {
		healthbar_test_settle(client)
		gpu_clear(color = true, depth = true)
		scene_render(client.scene, &client.camera, f32(client.viewport_width), f32(client.viewport_height))
		player_healthbars_render(client)
		test_read_rgb(0, 0, NAMETAG_W, NAMETAG_H, raw_data(pixels))
	}

	@(private = "file")
	nametag_test_pixel :: proc(pixels: []u8, x, y: int) -> [3]u8 {
		i := ((NAMETAG_H-1-y)*NAMETAG_W + x)*3
		return {pixels[i], pixels[i+1], pixels[i+2]}
	}

	@(private = "file")
	nametag_test_layout :: proc(client: ^Client, player: ^shared.Player) -> Nameplate_Layout {
		anchor := player_nameplate_anchor(player)
		screen, _ := player_healthbar_project(client.camera.projection_matrix*client.camera.world_inverse_matrix, anchor, client.ui.width, client.ui.height)
		return player_nameplate_layout({screen.x, screen.y}, client.ui.scale*player_nameplate_scale(client.camera.position, anchor), 0, true)
	}

	// Bounds of the pixels within 40 of `color` above a bar (its name).
	@(private = "file")
	nametag_test_bounds :: proc(pixels: []u8, layout: Nameplate_Layout, color: [3]u8) -> (left, right, top, bottom, count: int) {
		left, top = max(int), max(int)
		right, bottom = -1, -1
		for y in max(0, int(layout.bar_top) - 120) ..< int(layout.bar_top + layout.bar_height) {
			for x in int(layout.bar_left) - 20 ..< min(NAMETAG_W, int(layout.bar_left) + 420) {
				p := nametag_test_pixel(pixels, x, y)
				if abs(int(p[0]) - int(color[0])) + abs(int(p[1]) - int(color[1])) + abs(int(p[2]) - int(color[2])) > 40 { continue }
				left, right, top, bottom = min(left, x), max(right, x), min(top, y), max(bottom, y)
				count += 1
			}
		}
		return
	}

	@(private = "file")
	nametag_test_rgb :: proc(hex: u32) -> [3]u8 { return {u8(hex >> 16), u8(hex >> 8), u8(hex)} }

	// A 560x110 crop around the two plates, upscaled 2x for review.
	@(private = "file")
	nametag_test_preview :: proc(pixels: []u8, name: string) -> bool {
		CROP_W, CROP_H, CROP_X, CROP_Y, ZOOM :: 560, 110, 680, 470, 2
		crop := make([]u8, CROP_W*CROP_H*3*ZOOM*ZOOM, context.temp_allocator)
		for y in 0 ..< CROP_H*ZOOM {
			for x in 0 ..< CROP_W*ZOOM {
				p := nametag_test_pixel(pixels, CROP_X + x/ZOOM, CROP_Y + y/ZOOM)
				copy(crop[(y*CROP_W*ZOOM + x)*3:], p[:])
			}
		}
		os.make_directory("bin/healthbars")
		return stbi.write_png(fmt.ctprintf("bin/healthbars/%s.png", name), CROP_W*ZOOM, CROP_H*ZOOM, 3, raw_data(crop), CROP_W*ZOOM*3) != 0
	}

	// Team mode: an enemy at 60% and a teammate at 85%. Writes
	// bin/healthbars/nametag-{default,min,max,colors}.png.
	@(test)
	nametag_size_and_colors_render :: proc(t: ^testing.T) {
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		test_gpu := test_gpu_open(NAMETAG_W, NAMETAG_H, "Nametag size and colour")
		if !testing.expect(t, test_gpu.ok, "no GPU device for the test") do return
		defer test_gpu_close(&test_gpu, t)
		g_test_gpu = &test_gpu
		window := test_gpu.window
		gpu_set_target(test_gpu_current_target(), NAMETAG_W, NAMETAG_H)
		gpu_set_clear_color({f32(NAMETAG_BACKGROUND[0])/255, f32(NAMETAG_BACKGROUND[1])/255, f32(NAMETAG_BACKGROUND[2])/255})

		local := shared.Player{active = true, is_you = true, uid = 1, team = 1, height = 11, health = 100, max_health = 100}
		enemy := shared.Player{active = true, uid = 2, team = 2, position = {-12, 0, -45}, height = 11, health = 60, max_health = 100}
		ally := shared.Player{active = true, uid = 3, team = 1, position = {12, 0, -45}, height = 11, health = 85, max_health = 100}
		client := Client{in_game = true, viewport_width = NAMETAG_W, viewport_height = NAMETAG_H, me = &local}
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
		pixels := make([]u8, NAMETAG_W*NAMETAG_H*3, context.temp_allocator)
		white, red := [3]u8{255, 255, 255}, nametag_test_rgb(0xeb5656)

		// Default: Krunker's look, white teammate and #EB5656 enemy names.
		client.hud_settings.nametag_scale, client.hud_settings.nametag_colors = 1, menuui.DEFAULT_NAMETAG_COLORS
		nametag_test_draw(&client, pixels)
		enemy_bar, ally_bar := nametag_test_layout(&client, &enemy), nametag_test_layout(&client, &ally)
		l1, r1, _, b1, n1 := nametag_test_bounds(pixels, ally_bar, white)
		_, _, _, _, enemy_red := nametag_test_bounds(pixels, enemy_bar, red)
		testing.expectf(t, n1 > 30 && enemy_red > 30, "both names render in their default colours (%d white, %d red)", n1, enemy_red)
		testing.expect(t, nametag_test_preview(pixels, "nametag-default"))
		client.hud_settings = {}
		nametag_test_draw(&client, pixels)
		l0, r0, _, b0, n0 := nametag_test_bounds(pixels, ally_bar, white)
		testing.expect(t, l0 == l1 && r0 == r1 && b0 == b1 && n0 == n1, "unset settings (older files) draw exactly the default")

		// 50% and 200%: the name scales from the bar's left edge and stays above the bar.
		width1 := f32(r1 - l1 + 1)
		for scale in ([2]f32{menuui.NAMETAG_SCALE_MIN, menuui.NAMETAG_SCALE_MAX}) {
			client.hud_settings.nametag_scale = scale
			nametag_test_draw(&client, pixels)
			left, right, _, bottom, count := nametag_test_bounds(pixels, ally_bar, white)
			ratio := f32(right - left + 1)/width1
			testing.expectf(t, count > 5 && abs(ratio - scale) < 0.15*scale, "at %v%% the name is about %vx as wide (%v)", scale*100, scale, ratio)
			testing.expectf(t, abs(left - l1) <= 2, "at %v%% the name keeps the bar's left edge (%d vs %d)", scale*100, left, l1)
			testing.expectf(t, bottom < int(ally_bar.bar_top) - 1, "at %v%% the name stays above the bar (bottom %d, bar top %v)", scale*100, bottom, ally_bar.bar_top)
			bar_after := nametag_test_layout(&client, &ally)
			testing.expect(t, bar_after == ally_bar, "the bar keeps its size and place")
			testing.expect(t, nametag_test_preview(pixels, scale < 1 ? "nametag-min" : "nametag-max"))
		}

		// Custom colours: teammates (and FFA) in Nametag color, enemies in Enemy nametag color.
		client.hud_settings = {nametag_scale = 1, nametag_colors = {enemy = 0x3366ff, team = 0xffcc00}}
		nametag_test_draw(&client, pixels)
		_, _, _, _, ally_custom := nametag_test_bounds(pixels, ally_bar, nametag_test_rgb(0xffcc00))
		_, _, _, _, enemy_custom := nametag_test_bounds(pixels, enemy_bar, nametag_test_rgb(0x3366ff))
		_, _, _, _, ally_white := nametag_test_bounds(pixels, ally_bar, white)
		testing.expectf(t, ally_custom > 30 && enemy_custom > 30 && ally_white == 0, "custom name colours apply per team (%d team, %d enemy, %d white)", ally_custom, enemy_custom, ally_white)
		testing.expect(t, nametag_test_preview(pixels, "nametag-colors"))
		local.team, enemy.team, ally.team = 0, 0, 0
		nametag_test_draw(&client, pixels)
		_, _, _, _, ffa_team := nametag_test_bounds(pixels, enemy_bar, nametag_test_rgb(0xffcc00))
		_, _, _, _, ffa_enemy := nametag_test_bounds(pixels, enemy_bar, nametag_test_rgb(0x3366ff))
		testing.expectf(t, ffa_team > 30 && ffa_enemy == 0, "FFA names use Nametag color, as Krunker draws them white (%d, %d)", ffa_team, ffa_enemy)
		testing.expect(t, test_gpu_no_error())
	}
}
