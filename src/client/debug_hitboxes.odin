package main

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import glfw "vendor:glfw"
import shared "../shared"

// Developer hitbox visualizer: wireframes of what the hit tests use, toggled
// from the debug window's "Rendering" section. Only developer builds call any
// of this (every call site is `when KRODIN_DEV`), and with every toggle off the
// frame does no extra work beyond one bool test.
//
// Player boxes come from the same procs the hit tests use:
//   - native/offline: shared.krunker_target_pose + krunker_player_hurtboxes,
//     exactly the pose and boxes player_shoot tests (Krunker's oriented
//     head/torso/arm/leg boxes, +1 per side while the target's velocity is
//     non-zero), or shared.krunker_melee_box while holding a melee weapon;
//   - live Krunker:   shared.krunker_player_hurtboxes (Krunker's server
//     decides those hits).
// Positions are the ones this client simulates or shows: offline that is the
// simulation itself; online, remote players are drawn where they are displayed
// (interpolated), which is the pose Krunker's server rewinds to for your shots.

DEBUG_MAP_RANGE :: f32(150) // Map collision is drawn within this distance.
DEBUG_SHOT_MAX :: 16
DEBUG_SHOT_LIFE :: f64(2) // Seconds a fired ray stays drawn.

Debug_Shot :: struct {
	origin, end: shared.Vec3,
	hit:  bool,
	kind: shared.Bullet_Hit_Kind,
	time: f64,
}

Debug_Line_Vertex :: struct {
	position: shared.Vec3,
	color:    shared.Vec4,
}

Debug_Hitbox_Model :: enum u8 {
	KRODIN,  // Native/offline: Krodin decides hits.
	KRUNKER, // Live Krunker lobby: Krunker's server decides hits.
}

// Which of Krunker's two box sizes is drawn solid. Krunker's server grows
// every box by 1 unit per side (OBB halfSize + 1) while the target's velocity
// is non-zero; the other size is drawn dim.
Debug_Hurtbox_Padding :: enum u8 {
	AUTO,     // Follow the target's movement, as the server does.
	PADDED,   // Always the +1 boxes.
	UNPADDED, // Always the geometry boxes.
}

// Toggles default off and are not saved: every launch starts clean.
Debug_Render :: struct {
	player_hitboxes: bool,
	map_collision:   bool,
	shot_rays:       bool,
	xray:            bool, // Draw through walls instead of depth-testing.
	hurtbox_padding: Debug_Hurtbox_Padding,
	model_bounds:    bool, // The rendered model's part boxes, to compare.
	shots:      [DEBUG_SHOT_MAX]Debug_Shot,
	shot_count: int,
	shot_next:  int,
	lines: [dynamic]Debug_Line_Vertex,
	program: Gpu_Program, // debug_line.vert/.frag, created when first drawn
}

DEBUG_COLOR_BODY         :: shared.Vec4{0.2, 1.0, 0.35, 1}
DEBUG_COLOR_HEAD         :: shared.Vec4{1.0, 0.9, 0.1, 1}
DEBUG_COLOR_ARM          :: shared.Vec4{0.1, 0.9, 1.0, 1}
DEBUG_COLOR_LEG          :: shared.Vec4{1.0, 0.25, 0.25, 1}
// Krunker's own hitbox materials: head #ffff00, torso #00ff00, legs #ff0000.
// Krunker draws arms with the torso colour; cyan keeps them distinct here.
DEBUG_KRUNKER_COLORS :: [shared.Krunker_Hurtbox_Part]shared.Vec4{
	.HEAD  = {1, 1, 0, 1},
	.TORSO = {0, 1, 0, 1},
	.ARM   = {0, 1, 1, 1},
	.LEG   = {1, 0, 0, 1},
}
DEBUG_COLOR_MODEL        :: shared.Vec4{1.0, 0.2, 1.0, 1}
DEBUG_COLOR_MAP_SOLID    :: shared.Vec4{1.0, 0.55, 0.1, 1}
DEBUG_COLOR_MAP_PASS     :: shared.Vec4{0.35, 0.55, 1.0, 1}
DEBUG_COLOR_SHOT_MISS    :: shared.Vec4{1, 1, 1, 1}
DEBUG_COLOR_SHOT_WORLD   :: shared.Vec4{1.0, 0.55, 0.1, 1}
DEBUG_COLOR_SHOT_PLAYER  :: shared.Vec4{1.0, 0.1, 0.1, 1}

