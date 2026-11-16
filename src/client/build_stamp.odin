package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import shared "../shared"

// Out-of-date build detection (Krodin's own; Krunker has nothing like it).
//
// The client loads its shaders from assets/shaders at run time, so an exe
// older than the asset folder (after a `git pull` without a rebuild) compiles
// shaders written for newer code: compile errors and a black screen. To catch
// that, the exe carries the shader sources it was built with, embedded at
// compile time by #load_directory, and startup compares them with the files in
// assets/shaders. A difference shows a warning banner and a log line; it never
// stops the game.
//
// Both stamps are content hashes (FNV-1a 64 over each shader's name and text,
// sorted by name, carriage returns ignored), so there is no generated file to
// forget: a clean checkout builds as is, and the tester zip is consistent
// whenever it ships the exe with the shaders it was built from (the packager's
// asset sweep runs this check inside the unpacked zip and fails on a mismatch).
//
// build.bat also passes the git commit (-define:KRODIN_COMMIT=0x<short sha>)
// so the message names the exe's commit. Without it (a plain `odin build`) the
// commit is 0 and only the hashes are shown.

KRODIN_COMMIT :: #config(KRODIN_COMMIT, 0)

// The shader sources this exe was built with (every file in assets/shaders;
// only shader extensions take part in the stamp).
BUILD_SHADER_FILES := #load_directory("../../assets/shaders")

BUILD_STAMP_REBUILD_HINT :: "Rebuild with build.bat client / build.bat dev."
BUILD_STAMP_FOLDER_HINT :: "Run Krodin from its own folder, next to assets."

Build_Stamp_Status :: enum u8 {
	MATCH,
	MISMATCH,   // The shader files differ from the ones the exe was built with.
	NO_SHADERS, // No shader files were found in the asset folder at all.
}

Build_Stamp_Source :: struct {
	name: string, // Base name ("basic.frag").
	data: []u8,
}

Build_Stamp_Check :: struct {
	status:     Build_Stamp_Status,
	exe_hash:   u64,
	asset_hash: u64,
	commit:     u64,
	changed:    [dynamic]string, // In both, with different text.
	missing:    [dynamic]string, // Built into the exe, absent from the folder.
	added:      [dynamic]string, // In the folder, unknown to the exe.
	headline:   string,          // What is wrong; empty when the stamps match.
	message:    string,          // headline plus what to do (the log line).
}

build_stamp_check_destroy :: proc(check: ^Build_Stamp_Check) {
	for list in ([?]^[dynamic]string{&check.changed, &check.missing, &check.added}) {
		for name in list { delete(name) }
		delete(list^)
	}
	delete(check.headline)
	delete(check.message)
	check^ = {}
}

build_stamp_is_shader :: proc(name: string) -> bool {
	for ext in ([?]string{".vert", ".frag", ".geom", ".comp", ".glsl", ".tesc", ".tese"}) {
		if strings.has_suffix(name, ext) { return true }
	}
	return false
}

build_stamp_base_name :: proc(path: string) -> string {
	i := strings.last_index_any(path, "/\\")
	return i >= 0 ? path[i+1:] : path
}

// The exe's embedded shader files, sorted by name.
build_stamp_built_sources :: proc(allocator := context.temp_allocator) -> []Build_Stamp_Source {
	sources := make([dynamic]Build_Stamp_Source, allocator)
	for file in BUILD_SHADER_FILES {
		name := build_stamp_base_name(file.name)
		if build_stamp_is_shader(name) { append(&sources, Build_Stamp_Source{name, file.data}) }
	}
	slice.sort_by(sources[:], proc(a, b: Build_Stamp_Source) -> bool { return a.name < b.name })
	return sources[:]
}

// The embedded source of one shader file ("quad.frag"), for fallbacks.
build_stamp_built_source :: proc(name: string) -> (data: []u8, ok: bool) {
	for file in BUILD_SHADER_FILES {
		if build_stamp_base_name(file.name) == name { return file.data, true }
	}
	return nil, false
}

@(private = "file")
fnv_byte :: #force_inline proc(h: ^u64, b: u8) {
	h^ = (h^ ~ u64(b)) * 0x100000001b3
}

// Text with line endings normalised: a Windows checkout (CRLF) and a Linux one
// (LF) of the same commit hash the same.
build_stamp_file_hash :: proc(data: []u8) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for b in data { if b != '\r' { fnv_byte(&h, b) } }
	return h
}

