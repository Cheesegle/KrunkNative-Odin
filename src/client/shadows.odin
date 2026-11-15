package main

import "core:encoding/json"
import "core:math"
import "core:math/linalg"
import gl "vendor:OpenGL"
import menuui "../menu"
import shared "../shared"

// Krunker's "Shadows" and "Lighting" settings, reproduced from game.deob.js
// (krunkbox extractor). Line numbers refer to that file.
//
// Shadows (settings list near line 210198, renderer near line 205458):
//   * One shadow-casting light: the map's sky light, a THREE.DirectionalLight
//     placed at lightD along the sun angles and aimed at the world origin
//     (sceneInit near line 208209). Its shadow camera is orthographic with
//     left/right = -/+shadWidth and bottom/top = -/+shadLength, computed once
//     from the extent of the map's cubes (near line 170502). It does not
//     follow the player.
//   * mapSize = shadowR (default 1024), or 4096 with High-Res Shadows. The
//     camera's far plane is shadowD (default 1200), bias -0.0004, normalBias
//     shadowNB clamped to 0..5.
//   * renderer.shadowMap.type is BasicShadowMap (one nearest depth compare),
//     or PCFShadowMap with Soft Shadows: five Vogel-disk taps rotated by
//     interleaved gradient noise, one texel radius, each a hardware 2x2
//     compare (lines 69376-69400 and 69566).
//   * shadow.autoUpdate = Dynamic Shadows. Off (the default), the map is
//     rendered into the shadow map only when the scene changes; on, every
//     frame. Players only cast with Dynamic Shadows (castShadow =
//     dynamicShadows near line 206367); everything receives.
//   * The shadow pass draws back faces of single-sided materials
//     (shadowSide map near line 77522), so front faces are culled here.
//
// Lighting (settings list near line 210476, getMat near line 206107):
//   0 Low      MeshBasicMaterial: unlit.
//   1 Normal   MeshLambertMaterial (the default): what Krodin already did.
//   2 High     MeshPhongMaterial (specular 0x111111, shininess 30), plus the
//              map's POINT_LIGHT and SPOT_LIGHT objects.
//   3 Physical MeshStandardMaterial (roughness 1, metalness 0), plus
//              DIRECTIONAL_LIGHT objects. RECTAREA_LIGHT objects are not
//              drawn here: no shipped map has one.
//   Map lights also need Krunker's Map Details setting, which defaults to on
//   and which Krodin does not have.

Shadow_Caster :: enum u8 {
	NONE,
	STATIC,  // Map geometry: always in the shadow map.
	DYNAMIC, // Players: only with Dynamic Shadows.
}

SHADOW_HIGH_RES :: 4096
SHADOW_BIAS :: -0.0004
SHADOW_NEAR :: 0.5 // THREE.DirectionalLightShadow camera default.
MAX_MAP_LIGHTS :: 16

// Raw prefab IDs (Krunker's object list, crate variants excluded).
PREFAB_POINT_LIGHT :: 53
PREFAB_DIRECTIONAL_LIGHT :: 65
PREFAB_RECTAREA_LIGHT :: 66
PREFAB_SPOT_LIGHT :: 67

Map_Light_Kind :: enum i32 { POINT, SPOT, DIRECTIONAL }

Map_Light :: struct {
	kind:          Map_Light_Kind,
	position:      shared.Vec3,
	target:        shared.Vec3,
	color:         shared.Vec3, // Already multiplied by intensity.
	distance:      f32,
	decay:         f32,
	cone_cos:      f32,
	penumbra_cos:  f32,
}

Render_Quality :: struct {
	shadows:      bool, // A shadow map exists and receivers should sample it.
	soft_shadows: bool,
	dynamic_shadows: bool,
	lighting:     menuui.Lighting_Quality,
}

// What scene_render uses for this frame. The default (no shadows, Normal
// lighting) is the renderer as it was before these settings, so code that
// renders without going through client_update_graphics is unchanged.
g_render_quality := Render_Quality{lighting = .NORMAL}

Shadow_State :: struct {
	program:        u32,
	uniforms:       Shadow_Depth_Uniforms,
	fbo, texture:   u32,
	size:           i32,
	soft:           bool,
	view_projection: shared.Mat4,
	shadow_matrix:  shared.Mat4, // World to shadow-map UV and depth.
	map_inst:       ^shared.Map, // Map the bounds and lights belong to.
	half_width:     f32,
	half_length:    f32,
	lights:         [MAX_MAP_LIGHTS]Map_Light,
	light_count:    int,
	dirty:          bool,
	renders:        int, // Shadow-map renders since startup (tests, benchmark).
}

