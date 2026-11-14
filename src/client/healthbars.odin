package main

import "core:fmt"
import "core:math"
import gl "vendor:OpenGL"
import stbtt "vendor:stb/truetype"
import shared "../shared"

// Screen position and OpenGL clip depth from the world camera. The weapon
// camera has a separate FOV and must never move an overhead bar.
player_healthbar_project :: proc(view_projection: shared.Mat4, point: shared.Vec3, width, height: f32) -> (shared.Vec3, bool) {
	clip := view_projection * shared.Vec4{point.x, point.y, point.z, 1}
	if clip.w <= 0 || abs(clip.x) > clip.w || abs(clip.y) > clip.w || abs(clip.z) > clip.w { return {}, false }
	ndc := shared.Vec3{clip.x, clip.y, clip.z} / clip.w
	return {(ndc.x+1)*width*0.5, (1-ndc.y)*height*0.5, ndc.z}, true
}

// Krunker refreshes nameplate visibility (`canBSeen`) at most every 200 ms
// in its render loop, not per frame.
HEALTHBAR_VISIBILITY_INTERVAL :: f32(0.2)

// Krunker's nameplate rule. Teammates are always shown. Everyone else (all
// players in FFA, where the local team is 0) is shown only when the enemy-tag
// server option is off and `canSee` from the local eye to the target's feet
// reports no blocking map geometry.
player_healthbar_can_be_seen :: proc(client: ^Client, player: ^shared.Player) -> bool {
	me := client.me
	if me == nil || player == nil || !player.active { return false }
	if me.team != 0 && player.team == me.team { return true }
	if client.game.config.hide_enemy_nametags { return false }
	eye := me.position + shared.Vec3{0, me.height - shared.GAME_CONSTANTS.camera_height, 0}
	return shared.map_can_see(client.game.map_inst, eye, player.position)
}

player_healthbars_update_visibility :: proc(client: ^Client, now: f32) {
	if now - client.healthbar_visibility_checked_at < HEALTHBAR_VISIBILITY_INTERVAL { return }
	client.healthbar_visibility_checked_at = now
	live := client.me != nil && client.me.active
	for player in client.game.players {
		if player == nil || player == client.me { continue }
		player.can_be_seen = live && player_healthbar_can_be_seen(client, player)
	}
}

// Krunker nameplate geometry (nametagStyle 0, game.js `x.nametagOpacity > 0`).
// Lengths are 2D overlay canvas units. Krunker's canvas is scaled by the UI
// scale (`window.scaleBase`, the same formula as `ui.scale`) and then by the
// per-player distance scale, so on screen one unit is `ui.scale * plate_scale`.
NAMEPLATE_ANCHOR_HEIGHT :: f32(11.6) // objInstances.position.y + 11.6
NAMEPLATE_CROUCH_DROP   :: f32(3)    // - crouchVal * 3
NAMEPLATE_FADE_DISTANCE :: f32(600)  // max(0.3, 1 - distance / 600)
NAMEPLATE_MIN_SCALE     :: f32(0.3)
NAMEPLATE_BAR_WIDTH     :: f32(130)  // Y
NAMEPLATE_BAR_HEIGHT    :: f32(16)   // G with HP bars
NAMEPLATE_NO_BAR_HEIGHT :: f32(6)    // G without HP bars (mode.noHPbars)
NAMEPLATE_NAME_GAP      :: f32(10)   // translate(0, -G - 10)
NAMEPLATE_NAME_SIZE     :: f32(20)   // "20px GameFont"
NAMEPLATE_NAME_MAX_WIDTH :: f32(425) // fillText(..., 425)

// Krunker anchors the plate on the model root, 11.6 above the feet and 3 lower
// at full crouch. Krodin has no cosmetics data, so the +0.8 hat/head lift and
// the big-head (`headMlt`) lift are always zero.
player_nameplate_anchor :: proc(player: ^shared.Player) -> shared.Vec3 {
	return player.position + shared.Vec3{0, NAMEPLATE_ANCHOR_HEIGHT - player.crouch_val*NAMEPLATE_CROUCH_DROP, 0}
}

// Distance is measured from the world camera to the anchor.
player_nameplate_scale :: proc(camera_position, anchor: shared.Vec3) -> f32 {
	d := anchor - camera_position
	return max(NAMEPLATE_MIN_SCALE, 1 - math.sqrt(d.x*d.x + d.y*d.y + d.z*d.z)/NAMEPLATE_FADE_DISTANCE)
}

Nameplate_Layout :: struct {
	bar_left, bar_top, bar_width, bar_height: f32,
	name_x, name_baseline, name_size: f32,
}