debug_render_enabled :: proc(dr: ^Debug_Render) -> bool {
	return dr.player_hitboxes || dr.map_collision || dr.shot_rays
}

debug_hitbox_model :: proc(client: ^Client) -> Debug_Hitbox_Model {
	return client.krunker.connected ? .KRUNKER : .KRODIN
}

// The two native shot paths use different player boxes (hurtboxes for shots,
// one padded box for melee); show the ones the local weapon would use.
debug_hitbox_kind :: proc(client: ^Client) -> shared.Hitbox_Kind {
	if client.me != nil && client.me.weapon != nil && client.me.weapon.melee { return .MELEE }
	return .SHOT
}

// Keeps the local player's newest rays (called before impacts are consumed).
debug_render_record_impacts :: proc(client: ^Client, now: f64) {
	dr := &client.debug_render
	if !dr.shot_rays { return }
	for impact in client.game.impacts {
		if client.me != nil && impact.shooter_uid != client.me.uid { continue }
		dr.shots[dr.shot_next] = {origin = impact.origin, end = impact.position, hit = impact.hit, kind = impact.kind, time = now}
		dr.shot_next = (dr.shot_next + 1) % DEBUG_SHOT_MAX
		dr.shot_count = min(dr.shot_count + 1, DEBUG_SHOT_MAX)
	}
}

@(private="file")
debug_line :: proc(lines: ^[dynamic]Debug_Line_Vertex, a, b: shared.Vec3, color: shared.Vec4) {
	append(lines, Debug_Line_Vertex{a, color}, Debug_Line_Vertex{b, color})
}

// The 12 edges of the unit cube [-0.5, 0.5]^3 under `transform`.
debug_lines_cube :: proc(lines: ^[dynamic]Debug_Line_Vertex, transform: shared.Mat4, color: shared.Vec4) {
	corners: [8]shared.Vec3
	for i in 0 ..< 8 {
		local := shared.Vec4{(i & 1) != 0 ? 0.5 : -0.5, (i & 2) != 0 ? 0.5 : -0.5, (i & 4) != 0 ? 0.5 : -0.5, 1}
		corners[i] = (transform * local).xyz
	}
	for i in 0 ..< 8 {
		for bit in ([3]int{1, 2, 4}) {
			if i & bit == 0 { debug_line(lines, corners[i], corners[i | bit], color) }
		}
	}
}

debug_lines_box :: proc(lines: ^[dynamic]Debug_Line_Vertex, box: shared.Box, color: shared.Vec4) {
	debug_lines_cube(lines, shared.box_transform(box), color)
}

// A vertical cylinder from `base` up `height`, as two rings and four struts.
debug_lines_cylinder :: proc(lines: ^[dynamic]Debug_Line_Vertex, base: shared.Vec3, radius, height: f32, color: shared.Vec4) {
	SEGMENTS :: 16
	for i in 0 ..< SEGMENTS {
		a0 := f32(i) / SEGMENTS * math.TAU
		a1 := f32(i + 1) / SEGMENTS * math.TAU
		p0 := base + shared.Vec3{math.cos(a0) * radius, 0, math.sin(a0) * radius}
		p1 := base + shared.Vec3{math.cos(a1) * radius, 0, math.sin(a1) * radius}
		debug_line(lines, p0, p1, color)
		debug_line(lines, p0 + {0, height, 0}, p1 + {0, height, 0}, color)
		if i % (SEGMENTS / 4) == 0 { debug_line(lines, p0, p0 + {0, height, 0}, color) }
	}
}