Shadow_Depth_Uniforms :: struct {
	basic: Shader_Uniforms,
}

g_shadow: Shadow_State

json_truthy :: proc(value: json.Value) -> bool {
	#partial switch v in value {
	case json.Boolean: return bool(v)
	case json.Integer: return v != 0
	case json.Float: return v != 0
	case json.String: return len(v) > 0
	case json.Null: return false
	case json.Object, json.Array: return true
	}
	return false
}

// shadWidth/shadLength: the cube extent from the map loader, divided by 2.5
// and rounded (Krunker starts the min/max at zero and skips cubes with `l` or
// `col` set).
shadow_map_extent :: proc(map_inst: ^shared.Map) -> (half_width, half_length: f32) {
	min_x, max_x, min_z, max_z: f32
	for object in map_inst.objects {
		if object.prefab != .CUBE { continue }
		if raw, ok := object.raw_data.(json.Object); ok {
			if json_truthy(raw["l"]) || json_truthy(raw["col"]) { continue }
		}
		min_x = min(min_x, object.position.x - object.scale.x)
		max_x = max(max_x, object.position.x + object.scale.x)
		min_z = min(min_z, object.position.z - object.scale.z)
		max_z = max(max_z, object.position.z + object.scale.z)
	}
	return math.round(abs(max_z - min_z) / 2.5), math.round(abs(max_x - min_x) / 2.5)
}

@(private = "file")
shadow_object_color :: proc(map_inst: ^shared.Map, raw: json.Object) -> shared.Vec3 {
	color := shared.Vec4{242.0 / 255.0, 248.0 / 255.0, 252.0 / 255.0, 1} // "#f2f8fc"
	if hex, ok := raw["c"].(json.String); ok {
		shared.parse_hex_color(hex, &color)
	} else if index_value, has_index := raw["ci"]; has_index {
		index := int(shared.get_json_f32(index_value))
		if index >= 0 && index < len(map_inst.colors) { color = map_inst.colors[index] }
	}
	return {color.x, color.y, color.z}
}

@(private = "file")
shadow_json_f32 :: proc(raw: json.Object, key: string, fallback: f32) -> f32 {
	value, ok := raw[key]
	if !ok || !json_is_number(value) { return fallback }
	parsed := shared.get_json_f32(value)
	return parsed != 0 ? parsed : fallback // Krunker: parseFloat(x) || default.
}

// Map light objects (map loader near line 169666; clamps near line 167911).
map_lights_collect :: proc(map_inst: ^shared.Map, lights: ^[MAX_MAP_LIGHTS]Map_Light) -> int {
	count := 0
	for object in map_inst.objects {
		if count >= MAX_MAP_LIGHTS { break }
		id := int(object.prefab)
		if id != PREFAB_POINT_LIGHT && id != PREFAB_SPOT_LIGHT && id != PREFAB_DIRECTIONAL_LIGHT { continue }
		raw, ok := object.raw_data.(json.Object)
		if !ok { continue }
		light := Map_Light{position = object.position}
		intensity := clamp(shadow_json_f32(raw, "li", 1), 0, 15)
		light.color = shadow_object_color(map_inst, raw) * intensity
		if target, has_target := raw["lt"].(json.Array); has_target && len(target) >= 3 {
			light.target = {shared.get_json_f32(target[0]), shared.get_json_f32(target[1]), shared.get_json_f32(target[2])}
		}
		switch id {
		case PREFAB_POINT_LIGHT:
			light.kind = .POINT
			light.position.y += 2.5
			light.distance = clamp(shadow_json_f32(raw, "lds", 0), 0, 1000)
			light.decay = clamp(shadow_json_f32(raw, "ld", 1), 0.1, 2)
		case PREFAB_SPOT_LIGHT:
			light.kind = .SPOT
			light.position.y += 2
			distance: f32 = 50
			if value, has := raw["lds"]; has && json_is_number(value) { distance = shared.get_json_f32(value) }
			light.distance = clamp(distance, 0, 1000)
			light.decay = clamp(shadow_json_f32(raw, "ld", 1), 0.1, 2)
			angle := clamp(shadow_json_f32(raw, "la", 45), 1, 90) * math.PI / 180
			penumbra := clamp(shadow_json_f32(raw, "lp", 0), 0, 1)
			light.cone_cos = math.cos(angle)
			light.penumbra_cos = math.cos(angle * (1 - penumbra))
		case PREFAB_DIRECTIONAL_LIGHT:
			light.kind = .DIRECTIONAL
			light.position.y += 2
		}
		lights[count] = light
		count += 1
	}
	return count
}

