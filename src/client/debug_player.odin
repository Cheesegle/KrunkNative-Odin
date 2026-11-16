package main

import "core:fmt"
import "core:math"
import "core:strings"
import glfw "vendor:glfw"
import mu "vendor:microui"
import shared "../shared"

// The debug window's "Player" section (developer builds only): where the local
// player is, how they move, and which map object they stand on, plus a Copy
// button that puts a one-line summary on the clipboard for bug reports.
//
// Everything here sits inside `when KRODIN_DEV`, so release builds contain
// none of it. It runs only while the debug window is open and the section is
// expanded; the object lookup is a scan of the map's collision objects then.

when KRODIN_DEV {

// Feet within this distance of an object's top count as standing on it.
DEBUG_STAND_EPSILON :: f32(0.1)
// Horizontal slack for "touching" (a player pushed against a wall sits exactly
// at its face).
DEBUG_TOUCH_PAD :: f32(0.1)

Debug_Contact :: enum u8 {
	NONE,
	STANDING, // Feet on the object's top.
	TOUCHING, // Overlapping or against its side.
}

Debug_Player_Readout :: struct {
	valid:            bool, // A local player exists.
	map_name:         string,
	mode_name:        string,
	position:         shared.Vec3,
	velocity:         shared.Vec3,
	yaw, pitch:       f32, // Degrees; yaw in [0, 360).
	horizontal_speed: f32,
	crouch_val:       f32,
	on_ground, sliding, on_ramp, on_ladder: bool,
	on_wall:          u8,
	contact:          Debug_Contact,
	object_index:     int, // Index in map.objects; -1 without contact.
	object_prefab:    string,
	object_position:  shared.Vec3,
	object_size:      shared.Vec3,
	live:             bool, // Live Krunker lobby: server corrections apply.
	corrections:      int,
	last_correction:  shared.Vec3,
	correction_ack:   i32,
}

// Krunker mode indices named in krunker/gameplay.odin's stat tables.
debug_player_krunker_mode :: proc(index: i32) -> string {
	switch index {
	case 0: return "Free for All"
	case 1: return "Team Deathmatch"
	case 2: return "Hardpoint"
	case 3: return "Capture the Flag"
	case 10: return "Gun Game"
	case 13: return "Classic FFA"
	case 19: return "Kill Confirmed"
	case 21: return "Sharp Shooter"
	case 28: return "Team Defender"
	case 30: return "Carrier"
	case 33: return "Chaos Snipers"
	case 36: return "Impulsed"
	}
	return index < 0 ? "-" : fmt.tprintf("mode %d", index)
}

debug_player_mode_name :: proc(client: ^Client) -> string {
	if client.krunker.connected { return debug_player_krunker_mode(client.krunker_world.mode_index) }
	if client.game.mode == nil { return "-" }
	return client.game.mode.config.teams ? "Hardpoint" : "Free for All" // As the lobby screen names them.
}

// Lower-case prefab name ("crate", "container_r").
debug_player_prefab_name :: proc(prefab: shared.Prefab) -> string {
	return strings.to_lower(fmt.tprintf("%v", prefab), context.temp_allocator)
}

// The map object the player stands on, or failing that one they touch.
// Standing prefers the top closest to the feet; touching takes the nearest
// overlap in map order. Walks every collidable object (the movement pass's
// own list when the map has one).
debug_player_contact :: proc(player: ^shared.Player, map_inst: ^shared.Map) -> (contact: Debug_Contact, index: int) {
	index = -1
	if player == nil || map_inst == nil { return }
	best_gap := max(f32)
	disable_borders := player.game != nil && player.game.config.disable_borders
	count := map_inst.collision_indexed ? len(map_inst.collision_objects) : len(map_inst.objects)
	for i in 0..<count {
		object_index := map_inst.collision_indexed ? int(map_inst.collision_objects[i]) : i
		obj := map_inst.objects[object_index]
		if obj == nil || !obj.active || obj.collision_type == .NONE { continue }
		pad := player.scale + DEBUG_TOUCH_PAD
		dx, dz := player.position.x - obj.position.x, player.position.z - obj.position.z
		inside: bool
		if obj.collision_type == .CYLINDER {
			inside = dx*dx + dz*dz <= (obj.scale.x*0.5 + pad)*(obj.scale.x*0.5 + pad)
		} else {
			inside = abs(dx) <= obj.scale.x*0.5 + pad && abs(dz) <= obj.scale.z*0.5 + pad
		}
		if !inside { continue }
		top := obj.position.y + obj.scale.y
		if obj.is_border && !disable_borders { top += shared.GAME_CONSTANTS.border_height }
		feet := player.position.y
		if feet > top + DEBUG_STAND_EPSILON || feet + player.height < obj.position.y - DEBUG_STAND_EPSILON { continue }
		// A ramp's surface runs from its base to its top; standing anywhere on it counts.
		gap := obj.ramp != nil && player.on_ramp ? 0 : abs(top - feet)
		if gap <= DEBUG_STAND_EPSILON {
			if contact != .STANDING || gap < best_gap { contact, index, best_gap = .STANDING, object_index, gap }
		} else if contact == .NONE {
			contact, index = .TOUCHING, object_index
		}
	}
	return
}

debug_player_readout :: proc(client: ^Client) -> (r: Debug_Player_Readout) {
	r.map_name = debug_ui_map_name(client)
	r.mode_name = debug_player_mode_name(client)
	r.object_index = -1
	me := client.me
	if me == nil { return }
	r.valid = true
	r.position, r.velocity = me.position, me.velocity
	r.yaw = math.mod(math.to_degrees(me.direction.y), 360)
	if r.yaw < 0 { r.yaw += 360 }
	r.pitch = math.to_degrees(me.direction.x)
	r.horizontal_speed = math.sqrt(me.velocity.x*me.velocity.x + me.velocity.z*me.velocity.z)
	r.crouch_val = me.crouch_val
	r.on_ground, r.sliding, r.on_ramp, r.on_ladder, r.on_wall = me.on_ground, me.slide_timer > 0, me.on_ramp, me.on_ladder, me.on_wall
	map_inst := client.game.map_inst
	r.contact, r.object_index = debug_player_contact(me, map_inst)
	if r.object_index >= 0 {
		obj := map_inst.objects[r.object_index]
		r.object_prefab = debug_player_prefab_name(obj.prefab)
		r.object_position, r.object_size = obj.position, obj.scale
	}
	if client.krunker.connected {
		r.live = true
		r.corrections = client.krunker.prediction_corrections
		r.last_correction, r.correction_ack = client.krunker.last_correction, client.krunker.last_correction_ack
	}
	return
}

// One line for bug reports, e.g.
// `Sandstorm (-186.55, 53.00, -309.00) yaw 90.0 on crate #163 crouch 0.00`.
debug_player_summary :: proc(r: Debug_Player_Readout, allocator := context.temp_allocator) -> string {
	if !r.valid { return fmt.aprintf("%s (no player)", r.map_name, allocator = allocator) }
	contact: string
	switch r.contact {
	case .STANDING: contact = fmt.tprintf("on %s #%d", r.object_prefab, r.object_index)
	case .TOUCHING: contact = fmt.tprintf("touching %s #%d", r.object_prefab, r.object_index)
	case .NONE:     contact = "in air"
	}
	return fmt.aprintf("%s (%.2f, %.2f, %.2f) yaw %.1f %s crouch %.2f", r.map_name, r.position.x, r.position.y, r.position.z, r.yaw, contact, r.crouch_val, allocator = allocator)
}

debug_player_vec :: proc(v: shared.Vec3, decimals := 2) -> string {
	return decimals == 2 ? fmt.tprintf("%.2f, %.2f, %.2f", v.x, v.y, v.z) : fmt.tprintf("%.3f, %.3f, %.3f", v.x, v.y, v.z)
}

// Label, value, label, value: two short readings on one row.
debug_player_pair_row :: proc(ctx: ^mu.Context, label_width: i32, a, a_value: string, a_color: mu.Color, b, b_value: string, b_color: mu.Color) {
	body := mu.get_current_container(ctx).body
	value := max((body.w - label_width*2 - ctx.style.padding*2 - ctx.style.spacing*3)/2, 1)
	mu.layout_row(ctx, {label_width, value, label_width, -1})
	mu.label(ctx, a)
	debug_ui_value(ctx, a_value, a_color)
	mu.label(ctx, b)
	debug_ui_value(ctx, b_value, b_color)
}

// Copies the summary line; returns it for the caller (and tests).
debug_player_copy :: proc(client: ^Client, r: Debug_Player_Readout) -> string {
	line := debug_player_summary(r)
	if client.window != nil { glfw.SetClipboardString(client.window, strings.clone_to_cstring(line, context.temp_allocator)) }
	if client.debug_ui != nil {
		delete(client.debug_ui.player_copied)
		client.debug_ui.player_copied = strings.clone(line)
	}
	fmt.printf("[Debug] Copied player readout: %s\n", line)
	return line
}

// Expanded by default; the readout is built only while it is open.
debug_ui_player :: proc(client: ^Client, dbg: ^Debug_UI) {
	ctx := &dbg.ctx
	if .ACTIVE not_in mu.header(ctx, "Player", {.EXPANDED}) { return }
	s := dbg.scale
	muted := mu.Color{150, 156, 168, 255}
	white := ctx.style.colors[.TEXT]
	on := mu.Color{120, 220, 140, 255}
	label_width := i32(64*s)
	r := debug_player_readout(client)
	flag :: proc(value: bool, on, off: mu.Color) -> (string, mu.Color) { return value ? "yes" : "no", value ? on : off }
	mu.layout_row(ctx, {label_width, -1})
	if !r.valid {
		mu.label(ctx, "Player")
		debug_ui_value(ctx, "none", muted)
	} else {
		mu.label(ctx, "Pos")
		debug_ui_value(ctx, debug_player_vec(r.position), white)
		mu.label(ctx, "Vel")
		debug_ui_value(ctx, debug_player_vec(r.velocity), white)
		debug_player_pair_row(ctx, label_width, "Yaw", fmt.tprintf("%.1f", r.yaw), white, "Pitch", fmt.tprintf("%.1f", r.pitch), white)
		debug_player_pair_row(ctx, label_width, "Speed", fmt.tprintf("%.3f", r.horizontal_speed), white, "Crouch", fmt.tprintf("%.2f", r.crouch_val), r.crouch_val > 0 ? on : muted)
		ground, ground_color := flag(r.on_ground, on, muted)
		sliding, sliding_color := flag(r.sliding, on, muted)
		debug_player_pair_row(ctx, label_width, "Ground", ground, ground_color, "Sliding", sliding, sliding_color)
		ramp, ramp_color := flag(r.on_ramp, on, muted)
		ladder, ladder_color := flag(r.on_ladder, on, muted)
		debug_player_pair_row(ctx, label_width, "Ramp", ramp, ramp_color, "Ladder", ladder, ladder_color)
		mu.layout_row(ctx, {label_width, -1})
		mu.label(ctx, "Wall")
		debug_ui_value(ctx, r.on_wall == 0 ? "no" : fmt.tprintf("side %d", r.on_wall), r.on_wall == 0 ? muted : on)
		switch r.contact {
		case .NONE:
			mu.label(ctx, "On")
			debug_ui_value(ctx, "nothing", muted)
		case .STANDING, .TOUCHING:
			mu.label(ctx, r.contact == .STANDING ? "On" : "Touch")
			debug_ui_value(ctx, fmt.tprintf("%s #%d", r.object_prefab, r.object_index), white)
			mu.label(ctx, "Obj pos")
			debug_ui_value(ctx, debug_player_vec(r.object_position), white)
			mu.label(ctx, "Obj size")
			debug_ui_value(ctx, debug_player_vec(r.object_size), white)
		}
	}
	if r.live {
		mu.label(ctx, "Server")
		if r.corrections == 0 {
			debug_ui_value(ctx, "no corrections", muted)
		} else {
			error := math.sqrt(r.last_correction.x*r.last_correction.x + r.last_correction.y*r.last_correction.y + r.last_correction.z*r.last_correction.z)
			debug_ui_value(ctx, fmt.tprintf("%.3f at #%d (%d)", error, r.correction_ack, r.corrections), error >= 2 ? mu.Color{240, 120, 100, 255} : white)
			mu.label(ctx, "")
			debug_ui_value(ctx, debug_player_vec(r.last_correction, 3), muted)
		}
	}
	// Map and mode, with the Copy button at the end of the row.
	mu.layout_row(ctx, {label_width, -i32(64*s) - ctx.style.spacing, -1})
	mu.label(ctx, "Map")
	debug_ui_value(ctx, fmt.tprintf("%s, %s", r.map_name, r.mode_name), white)
	if .SUBMIT in mu.button(ctx, "Copy") { debug_player_copy(client, r) }
}

}
