package main

import "base:runtime"
import "core:bytes"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import mu "vendor:microui"
import stbi "vendor:stb/image"
import menuui "../menu"
import shared "../shared"

when ODIN_TEST {
	// Builds a needle at run time so this test's own code never contains it.
	debug_player_needle :: proc(parts: ..string) -> []u8 {
		return transmute([]u8)strings.concatenate(parts, context.temp_allocator)
	}

	// The Player section is developer-only: release builds must contain none of
	// its code. This reads the running test executable (built like the client,
	// with or without -define:KRODIN_DEV=true) for the section's strings.
	@(test)
	debug_player_strings_only_in_dev_builds :: proc(t: ^testing.T) {
		exe, err := os.read_entire_file(os.args[0], context.allocator)
		if !testing.expectf(t, err == nil, "read %s: %v", os.args[0], err) { return }
		defer delete(exe)
		needles := [?][]u8{
			debug_player_needle("ya", "w %.1f"),          // the Copy line's format
			debug_player_needle("Obj ", "size"),          // a Player section label
			debug_player_needle("Copied player ", "readout"), // the Copy log line
		}
		for needle in needles {
			found := bytes.index(exe, needle) >= 0
			testing.expectf(t, found == KRODIN_DEV, "%q in the executable: %v (KRODIN_DEV=%v)", string(needle), found, KRODIN_DEV)
		}
	}
}