// Hash of a sorted file set: name, NUL, text hash, per file.
build_stamp_hash :: proc(sources: []Build_Stamp_Source) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for source in sources {
		for b in transmute([]u8)source.name { fnv_byte(&h, b) }
		fnv_byte(&h, 0)
		file := build_stamp_file_hash(source.data)
		for i in 0..<8 { fnv_byte(&h, u8(file >> (u64(i)*8))) }
	}
	return h
}

// Short form for messages: the high 32 bits as 8 hex digits.
build_stamp_short :: proc(hash: u64) -> string {
	return fmt.tprintf("%08x", u32(hash >> 32))
}

// "a8bf023 shaders 1a2b3c4d", or just the hash without a commit.
build_stamp_exe_label :: proc(check: Build_Stamp_Check) -> string {
	if check.commit == 0 { return build_stamp_short(check.exe_hash) }
	return fmt.tprintf("%07x shaders %s", check.commit, build_stamp_short(check.exe_hash))
}

// Compares the shader files in `shader_dir` (assets/shaders) with `built`.
// The folder's files are read through shared.read_file, so the packager's
// asset sweep records (and ships) every one of them.
build_stamp_check :: proc(shader_dir: string, built: []Build_Stamp_Source, commit: u64 = KRODIN_COMMIT) -> (check: Build_Stamp_Check) {
	check.commit = commit
	check.exe_hash = build_stamp_hash(built)
	found := make([dynamic]Build_Stamp_Source, context.temp_allocator)
	defer { for source in found { delete(source.data) } }

	// The folder's shader files: the exe's own names first, then any others.
	names := make([dynamic]string, context.temp_allocator)
	for source in built { append(&names, source.name) }
	if infos, err := os.read_all_directory_by_path(shader_dir, context.temp_allocator); err == nil {
		for info in infos {
			if info.type != .Regular || !build_stamp_is_shader(info.name) { continue }
			if !slice.contains(names[:], info.name) { append(&names, strings.clone(info.name, context.temp_allocator)) }
		}
	}
	for name, i in names {
		path := strings.concatenate({shader_dir, "/", name}, context.temp_allocator)
		data, ok := shared.read_file(path)
		if !ok {
			if i < len(built) { append(&check.missing, strings.clone(name)) }
			continue
		}
		append(&found, Build_Stamp_Source{name, data})
		if i >= len(built) {
			append(&check.added, strings.clone(name))
		} else if build_stamp_file_hash(data) != build_stamp_file_hash(built[i].data) {
			append(&check.changed, strings.clone(name))
		}
	}
	slice.sort_by(found[:], proc(a, b: Build_Stamp_Source) -> bool { return a.name < b.name })
	check.asset_hash = build_stamp_hash(found[:])

	hint: string
	switch {
	case len(found) == 0:
		check.status = .NO_SHADERS
		check.headline = fmt.aprintf("No shader files found in %s (exe %s).", shader_dir, build_stamp_exe_label(check))
		hint = BUILD_STAMP_FOLDER_HINT
	case len(check.changed) + len(check.missing) + len(check.added) > 0:
		check.status = .MISMATCH
		check.headline = fmt.aprintf("This build is out of date with its assets (exe %s, assets %s).", build_stamp_exe_label(check), build_stamp_short(check.asset_hash))
		hint = BUILD_STAMP_REBUILD_HINT
	case:
		check.status = .MATCH
		return
	}
	check.message = strings.concatenate({check.headline, " ", hint})
	return
}

