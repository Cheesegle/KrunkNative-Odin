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
	// Pixels where two touching surfaces store the same depth take the colour
	// of whichever draws first. Per-object order is the map's object order;
	// map_batch_plan keeps coincident same-facing faces in that order, but
	// surfaces that only meet along a line cannot all keep it without undoing
	// the batching. Such pixels lie on contact lines; allow a few per
	// 1280x720 frame (32 = 0.0035%; at most 23 seen, on Sandstorm). Any pixel whose depth differs fails.
	BATCH_EQ_MAX_TIE_PIXELS :: 32

	Batch_Eq_View :: struct {
		name:     string,
		position: shared.Vec3,
		rotation: shared.Vec3,
	}

	Batch_Eq_Toggles :: struct {
		name:             string,
		hide_cats:        bool,
		hide_extra_props: bool,
	}

	@(private = "file")
	batch_eq_views :: proc(map_inst: ^shared.Map) -> [3]Batch_Eq_View {
		p := map_inst.camera_position
		views: [3]Batch_Eq_View
		// The menu camera, looking down at the map centre (bench view 0).
		views[0] = {"menu", p, {-0.35, math.atan2(p.x, p.z), 0}}
		// Two spawns at eye height, looking along the spawn direction.
		for i in 0 ..< 2 {
			if len(map_inst.spawns) == 0 {
				views[i + 1] = views[0]
				continue
			}
			spawn := map_inst.spawns[(i * len(map_inst.spawns)) / 2]
			// The second view turns around, so single-spawn maps get two views.
			yaw := f32(spawn.direction) * math.PI / 2 + (i == 0 ? 0.4 : math.PI - 0.3)
			views[i + 1] = {i == 0 ? "spawn-a" : "spawn-b", spawn.position + shared.Vec3{0, 10, 0}, {-0.08, yaw, 0}}
		}
		return views
	}

	@(private = "file")
	batch_eq_write_ppm :: proc(path: string, pixels: []u8, w, h: i32) {
		file := make([dynamic]u8)
		defer delete(file)
		append(&file, ..transmute([]u8)fmt.tprintf("P6\n%d %d\n255\n", w, h))
		for row := h - 1; row >= 0; row -= 1 {
			append(&file, ..pixels[row * w * 3:(row + 1) * w * 3])
		}
		_ = os.write_entire_file(path, file[:])
	}

	@(private = "file")
	batch_eq_render :: proc(client: ^Client, camera: ^Camera, target: ^Bench_Target, batched: bool, sampler: u32, pixels: []u8, depth: []u32 = nil) -> Draw_Stats {
		client.scene.batching_enabled = batched
		g_draw_stats = {}
		gl.BindFramebuffer(gl.FRAMEBUFFER, target.fbo)
		gl.Viewport(0, 0, target.width, target.height)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		scene_render(client.scene, camera, f32(target.width), f32(target.height), sampler)
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		gl.ReadPixels(0, 0, target.width, target.height, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
		if depth != nil {
			gl.ReadPixels(0, 0, target.width, target.height, gl.DEPTH_COMPONENT, gl.UNSIGNED_INT, raw_data(depth))
		}
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		return g_draw_stats
	}

	// Batched and per-object rendering must produce the same image: Burg,
	// Bastion and Stockade, three viewpoints each, with the map-detail toggles
	// off and on, with the default nearest-texel sampling and with trilinear +
	// anisotropic sampling. Mismatches dump PPMs to bin/batch_eq/.
	@(test)
	map_batching_matches_per_object_render :: proc(t: ^testing.T) {
		// Keep the test logger: the runner records failures through it.
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(64, 64, "Map batching", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

		w, h := i32(1280), i32(720)
		target := bench_target_init(w, h)
		defer bench_target_fini(&target)
		off := make([]u8, int(w * h * 3))
		on := make([]u8, int(w * h * 3))
		defer delete(off)
		defer delete(on)
		depth_off := make([]u32, int(w * h))
		depth_on := make([]u32, int(w * h))
		defer delete(depth_off)
		defer delete(depth_on)

		smooth: u32
		gl.GenSamplers(1, &smooth)
		defer gl.DeleteSamplers(1, &smooth)
		gl.SamplerParameteri(smooth, gl.TEXTURE_WRAP_S, gl.REPEAT)
		gl.SamplerParameteri(smooth, gl.TEXTURE_WRAP_T, gl.REPEAT)
		gl.SamplerParameteri(smooth, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
		gl.SamplerParameteri(smooth, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		max_anisotropy: f32 = 1
		gl.GetFloatv(0x84FF, &max_anisotropy)
		if max_anisotropy >= 2 { gl.SamplerParameterf(smooth, 0x84FE, min(16, max_anisotropy)) }
		_ = gl.GetError()

		old_lighting, old_visuals := g_lighting_config, g_visual_settings
		defer { g_lighting_config, g_visual_settings = old_lighting, old_visuals }
		toggles := [?]Batch_Eq_Toggles{{"details-shown", false, false}, {"details-hidden", true, true}, {"cats-hidden", true, false}}
		failures := 0
		for map_name in ([]string{"burg", "bastion", "sandstorm_v3", "undergrowth"}) {
			client := Client{scene = scene_init(), render_batching = true}
			g_client = &client
			map_inst, ok := shared.map_load_from_file(fmt.tprintf("assets/maps/%s.json", map_name))
			if !testing.expect(t, ok && map_inst != nil, map_name) {
				scene_fini(client.scene)
				continue
			}
			client.game.map_inst = map_inst
			client_load_current_map(&client)
			set := client.scene.batches
			if testing.expect(t, set != nil && len(set.members) > 0, fmt.tprintf("%s must build map batches", map_name)) {
				fmt.printf("[batch-eq] %s: %d meshes, %d merged into %d slots (%d single, %d moved out for depth ties)\n", map_name, len(client.scene.meshes), set.merged, len(set.batches), set.singles, set.tie_excluded)
			}

			for view, view_index in batch_eq_views(map_inst) {
				camera := camera_init(menuui.DEFAULT_FOV * math.PI / 180)
				camera.position, camera.rotation = view.position, view.rotation
				for toggle, toggle_index in toggles {
					visuals := menuui.DEFAULT_VISUAL_SETTINGS
					visuals.hide_cats, visuals.hide_extra_props = toggle.hide_cats, toggle.hide_extra_props
					g_visual_settings = visuals
					client_update_map_details(&client, visuals)
					samplers := [2]u32{0, smooth}
					// The smooth sampler pass runs once per view to cover mip selection.
					for sampler, sampler_index in samplers {
						if sampler_index == 1 && toggle_index != 0 do continue
						stats_off := batch_eq_render(&client, &camera, &target, false, sampler, off, depth_off)
						stats_on := batch_eq_render(&client, &camera, &target, true, sampler, on, depth_on)
						// A pixel may differ by more than 1 only where both renders
						// stored the same depth: two surfaces tied in the depth
						// buffer and draw order picked the colour (see PR notes).
						max_diff, max_geometry_diff, tie_pixels, geometry_pixels := 0, 0, 0, 0
						first := -1
						for pixel in 0 ..< int(w * h) {
							d := 0
							for c in 0 ..< 3 { d = max(d, abs(int(off[pixel * 3 + c]) - int(on[pixel * 3 + c]))) }
							max_diff = max(max_diff, d)
							if d <= 1 { continue }
							if depth_off[pixel] == depth_on[pixel] {
								tie_pixels += 1
							} else {
								geometry_pixels += 1
								max_geometry_diff = max(max_geometry_diff, d)
								if first < 0 { first = pixel }
							}
						}
						label := fmt.tprintf("%s_%s_%s_%s", map_name, view.name, toggle.name, sampler == 0 ? "nearest" : "smooth")
						fmt.printf("[batch-eq] %-48s max diff %3d; depth-tie pixels %3d, other pixels %d; draws %5d -> %4d (batches %d, culled %d)\n",
							label, max_diff, tie_pixels, geometry_pixels, stats_off.draw_calls, stats_on.draw_calls, stats_on.batch_draws, stats_on.batches_culled)
						testing.expect(t, stats_on.draw_calls <= stats_off.draw_calls, fmt.tprintf("%s: batching must not add draw calls", label))
						if !testing.expect(t, geometry_pixels == 0 && tie_pixels <= BATCH_EQ_MAX_TIE_PIXELS, fmt.tprintf("%s: batched render differs: %d depth-tie pixels (limit %d), %d other pixels (max diff %d, first %d)", label, tie_pixels, BATCH_EQ_MAX_TIE_PIXELS, geometry_pixels, max_geometry_diff, first)) {
							failures += 1
							os.make_directory("bin/batch_eq")
							diff := make([]u8, len(off))
							for i in 0 ..< len(off) {
								if abs(int(off[i]) - int(on[i])) > 1 { diff[i] = depth_off[i / 3] == depth_on[i / 3] ? 96 : 255 }
							}
							batch_eq_write_ppm(fmt.tprintf("bin/batch_eq/%s_off.ppm", label), off, w, h)
							batch_eq_write_ppm(fmt.tprintf("bin/batch_eq/%s_on.ppm", label), on, w, h)
							batch_eq_write_ppm(fmt.tprintf("bin/batch_eq/%s_diff.ppm", label), diff, w, h)
							delete(diff)
						}
						_ = view_index
					}
				}
			}
			testing.expect(t, gl.GetError() == gl.NO_ERROR, fmt.tprintf("%s must render without OpenGL errors", map_name))

			client_unload_map(&client)
			shared.map_destroy(map_inst)
			scene_fini(client.scene)
			resource_cache_fini()
			g_client = nil
			free_all(context.temp_allocator)
		}
		testing.expect(t, failures == 0, "batched rendering must match per-object rendering")
	}

	// A camera outside the map looking away draws no map batch; turned around
	// it draws some, and the image still matches the per-object path.
	@(test)
	map_batching_culls_offscreen_chunks :: proc(t: ^testing.T) {
		// Keep the test logger: the runner records failures through it.
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(64, 64, "Map culling", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

		w, h := i32(320), i32(180)
		target := bench_target_init(w, h)
		defer bench_target_fini(&target)
		off := make([]u8, int(w * h * 3))
		on := make([]u8, int(w * h * 3))
		defer delete(off)
		defer delete(on)

		old_lighting := g_lighting_config
		defer g_lighting_config = old_lighting
		client := Client{scene = scene_init(), render_batching = true}
		g_client = &client
		defer {
			client_unload_map(&client)
			shared.map_destroy(client.game.map_inst)
			scene_fini(client.scene)
			resource_cache_fini()
			g_client = nil
		}
		map_inst, ok := shared.map_load_from_file("assets/maps/burg.json")
		if !testing.expect(t, ok && map_inst != nil) do return
		client.game.map_inst = map_inst
		client_load_current_map(&client)
		set := client.scene.batches
		if !testing.expect(t, set != nil && len(set.batches) > 0) do return

		lo, hi := set.batches[0].bounds_min, set.batches[0].bounds_max
		for batch in set.batches {
			lo = {min(lo.x, batch.bounds_min.x), min(lo.y, batch.bounds_min.y), min(lo.z, batch.bounds_min.z)}
			hi = {max(hi.x, batch.bounds_max.x), max(hi.y, batch.bounds_max.y), max(hi.z, batch.bounds_max.z)}
		}
		camera := camera_init(menuui.DEFAULT_FOV * math.PI / 180)
		camera.position = {hi.x + 500, (lo.y + hi.y) * 0.5, (lo.z + hi.z) * 0.5}
		// Yaw -PI/2 looks down +X (away from the map); +PI/2 looks back at it.
		camera.rotation = {0, -math.PI / 2, 0}
		away := batch_eq_render(&client, &camera, &target, true, 0, on)
		testing.expect(t, away.batch_draws == 0 && away.batches_culled == len(set.batches), fmt.tprintf("facing away must cull every batch (%d drawn, %d culled)", away.batch_draws, away.batches_culled))
		camera.rotation = {0, math.PI / 2, 0}
		toward := batch_eq_render(&client, &camera, &target, true, 0, on)
		testing.expect(t, toward.batch_draws > 0, "facing the map must draw batches")
		_ = batch_eq_render(&client, &camera, &target, false, 0, off)
		max_diff := 0
		for i in 0 ..< len(off) { max_diff = max(max_diff, abs(int(off[i]) - int(on[i]))) }
		testing.expect(t, max_diff <= 1, fmt.tprintf("culled render must match (max diff %d)", max_diff))
	}
}
