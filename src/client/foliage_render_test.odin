package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import menuui "../menu"
import shared "../shared"

when ODIN_TEST {
	FOLIAGE_W :: 640
	FOLIAGE_H :: 360

	Foliage_View :: struct {
		name:     string,
		position: shared.Vec3,
		rotation: shared.Vec3,
	}

	// Littletown's street of GRASS prefabs (x ~ -30), the grass-textured
	// ground cube under them and the grass hedge (object 584, x -45..-39,
	// z -14..64). "hedge-*" look past tufts at the hedge face: before the fix
	// the empty part of each tuft quad wrote depth, so the hedge and ground
	// (then transparent too) drawn after it showed the buildings and sky behind.
	@(private = "file")
	foliage_views := [?]Foliage_View{
		{"hedge-south", {-30, 5, 20}, {-0.1, 0, 0}},
		{"hedge-north", {-32, 5, 30}, {-0.1, math.PI, 0}},
		{"hedge-across", {0, 4, 40}, {-0.05, math.PI / 2, 0}},
		{"street-north", {-30, 4, 100}, {-0.08, 0, 0}},
		{"street-south", {-30, 4, -20}, {-0.08, math.PI, 0}},
		{"low-west", {-10, 2, 10}, {0.0, math.PI / 2 + 0.3, 0}},
	}

	// Pixels whose colour changes when the tufts are hidden but that no grass
	// texel covers: geometry the tufts wrongly hid. A handful can come from
	// filtered texel edges; a see-through tuft costs hundreds.
	FOLIAGE_MAX_LEAKS :: 24

	Foliage_Mode :: struct {
		name:     string,
		batched:  bool,
		night:    bool,
	}

	@(private = "file")
	foliage_modes := [?]Foliage_Mode{
		{"batched", true, false},
		{"objects", false, false},
		{"night", true, true},
	}

	@(private = "file")
	foliage_frame :: proc(client: ^Client, pixels: []u8) {
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		gl.Viewport(0, 0, FOLIAGE_W, FOLIAGE_H)
		client_render_world(client)
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		gl.ReadPixels(0, 0, FOLIAGE_W, FOLIAGE_H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
	}

	@(private = "file")
	foliage_write :: proc(name: string, pixels: []u8) {
		stbi.write_png(fmt.ctprintf("bin/foliage/%s.png", name), FOLIAGE_W, FOLIAGE_H, 3, &pixels[(FOLIAGE_H - 1) * FOLIAGE_W * 3], -FOLIAGE_W * 3)
	}

	@(private = "file")
	foliage_differs :: proc(a, b: []u8, i: int, threshold: int) -> bool {
		return max(abs(int(a[i]) - int(b[i])), abs(int(a[i + 1]) - int(b[i + 1])), abs(int(a[i + 2]) - int(b[i + 2]))) > threshold
	}

	@(test)
	littletown_foliage_render :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(FOLIAGE_W, FOLIAGE_H, "Littletown foliage", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		os.make_directory("bin/foliage")
		tag := os.get_env("KRODIN_SHOT_TAG", context.temp_allocator)
		if tag == "" do tag = "after"

		defer shadow_fini()
		config := shared.config_load_gameplay("assets/config/game.toml")
		defer shared.config_destroy_gameplay(config)

		client := new(Client)
		g_client = client
		defer { free(client); g_client = nil }
		client.render_batching = true
		client.camera = camera_init(menuui.DEFAULT_FOV * math.PI / 180)
		client.camera.near, client.camera.far = 0.1, 10000
		client.viewport_width, client.viewport_height = FOLIAGE_W, FOLIAGE_H
		client.visual_settings, client.quality_settings = menuui.DEFAULT_VISUAL_SETTINGS, menuui.DEFAULT_QUALITY_SETTINGS
		client.viewmodel_settings = menuui.DEFAULT_VIEWMODEL_SETTINGS
		client_graphics_init(client)
		defer { client_graphics_fini(client); resource_cache_fini() }
		client.scene = scene_init()
		client.fps_scene = scene_init()
		defer { scene_fini(client.fps_scene); scene_fini(client.scene) }
		map_inst, ok := shared.map_load_from_file("assets/maps/littletown.json")
		if !testing.expect(t, ok && map_inst != nil, "littletown.json must load") do return
		defer shared.map_destroy(map_inst)
		maps := []^shared.Map{map_inst}
		shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, -1, true)
		defer shared.game_destroy(&client.game)
		client_load_current_map(client)
		defer client_unload_map(client)

		tufts: [dynamic]^Mesh
		defer delete(tufts)
		grass_cubes, link_cubes := 0, 0
		for object in map_inst.objects {
			if object.mesh == nil do continue
			client_animate_object_texture(object, 0)
			mesh := cast(^Mesh)object.mesh
			material := cast(^Basic_Material)mesh.material
			if object.prefab == .GRASS {
				append(&tufts, mesh)
				// Krunker's GRASS prefab: transparent, doubleSide, alphaTest .02.
				testing.expectf(t, material.base.transparent && material.alpha_test == 0.02, "GRASS at %v must be a transparent .02 cutout (alpha_test %v)", object.position, material.alpha_test)
				continue
			}
			raw, _ := object.raw_data.(json.Object)
			tex, has_tex := raw["t"]
			if object.prefab != .CUBE || !has_tex || !json_is_number(tex) do continue
			switch int(get_json_f32(tex)) {
			case 8:
				// GRASS (grass_1) is not a `link_` texture: opaque, so it batches.
				grass_cubes += 1
				testing.expectf(t, !material.base.transparent && material.alpha_test == 0 && mesh.batched, "grass cube at %v must be opaque and batched", object.position)
			case 12:
				link_cubes += 1
				testing.expectf(t, material.base.transparent && material.alpha_test == 0.02, "LINK cube at %v keeps its .02 cutout", object.position)
			}
		}
		fmt.printfln("[foliage] %d grass prefabs, %d grass cubes, %d link cubes", len(tufts), grass_cubes, link_cubes)
		testing.expect(t, len(tufts) == 163 && grass_cubes == 74, "Littletown has 163 GRASS prefabs and 74 grass cubes")

		pixels := make([]u8, FOLIAGE_W * FOLIAGE_H * 3)
		without := make([]u8, len(pixels))
		mask := make([]u8, len(pixels))
		defer { delete(pixels); delete(without); delete(mask) }

		for mode in foliage_modes {
			client.render_batching = mode.batched
			client.visual_settings.night_mode = mode.night
			for view in foliage_views {
				client.camera.position, client.camera.rotation = view.position, view.rotation
				label := fmt.tprintf("%s_%s_%s", view.name, mode.name, tag)

				for mesh in tufts { mesh.map_detail_visible, mesh.visible = false, false }
				for _ in 0 ..< 2 { foliage_frame(client, without) }
				for mesh in tufts { mesh.map_detail_visible, mesh.visible = true, true }
				for _ in 0 ..< 2 { foliage_frame(client, pixels) }
				foliage_write(label, pixels)

				// Coverage of the grass texels alone: the tufts over a magenta clear.
				hidden: [dynamic]^Mesh
				defer delete(hidden)
				for mesh in client.scene.meshes {
					is_tuft := false
					for tuft in tufts { if tuft == mesh { is_tuft = true; break } }
					if !is_tuft && mesh.visible { mesh.visible = false; append(&hidden, mesh) }
				}
				gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
				gl.Viewport(0, 0, FOLIAGE_W, FOLIAGE_H)
				clear_color: [4]f32
				gl.GetFloatv(gl.COLOR_CLEAR_VALUE, &clear_color[0])
				gl.ClearColor(1, 0, 1, 1)
				gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
				scene_render(client.scene, &client.camera, FOLIAGE_W, FOLIAGE_H, client.graphics_sampler)
				gl.ReadPixels(0, 0, FOLIAGE_W, FOLIAGE_H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(mask))
				gl.ClearColor(clear_color[0], clear_color[1], clear_color[2], clear_color[3])
				for mesh in hidden { mesh.visible = true }

				// Leak map: see-through pixels red over the darkened frame.
				grass, leaks := 0, 0
				grass_rgb: [3]f32
				for i := 0; i < len(pixels); i += 3 {
					on_grass := !(mask[i] > 240 && mask[i + 1] < 15 && mask[i + 2] > 240)
					if on_grass {
						grass += 1
						for c in 0 ..< 3 { grass_rgb[c] += f32(pixels[i + c]) }
					}
					if !on_grass && foliage_differs(pixels, without, i, 12) {
						leaks += 1
						mask[i], mask[i + 1], mask[i + 2] = 255, 0, 0
					} else {
						mask[i], mask[i + 1], mask[i + 2] = pixels[i] / 2, pixels[i + 1] / 2, pixels[i + 2] / 2
					}
				}
				foliage_write(fmt.tprintf("%s_leaks", label), mask)
				if grass > 0 { grass_rgb /= f32(grass) }
				fmt.printfln("[foliage] %s %s: %d grass px, mean grass rgb %.0f %.0f %.0f, %d see-through px", mode.name, view.name, grass, grass_rgb[0], grass_rgb[1], grass_rgb[2], leaks)
				testing.expectf(t, leaks <= FOLIAGE_MAX_LEAKS, "%s %s: %d pixels seen through the grass", mode.name, view.name, leaks)
			}
		}
		client.render_batching, client.visual_settings.night_mode = true, false
		testing.expect(t, gl.GetError() == gl.NO_ERROR, "Littletown must render without OpenGL errors")
		client_clear_players(client)
		free_all(context.temp_allocator)
	}
}
