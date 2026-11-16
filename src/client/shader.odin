package main

import "core:fmt"
import "core:strings"
import gl "vendor:OpenGL"
import shared "../shared"

// Programs compiled so far this session (diagnostics and tests).
g_shader_compiles: int

// `defines` (for example a "#define BATCHED" line) is inserted after the #version line.
// A file that cannot be read, compiled or linked is logged to logs/shaders.log
// and named in the on-screen error banner (build_stamp.odin).
shader_compile :: proc(vertex_shader_path, fragment_shader_path: string, defines := "") -> u32 {
	g_shader_compiles += 1
	vertex_shader, v_ok := shared.read_file(vertex_shader_path)
	fragment_shader, f_ok := shared.read_file(fragment_shader_path)
	defer delete(vertex_shader)
	defer delete(fragment_shader)

	if !v_ok || !f_ok {
		build_status_shader_failed(!v_ok ? vertex_shader_path : fragment_shader_path, "read", "the file could not be opened")
		return 0
	}
	return shader_compile_sources(string(vertex_shader), string(fragment_shader), vertex_shader_path, fragment_shader_path, defines)
}

// Compiles and links already loaded sources; the paths only label errors.
shader_compile_sources :: proc(vertex_source, fragment_source, vertex_shader_path, fragment_shader_path: string, defines := "") -> u32 {
	v_src := shader_insert_defines(vertex_source, defines)
	f_src := shader_insert_defines(fragment_source, defines)
	defer if len(defines) > 0 {
		delete(v_src)
		delete(f_src)
	}

	vert := gl.CreateShader(gl.VERTEX_SHADER)
	frag := gl.CreateShader(gl.FRAGMENT_SHADER)

	v_cstr := cstring(raw_data(v_src))
	f_cstr := cstring(raw_data(f_src))
	// read_file returns bytes without a terminating NUL. Passing explicit
	// lengths prevents GL from compiling memory beyond the source buffer.
	v_length := i32(len(v_src))
	f_length := i32(len(f_src))

	gl.ShaderSource(vert, 1, &v_cstr, &v_length)
	gl.CompileShader(vert)

	status: i32
	gl.GetShaderiv(vert, gl.COMPILE_STATUS, &status)

	if status == 0 {
		error: [1024]u8
		gl.GetShaderInfoLog(vert, len(error), nil, &error[0])
		build_status_shader_failed(vertex_shader_path, "vertex shader compile", string(cstring(&error[0])))

		gl.DeleteShader(vert)
		gl.DeleteShader(frag)
		return 0
	}

	gl.ShaderSource(frag, 1, &f_cstr, &f_length)
	gl.CompileShader(frag)

	gl.GetShaderiv(frag, gl.COMPILE_STATUS, &status)

	if status == 0 {
		error: [1024]u8
		gl.GetShaderInfoLog(frag, len(error), nil, &error[0])
		build_status_shader_failed(fragment_shader_path, "fragment shader compile", string(cstring(&error[0])))

		gl.DeleteShader(vert)
		gl.DeleteShader(frag)
		return 0
	}

	program := gl.CreateProgram()

	gl.AttachShader(program, vert)
	gl.AttachShader(program, frag)

	gl.LinkProgram(program)

	gl.DeleteShader(vert)
	gl.DeleteShader(frag)

	gl.GetProgramiv(program, gl.LINK_STATUS, &status)

	if status == 0 {
		error: [1024]u8
		gl.GetProgramInfoLog(program, len(error), nil, &error[0])
		build_status_shader_failed(fragment_shader_path, fmt.tprintf("shader link (with %s)", vertex_shader_path), string(cstring(&error[0])))

		gl.DeleteProgram(program)
		return 0
	}

	return program
}

// The HUD and menu programs. If the asset folder's copy fails (for example a
// newer shader than this exe understands), the sources built into the exe are
// used instead, so menus and the error banner always draw. The failure is
// still recorded and shown. `dir` ends with a slash.
shader_compile_ui :: proc(dir, vertex_name, fragment_name: string) -> u32 {
	vert := strings.concatenate({dir, vertex_name}, context.temp_allocator)
	frag := strings.concatenate({dir, fragment_name}, context.temp_allocator)
	if program := shader_compile(vert, frag); program != 0 { return program }
	vertex_source, v_ok := build_stamp_built_source(vertex_name)
	fragment_source, f_ok := build_stamp_built_source(fragment_name)
	if !v_ok || !f_ok { return 0 }
	fmt.printf("[Shader] Using the built-in %s and %s for the interface\n", vertex_name, fragment_name)
	return shader_compile_sources(string(vertex_source), string(fragment_source), fmt.tprintf("built-in %s", vertex_name), fmt.tprintf("built-in %s", fragment_name))
}

shader_insert_defines :: proc(source, defines: string) -> string {
	if len(defines) == 0 {
		return source
	}
	line_end := strings.index_byte(source, '\n')
	if line_end < 0 {
		return strings.concatenate({source, "\n", defines})
	}
	return strings.concatenate({source[:line_end + 1], defines, source[line_end + 1:]})
}