// The detail for the log: which files differ.
build_stamp_detail :: proc(check: Build_Stamp_Check) -> string {
	b := strings.builder_make(context.temp_allocator)
	lists := [?]struct { label: string, names: []string }{{"changed", check.changed[:]}, {"missing", check.missing[:]}, {"new", check.added[:]}}
	for list in lists {
		if len(list.names) == 0 { continue }
		if strings.builder_len(b) > 0 { strings.write_string(&b, "; ") }
		fmt.sbprintf(&b, "%s: %s", list.label, strings.join(list.names, ", ", context.temp_allocator))
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Startup check, shader failures and the on-screen banner.

BUILD_STAMP_LOG_PATH :: "logs/shaders.log"
BUILD_STAMP_MAX_SHADER_ERRORS :: 8

Build_Status :: struct {
	stamp:         Build_Stamp_Check,
	stamp_checked: bool,
	// Shader files that failed to compile or link this session (base names).
	shader_failures: [dynamic; BUILD_STAMP_MAX_SHADER_ERRORS]string,
	shader_failure_count: int,
}

g_build_status: Build_Status

// Appends a line to logs/shaders.log (best effort; the console gets it too).
build_status_log :: proc(line: string) {
	fmt.println(line)
	if !os.exists(DIAGNOSTICS_LOG_DIR) { os.make_directory(DIAGNOSTICS_LOG_DIR) }
	file, err := os.open(BUILD_STAMP_LOG_PATH, {.Write, .Create, .Append})
	if err != nil { return }
	defer os.close(file)
	os.write_string(file, line)
	os.write_string(file, "\n")
}

// Runs the stamp check once at startup (after the GL context, before any
// shader compiles) and logs a mismatch.
build_status_check_assets :: proc() {
	if g_build_status.stamp_checked { return }
	g_build_status.stamp_checked = true
	dir := strings.concatenate({strings.trim_right(shared.assets_path(), "/\\"), "/shaders"}, context.temp_allocator)
	g_build_status.stamp = build_stamp_check(dir, build_stamp_built_sources())
	stamp := &g_build_status.stamp
	switch stamp.status {
	case .MATCH:
		fmt.printf("[Build] Shaders match this build (%s)\n", build_stamp_exe_label(stamp^))
	case .MISMATCH, .NO_SHADERS:
		build_status_log(fmt.tprintf("[Build] WARNING: %s", stamp.message))
		if detail := build_stamp_detail(stamp^); len(detail) > 0 { build_status_log(fmt.tprintf("[Build] Shader files %s", detail)) }
	}
}

build_status_fini :: proc() {
	build_stamp_check_destroy(&g_build_status.stamp)
	for name in g_build_status.shader_failures { delete(name) }
	g_build_status = {}
}

// Called by shader_compile on a compile or link failure.
build_status_shader_failed :: proc(path, stage, info_log: string) {
	g_build_status.shader_failure_count += 1
	name := build_stamp_base_name(path)
	known := false
	for failed in g_build_status.shader_failures { if failed == name { known = true } }
	if !known && len(g_build_status.shader_failures) < BUILD_STAMP_MAX_SHADER_ERRORS {
		append(&g_build_status.shader_failures, strings.clone(name))
	}
	build_status_log(fmt.tprintf("[Shader] %s failed (%s):\n%s", stage, path, strings.trim_space(info_log)))
}

// The banner's lines, most important first. Empty when all is well.
build_status_banner_lines :: proc(status: ^Build_Status) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	if len(status.shader_failures) > 0 {
		names := strings.join(status.shader_failures[:], ", ", context.temp_allocator)
		append(&lines, fmt.tprintf("Shader failed to compile; see %s (%s).", BUILD_STAMP_LOG_PATH, names))
	}
	switch status.stamp.status {
	case .MATCH:
	case .MISMATCH: append(&lines, status.stamp.headline, BUILD_STAMP_REBUILD_HINT)
	case .NO_SHADERS: append(&lines, status.stamp.headline, BUILD_STAMP_FOLDER_HINT)
	}
	return lines[:]
}

// A strip across the top of the screen, over everything but the debug window.
// Drawn only when there is something to say.
build_status_banner_render :: proc(ui: ^UI, status_override: ^Build_Status = nil) -> (drawn: bool) {
	status := status_override != nil ? status_override : &g_build_status
	lines := build_status_banner_lines(status)
	if len(lines) == 0 || ui == nil || ui.width <= 0 { return false }
	scale := clamp(ui.height / 1080, 0.6, 2)
	size := 26 * scale
	pad := 12 * scale
	line_h := size * 1.25
	widest: f32
	for line in lines { widest = max(widest, ui_measure_text(ui, line, size)) }
	w := min(widest + pad*2, ui.width)
	h := pad*2 + line_h*f32(len(lines))
	x := (ui.width - w) * 0.5
	y := 8 * scale
	shader_error := len(status.shader_failures) > 0
	ui_fill_rect(ui, shader_error ? shared.Vec4{0.55, 0.08, 0.08, 0.92} : shared.Vec4{0.50, 0.30, 0.02, 0.92}, x, y, w, h)
	ui_fill_rect(ui, shared.Vec4{1, 0.85, 0.3, 1}, x, y + h - 2*scale, w, 2*scale)
	for line, i in lines {
		baseline := y + pad + line_h*f32(i) + size*0.85
		ui_fill_text(ui, shared.Vec4{1, 1, 1, 1}, line, x + pad, baseline, size)
	}
	return true
}
