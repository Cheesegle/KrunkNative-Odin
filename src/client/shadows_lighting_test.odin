package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import menuui "../menu"
import shared "../shared"

when ODIN_TEST {
	@(test)
	shadows_lighting_settings_default_and_persist :: proc(t: ^testing.T) {
		defaults := client_settings_defaults()
		testing.expect(t, defaults.quality.shadows && !defaults.quality.soft_shadows && !defaults.quality.high_res_shadows && !defaults.quality.dynamic_shadows,
			"Shadows must default on and its advanced options off, as in Krunker")
		testing.expect(t, defaults.quality.lighting == i32(menuui.Lighting_Quality.NORMAL), "Lighting must default to Normal")
		testing.expect(t, menuui.quality_settings_validate({lighting = 7}).lighting == 1 && menuui.quality_settings_validate({lighting = -1}).lighting == 1 &&
			menuui.quality_settings_validate({lighting = 3}).lighting == 3, "Lighting must stay within Low..Physical")

		path := "bin/client-settings-shadows-test.json"
		defer os.remove(path)
		// A file written before these settings existed gets Krunker's defaults
		// and keeps its other quality choices.
		testing.expect(t, os.write_entire_file(path, `{"version":1,"quality":{"smooth_textures":true,"anisotropy":4}}`) == nil)
		older := client_settings_load(path)
		testing.expect(t, older.quality == menuui.Quality_Settings{smooth_textures = true, anisotropy = 4, shadows = true, lighting = 1},
			fmt.tprintf("older preferences must load Krunker's Shadows and Lighting defaults: %v", older.quality))
		testing.expect(t, os.write_entire_file(path, `{"version":1}`) == nil)
		testing.expect(t, client_settings_load(path).quality == menuui.DEFAULT_QUALITY_SETTINGS, "files without a quality block must use the defaults")

		settings := client_settings_defaults()
		settings.quality = {shadows = false, soft_shadows = true, high_res_shadows = true, dynamic_shadows = true, lighting = 3}
		testing.expect(t, client_settings_save(settings, path))
		testing.expect(t, client_settings_load(path).quality == settings.quality, "every Shadows and Lighting choice must survive a restart")

		// The menu edits the draft (live preview) and Save commits it.
		client := Client{visual_settings = menuui.DEFAULT_VISUAL_SETTINGS, quality_settings = menuui.DEFAULT_QUALITY_SETTINGS}
		client.menu.page = .SETTINGS
		menuui.prepare_settings(&client.menu, menuui.View{visuals = client.visual_settings, quality = client.quality_settings})
		client.menu.settings_draft.quality = client.quality_settings
		menuui.activate(&client.menu, {action = {kind = .QUALITY_TOGGLE, index = i32(menuui.Quality_Toggle.SHADOWS)}})
		menuui.activate(&client.menu, {action = {kind = .QUALITY_TOGGLE, index = i32(menuui.Quality_Toggle.SOFT_SHADOWS)}})
		menuui.activate(&client.menu, {action = {kind = .LIGHTING, index = 2}})
		_, preview := client_graphics_values(&client)
		testing.expect(t, !preview.shadows && preview.soft_shadows && preview.lighting == 2 && client.quality_settings == menuui.DEFAULT_QUALITY_SETTINGS,
			"Shadows and Lighting must preview from the draft without changing saved settings")
		menu_apply_action(&client, {kind = .SETTINGS_SAVE})
		testing.expect(t, !client.quality_settings.shadows && client.quality_settings.soft_shadows && client.quality_settings.lighting == 2 && client_settings_snapshot(&client).quality == client.quality_settings,
			"Save must commit and persist Shadows and Lighting")
	}

	shadow_test_pixel :: proc(scene: ^Scene, camera: ^Camera, map_inst: ^shared.Map, quality: menuui.Quality_Settings, x, y: i32) -> [4]u8 {
		shadow_prepare(scene, map_inst, quality)
		gl.Viewport(0, 0, 64, 64)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		scene_render(scene, camera, 64, 64)
		pixel: [4]u8
		gl.ReadPixels(x, y, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, &pixel[0])
		return pixel
	}

	// A box above a floor, lit by a sun 30 degrees off vertical towards +x: the
	// floor beside the box on the -x side is in its shadow.
	@(test)
	shadows_cast_from_the_sun :: proc(t: ^testing.T) {
		context = runtime.default_context()
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(64, 64, "Shadow regression", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.ClearColor(0, 0, 0, 1)

		scene := scene_init()
		floor_material, box_material := basic_material_init(), basic_material_init()
		if !testing.expect(t, floor_material != nil && box_material != nil) do return
		floor_material.no_fog, box_material.no_fog = true, true
		floor_material.receive_shadow, box_material.receive_shadow = true, true
		floor := mesh_init(create_cube_geo(), &floor_material.base)
		floor.transform.position, floor.transform.scale = {0, -2, -6}, {80, 1, 80}
		floor.shadow_caster = .STATIC
		box := mesh_init(create_cube_geo(), &box_material.base)
		box.transform.position, box.transform.scale = {0, 0, -6}, {6, 4, 6}
		box.shadow_caster = .STATIC
		scene_add_mesh(scene, floor)
		scene_add_mesh(scene, box)
		cube := shared.Object{prefab = .CUBE, scale = {100, 1, 100}}
		map_inst := shared.Map{lighting = shared.DEFAULT_LIGHTING_CONFIG}
		append(&map_inst.objects, &cube)
		saved_lighting := g_lighting_config
		defer {
			shadow_fini()
			g_lighting_config = saved_lighting
			delete(map_inst.objects)
			mesh_fini(floor)
			mesh_fini(box)
			scene_fini(scene)
			resource_cache_fini()
		}
		g_lighting_config = shared.DEFAULT_LIGHTING_CONFIG
		g_lighting_config.ambient_color, g_lighting_config.ambient_intensity = {0.3, 0.3, 0.3}, 1
		g_lighting_config.light_color, g_lighting_config.light_intensity = {1, 1, 1}, 1
		g_lighting_config.sun_angle_x, g_lighting_config.sun_angle_y = 60, -90
		map_inst.lighting = g_lighting_config
		half_width, half_length := shadow_map_extent(&map_inst)
		testing.expect(t, half_width == 80 && half_length == 80, "shadow bounds must follow Krunker's cube extent / 2.5")

		camera := camera_init(math.PI / 2)
		camera.position, camera.rotation = {0, 20, -6}, {-math.PI / 2, 0, 0}
		shaded_x, lit_x := i32(25), i32(50)
		renders := g_shadow.renders
		off := menuui.Quality_Settings{lighting = 1}
		shaded_off := shadow_test_pixel(scene, &camera, &map_inst, off, shaded_x, 32)
		lit_off := shadow_test_pixel(scene, &camera, &map_inst, off, lit_x, 32)
		testing.expect(t, g_shadow.renders == renders && g_shadow.static_target.fbo == 0 && !g_render_quality.shadows, "Shadows off must not create or render a shadow map")
		testing.expect(t, shaded_off == lit_off && lit_off.r > 240, fmt.tprintf("without shadows the floor is evenly lit (%v, %v)", shaded_off, lit_off))

		on := menuui.DEFAULT_QUALITY_SETTINGS
		shaded := shadow_test_pixel(scene, &camera, &map_inst, on, shaded_x, 32)
		lit := shadow_test_pixel(scene, &camera, &map_inst, on, lit_x, 32)
		testing.expect(t, g_shadow.renders == renders + 1, "static shadows must render the shadow map once, not every frame")
		testing.expect(t, shaded.r < 100 && lit.r > 240, fmt.tprintf("the box must shadow the floor beside it (%v vs %v)", shaded, lit))

		soft := on
		soft.soft_shadows = true
		testing.expect(t, shadow_test_pixel(scene, &camera, &map_inst, soft, shaded_x, 32).r < 100, "Soft Shadows must still shadow the floor")
		testing.expect(t, g_shadow.renders == renders + 2, "changing the filter must rebuild the shadow map once")
		dynamic_quality := on
		dynamic_quality.dynamic_shadows = true
		dynamic_before := g_shadow.dynamic_renders
		shadow_test_pixel(scene, &camera, &map_inst, dynamic_quality, shaded_x, 32)
		testing.expect(t, shadow_test_pixel(scene, &camera, &map_inst, dynamic_quality, shaded_x, 32).r < 100, "Dynamic Shadows must keep the static map's shadows")
		testing.expect(t, g_shadow.dynamic_renders == dynamic_before + 2 && g_shadow.renders == renders + 2,
			"Dynamic Shadows must redraw the players every frame on a copy of the cached static map")
		// A player-like caster only shows with Dynamic Shadows.
		box.shadow_caster = .DYNAMIC
		shadow_mark_dirty()
		testing.expect(t, shadow_test_pixel(scene, &camera, &map_inst, on, shaded_x, 32).r > 240, "players must not cast without Dynamic Shadows")
		testing.expect(t, shadow_test_pixel(scene, &camera, &map_inst, dynamic_quality, shaded_x, 32).r < 100, "players must cast with Dynamic Shadows")
		box.shadow_caster = .STATIC
		shadow_mark_dirty()

		low := on
		low.lighting = 0
		before_low := g_shadow.renders
		testing.expect(t, shadow_test_pixel(scene, &camera, &map_inst, low, shaded_x, 32).r > 240 && g_shadow.renders == before_low,
			"Lighting Low is unlit, so it shows no shadows and skips the shadow pass")
		high := on
		high.lighting = 2
		testing.expect(t, shadow_test_pixel(scene, &camera, &map_inst, high, shaded_x, 32).r < 100, "High lighting must keep the sun's shadow")

		shadow_release_map()
		testing.expect(t, g_shadow.static_target.fbo == 0 && g_shadow.static_target.texture == 0 && g_shadow.dynamic_target.texture == 0, "a map change must free the shadow map")
		testing.expect(t, gl.GetError() == gl.NO_ERROR, "shadows must not generate OpenGL errors")
	}
}