// `unit` is screen pixels per canvas unit. With a bar, the bar's bottom edge
// sits on the anchor and the name is left-aligned with the bar, its baseline
// 10 units above the bar. Without a bar Krunker shrinks G to 6 and centres the
// name (Y becomes the name width).
player_nameplate_layout :: proc(screen: shared.Vec2, unit, name_width: f32, show_bar: bool) -> Nameplate_Layout {
	layout: Nameplate_Layout
	g := show_bar ? NAMEPLATE_BAR_HEIGHT : NAMEPLATE_NO_BAR_HEIGHT
	layout.bar_width, layout.bar_height = NAMEPLATE_BAR_WIDTH*unit, NAMEPLATE_BAR_HEIGHT*unit
	layout.bar_left, layout.bar_top = screen.x - layout.bar_width*0.5, screen.y - layout.bar_height
	layout.name_size = NAMEPLATE_NAME_SIZE*unit
	width := name_width*unit
	if width > NAMEPLATE_NAME_MAX_WIDTH*unit {
		layout.name_size *= NAMEPLATE_NAME_MAX_WIDTH*unit/width
		width = NAMEPLATE_NAME_MAX_WIDTH*unit
	}
	plate_width := show_bar ? layout.bar_width : width
	layout.name_x = screen.x - plate_width*0.5
	layout.name_baseline = screen.y - (g + NAMEPLATE_NAME_GAP)*unit
	return layout
}

// CSS font sizes are em sizes; Krodin's glyph cache scales by pixel height.
nameplate_font_size :: proc(em_pixels: f32) -> f32 {
	load_font()
	if !g_font_loaded { return em_pixels }
	return em_pixels * stbtt.ScaleForMappingEmToPixels(&g_font_info, 1) / stbtt.ScaleForPixelHeight(&g_font_info, 1)
}

// Live Krunker roster name, else the same "Player N" fallback as the lobby
// and scoreboard. Native sessions carry no names.
player_nameplate_name :: proc(client: ^Client, player: ^shared.Player) -> string {
	if client.krunker.connected {
		for entry in client.krunker_world.players {
			if entry.sid == player.uid && len(entry.name) > 0 { return entry.name }
		}
	}
	return fmt.tprintf("Player %d", player.uid)
}

player_healthbars_render :: proc(client: ^Client) {
	show_bars, show_names := !client.hud_settings.hide_healthbars, !client.hud_settings.hide_nametags
	if !show_bars && !show_names { return }
	if !client.in_game || !client.mouse_state.locked || client.me == nil || !client.me.active ||
		client.ui == nil || len(client.game.players) < 2 ||
		client.viewport_width <= 0 || client.viewport_height <= 0 { return }

	ui := client.ui
	ui_update(ui, f32(client.viewport_width), f32(client.viewport_height))
	// Krunker draws nameplates on its 2D overlay canvas, projected from 3D:
	// geometry never cuts a plate. Whether a plate exists at all is decided by
	// the line-of-sight gate (`can_be_seen`), so draw it whole, untested
	// against the world depth buffer and on top of the view model.
	gl.Disable(gl.DEPTH_TEST)
	view_projection := client.camera.projection_matrix * client.camera.world_inverse_matrix
	for player in client.game.players {
		if player == nil || player == client.me || player.is_you || !player.active || player.health <= 0 || player.max_health <= 0 || !player.can_be_seen { continue }
		anchor := player_nameplate_anchor(player)
		screen, visible := player_healthbar_project(view_projection, anchor, ui.width, ui.height)
		if !visible { continue }
		unit := ui.scale * player_nameplate_scale(client.camera.position, anchor)
		name := show_names ? player_nameplate_name(client, player) : ""
		name_width := show_names ? ui_measure_text(ui, name, nameplate_font_size(NAMEPLATE_NAME_SIZE)) : 0
		layout := player_nameplate_layout({screen.x, screen.y}, unit, name_width, show_bars)
		friendly := client.me.team != 0 && player.team == client.me.team
		if show_bars {
			border := max(1, 2*unit)
			progress := clamp(player.health/f32(player.max_health), 0, 1)
			color := shared.hex_to_vec(friendly ? 0x9eeb56 : 0xff4444)
			ui_fill_rect(ui, {0, 0, 0, 0.85}, layout.bar_left-border, layout.bar_top-border, layout.bar_width+2*border, layout.bar_height+2*border)
			ui_fill_rect(ui, {0.15, 0.15, 0.15, 1}, layout.bar_left, layout.bar_top, layout.bar_width, layout.bar_height)
			ui_fill_rect(ui, color, layout.bar_left, layout.bar_top, layout.bar_width*progress, layout.bar_height)
		}
		if show_names {
			// White, except enemies in team modes take the enemy colour.
			color := client.me.team != 0 && !friendly ? shared.hex_to_vec(0xff4444) : shared.Vec4{1, 1, 1, 1}
			ui_fill_text(ui, color, name, layout.name_x, layout.name_baseline, nameplate_font_size(layout.name_size))
		}
	}
}