// Lights visible at this lighting level: point and spot from High, directional
// from Physical.
map_light_enabled :: proc(light: Map_Light, lighting: menuui.Lighting_Quality) -> bool {
	switch light.kind {
	case .POINT, .SPOT: return lighting >= .HIGH
	case .DIRECTIONAL: return lighting == .PHYSICAL
	}
	return false
}

sun_position :: proc(config: shared.Lighting_Config) -> shared.Vec3 {
	ax := -config.sun_angle_x * math.PI / 180.0
	ay := -config.sun_angle_y * math.PI / 180.0
	d := config.light_distance
	return {d * math.cos(ax), d * math.sin(ax) * math.sin(ay), d * math.sin(ax) * math.cos(ay)}
}

// THREE.Matrix4.lookAt for a camera at `eye` looking at the origin, then the
// inverse (the view matrix).
shadow_view_matrix :: proc(eye: shared.Vec3) -> shared.Mat4 {
	up := shared.Vec3{0, 1, 0}
	z := eye
	if linalg.length2(z) == 0 { z.z = 1 }
	z = linalg.normalize(z)
	x := linalg.cross(up, z)
	if linalg.length2(x) == 0 {
		if abs(up.z) == 1 { z.x += 0.0001 } else { z.z += 0.0001 }
		z = linalg.normalize(z)
		x = linalg.cross(up, z)
	}
	x = linalg.normalize(x)
	y := linalg.cross(z, x)
	return shared.Mat4{
		x.x, x.y, x.z, -linalg.dot(x, eye),
		y.x, y.y, y.z, -linalg.dot(y, eye),
		z.x, z.y, z.z, -linalg.dot(z, eye),
		0, 0, 0, 1,
	}
}

// THREE.Matrix4.makeOrthographic (OpenGL clip space, z in -1..1).
shadow_ortho_matrix :: proc(left, right, top, bottom, near, far: f32) -> shared.Mat4 {
	w := 1 / (right - left)
	h := 1 / (top - bottom)
	p := 1 / (far - near)
	return shared.Mat4{
		2 * w, 0, 0, -(right + left) * w,
		0, 2 * h, 0, -(top + bottom) * h,
		0, 0, -2 * p, -(far + near) * p,
		0, 0, 0, 1,
	}
}

shadow_map_size :: proc(config: shared.Lighting_Config, high_res: bool) -> i32 {
	if high_res { return SHADOW_HIGH_RES }
	size := config.shadow_resolution > 0 ? config.shadow_resolution : shared.SHADOW_DEFAULT_RESOLUTION
	// Query once: a glGet every frame makes threaded drivers sync with the GPU.
	@(static) max_size: i32
	if max_size == 0 { gl.GetIntegerv(gl.MAX_TEXTURE_SIZE, &max_size) }
	return clamp(size, 1, max(max_size, 1))
}

// The sky light exists only when the map has a light colour (sceneInit tests
// `light` for truthiness, so 0 / black disables it).
sun_casts_light :: proc(config: shared.Lighting_Config) -> bool {
	return config.light_color != {} && config.light_intensity > 0
}

@(private = "file")
shadow_program_init :: proc() -> bool {
	if g_shadow.program != 0 { return true }
	vert := shared.concat(shared.assets_path(), "shaders/basic.vert")
	frag := shared.concat(shared.assets_path(), "shaders/basic.frag")
	defer { delete(vert); delete(frag) }
	g_shadow.program = shader_compile(vert, frag, "#define SHADOW_DEPTH_PASS\n")
	if g_shadow.program == 0 { return false }
	g_shadow.uniforms.basic = cache_uniforms(g_shadow.program)
	return true
}

