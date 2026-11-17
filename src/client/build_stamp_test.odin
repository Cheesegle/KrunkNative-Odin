package main

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import shared "../shared"

when ODIN_TEST {
	// A temp asset folder holding `files` (name -> text).
	build_stamp_test_dir :: proc(t: ^testing.T, files: map[string]string) -> (dir: string, ok: bool) {
		temp, err := os.make_directory_temp("", "krodin-stamp-*", context.allocator)
		if !testing.expectf(t, err == nil, "temp dir: %v", err) { return }
		for name, text in files {
			path := strings.concatenate({temp, "/", name}, context.temp_allocator)
			if !testing.expect(t, os.write_entire_file(path, transmute([]u8)text) == nil, path) { return temp, false }
		}
		return temp, true
	}

	build_stamp_test_remove :: proc(dir: string) {
		os.remove_all(dir)
		delete(dir)
	}

	// The exe's own shaders, as a name -> text map (what a fresh checkout has).
	build_stamp_test_built_files :: proc() -> map[string]string {
		files := make(map[string]string, context.temp_allocator)
		for source in build_stamp_built_sources() { files[source.name] = string(source.data) }
		return files
	}

	@(test)
	build_stamp_matching_assets_have_no_warning :: proc(t: ^testing.T) {
		built := build_stamp_built_sources()
		names := make([dynamic]string, context.temp_allocator)
		for source in built { append(&names, source.name) }
		testing.expectf(t, len(built) >= 5, "the exe carries its shaders: %v", names[:])
		for name in ([?]string{"basic.vert", "basic.frag", "quad.vert", "quad.frag", "text.frag"}) {
			_, found := build_stamp_built_source(name)
			testing.expectf(t, found, "%s is built in", name)
		}
		for source in built { testing.expectf(t, build_stamp_is_shader(source.name), "only shader files take part: %s", source.name) }

		files := build_stamp_test_built_files()
		dir, ok := build_stamp_test_dir(t, files)
		defer build_stamp_test_remove(dir)
		if !ok { return }
		check := build_stamp_check(dir, built, 0xa8bf023)
		defer build_stamp_check_destroy(&check)
		testing.expectf(t, check.status == .MATCH && check.exe_hash == check.asset_hash && len(check.message) == 0, "identical shaders match: %v %q", check.status, check.message)
		status := Build_Status{stamp = check}
		testing.expect(t, len(build_status_banner_lines(&status)) == 0, "no banner when everything matches")

		// Line endings and non-shader files do not count.
		crlf := make(map[string]string, context.temp_allocator)
		for name, text in files {
			crlf[name], _ = strings.replace_all(text, "\n", "\r\n", context.temp_allocator)
		}
		crlf["sample.json"] = "{}"
		crlf_dir, crlf_ok := build_stamp_test_dir(t, crlf)
		defer build_stamp_test_remove(crlf_dir)
		if !crlf_ok { return }
		crlf_check := build_stamp_check(crlf_dir, built, 0)
		defer build_stamp_check_destroy(&crlf_check)
		testing.expectf(t, crlf_check.status == .MATCH && crlf_check.asset_hash == check.exe_hash, "a CRLF checkout matches: %v %v", crlf_check.status, build_stamp_detail(crlf_check))

		// The repository's own asset folder matches the exe built from it.
		repo := strings.concatenate({strings.trim_right(shared.assets_path(), "/\\"), "/shaders"}, context.temp_allocator)
		repo_check := build_stamp_check(repo, built)
		defer build_stamp_check_destroy(&repo_check)
		testing.expectf(t, repo_check.status == .MATCH, "this checkout's assets match: %q", repo_check.message)
	}

	@(test)
	build_stamp_changed_shader_warns :: proc(t: ^testing.T) {
		built := build_stamp_built_sources()
		files := build_stamp_test_built_files()
		files["basic.frag"] = strings.concatenate({files["basic.frag"], "\n// newer\n"}, context.temp_allocator)
		files["fog.glsl"] = "// a shader the exe has never seen\n"
		dir, ok := build_stamp_test_dir(t, files)
		defer build_stamp_test_remove(dir)
		if !ok { return }
		check := build_stamp_check(dir, built, 0xa8bf023)
		defer build_stamp_check_destroy(&check)
		testing.expect(t, check.status == .MISMATCH && check.exe_hash != check.asset_hash, "a changed shader is a mismatch")
		testing.expectf(t, len(check.changed) == 1 && check.changed[0] == "basic.frag", "the changed file is named: %v", check.changed[:])
		testing.expectf(t, len(check.added) == 1 && check.added[0] == "fog.glsl", "a new shader file is named: %v", check.added[:])
		expected := strings.concatenate({"This build is out of date with its assets (exe a8bf023 shaders ", build_stamp_short(check.exe_hash), ", assets ", build_stamp_short(check.asset_hash), "). Rebuild with build.bat client / build.bat dev."}, context.temp_allocator)
		testing.expectf(t, check.message == expected, "the message:\n%q\nwant\n%q", check.message, expected)
		testing.expectf(t, build_stamp_detail(check) == "changed: basic.frag; new: fog.glsl", "the log detail: %q", build_stamp_detail(check))
		status := Build_Status{stamp = check}
		lines := build_status_banner_lines(&status)
		testing.expectf(t, len(lines) == 2 && lines[0] == check.headline && lines[1] == BUILD_STAMP_REBUILD_HINT, "the banner: %v", lines)

		// Without a commit (a plain `odin build`), the exe is named by its hash.
		bare := build_stamp_check(dir, built, 0)
		defer build_stamp_check_destroy(&bare)
		testing.expectf(t, strings.has_prefix(bare.message, strings.concatenate({"This build is out of date with its assets (exe ", build_stamp_short(bare.exe_hash), ", assets"}, context.temp_allocator)), "no commit: %q", bare.message)
	}

	@(test)
	build_stamp_missing_files_fall_back :: proc(t: ^testing.T) {
		built := build_stamp_built_sources()
		// No asset folder at all: a clear message, not a crash.
		check := build_stamp_check("does-not-exist/assets/shaders", built, 0)
		defer build_stamp_check_destroy(&check)
		testing.expectf(t, check.status == .NO_SHADERS && strings.contains(check.message, "No shader files found in does-not-exist/assets/shaders") && strings.has_suffix(check.message, BUILD_STAMP_FOLDER_HINT), "missing folder: %q", check.message)
		testing.expect(t, len(check.missing) == len(built), "every built-in shader is listed as missing")

		// One file missing (an asset folder older than the exe) is a mismatch.
		files := build_stamp_test_built_files()
		delete_key(&files, "text.frag")
		dir, ok := build_stamp_test_dir(t, files)
		defer build_stamp_test_remove(dir)
		if !ok { return }
		partial := build_stamp_check(dir, built, 0)
		defer build_stamp_check_destroy(&partial)
		testing.expectf(t, partial.status == .MISMATCH && len(partial.missing) == 1 && partial.missing[0] == "text.frag" && len(partial.changed) == 0, "missing text.frag: %v", build_stamp_detail(partial))
	}

	// The tester zip holds the files the asset sweep traced. The check reads
	// every shader through shared.read_file, so the sweep records all of them,
	// and the packaged folder (exactly those files) matches the exe.
	@(test)
	build_stamp_package_layout_is_consistent :: proc(t: ^testing.T) {
		built := build_stamp_built_sources()
		repo := strings.concatenate({strings.trim_right(shared.assets_path(), "/\\"), "/shaders"}, context.temp_allocator)
		shared.asset_trace_begin()
		check := build_stamp_check(repo, built)
		packaged := make(map[string]string, context.temp_allocator)
		for path in shared.asset_trace_sorted(shared.g_asset_trace.used) {
			name := build_stamp_base_name(path)
			testing.expectf(t, strings.has_prefix(path, "assets/shaders/"), "traced as a packaged asset path: %s", path)
			data, ok := os.read_entire_file(strings.concatenate({repo, "/", name}, context.temp_allocator), context.temp_allocator)
			if testing.expect(t, ok == nil) { packaged[name] = string(data) }
		}
		shared.asset_trace_end()
		build_stamp_check_destroy(&check)
		for source in built { testing.expectf(t, source.name in packaged, "the sweep packages %s", source.name) }

		// Unpack: a folder with exactly the traced files.
		dir, ok := build_stamp_test_dir(t, packaged)
		defer build_stamp_test_remove(dir)
		if !ok { return }
		unpacked := build_stamp_check(dir, built)
		defer build_stamp_check_destroy(&unpacked)
		testing.expectf(t, unpacked.status == .MATCH, "the packaged shaders match the packaged exe: %q", unpacked.message)
	}

	// A broken shader in a temp asset folder: shader_compile returns 0, the
	// failure is recorded and logged, the UI shaders fall back to their built-in
	// copies, and the banner is drawn on screen. Writes the banner previews to
	// bin/build_stamp/.
	@(test)
	build_stamp_shader_failure_shows_error :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		W, H :: 1280, 720
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(W, H, "Build stamp", nil, nil)
		if !testing.expect(t, window != nil) { return }
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.Viewport(0, 0, W, H)
		build_status_fini()
		defer build_status_fini()

		files := build_stamp_test_built_files()
		files["basic.frag"] = "#version 450 core\nout vec4 color;\nvoid main() { color = vec4(1.0) this is not glsl; }\n"
		files["quad.frag"] = "#version 450 core\nvoid main() { broken }\n"
		dir, ok := build_stamp_test_dir(t, files)
		defer build_stamp_test_remove(dir)
		if !ok { return }
		vert := strings.concatenate({dir, "/basic.vert"}, context.temp_allocator)
		frag := strings.concatenate({dir, "/basic.frag"}, context.temp_allocator)
		defines := basic_shader_defines(false, false, context.temp_allocator)
		testing.expect(t, shader_compile(vert, frag, defines) == 0, "the broken shader does not compile")
		testing.expectf(t, len(g_build_status.shader_failures) == 1 && g_build_status.shader_failures[0] == "basic.frag", "the failure is recorded: %v", g_build_status.shader_failures[:])
		testing.expect(t, shader_compile(vert, frag, defines) == 0 && len(g_build_status.shader_failures) == 1 && g_build_status.shader_failure_count == 2, "a file is listed once")

		// The UI program falls back to the exe's own quad shader.
		quad := shader_compile_ui(strings.concatenate({dir, "/"}, context.temp_allocator), "quad.vert", "quad.frag")
		defer if quad != 0 { gl.DeleteProgram(quad) }
		testing.expect(t, quad != 0, "the UI shader falls back to its built-in source")
		testing.expectf(t, len(g_build_status.shader_failures) == 2 && g_build_status.shader_failures[1] == "quad.frag", "the asset copy's failure is still reported: %v", g_build_status.shader_failures[:])

		// The banner, over a black frame (what a failed world shader leaves).
		client := new(Client)
		defer free(client)
		client.ui = ui_init()
		defer { ui_fini(client.ui); resource_cache_fini() }
		testing.expect(t, client.ui != nil && client.ui.material != nil)
		pixels := make([]u8, W*H*3)
		defer delete(pixels)
		os.make_directory("bin/build_stamp")
		banner_rows :: proc(pixels: []u8, w, h: int) -> (top, bottom: int, red: int) {
			top, bottom = -1, -1
			for y in 0..<h {
				row_red := 0
				for x in 0..<w {
					i := ((h - 1 - y)*w + x)*3
					if int(pixels[i]) > int(pixels[i+1]) + 40 { row_red += 1 }
				}
				if row_red > w/4 { if top < 0 { top = y }; bottom = y; red += row_red }
			}
			return
		}
		render :: proc(client: ^Client, pixels: []u8, w, h: int) -> bool {
			gl.ClearColor(0, 0, 0, 1)
			gl.Clear(gl.COLOR_BUFFER_BIT)
			ui_update(client.ui, f32(w), f32(h))
			drawn := build_status_banner_render(client.ui)
			gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
			gl.ReadPixels(0, 0, i32(w), i32(h), gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
			return drawn
		}
		testing.expect(t, render(client, pixels, W, H), "the shader error banner is drawn")
		top, bottom, red := banner_rows(pixels, W, H)
		testing.expectf(t, top >= 0 && top < 40 && bottom < H/4 && red > 0, "a red strip at the top of the screen (rows %d..%d)", top, bottom)
		bright := 0
		for y in top..=bottom { for x in 0..<W { i := ((H - 1 - y)*W + x)*3; if pixels[i] > 230 && pixels[i+1] > 230 && pixels[i+2] > 230 { bright += 1 } } }
		testing.expectf(t, bright > 300, "its text is drawn (%d white pixels)", bright)
		lines := build_status_banner_lines(&g_build_status)
		testing.expectf(t, len(lines) == 1 && lines[0] == "Shader failed to compile; see logs/shaders.log (basic.frag, quad.frag).", "the message: %v", lines)
		stbi.write_png("bin/build_stamp/shader_error.png", W, i32(bottom + 12), 3, &pixels[(H - 1)*W*3], -W*3)

		// Plus an out-of-date build: both lines, shader error first.
		g_build_status.stamp = build_stamp_check(dir, build_stamp_built_sources(), 0xa8bf023)
		testing.expect(t, g_build_status.stamp.status == .MISMATCH)
		testing.expect(t, render(client, pixels, W, H))
		_, bottom2, _ := banner_rows(pixels, W, H)
		testing.expectf(t, bottom2 > bottom, "the banner grows for the extra lines (%d > %d)", bottom2, bottom)
		stbi.write_png("bin/build_stamp/out_of_date.png", W, i32(bottom2 + 12), 3, &pixels[(H - 1)*W*3], -W*3)

		// Only the out-of-date warning (amber).
		for name in g_build_status.shader_failures { delete(name) }
		clear(&g_build_status.shader_failures)
		testing.expect(t, render(client, pixels, W, H))
		stbi.write_png("bin/build_stamp/warning_banner.png", W, 120, 3, &pixels[(H - 1)*W*3], -W*3)
		testing.expect(t, gl.GetError() == gl.NO_ERROR)

		// Nothing wrong, nothing drawn.
		build_status_fini()
		testing.expect(t, !render(client, pixels, W, H), "no banner without a problem")
	}
}