debug_lines_cross :: proc(lines: ^[dynamic]Debug_Line_Vertex, at: shared.Vec3, size: f32, color: shared.Vec4) {
	debug_line(lines, at - {size, 0, 0}, at + {size, 0, 0}, color)
	debug_line(lines, at - {0, size, 0}, at + {0, size, 0}, color)
	debug_line(lines, at - {0, 0, size}, at + {0, 0, size}, color)
}

// Whether `player`'s hitboxes are drawn: everyone else, and yourself only when
// your body is on screen (third person or free camera).
debug_hitbox_player_shown :: proc(client: ^Client, player: ^shared.Player) -> bool {
	if player == nil || !player.active { return false }
	if player == client.me { return client.freecam_enabled || player_uses_third_person_camera(player) }
	return true
}

debug_lines_player :: proc(lines: ^[dynamic]Debug_Line_Vertex, player: ^shared.Player, model: Debug_Hitbox_Model, kind: shared.Hitbox_Kind, moving: bool) {
	switch model {
	case .KRODIN:
		if kind == .MELEE {
			debug_lines_box(lines, shared.krunker_melee_box(shared.krunker_shot_target(player)), DEBUG_COLOR_BODY)
		} else {
			debug_lines_krunker_pose(lines, shared.krunker_target_pose(player), moving)
		}
	case .KRUNKER:
		debug_lines_krunker_pose(lines, shared.krunker_hurtbox_pose(player, moving), moving)
	}
}

debug_dim :: proc(color: shared.Vec4) -> shared.Vec4 {
	return {color.r * 0.4, color.g * 0.4, color.b * 0.4, 1}
}

// Krunker's boxes for one pose: the size the server uses (`padded`) solid,
// with a marker at each active box's centre, its inactive leg set dim, and
// the other size dim.
debug_lines_krunker_pose :: proc(lines: ^[dynamic]Debug_Line_Vertex, pose: shared.Krunker_Hurtbox_Pose, padded: bool) {
	pose := pose
	colors := DEBUG_KRUNKER_COLORS
	for variant in ([2]bool{!padded, padded}) {
		pose.moving, pose.inactive_legs = variant, variant == padded
		boxes: [shared.KRUNKER_HURTBOX_MAX]shared.Krunker_Hurtbox
		count := shared.krunker_player_hurtboxes(pose, &boxes)
		for box in boxes[:count] {
			solid := variant == padded && box.active
			debug_lines_cube(lines, box.transform, solid ? colors[box.part] : debug_dim(colors[box.part]))
			if solid { debug_lines_cross(lines, shared.krunker_hurtbox_center(box), 0.3, colors[box.part]) }
		}
	}
}

// The pose Krunker's server tests for `player`, as far as this client knows:
//   - position, angles, stepVal: the displayed (interpolated) pose, which is
//     what the shot's servTim/progress rewinds the server to;
//   - cV: fetchState returns the NEWER history entry's cV (and weapon) without
//     lerping them, i.e. the newest k snapshot's crouch value;
//   - headMlt: roster/bh; hurtboxScale: the lobby setting;
//   - padding: the server tests the target's CURRENT velocity != 0. Remote
//     velocity is not sent, so a change between the two newest k snapshots
//     stands in for it. (Per-frame displayed motion drew unpadded boxes on a
//     strafing target in testing.) Your own player uses its velocity.
debug_krunker_hurtbox_pose :: proc(client: ^Client, player: ^shared.Player) -> (pose: shared.Krunker_Hurtbox_Pose, server_moving: bool) {
	pose = shared.krunker_hurtbox_pose(player, false)
	if scale := client.game.config.hurtbox_scale; scale > 0 { pose.hurtbox_scale = scale }
	if player == client.me { return pose, player.velocity != {} }
	for &source in client.krunker_world.players {
		if source.sid != player.uid { continue }
		if source.head_mlt > 0 { pose.head_mlt = source.head_mlt }
		if source.pose_count > 0 {
			newest := source.poses[source.pose_count - 1]
			pose.crouch = math.round(clamp(newest.crouch, 0, 1))
			if source.pose_count > 1 {
				previous := source.poses[source.pose_count - 2]
				server_moving = linalg.length2(newest.position - previous.position) > 1e-6
			}
		}
		break
	}
	return
}

