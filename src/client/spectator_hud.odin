package main

import "core:fmt"
import gl "vendor:OpenGL"
import shared "../shared"
import kproto "../krunker"
import menuui "../menu"

// The spectator HUD. Krunker's spectate UI shows the followed player's name
// and health and a fake crosshair, with the player list and the scoreboard
// on demand. This layout is Krodin's own: a focus card, a numbered player
// list (the 1-9 keys), names over players (M), the round HUD, the kill feed
// and the scoreboard (the Leaderboard bind).

SPECTATOR_HUD_BG :: shared.Vec4{0, 0, 0, 0.45}
SPECTATOR_HUD_WHITE :: shared.Vec4{1, 1, 1, 1}
SPECTATOR_HUD_MUTED :: shared.Vec4{1, 1, 1, 0.65}
SPECTATOR_HUD_HEALTH :: shared.Vec4{0.62, 0.92, 0.34, 1}
SPECTATOR_HUD_HIGHLIGHT :: shared.Vec4{1, 0.83, 0.25, 1}

spectator_team_color :: proc(team: i32) -> shared.Vec4 {
	switch team {
	case 1: return {0.38, 0.66, 1, 1}
	case 2: return {1, 0.45, 0.38, 1}
	}
	return SPECTATOR_HUD_WHITE
}

spectator_mode_label :: proc(mode: Spectator_Mode) -> string {
	switch mode {
	case .FIRST_PERSON: return "First person"
	case .CHASE: return "Third person"
	case .FREE: return "Free cam"
	}
	return ""
}

spectator_hud_render :: proc(client: ^Client, delta: f32) {
	ui := client.ui
	if ui == nil { return }
	spec := &client.spectator
	s := ui.scale
	source, target := spectator_target(client)
	// The world pass leaves depth testing on; the HUD is flat.
	gl.Disable(gl.DEPTH_TEST)

	if spec.mode == .FIRST_PERSON && target != nil && target.weapon != nil && target.weapon.scope && spec.aim > 0.95 {
		overlay_scope_render(ui, !client.hud_settings.hide_scope_borders)
	}
	if !spec.hide_names { spectator_names_render(client) }

	// Fake crosshair (browser ct.fakeCross) in first person, fading with ADS.
	if spec.mode == .FIRST_PERSON && target != nil && !client.scoreboard_open {
		// The followed player's ADS fades it like your own, unless the
		// crosshair settings say Always Show (or a custom opacity).
		crosshair := client_crosshair_values(client)
		crosshair_render(ui, crosshair, ui.width*0.5, ui.height*0.5, s, spectator_crosshair_opacity(client, crosshair))
	}
	// The followed player's hits (spectator_hits), at the centre.
	hitmarker := client_hitmarker_values(client)
	hit_marker_tick(&client.hit_marker, hitmarker, delta)
	if spec.mode != .FREE { hit_marker_render(ui, client.hit_marker, hitmarker, ui.width*0.5, ui.height*0.5, s) }

	// Title: who and how.
	{
		title := "SPECTATING"
		if spec.mode == .FREE { title = "FREE CAM" }
		else if source != nil { title = fmt.tprintf("SPECTATING  %s", source.name) }
		size := 26 * s
		width := ui_measure_text(ui, title, size)
		hint := fmt.tprintf("%s  |  L/R click: prev/next  1-9: pick  F: free cam  R: first/third  M: names  Wheel: %s",
			spectator_mode_label(spec.mode), spec.mode == .FREE ? "speed" : "distance")
		hint_size := 17 * s
		hint_width := ui_measure_text(ui, hint, hint_size)
		box := max(width, hint_width) + 32*s
		x := (ui.width - box) * 0.5
		y := ui.height - 150*s
		ui_round_rect(ui, SPECTATOR_HUD_BG, x, y, box, 60*s, 6*s)
		ui_fill_text(ui, source != nil && spec.mode != .FREE ? spectator_team_color(source.team) : SPECTATOR_HUD_WHITE, title, (ui.width - width)*0.5, y + 28*s, size)
		ui_fill_text(ui, SPECTATOR_HUD_MUTED, hint, (ui.width - hint_width)*0.5, y + 50*s, hint_size)
	}

	// Focus card: health, class and weapon of the followed player.
	if spec.mode != .FREE && source != nil && target != nil {
		w, h := 420*s, 64*s
		x, y := (ui.width - w)*0.5, ui.height - 82*s
		ui_round_rect(ui, SPECTATOR_HUD_BG, x, y, w, h, 6*s)
		health := source.health
		max_health := source.max_health > 0 ? source.max_health : f32(target.max_health)
		progress := max_health > 0 ? clamp(health/max_health, 0, 1) : 0
		bar_x, bar_y, bar_w, bar_h := x + 12*s, y + 38*s, 200*s, 16*s
		ui_round_rect(ui, {0, 0, 0, 0.5}, bar_x, bar_y, bar_w, bar_h, 4*s)
		if progress > 0 { ui_round_rect(ui, SPECTATOR_HUD_HEALTH, bar_x, bar_y, bar_w*progress, bar_h, 4*s) }
		ui_fill_text(ui, SPECTATOR_HUD_WHITE, fmt.tprintf("%.0f / %.0f", health, max_health), bar_x + bar_w + 10*s, bar_y + 14*s, 18*s)
		class_name := ""
		if target.class_index >= 0 && int(target.class_index) < len(client.game.classes) { class_name = client.game.classes[target.class_index].name }
		ui_fill_text(ui, SPECTATOR_HUD_MUTED, fmt.tprintf("%s   K %d  D %d", class_name, source.kills, source.deaths), x + 12*s, y + 26*s, 17*s)
		if target.weapon != nil {
			weapon_id: i32 = -1
			if target.loadout_index >= 0 && int(target.loadout_index) < len(target.loadout) { weapon_id = target.loadout[target.loadout_index] }
			icon, _ := overlay_weapon_icon(client, weapon_id)
			name_size := 18*s
			name_width := ui_measure_text(ui, target.weapon.name, name_size)
			ui_fill_text(ui, SPECTATOR_HUD_WHITE, target.weapon.name, x + w - 12*s - name_width, y + 26*s, name_size)
			if icon != 0 { ui_draw_image(ui, icon, x + w - 12*s - 70*s, y + 30*s, 70*s, 28*s) }
		}
	}

	spectator_player_list_render(client)
	if !client.hud_settings.hide_timer {
		timer := krunker_client_timer_label(client)
		size := 30*s
		width := ui_measure_text(ui, timer, size)
		ui_round_rect(ui, SPECTATOR_HUD_BG, 20*s, 20*s, width + 28*s, 46*s, 6*s)
		ui_fill_text(ui, SPECTATOR_HUD_WHITE, timer, 34*s, 20*s + 34*s, size)
	}
	overlay_match_render(client)
	kill_feed_render(client)
	if client.scoreboard_open {
		board := client_scoreboard(client)
		scoreboard_render(ui, &board, 160*s)
	}
}

