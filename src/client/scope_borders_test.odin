package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import menuui "../menu"
import shared "../shared"

when ODIN_TEST {
	@(test)
	scope_borders_setting_defaults_persists_and_maps :: proc(t: ^testing.T) {
		testing.expect(t, !client_settings_defaults().hud.hide_scope_borders, "scope borders show by default, as Krunker's scopeBorders (val:!0)")
		path := "bin/client-settings-scope-borders-test.json"
		defer os.remove(path)
		legacy := `{"version":1,"hud":{"hide_timer":true}}`
		testing.expect(t, os.write_entire_file(path, transmute([]u8)legacy) == nil)
		loaded := client_settings_load(path)
		testing.expect(t, loaded.hud.hide_timer && !loaded.hud.hide_scope_borders, "older settings files keep the borders")
		loaded.hud.hide_scope_borders = true
		testing.expect(t, client_settings_save(loaded, path))
		again := client_settings_load(path)
		testing.expect(t, again.hud.hide_scope_borders && again.hud.hide_timer, "the scope borders toggle persists")

		// Draft, then Save/Cancel.
		client := Client{}
		client.menu.page = .SETTINGS
		menuui.prepare_settings(&client.menu, {hud = client.hud_settings})
		menuui.activate(&client.menu, {action = {kind = .HUD_TOGGLE, index = 8}})
		testing.expect(t, client.menu.settings_draft.hud.hide_scope_borders && !client.menu.settings_draft.hud.hide_healthbars && !client.menu.settings_draft.hud.healthbar_border,
			"Scope borders toggles only the borders")
		testing.expect(t, !client.hud_settings.hide_scope_borders, "the toggle must not commit before Save")
		menuui.activate(&client.menu, {action = {kind = .SETTINGS_CANCEL}})
		testing.expect(t, !client.hud_settings.hide_scope_borders, "Cancel keeps the borders")

		state := menuui.State{settings_active = true}
		menuui.activate(&state, {action = {kind = .HUD_TOGGLE, index = 8}})
		menuui.settings_reset_tab(&state.settings_draft, client_settings_default_values(), .HUD)
		testing.expect(t, !state.settings_draft.hud.hide_scope_borders, "Reset on the HUD tab shows the borders again")

		// Krunker import/export: scopeBorders, a switch that defaults to true.
		values := menuui.Settings_Values{}
		result, err := menuui.krunker_settings_import(&values, `{"scopeBorders":false}`)
		testing.expect(t, len(err) == 0 && result.imported == 1 && result.ignored == 0 && values.hud.hide_scope_borders, "scopeBorders:false imports as hidden borders")
		text := menuui.krunker_settings_export(values)
		testing.expect(t, strings.contains(text, `"scopeBorders":false`), "hidden borders export as scopeBorders:false")
		delete(text)
		_, err = menuui.krunker_settings_import(&values, `{}`)
		testing.expect(t, len(err) == 0 && !values.hud.hide_scope_borders, "a Krunker export without scopeBorders restores Krunker's default (shown)")
		text = menuui.krunker_settings_export(values)
		testing.expect(t, !strings.contains(text, "scopeBorders"), "the default is left out of the export, as Krunker does")
		delete(text)
	}

	// Renders Undergrowth with the scope overlay, borders on and off, in a
	// hidden window. Writes bin/scope/scope-borders-on.png and -off.png.
	@(test)
	scope_borders_render_on_and_off :: proc(t: ^testing.T) {
		context = runtime.default_context()
		W, H :: 1280, 720
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(W, H, "Scope borders", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		ui := ui_init()
		client := Client{scene = scene_init(), ui = ui}
		g_client = &client
		old_lighting := g_lighting_config
		defer {
			client_unload_map(&client)
			shared.map_destroy(client.game.map_inst)
			scene_fini(client.scene)
			overlay_fini()
			ui_fini(ui)
			resource_cache_fini()
			g_client = nil
			g_lighting_config = old_lighting
		}
		map_inst, ok := shared.map_load_from_file("assets/maps/undergrowth.json")
		if !testing.expect(t, ok && map_inst != nil) do return
		client.game.map_inst = map_inst
		client_load_current_map(&client)
		camera := camera_init(DEFAULT_WEAPON_FOV)
		camera.position = {60, 115, 210}
		camera.rotation = {-0.12, 0.3, 0}
		gl.Viewport(0, 0, W, H)
		os.make_directory("bin/scope")
		pixels := make([]u8, W*H*3)
		defer delete(pixels)
		flipped := make([]u8, W*H*3)
		defer delete(flipped)
		edge: [2][3]u8
		for borders, i in ([2]bool{true, false}) {
			gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
			scene_render(client.scene, &camera, W, H)
			ui_update(ui, W, H)
			overlay_scope_render(ui, borders)
			gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
			gl.ReadPixels(0, 0, W, H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
			// The left edge, outside the square scope image, at mid height.
			edge[i] = {pixels[(H/2*W)*3], pixels[(H/2*W)*3+1], pixels[(H/2*W)*3+2]}
			center := pixels[(H/2*W + W/2)*3:][:3]
			testing.expect(t, center[0] < 20 && center[1] < 20 && center[2] < 20, "the scope reticle stays drawn either way")
			for row in 0 ..< H { copy(flipped[row*W*3:][:W*3], pixels[(H-1-row)*W*3:][:W*3]) }
			name := borders ? "on" : "off"
			testing.expect(t, stbi.write_png(fmt.ctprintf("bin/scope/scope-borders-%s.png", name), W, H, 3, raw_data(flipped), W*3) != 0)
		}
		testing.expect(t, edge[0] == ([3]u8{}), "borders on: black outside the scope")
		testing.expect(t, int(edge[1][0]) + int(edge[1][1]) + int(edge[1][2]) > 30, "borders off: the map shows outside the scope")
		testing.expect(t, gl.GetError() == gl.NO_ERROR, "scope borders render without OpenGL errors")
	}
}