when ODIN_TEST && KRODIN_DEV {
	// A small hand-built map:
	//   0 floor   (top y 0)          2 barrel cylinder (top y 8)
	//   1 crate   (top y 5)          3 wall            (z -31..-29, top y 30)
	//   4 a non-colliding box over the crate, which the lookup ignores.
	Debug_Player_Test_Map :: struct {
		objects: [5]shared.Object,
		map_inst: shared.Map,
	}

	debug_player_test_map :: proc(m: ^Debug_Player_Test_Map) {
		m.objects = {
			{prefab = .PLANE, active = true, collision_type = .BOX, position = {0, -1, 0}, scale = {200, 1, 200}},
			{prefab = .CRATE, active = true, collision_type = .BOX, position = {10, 0, 10}, scale = {10, 5, 10}},
			{prefab = .BARREL, active = true, collision_type = .CYLINDER, position = {-20, 0, 0}, scale = {4, 8, 4}},
			{prefab = .CUBE, active = true, collision_type = .BOX, position = {0, 0, -30}, scale = {40, 30, 2}},
			{prefab = .CUBE, active = true, collision_type = .NONE, position = {10, 0, 10}, scale = {10, 5.05, 10}},
		}
		for &object in m.objects { append(&m.map_inst.objects, &object) }
	}

	@(test)
	debug_player_contact_lookup :: proc(t: ^testing.T) {
		m := new(Debug_Player_Test_Map)
		defer { delete(m.map_inst.objects); free(m) }
		debug_player_test_map(m)
		player := shared.Player{scale = shared.GAME_CONSTANTS.player_scale, height = shared.GAME_CONSTANTS.player_height}
		Case :: struct { position: shared.Vec3, contact: Debug_Contact, index: int, what: string }
		cases := [?]Case{
			{{12, 5, 8}, .STANDING, 1, "on the crate's top (not the floor 5 below)"},
			{{14.9 + player.scale, 5, 10}, .STANDING, 1, "on the crate's edge"},
			{{-20, 8, 1}, .STANDING, 2, "on the barrel"},
			{{50, 0, 50}, .STANDING, 0, "on the floor"},
			{{0, 0, -29 + player.scale}, .STANDING, 0, "standing beats touching the wall"},
			{{0, 3, -29 + player.scale}, .TOUCHING, 3, "in the air against the wall"},
			{{10, 2, 10 - 5 - player.scale}, .TOUCHING, 1, "against the crate's side"},
			{{50, 20, 50}, .NONE, -1, "in the air"},
			{{500, 0, 500}, .NONE, -1, "off the map"},
		}
		for c in cases {
			player.position = c.position
			contact, index := debug_player_contact(&player, &m.map_inst)
			testing.expectf(t, contact == c.contact && index == c.index, "%s: got %v #%d, want %v #%d", c.what, contact, index, c.contact, c.index)
		}
		// Inactive objects are skipped; loaded maps' collision index is honoured.
		player.position = {12, 5, 8}
		m.objects[1].active = false
		contact, index := debug_player_contact(&player, &m.map_inst)
		testing.expectf(t, contact == .NONE, "an inactive crate is not stood on: %v #%d", contact, index)
		m.objects[1].active = true
		append(&m.map_inst.collision_objects, 0, 2, 3)
		defer delete(m.map_inst.collision_objects)
		m.map_inst.collision_indexed = true
		contact, index = debug_player_contact(&player, &m.map_inst)
		testing.expectf(t, contact == .NONE, "objects outside the collision index are skipped: %v #%d", contact, index)
		player.position = {-20, 8, 1}
		contact, index = debug_player_contact(&player, &m.map_inst)
		testing.expectf(t, contact == .STANDING && index == 2, "indexed objects keep their map index: %v #%d", contact, index)
		testing.expect(t, debug_player_prefab_name(.CONTAINER_R) == "container_r")
	}

	// A local player standing on the crate, on the test map, in client.
	debug_player_test_setup :: proc(client: ^Client, m: ^Debug_Player_Test_Map) -> (me: ^shared.Player) {
		debug_player_test_map(m)
		client.game.map_inst = &m.map_inst
		me = new(shared.Player)
		me^ = {
			game = &client.game, active = true, is_you = true,
			scale = shared.GAME_CONSTANTS.player_scale, height = shared.GAME_CONSTANTS.player_height,
			position = {12, 5, 8}, velocity = {3, -1, 4},
			direction = {math.to_radians(f32(-10)), math.to_radians(f32(90))},
			crouch_val = 0.5, slide_timer = 0.2, on_ground = true, on_wall = 2,
		}
		client.me = me
		return
	}

	@(test)
	debug_player_readout_values :: proc(t: ^testing.T) {
		m := new(Debug_Player_Test_Map)
		defer { delete(m.map_inst.objects); free(m) }
		client := new(Client)
		me := debug_player_test_setup(client, m)
		defer { free(me); free(client) }
		g_map_name = "Sandstorm"
		defer g_map_name = ""

		r := debug_player_readout(client)
		near :: proc(a, b: f32) -> bool { return abs(a - b) < 1e-3 }
		testing.expect(t, r.valid && r.map_name == "Sandstorm" && r.mode_name == "-", "map and mode")
		testing.expectf(t, r.position == {12, 5, 8} && r.velocity == {3, -1, 4}, "position and velocity: %v %v", r.position, r.velocity)
		testing.expectf(t, near(r.yaw, 90) && near(r.pitch, -10), "yaw/pitch in degrees: %v %v", r.yaw, r.pitch)
		testing.expectf(t, near(r.horizontal_speed, 5), "horizontal speed ignores y: %v", r.horizontal_speed)
		testing.expect(t, r.on_ground && r.sliding && !r.on_ramp && !r.on_ladder && r.on_wall == 2 && near(r.crouch_val, 0.5), "flags")
		testing.expect(t, r.contact == .STANDING && r.object_index == 1 && r.object_prefab == "crate", "standing on the crate")
		testing.expect(t, r.object_position == {10, 0, 10} && r.object_size == {10, 5, 10}, "the crate's position and size")
		testing.expect(t, !r.live && r.corrections == 0, "offline has no server corrections")

		// Yaw wraps into [0, 360).
		me.direction.y = math.to_radians(f32(-90))
		testing.expectf(t, near(debug_player_readout(client).yaw, 270), "negative yaw wraps: %v", debug_player_readout(client).yaw)
		me.direction.y = math.to_radians(f32(90))

		// Live lobbies add the last server correction and Krunker's mode name.
		client.krunker.connected = true
		client.krunker_world.mode_index = 2
		client.krunker.prediction_corrections = 4
		client.krunker.last_correction, client.krunker.last_correction_ack = {0.3, 0, -0.4}, 117
		r = debug_player_readout(client)
		testing.expect(t, r.live && r.mode_name == "Hardpoint" && r.corrections == 4 && r.last_correction == {0.3, 0, -0.4} && r.correction_ack == 117, "live correction")
		client.krunker_world.mode_index = 99
		testing.expect(t, debug_player_readout(client).mode_name == "mode 99", "unknown modes show their index")
		client.krunker.connected = false
		client.krunker_world.mode_index = -1
		client.game.mode = new(shared.Game_Mode)
		defer free(client.game.mode)
		testing.expect(t, debug_player_readout(client).mode_name == "Free for All", "offline mode as the lobby names it")

		client.me = nil
		r = debug_player_readout(client)
		testing.expect(t, !r.valid && r.object_index == -1, "no player, no readout")
		client.me = me
	}

	@(test)
	debug_player_summary_format :: proc(t: ^testing.T) {
		r := Debug_Player_Readout{
			valid = true, map_name = "Sandstorm", position = {-186.554, 53, -309}, yaw = 90, crouch_val = 0,
			contact = .STANDING, object_index = 163, object_prefab = "crate",
		}
		testing.expectf(t, debug_player_summary(r) == "Sandstorm (-186.55, 53.00, -309.00) yaw 90.0 on crate #163 crouch 0.00", "standing: %q", debug_player_summary(r))
		r.contact, r.crouch_val = .TOUCHING, 1
		testing.expectf(t, debug_player_summary(r) == "Sandstorm (-186.55, 53.00, -309.00) yaw 90.0 touching crate #163 crouch 1.00", "touching: %q", debug_player_summary(r))
		r.contact, r.object_index = .NONE, -1
		testing.expectf(t, debug_player_summary(r) == "Sandstorm (-186.55, 53.00, -309.00) yaw 90.0 in air crouch 1.00", "in air: %q", debug_player_summary(r))
		testing.expect(t, debug_player_summary({map_name = "Sandstorm"}) == "Sandstorm (no player)")
		testing.expect(t, !strings.contains(debug_player_summary(r), "\n"), "one line")
	}

	debug_player_test_texts :: proc(dbg: ^Debug_UI) -> map[string]bool {
		texts := make(map[string]bool, context.temp_allocator)
		command: ^mu.Command
		for variant in mu.next_command_iterator(&dbg.ctx, &command) {
			if text, ok := variant.(^mu.Command_Text); ok { texts[text.str] = true }
		}
		return texts
	}

	@(test)
	debug_player_section :: proc(t: ^testing.T) {
		m := new(Debug_Player_Test_Map)
		defer { delete(m.map_inst.objects); free(m) }
		client, dbg := perf_test_debug_ui()
		defer { delete(dbg.player_copied); free(dbg); free(client) }
		me := debug_player_test_setup(client, m)
		defer free(me)
		g_map_name = "Sandstorm"
		defer g_map_name = ""

		// 1080p: everything fits without scrolling.
		debug_ui_layout(dbg, 1920, 1080)
		perf_test_frame(client, dbg, {})
		perf_test_frame(client, dbg, {})
		texts := debug_player_test_texts(dbg)
		testing.expect(t, texts["Player"] && texts["12.00, 5.00, 8.00"] && texts["3.00, -1.00, 4.00"] && texts["crate #1"] && texts["90.0"] && texts["-10.0"] && texts["5.000"], "the Player section starts expanded with the readout")
		testing.expect(t, texts["10.00, 0.00, 10.00"] && texts["10.00, 5.00, 10.00"] && texts["Sandstorm, -"] && texts["Copy"], "the object and map rows")
		testing.expect(t, texts["Performance"] && texts["Rendering"] && !dbg.overflow, "the other sections are still there and nothing scrolls")

		copy_at, has_copy := debug_test_text_pos(dbg, "Copy")
		if !testing.expect(t, has_copy, "the Copy button is visible") { return }
		debug_test_click(client, dbg, copy_at)
		testing.expectf(t, dbg.player_copied == "Sandstorm (12.00, 5.00, 8.00) yaw 90.0 on crate #1 crouch 0.50", "Copy puts the summary line on the clipboard: %q", dbg.player_copied)

		// 720p: the window stops at the screen's bottom and scrolls instead.
		debug_ui_layout(dbg, 1280, 720)
		for _ in 0..<3 { perf_test_frame(client, dbg, {}) }
		cnt := mu.get_container(&dbg.ctx, DEBUG_WINDOW_TITLE)
		testing.expectf(t, dbg.overflow && cnt.rect.y >= 0 && cnt.rect.y + cnt.rect.h <= 720, "the window is capped to the 720p screen: %v", cnt.rect)
		debug_ui_layout(dbg, 1920, 1080)
		for _ in 0..<3 { perf_test_frame(client, dbg, {}) }
		testing.expect(t, !dbg.overflow && cnt.scroll == {}, "back at 1080p it fits again, unscrolled")

		// Collapsed, the section builds nothing.
		header, _ := debug_test_text_pos(dbg, "Player")
		debug_test_click(client, dbg, header)
		perf_test_frame(client, dbg, {})
		texts = debug_player_test_texts(dbg)
		testing.expect(t, texts["Player"] && !texts["Pos"] && !texts["Copy"], "a collapsed Player section shows only its header")
	}

	// Hidden-window render of the debug window with the Player section open, in
	// a live lobby (so the server correction row shows). The window's pixels are
	// written to bin/debug_player/player_section.png.
	@(test)
	debug_player_section_renders :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		W, H :: 1920, 1080
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		test_gpu := test_gpu_open(640, 360, "Debug player")
		if !testing.expect(t, test_gpu.ok, "no GPU device for the test") do return
		defer test_gpu_close(&test_gpu, t)
		g_test_gpu = &test_gpu
		window := test_gpu.window
		gpu_set_clear_color({0.16, 0.18, 0.20})
		framebuffer: Gpu_Render_Target
		defer test_gpu_target_destroy(&framebuffer)
		test_gpu_target_destroy(&framebuffer)
		framebuffer = test_gpu_target(W, H)
		if !testing.expect(t, framebuffer != 0) { return }
		test_gpu_use_target(framebuffer, W, H)
		g_active_texture = 0
		gpu_set_target(test_gpu_current_target(), W, H)

		m := new(Debug_Player_Test_Map)
		defer { delete(m.map_inst.objects); free(m) }
		client := new(Client)
		defer free(client)
		client.ui, client.window, client.bindings = ui_init(), window, menuui.default_bindings()
		defer { debug_ui_fini(client); ui_fini(client.ui); resource_cache_fini() }
		client.viewport_width, client.viewport_height = W, H
		me := debug_player_test_setup(client, m)
		defer free(me)
		me.position = {-186.55, 53, -309}
		m.objects[1].position, m.objects[1].scale = {-186, 48, -309}, {10, 5, 10}
		client.krunker.connected = true
		client.krunker_world.mode_index = 0
		client.krunker.prediction_corrections = 12
		client.krunker.last_correction, client.krunker.last_correction_ack = {0.012, 0, -0.031}, 4211
		g_map_name = "Sandstorm"
		defer g_map_name = ""
		perf_overlay_set(client, true)
		for i in 0..<300 { perf_push(&client.perf, i % 50 == 0 ? 12 : 6.9, 2.5) }
		client.mouse_state.locked = true
		for _ in 0..<3 {
			gpu_clear(color = true, depth = false)
			ui_update(client.ui, W, H)
			debug_ui_update(client)
			debug_ui_render(client)
		}
		testing.expect(t, test_gpu_no_error())
		rect := mu.get_container(&client.debug_ui.ctx, DEBUG_WINDOW_TITLE).rect
		testing.expectf(t, !client.debug_ui.overflow && rect.y + rect.h <= H, "the window fits 1080p: %v", rect)
		texts := debug_player_test_texts(client.debug_ui)
		testing.expect(t, texts["-186.55, 53.00, -309.00"] && texts["crate #1"] && texts["Sandstorm, Free for All"], "the readout is drawn")
		testing.expect(t, texts["0.033 at #4211 (12)"], "the live server correction is drawn")

		// The window region, flipped to top-down rows, one pixel of margin.
		x0, y0 := max(int(rect.x) - 1, 0), max(int(rect.y) - 1, 0)
		w, h := min(int(rect.w) + 2, W - x0), min(int(rect.h) + 2, H - y0)
		pixels := make([]u8, w*h*3)
		defer delete(pixels)
		test_read_rgb(i32(x0), i32(H - y0 - h), i32(w), i32(h), raw_data(pixels))
		lit := 0
		for i := 0; i < len(pixels); i += 3 { if pixels[i] > 200 && pixels[i+1] > 200 && pixels[i+2] > 200 { lit += 1 } }
		testing.expectf(t, lit > 500, "white text is drawn inside the window (%d bright pixels)", lit)
		os.make_directory("bin/debug_player")
		testing.expect(t, stbi.write_png("bin/debug_player/player_section.png", i32(w), i32(h), 3, &pixels[(h - 1)*w*3], -i32(w)*3) != 0)
	}
}