// The rendered model's parts: each mesh's geometry bounds under its world
// matrix, so model-vs-hitbox misalignment shows directly.
debug_lines_model_bounds :: proc(lines: ^[dynamic]Debug_Line_Vertex, player: ^shared.Player) {
	if player.mesh == nil { return }
	pm := cast(^Player_Mesh)player.mesh
	add :: proc(lines: ^[dynamic]Debug_Line_Vertex, mesh: ^Mesh) {
		if mesh == nil || !mesh.visible || mesh.geometry == nil || !mesh.geometry.has_bounds { return }
		g := mesh.geometry
		local := linalg.matrix4_translate_f32((g.bounds_min + g.bounds_max) * 0.5) * linalg.matrix4_scale_f32(g.bounds_max - g.bounds_min)
		debug_lines_cube(lines, mesh.transform_matrix * local, DEBUG_COLOR_MODEL)
	}
	cube :: proc(lines: ^[dynamic]Debug_Line_Vertex, c: ^Color_Cube) {
		if c == nil { return }
		for mesh in c.meshes { add(lines, mesh) }
	}
	cube(lines, pm.head)
	cube(lines, pm.body)
	for leg in pm.legs { cube(lines, leg) }
	for leg in pm.crouched_legs {
		if leg == nil { continue }
		add(lines, leg.upper); add(lines, leg.joint); cube(lines, leg.lower)
	}
	for arms in pm.arms {
		if arms == nil { continue }
		for arm in ([2]^Player_Arm_Mesh{arms.left, arms.right}) {
			if arm == nil { continue }
			add(lines, arm.upper); add(lines, arm.joint); cube(lines, arm.lower)
		}
	}
}

// Distance from `point` to the nearest point of an axis-aligned box.
@(private="file")
debug_box_distance :: proc(point, box_min, box_max: shared.Vec3) -> f32 {
	nearest := linalg.clamp(point, box_min, box_max)
	return linalg.length(point - nearest)
}

debug_lines_map :: proc(lines: ^[dynamic]Debug_Line_Vertex, game: ^shared.Game, around: shared.Vec3, range: f32) {
	map_inst := game.map_inst
	if map_inst == nil { return }
	for object in map_inst.objects {
		if object == nil || !object.active || object.collision_type == .NONE { continue }
		// The vertical extent player_collides uses (borders reach higher).
		border: f32 = game.config.disable_borders || !object.is_border ? 0 : shared.GAME_CONSTANTS.border_height
		half := shared.Vec3{object.scale.x * 0.5, 0, object.scale.z * 0.5}
		box_min := object.position - half
		box_max := object.position + half + {0, object.scale.y + border, 0}
		if debug_box_distance(around, box_min, box_max) > range { continue }
		color := shared.map_object_blocks_shots(object) ? DEBUG_COLOR_MAP_SOLID : DEBUG_COLOR_MAP_PASS
		switch object.collision_type {
		case .BOX:
			debug_lines_box(lines, {object.position, {object.scale.x, object.scale.y + border, object.scale.z}}, color)
		case .CYLINDER:
			debug_lines_cylinder(lines, object.position, object.scale.x * 0.5, object.scale.y + border, color)
		case .NONE:
		}
	}
}

