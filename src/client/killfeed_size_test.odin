package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import menuui "../menu"
import shared "../shared"

when ODIN_TEST {
	@(test)
	kill_feed_size_setting_stages_saves_and_persists :: proc(t: ^testing.T) {
		testing.expect_value(t, menuui.kill_feed_size({}), menuui.KILL_FEED_DEFAULT_SIZE)
		testing.expect_value(t, menuui.kill_feed_size({kill_feed_size = 9}), menuui.KILL_FEED_MAX_SIZE)
		testing.expect_value(t, menuui.kill_feed_size({kill_feed_size = -1}), menuui.KILL_FEED_DEFAULT_SIZE)

		client := Client{}
		view := menuui.View{}
		client.menu.page = .SETTINGS
		menuui.prepare_settings(&client.menu, view)
		testing.expect_value(t, menuui.settings_slider_value(&client.menu, view, {kind = .KILL_FEED_SIZE}), 2)
		menuui.activate(&client.menu, {action = {kind = .KILL_FEED_SIZE, value = 1.44}})
		testing.expect_value(t, client.menu.settings_draft.hud.kill_feed_size, 1.4)
		menuui.activate(&client.menu, {action = {kind = .KILL_FEED_SIZE, value = 0.2}})
		testing.expect_value(t, client.menu.settings_draft.hud.kill_feed_size, 1)
		menuui.activate(&client.menu, {action = {kind = .KILL_FEED_SIZE, value = 40}})
		testing.expect_value(t, client.menu.settings_draft.hud.kill_feed_size, 3)
		testing.expect(t, client.hud_settings.kill_feed_size == 0, "the draft does not apply before Save")
		menu_apply_action(&client, {kind = .SETTINGS_SAVE})
		testing.expect_value(t, client.hud_settings.kill_feed_size, 3)

		// Settings > HUD > Reset restores 2x.
		defaults := client_settings_default_values()
		draft := client.menu.settings_draft
		menuui.settings_reset_tab(&draft, defaults, .HUD)
		testing.expect_value(t, menuui.kill_feed_size(draft.hud), 2)

		// Krunker has no such key: import leaves it alone.
		imported := menuui.Settings_Values{hud = {kill_feed_size = 2.5}}
		_, err := menuui.krunker_settings_import(&imported, `{"showKills":true,"feedLimit":5}`)
		testing.expect(t, len(err) == 0 && imported.hud.kill_feed_size == 2.5)

		// client-settings.json: files without the key get 2x; the value persists.
		path := "bin/killfeed-size-settings-test.json"
		defer os.remove(path)
		legacy := `{"version":1,"hud":{"hide_kill_feed":false,"kill_feed_limit":6}}`
		testing.expect(t, os.write_entire_file(path, transmute([]u8)legacy) == nil)
		loaded := client_settings_load(path)
		testing.expect(t, menuui.kill_feed_size(loaded.hud) == 2 && menuui.kill_feed_limit(loaded.hud) == 6, "older settings files get the 2x default")
		loaded.hud.kill_feed_size = 2.7
		testing.expect(t, client_settings_save(loaded, path))
		again := client_settings_load(path)
		testing.expect_value(t, again.hud.kill_feed_size, 2.7)
	}

	@(private = "file")
	size_frame :: proc(client: ^Client, pixels: []u8) {
		gpu_clear(color = true, depth = true)
		ui_update(client.ui, f32(client.viewport_width), f32(client.viewport_height))
		kill_feed_render(client)
		test_read_rgb(0, 0, client.viewport_width, client.viewport_height, raw_data(pixels))
	}

	// The changed pixels' bounds in screen pixels (top-down), and how many fall
	// inside `avoid` (x1, y1, x2, y2).
	@(private = "file")
	size_bounds :: proc(client: ^Client, before, after: []u8, avoid: [4]f32) -> (left, top, right, bottom: f32, overlap, changed: int) {
		w, h := int(client.viewport_width), int(client.viewport_height)
		left, top = f32(w), f32(h)
		for y in 0..<h {
			for x in 0..<w {
				o := ((h-1-y)*w + x)*3
				if before[o] == after[o] && before[o+1] == after[o+1] && before[o+2] == after[o+2] { continue }
				changed += 1
				fx, fy := f32(x), f32(y)
				left, right, top, bottom = min(left, fx), max(right, fx), min(top, fy), max(bottom, fy)
				if fx >= avoid[0] && fx <= avoid[2] && fy >= avoid[1] && fy <= avoid[3] { overlap += 1 }
			}
		}
		return
	}

	@(test)
	kill_feed_size_renders_at_each_resolution :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		test_gpu := test_gpu_open(640, 360, "Killfeed size")
		if !testing.expect(t, test_gpu.ok, "no GPU device for the test") do return
		defer test_gpu_close(&test_gpu, t)
		g_test_gpu = &test_gpu
		window := test_gpu.window
		gpu_set_clear_color({0.42, 0.55, 0.62})
		framebuffer: Gpu_Render_Target
		defer test_gpu_target_destroy(&framebuffer)
		client := Client{ui = ui_init()}
		defer { overlay_fini(); ui_fini(client.ui); resource_cache_fini() }
		client.game.weapons = shared.g_weapons()
		os.make_directory("bin/killfeed")

		// Five lines with Krunker-length (up to 16 character) names.
		entries := [?]Kill_Feed_Entry{
			{has_killer = true, killer = kill_feed_name("Me", true, 1, 1), victim = kill_feed_name("Sidney_Prescott", false, 2, 1), weapon_id = 1, headshot = true},
			{has_killer = true, killer = kill_feed_name("Ash_Ketchum_420", false, 2, 1), victim = kill_feed_name("Me", true, 1, 1), weapon_id = 12},
			{has_killer = true, killer = kill_feed_name("Teammate", false, 1, 1), victim = kill_feed_name("HunterKiller", false, 2, 1), weapon_id = 0, wallbang = true, headshot = true},
			{has_killer = true, victim = kill_feed_name("Rocketeer", false, 2, 1), weapon_id = 8},
			{has_killer = false, victim = kill_feed_name("Faller", false, 1, 1), phrase = 2},
		}
		for size in ([?][2]i32{{1280, 720}, {1920, 1080}, {2560, 1600}}) {
			w, h := size[0], size[1]
			test_gpu_target_destroy(&framebuffer)
			framebuffer = test_gpu_target(w, h)
			if !testing.expect(t, framebuffer != 0) { return }
			test_gpu_use_target(framebuffer, w, h)
			g_active_texture = 0
			client.viewport_width, client.viewport_height = w, h
			gpu_set_target(test_gpu_current_target(), w, h)
			empty := make([]u8, int(w*h*3)); defer delete(empty)
			full := make([]u8, len(empty)); defer delete(full)
			kill_feed_clear(&client.kill_feed)
			client.hud_settings = {}
			size_frame(&client, empty)
			for entry in entries { kill_feed_push(&client.kill_feed, entry, menuui.kill_feed_limit(client.hud_settings)) }
			s := client.ui.scale
			// The round/score panel at the top centre (overlay.odin: two 80 px
			// score boxes, a 104 px round box and 8 px gaps, 84 px tall).
			panel_half := (80*2 + 104 + 8)*s*0.5
			panel := [4]f32{f32(w)*0.5 - panel_half, 20*s, f32(w)*0.5 + panel_half, 104*s}
			one_x_bottom: f32
			for multiplier in ([?]f32{1, 2, 3}) {
				client.hud_settings.kill_feed_size = multiplier
				size_frame(&client, full)
				left, top, right, bottom, overlap, changed := size_bounds(&client, empty, full, panel)
				k := s*multiplier
				label := fmt.tprintf("%dx%d at %vx", w, h, multiplier)
				testing.expectf(t, changed > 0, "%s: the feed draws", label)
				// The 20 px inset from the top and right edges scales too.
				testing.expectf(t, abs(top - 20*k) <= 1.5 && abs(f32(w) - 1 - right - 20*k) <= 1.5, "%s: inset %v/%v, want %v", label, top, f32(w)-1-right, 20*k)
				// Five 38 px lines on a 48 px pitch.
				testing.expectf(t, abs(bottom - (20 + 4*48 + 38)*k) <= 2, "%s: bottom %v, want %v", label, bottom, (20 + 4*48 + 38)*k)
				if multiplier == 1 { one_x_bottom = bottom } else { testing.expectf(t, abs(bottom - one_x_bottom*multiplier) <= 2*multiplier, "%s: everything scales together (bottom %v, 1x %v)", label, bottom, one_x_bottom) }
				// Top-right only: right half, upper 60%, clear of the score panel.
				// FPS and ping sit top-left beside the timer (fps_render).
				testing.expectf(t, left > f32(w)*0.5 && bottom < f32(h)*0.6, "%s: stays in the top-right (left %v bottom %v)", label, left, bottom)
				testing.expectf(t, overlap == 0, "%s: %d pixels over the top-centre score panel", label, overlap)
				stbi.write_png(fmt.ctprintf("bin/killfeed/killfeed-%dx%d-%vx.png", w, h, multiplier), w, h, 3, &full[(h-1)*w*3], -w*3)
			}
		}
		testing.expect(t, test_gpu_no_error())
	}
}