// Numbered list of followable players (the 1-9 keys), grouped by team.
spectator_player_list_render :: proc(client: ^Client) {
	ui := client.ui
	s := ui.scale
	list: [dynamic; 64]i32
	spectator_candidates(client, &list)
	if len(list) == 0 { return }
	// Below the timer and the team-score widget (overlay_match_render).
	x, y := 20*s, 240*s
	row := 32*s
	w := 300*s
	shown := min(len(list), 16)
	ui_round_rect(ui, SPECTATOR_HUD_BG, x, y, w, row*f32(shown) + 10*s, 6*s)
	for sid, i in list[:shown] {
		source: ^kproto.Krunker_World_Player
		for &p in client.krunker_world.players { if p.sid == sid { source = &p } }
		if source == nil { continue }
		top := y + 5*s + row*f32(i)
		current := sid == client.spectator.target_sid && client.spectator.mode != .FREE
		if current { ui_round_rect(ui, {1, 1, 1, 0.12}, x + 4*s, top, w - 8*s, row, 4*s) }
		label := i < SPECTATOR_LIST_MAX ? fmt.tprintf("%d", i+1) : " "
		ui_fill_text(ui, current ? SPECTATOR_HUD_HIGHLIGHT : SPECTATOR_HUD_MUTED, label, x + 10*s, top + 23*s, 20*s)
		ui_fill_text(ui, spectator_team_color(source.team), scoreboard_fit_text(ui, source.name, 20*s, 170*s), x + 34*s, top + 23*s, 20*s)
		max_health := source.max_health > 0 ? source.max_health : 100
		progress := clamp(source.health/max_health, 0, 1)
		bar_x := x + w - 70*s
		ui_fill_rect(ui, {0, 0, 0, 0.5}, bar_x, top + 12*s, 56*s, 9*s)
		ui_fill_rect(ui, SPECTATOR_HUD_HEALTH, bar_x, top + 12*s, 56*s*progress, 9*s)
	}
}

// Names over players (Krunker's specNames, M). Projected from the camera like
// the normal nameplates, without their line-of-sight gate.
spectator_names_render :: proc(client: ^Client) {
	ui := client.ui
	if client.viewport_width <= 0 || client.viewport_height <= 0 { return }
	camera := client.camera
	camera.fov = client_world_fov(client)
	camera_update_projection_matrix(&camera, f32(client.viewport_width)/f32(client.viewport_height))
	camera_update_world_inverse_matrix(&camera)
	view_projection := camera.projection_matrix * camera.world_inverse_matrix
	for &source in client.krunker_world.players {
		if !source.active || source.life_ended || source.sid == client.krunker_world.local_sid { continue }
		if source.sid == client.spectator.target_sid && client.spectator.mode == .FIRST_PERSON { continue }
		player := client_find_player(client, source.sid)
		if player == nil || !player.active { continue }
		screen, visible := player_healthbar_project(view_projection, player_nameplate_anchor(player), ui.width, ui.height)
		if !visible { continue }
		size := 15*ui.scale
		width := ui_measure_text(ui, source.name, size)
		ui_fill_text(ui, spectator_team_color(source.team), source.name, screen.x - width*0.5, screen.y - 8*ui.scale, size)
		max_health := source.max_health > 0 ? source.max_health : 100
		bar := 50*ui.scale
		ui_fill_rect(ui, {0, 0, 0, 0.5}, screen.x - bar*0.5, screen.y - 4*ui.scale, bar, 5*ui.scale)
		ui_fill_rect(ui, SPECTATOR_HUD_HEALTH, screen.x - bar*0.5, screen.y - 4*ui.scale, bar*clamp(source.health/max_health, 0, 1), 5*ui.scale)
	}
}

// Krunker's spectator fakeCross fades with the followed player's ADS (the
// browser sets the reticle opacity from aimVal); Always Show and Custom
// opacity apply as they do to your own crosshair.
spectator_crosshair_opacity :: proc(client: ^Client, settings: menuui.Crosshair_Settings) -> f32 {
	return menuui.crosshair_opacity(settings, 1 - clamp(client.spectator.aim, 0, 1))
}