// Rebuilds this frame's line list from the enabled toggles.
debug_render_build :: proc(client: ^Client, now: f64) {
	dr := &client.debug_render
	clear(&dr.lines)
	if dr.map_collision { debug_lines_map(&dr.lines, &client.game, client.camera.position, DEBUG_MAP_RANGE) }
	if dr.player_hitboxes {
		model := debug_hitbox_model(client)
		kind := debug_hitbox_kind(client)
		for player in client.game.players {
			if !debug_hitbox_player_shown(client, player) { continue }
			if model == .KRUNKER {
				pose, server_moving := debug_krunker_hurtbox_pose(client, player)
				padded := dr.hurtbox_padding == .AUTO ? server_moving : dr.hurtbox_padding == .PADDED
				debug_lines_krunker_pose(&dr.lines, pose, padded)
			} else {
				// player_shoot pads by the target's own velocity.
				server_moving := player.velocity != {}
				padded := dr.hurtbox_padding == .AUTO ? server_moving : dr.hurtbox_padding == .PADDED
				debug_lines_player(&dr.lines, player, model, kind, padded)
			}
			if dr.model_bounds { debug_lines_model_bounds(&dr.lines, player) }
		}
	}
	if dr.shot_rays {
		for i in 0 ..< dr.shot_count {
			shot := dr.shots[i]
			if now - shot.time > DEBUG_SHOT_LIFE { continue }
			color := DEBUG_COLOR_SHOT_MISS
			if shot.hit { color = shot.kind == .Player ? DEBUG_COLOR_SHOT_PLAYER : DEBUG_COLOR_SHOT_WORLD }
			debug_line(&dr.lines, shot.origin, shot.end, color)
			if shot.hit { debug_lines_cross(&dr.lines, shot.end, 0.6, color) }
		}
	}
}

// Draws the line list with the world camera. The depth-tested pass runs right
// after the world (before the view model clears depth); with x-ray on, the
// lines are drawn last instead, with no depth test, over everything.
debug_render_lines :: proc(dr: ^Debug_Render, view_projection: shared.Mat4, depth_test: bool) -> (vertices: int) {
	if len(dr.lines) == 0 { return }
	if dr.program == 0 { dr.program = gpu_program_create_debug_lines() }
	if dr.program == 0 { return }
	indices := make([]u32, len(dr.lines), context.temp_allocator)
	for &index, i in indices { index = u32(i) }
	if !gpu_transient_bind(.Debug_Line, slice.to_bytes(dr.lines[:]), indices) { return }
	gpu_program_bind(dr.program)
	view_projection := view_projection
	gpu_uniform_push(GPU_BINDING_DRAW, mem.ptr_to_bytes(&view_projection))
	// Opaque lines that never write depth: on surfaces (LEQUAL) or, x-ray,
	// through them.
	gpu_draw_state_set({depth_test = depth_test ? .Less_Equal : .Off})
	gpu_draw_indexed(i32(len(dr.lines)), 0)
	g_draw_calls += 1
	gpu_draw_state_reset()
	return len(dr.lines)
}

// Frame hook after the world pass (depth still holds the world).
debug_render_after_world :: proc(client: ^Client) {
	dr := &client.debug_render
	if !debug_render_enabled(dr) { return }
	debug_render_build(client, glfw.GetTime())
	if !dr.xray { debug_render_lines(dr, client.camera.projection_matrix * client.camera.world_inverse_matrix, true) }
}

// Frame hook after the view model: x-ray lines go on top of everything.
debug_render_after_viewmodel :: proc(client: ^Client) {
	dr := &client.debug_render
	if !debug_render_enabled(dr) || !dr.xray { return }
	debug_render_lines(dr, client.camera.projection_matrix * client.camera.world_inverse_matrix, false)
}

debug_render_fini :: proc(dr: ^Debug_Render) {
	gpu_program_destroy(&dr.program)
	delete(dr.lines)
	dr^ = {}
}