@(private = "file")
shadow_target_init :: proc(size: i32, soft: bool) {
	if g_shadow.fbo != 0 && g_shadow.size == size && g_shadow.soft == soft { return }
	shadow_release_target()
	gl.CreateTextures(gl.TEXTURE_2D, 1, &g_shadow.texture)
	gl.TextureStorage2D(g_shadow.texture, 1, gl.DEPTH_COMPONENT24, size, size)
	filter := i32(soft ? gl.LINEAR : gl.NEAREST)
	gl.TextureParameteri(g_shadow.texture, gl.TEXTURE_MIN_FILTER, filter)
	gl.TextureParameteri(g_shadow.texture, gl.TEXTURE_MAG_FILTER, filter)
	gl.TextureParameteri(g_shadow.texture, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TextureParameteri(g_shadow.texture, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TextureParameteri(g_shadow.texture, gl.TEXTURE_COMPARE_MODE, gl.COMPARE_REF_TO_TEXTURE)
	gl.TextureParameteri(g_shadow.texture, gl.TEXTURE_COMPARE_FUNC, gl.LEQUAL)
	gl.CreateFramebuffers(1, &g_shadow.fbo)
	gl.NamedFramebufferTexture(g_shadow.fbo, gl.DEPTH_ATTACHMENT, g_shadow.texture, 0)
	gl.NamedFramebufferDrawBuffer(g_shadow.fbo, gl.NONE)
	gl.NamedFramebufferReadBuffer(g_shadow.fbo, gl.NONE)
	g_shadow.size, g_shadow.soft = size, soft
	g_shadow.dirty = true
}

shadow_release_target :: proc() {
	if g_shadow.fbo != 0 { gl.DeleteFramebuffers(1, &g_shadow.fbo) }
	if g_shadow.texture != 0 { gl.DeleteTextures(1, &g_shadow.texture) }
	g_shadow.fbo, g_shadow.texture, g_shadow.size = 0, 0, 0
}

// Map change: the shadow map and the light list belong to the old map.
shadow_release_map :: proc() {
	shadow_release_target()
	g_shadow.map_inst = nil
	g_shadow.light_count = 0
	g_shadow.dirty = true
}

// Shutdown: everything, including the depth program.
shadow_fini :: proc() {
	shadow_release_map()
	if g_shadow.program != 0 { gl.DeleteProgram(g_shadow.program) }
	if g_active_shader == g_shadow.program { g_active_shader = 0 }
	g_shadow = {}
	g_render_quality = {lighting = .NORMAL}
}

shadow_mark_dirty :: proc() { g_shadow.dirty = true }

// Called once per frame before the world pass. Decides what this frame draws
// and, when needed, renders the shadow map. With Shadows off (or nothing to
// shadow) it does no GL work at all.
// `framebuffer` and `viewport` are restored after a shadow-map render; they are
// passed in because reading them back with glGet stalls threaded drivers.
shadow_prepare :: proc(scene: ^Scene, map_inst: ^shared.Map, quality: menuui.Quality_Settings, framebuffer: u32 = 0, viewport: [4]i32 = {}) {
	lighting := menuui.Lighting_Quality(clamp(quality.lighting, 0, 3))
	g_render_quality = {lighting = lighting}
	if map_inst == nil { return }
	if g_shadow.map_inst != map_inst {
		shadow_release_target()
		g_shadow.map_inst = map_inst
		g_shadow.half_width, g_shadow.half_length = shadow_map_extent(map_inst)
		g_shadow.light_count = map_lights_collect(map_inst, &g_shadow.lights)
		g_shadow.dirty = true
	}
	config := g_lighting_config
	// Low lighting is MeshBasicMaterial, which never shows shadows; skip the
	// pass instead of rendering a map nobody samples.
	if !quality.shadows || lighting == .LOW || !sun_casts_light(config) || g_shadow.half_width <= 0 || g_shadow.half_length <= 0 {
		return
	}
	if !shadow_program_init() { return }
	shadow_target_init(shadow_map_size(config, quality.high_res_shadows), quality.soft_shadows)

	far := f32(config.shadow_distance > 0 ? config.shadow_distance : shared.SHADOW_DEFAULT_DISTANCE)
	view := shadow_view_matrix(sun_position(config))
	projection := shadow_ortho_matrix(-g_shadow.half_width, g_shadow.half_width, g_shadow.half_length, -g_shadow.half_length, SHADOW_NEAR, far)
	view_projection := projection * view
	if view_projection != g_shadow.view_projection { g_shadow.dirty = true }
	g_shadow.view_projection = view_projection
	uv := shared.Mat4{
		0.5, 0, 0, 0.5,
		0, 0.5, 0, 0.5,
		0, 0, 0.5, 0.5,
		0, 0, 0, 1,
	}
	g_shadow.shadow_matrix = uv * view_projection

	if g_shadow.dirty || quality.dynamic_shadows {
		shadow_render(scene, view, projection, quality.dynamic_shadows, framebuffer, viewport)
		g_shadow.dirty = false
	}
	g_render_quality.shadows = true
	g_render_quality.soft_shadows = quality.soft_shadows
	g_render_quality.dynamic_shadows = quality.dynamic_shadows
}

@(private = "file")
shadow_render :: proc(scene: ^Scene, view, projection: shared.Mat4, dynamic_shadows: bool, previous_fbo: u32, previous_viewport: [4]i32) {
	gl.BindFramebuffer(gl.FRAMEBUFFER, g_shadow.fbo)
	gl.Viewport(0, 0, g_shadow.size, g_shadow.size)
	gl.Enable(gl.DEPTH_TEST)
	gl.DepthMask(gl.TRUE)
	gl.Disable(gl.BLEND)
	gl.PolygonMode(gl.FRONT_AND_BACK, gl.FILL)
	gl.Clear(gl.DEPTH_BUFFER_BIT)
	gl.Enable(gl.CULL_FACE)
	gl.CullFace(gl.FRONT)
	gl.ActiveTexture(gl.TEXTURE0)

	gl.UseProgram(g_shadow.program)
	g_active_shader = g_shadow.program
	view_matrix, projection_matrix := view, projection
	u := &g_shadow.uniforms.basic
	gl.UniformMatrix4fv(u.camera_world_inverse, 1, gl.FALSE, &view_matrix[0, 0])
	gl.UniformMatrix4fv(u.camera_projection, 1, gl.FALSE, &projection_matrix[0, 0])
	gl.Uniform1f(u.world_uv_scale, shared.GAME_CONSTANTS.world_uv_scale)
	gl.Uniform1i(u.tex, 0)

	// basic_material_update_uniforms writes through u_basic; point it at the
	// depth program's locations for this pass.
	saved_uniforms := u_basic
	u_basic = u^
	defer u_basic = saved_uniforms
	vao: u32
	for mesh in scene.meshes {
		if !mesh.visible || mesh.shadow_caster == .NONE { continue }
		if mesh.shadow_caster == .DYNAMIC && !dynamic_shadows { continue }
		if mesh.material == nil || mesh.material.vtable != &basic_material_vtable { continue }
		mesh_update_transform_matrix(mesh)
		if vao != mesh.geometry.vao {
			gl.BindVertexArray(mesh.geometry.vao)
			vao = mesh.geometry.vao
		}
		basic_material_update_uniforms(mesh.material)
		gl.UniformMatrix4fv(u.transform, 1, gl.FALSE, &mesh.transform_matrix[0, 0])
		gl.DrawElements(gl.TRIANGLES, mesh.geometry.index_count, gl.UNSIGNED_INT, nil)
	}

	gl.Disable(gl.CULL_FACE)
	gl.CullFace(gl.BACK)
	gl.BindFramebuffer(gl.FRAMEBUFFER, previous_fbo)
	gl.Viewport(previous_viewport[0], previous_viewport[1], previous_viewport[2], previous_viewport[3])
	g_shadow.renders += 1
}

// Per-pass uniforms for basic.frag; called with the basic program bound.
shadow_update_pass_uniforms :: proc() {
	q := g_render_quality
	gl.Uniform1i(u_basic.lighting_mode, i32(q.lighting))
	gl.Uniform1i(u_basic.shadow_enabled, i32(q.shadows))
	if q.shadows {
		shadow_matrix := g_shadow.shadow_matrix
		gl.UniformMatrix4fv(u_basic.shadow_matrix, 1, gl.FALSE, &shadow_matrix[0, 0])
		gl.Uniform1i(u_basic.shadow_soft, i32(q.soft_shadows))
		gl.Uniform1f(u_basic.shadow_texel, 1 / f32(g_shadow.size))
		gl.Uniform1f(u_basic.shadow_bias, SHADOW_BIAS)
		gl.Uniform1f(u_basic.shadow_normal_bias, g_lighting_config.shadow_normal_bias)
		gl.Uniform1i(u_basic.shadow_map, 1)
		gl.BindTextureUnit(1, g_shadow.texture)
	}
	count: i32
	if q.lighting >= .HIGH {
		for light in g_shadow.lights[:g_shadow.light_count] {
			if !map_light_enabled(light, q.lighting) { continue }
			direction := light.kind == .POINT ? shared.Vec3{} : linalg.normalize0(light.kind == .DIRECTIONAL ? light.position - light.target : light.target - light.position)
			gl.Uniform4f(u_basic.map_light_position + count, light.position.x, light.position.y, light.position.z, f32(light.kind))
			gl.Uniform4f(u_basic.map_light_color + count, light.color.x, light.color.y, light.color.z, light.distance)
			gl.Uniform4f(u_basic.map_light_direction + count, direction.x, direction.y, direction.z, light.decay)
			gl.Uniform2f(u_basic.map_light_cone + count, light.cone_cos, light.penumbra_cos)
			count += 1
		}
	}
	gl.Uniform1i(u_basic.map_light_count, count)
}
