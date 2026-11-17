package main

// Backend-neutral GPU interface (Vulkan port, Phase 1).
//
// Renderer code creates, updates, binds and destroys GPU resources only
// through the gpu_* procedures; each backend (gpu_gl.odin today, Vulkan next)
// implements them. Handles are opaque: 0 always means "none", and nothing
// outside the backend may assume what the value is. On the GL backend a
// handle's value happens to be the GL object name, so code that has not been
// moved behind this interface yet can still cast it (u32(handle)) to call GL
// directly. Every such cast marks a site the port still has to convert.

// The Vulkan backend (gpu_vk.odin) instead of OpenGL (gpu_gl.odin):
// -define:KRODIN_VULKAN=true, after tools/build-spirv.ps1 (build.bat vulkan).
KRODIN_VULKAN :: #config(KRODIN_VULKAN, false)

Gpu_Texture :: distinct u32
// A separate sampler object; bound over a texture's own sampling.
Gpu_Sampler :: distinct u32
// Something a pass renders into: a colour+depth target (offscreen frames,
// tests, the benchmark) or a depth-only one (shadow maps). 0 is the window.
Gpu_Render_Target :: distinct u32
// A compiled shader program variant (the world shaders; the UI still uses raw
// GL programs).
Gpu_Program :: distinct u32
// GPU memory holding vertices, indices or shader-readable storage.
Gpu_Buffer :: distinct u32
// A vertex buffer and an index buffer read with one Gpu_Vertex_Layout: what a
// draw binds. A VAO on GL; on Vulkan the layout belongs to the pipeline and
// this only names the two buffers.
Gpu_Vertex_Input :: distinct u32

Gpu_Buffer_Kind :: enum u8 {
	Vertex,
	Index,   // u32 indices
	Storage, // std430 shader storage
}

// Shader resource bindings shared by every backend. Uniform blocks: the
// per-pass block and the per-draw block. Storage buffers: the map batches'
// objects. Texture units: the colour texture, the sun shadow map array and
// the player shadow map.
GPU_BINDING_PASS    :: 0
GPU_BINDING_DRAW    :: 1
GPU_BINDING_OBJECTS :: 0
GPU_UNIT_COLOR         :: 0
GPU_UNIT_SHADOW        :: 1
GPU_UNIT_PLAYER_SHADOW :: 2

// Fixed-function state of a world draw. Depth testing (less) is always on;
// culling is a property of the pass (shadow passes cull front faces).
Gpu_Draw_State :: struct {
	blend:       bool, // src alpha, one minus src alpha
	depth_write: bool,
	wireframe:   bool,
}
GPU_DRAW_STATE_DEFAULT :: Gpu_Draw_State{depth_write = true}

// Frames in flight: gpu_frame_begin waits for the frame that last used its slot.
GPU_FRAMES_IN_FLIGHT :: 2

// Every vertex format the renderer draws from buffers. Attribute locations
// are fixed per layout and match the shaders' `layout(location = n)`.
Gpu_Vertex_Layout :: enum u8 {
	Basic,   // Vertex: position (0), tex_coord (1)
	Batched, // Batched_Vertex: position (0), tex_coord (1), face_idx (2), object_index (3)
}

Gpu_Format :: enum u8 {
	RGBA8, // 4 bytes per pixel, rows tightly packed
	R8,    // 1 byte per pixel (glyph coverage), rows tightly packed
	// Depth only, sampled through a comparison sampler (shadow maps). 24-bit
	// on GL; D32_SFLOAT on Vulkan, where D24 is optional. Uploads are f32.
	Depth,
}

Gpu_Filter :: enum u8 {
	Nearest,
	Linear,
}

Gpu_Wrap :: enum u8 {
	Repeat,
	Clamp,
}

// How a texture is sampled when no separate sampler overrides it (the world
// pass binds client.graphics_sampler over these). Vulkan bakes this into the
// texture's descriptor, so changing it later goes through
// gpu_texture_set_filter rather than a raw parameter write.
Gpu_Sampler_Desc :: struct {
	filter:     Gpu_Filter, // minification and magnification
	mip_filter: bool,       // pick the nearest mip level when minifying
	wrap:       Gpu_Wrap,
	// Depth comparison (reference <= stored), for shadow samplers.
	compare:    bool,
}

Gpu_Texture_Desc :: struct {
	width, height: i32,
	format:        Gpu_Format,
	// > 0 makes a 2D array texture with this many layers; 0 a plain 2D one.
	layers:        i32,
	// Allocate a full mip chain and build it from level 0 after upload.
	mipmaps:       bool,
	sampler:       Gpu_Sampler_Desc,
}

// Upload-time filtering of the map's prefab textures: sharp pixels, mip
// selection on minify, tiled.
GPU_SAMPLER_WORLD :: Gpu_Sampler_Desc{filter = .Nearest, mip_filter = true, wrap = .Repeat}
GPU_SAMPLER_UI_LINEAR :: Gpu_Sampler_Desc{filter = .Linear, wrap = .Clamp}
GPU_SAMPLER_UI_NEAREST :: Gpu_Sampler_Desc{filter = .Nearest, wrap = .Clamp}

gpu_format_bytes_per_pixel :: proc(format: Gpu_Format) -> int {
	switch format {
	case .RGBA8: return 4
	case .R8:    return 1
	case .Depth: return 4
	}
	return 0
}

// The texture sampled by untextured materials: one opaque white texel,
// created on first use and kept until resource_cache_fini.
gpu_blank_texture :: proc() -> Gpu_Texture {
	if g_blank_texture == 0 {
		white := [4]u8{255, 255, 255, 255}
		g_blank_texture = gpu_texture_create({width = 1, height = 1, format = .RGBA8, sampler = GPU_SAMPLER_UI_NEAREST}, white[:])
	}
	return g_blank_texture
}

// Binds `texture` (0 = the blank texture) for the colour sampler on unit 0.
// Consecutive binds of the same texture are skipped; g_active_texture is the
// cache, and anything that binds a texture behind this interface's back must
// reset it to 0.
gpu_bind_color_texture :: proc(texture: Gpu_Texture) {
	target := texture != 0 ? texture : gpu_blank_texture()
	if g_active_texture == target { return }
	gpu_texture_bind(0, target)
	g_active_texture = target
}
