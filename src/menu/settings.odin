package menu

import "core:fmt"
import "core:math"
import clay "../third_party/clay"

SETTINGS_ORANGE :: clay.Color{239, 110, 24, 255}
SETTINGS_BG :: clay.Color{39, 37, 44, 255}
SETTINGS_DARK :: clay.Color{29, 28, 33, 255}
SETTINGS_LINE :: clay.Color{73, 70, 79, 255}
SETTINGS_MUTED :: clay.Color{166, 164, 177, 255}
SETTINGS_TABS := [Settings_Tab]string{.MAIN = "Main", .INPUT = "Key binds", .VIDEO = "Video", .VISUALS = "Visuals", .GAMEPLAY = "Gameplay", .AUDIO = "Audio", .HUD = "HUD"}

settings_window :: proc(state: ^State, view: View) {
	s := state.scale
	if clay.UI(clay.ID("Overlay"))({
		layout = {sizing = {width = clay.SizingFixed(1360*s), height = clay.SizingFixed(780*s)}, layoutDirection = .TopToBottom},
		backgroundColor = SETTINGS_BG, cornerRadius = clay.CornerRadiusAll(12*s),
		border = {color = {131, 127, 140, 255}, width = clay.BorderOutside(1)},
	}) {
		if clay.UI(clay.ID("SettingsBody"))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()}}}) {
			if clay.UI(clay.ID("SettingsSidebar"))({
				layout = {sizing = {width = clay.SizingFixed(232*s), height = clay.SizingGrow()}, layoutDirection = .TopToBottom},
				backgroundColor = SETTINGS_DARK, border = {color = SETTINGS_LINE, width = {right = 1}},
			}) {
				if clay.UI()({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(80*s)}, padding = {left = u16(24*s)}, childAlignment = {y = .Center}}}) {
					text("SETTINGS", 28, s, SETTINGS_MUTED)
				}
				if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(u16(8*s)), childGap = u16(4*s)}}) {
					for tab in Settings_Tab {
						// Like Krunker, no tab is selected while search results are shown.
						settings_button(state, SETTINGS_TABS[tab], "SettingsTab", {kind = .SETTINGS_TAB, index = i32(tab)}, selected = tab == state.settings_tab && !settings_searching(state), align_left = true)
					}
				}
				spacer()
				if state.settings_tab == .GAMEPLAY { settings_crosshair_preview(state) }
				if state.settings_tab == .HUD && !settings_searching(state) { settings_damage_preview(state) }
				if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}, padding = clay.PaddingAll(u16(24*s))}}) { text("KRODIN", 16, s, SETTINGS_MUTED) }
			}
			if clay.UI(clay.ID("SettingsContent"))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()}, layoutDirection = .TopToBottom}}) {
				if clay.UI(clay.ID("SettingsHeading"))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(80*s)}, padding = {left = u16(32*s), right = u16(32*s)}, childAlignment = {y = .Center}}, backgroundColor = SETTINGS_DARK}) {
					text(settings_searching(state) ? "Search results" : SETTINGS_TABS[state.settings_tab], 28, s)
					spacer()
					// Krunker's header holds a 220px search field (settSearch, placeholder generic.search).
					if clay.UI()({layout = {sizing = {width = clay.SizingFixed(232*s)}, padding = {right = u16(12*s)}}}) { settings_search_field(state) }
					// Krunker's settings header places Reset, Export, then Import (settings.reset/settings.export/settings.import).
					if clay.UI()({layout = {sizing = {width = clay.SizingFixed(132*s)}, padding = {right = u16(12*s)}}}) { settings_button(state, "Reset", "SettingsReset", {kind = .SETTINGS_RESET_OPEN}, enabled = settings_reset_available(state)) }
					if clay.UI()({layout = {sizing = {width = clay.SizingFixed(132*s)}}}) { settings_button(state, "Export", "SettingsExport", {kind = .SETTINGS_EXPORT}) }
					if clay.UI()({layout = {sizing = {width = clay.SizingFixed(132*s), height = clay.SizingFixed(48*s)}, padding = {left = u16(12*s)}}}) { settings_button(state, "Import", "SettingsImport", {kind = .SETTINGS_IMPORT_OPEN}) }
				}
				if clay.UI(clay.ID("SettingsPanel"))({
					layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(u16(32*s))},
					clip = {vertical = true, childOffset = clay.GetScrollOffset()},
				}) {
					if settings_searching(state) { settings_search_results(state, view) } else { settings_tab_content(state, view, state.settings_tab) }
				}
				settings_scrollbar(state)
			}
		}
		if clay.UI(clay.ID("SettingsFooter"))({
			layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(88*s)}, padding = {left = u16(24*s), right = u16(24*s)}, childGap = u16(24*s), childAlignment = {y = .Center}},
			backgroundColor = SETTINGS_DARK, border = {color = SETTINGS_LINE, width = {top = 1}},
		}) {
			if clay.UI()({layout = {sizing = {width = clay.SizingFixed(184*s)}}}) { settings_button(state, "Cancel", "SettingsCancel", {kind = .SETTINGS_CANCEL}) }
			spacer()
			message_error := state.number_edit == .NONE && state.settings_message_length > 0 && state.settings_message_error
			text(settings_number_hint(state), 16, s, state.number_invalid || message_error ? clay.Color{255,100,100,255} : SETTINGS_MUTED)
			spacer()
			if clay.UI()({layout = {sizing = {width = clay.SizingFixed(184*s)}}}) { settings_button(state, "Save", "SettingsSave", {kind = .SETTINGS_SAVE}, selected = true) }
		}
	}
	settings_dropdown_menu(state, view)
	settings_import_popup(state)
	settings_reset_popup(state)
}

// One tab's sections and rows. Search lays out every tab through this too; the
// row helpers then skip rows that do not match.
settings_tab_content :: proc(state: ^State, view: View, tab: Settings_Tab) {
	values := state.settings_draft
	switch tab {
	case .MAIN:
		settings_section(state, "General")
		settings_sensitivity(state)
		// Search shows these shared rows once, under Audio, Video and HUD.
		if !settings_searching(state) {
			settings_slider(state, "Master volume", "MasterVolume", values.audio_volumes[0], 0, 1, {kind = .AUDIO_VOLUME})
			settings_display_rows(state, view)
			settings_fps_row(state)
		}
	case .INPUT:
		settings_bindings(state)
	case .VIDEO:
		settings_section(state, "Display")
		settings_display_rows(state, view)
		settings_toggle_row(state, "V-Sync", "VSync", values.vsync, {kind = .VSYNC})
		settings_game_fps_limit_row(state)
		settings_menu_fps_limit_row(state)
		settings_note(state, "Windowed sets the window size and Fullscreen switches the monitor to the chosen resolution. Borderless always uses the monitor's resolution.")
		settings_note(state, "Game FPS limit (Krunker's Frame Cap) caps frames while you play; 0 is unlimited, Krunker's default. With V-Sync also on, the lower rate wins. Menu FPS limit caps menus, loading and the end screen.")
		settings_quality(state, view)
	case .VISUALS:
		settings_visuals(state)
	case .GAMEPLAY:
		settings_viewmodel(state)
		settings_trails(state)
		settings_crosshair(state)
		settings_hitmarker(state)
		settings_section(state, "Loadout")
		settings_toggle_row(state, "Remember last secondary", "RememberSecondary", values.remember_secondary, {kind = .REMEMBER_SECONDARY})
		settings_note(state, "Krodin's own (default Off). Picking a class reuses the secondary you last chose for it and skips the loadout prompt. To change it, choose the class you already have again to open its loadout.")
	case .AUDIO:
		settings_section(state, "Volume")
		// Display order; audio_volumes is indexed master, effects, footsteps, UI, weapons.
		order := [5]int{0, 1, 4, 2, 3}
		labels := [5]string{"Master volume", "Effects volume", "Footsteps volume", "UI volume", "Weapon volume"}
		ids := [5]string{"MasterVolume", "EffectsVolume", "FootstepsVolume", "UiVolume", "WeaponVolume"}
		for i in order { settings_slider(state, labels[i], ids[i], values.audio_volumes[i], 0, 1, {kind = .AUDIO_VOLUME, index = i32(i)}) }
		settings_note(state, "Master affects every channel; 0% mutes one. Weapon volume (Krunker's, default 30%) covers every player's gunshots, swings, reloads and explosions.")
		settings_section(state, "Positional audio")
		if settings_search_show(state, "Spatial audio") {
			if clay.UI(clay.ID("SpatialAudioRow"))(settings_row(state)) {
				settings_label("Spatial audio", state.scale)
				spacer()
				settings_dropdown_field(state, spatial_audio_label(values.spatial_audio, view.surround_channels), "SpatialAudio", .SPATIAL_AUDIO)
			}
		}
		if settings_search_show(state, "Distance falloff") {
			if clay.UI(clay.ID("DistanceFalloffRow"))(settings_row(state)) {
				settings_label("Distance falloff", state.scale)
				spacer()
				settings_dropdown_field(state, DISTANCE_FALLOFF_LABELS[Distance_Falloff_Mode(clamp(values.distance_falloff, 0, 2))], "DistanceFalloff", .DISTANCE_FALLOFF)
			}
		}
		settings_toggle_row(state, "Loudness levelling", "LoudnessLevelling", values.levelling, {kind = .LEVELLING_TOGGLE})
		settings_slider(state, "Levelling strength", "LevellingStrength", values.levelling_strength, 0, 1, {kind = .LEVELLING_STRENGTH})
		settings_note(state, "HRTF (Krunker's default) needs headphones; Surround uses 5.1/7.1 speakers. Falloff Krunker matches the browser; Reduced keeps far sounds louder. Levelling lifts quiet sounds and tames loud shots.")
	case .HUD:
		settings_section(state, "Match")
		settings_toggle_row(state, "Timer", "HudTimer", !values.hud.hide_timer, {kind = .HUD_TOGGLE})
		settings_toggle_row(state, "Team round score", "HudRoundScore", !values.hud.hide_round_score, {kind = .HUD_TOGGLE, index = 1})
		settings_toggle_row(state, "Team game score", "HudGameScore", !values.hud.hide_game_score, {kind = .HUD_TOGGLE, index = 2})
		settings_note(state, "Round score: objective points this round. Game score: rounds won.")
		settings_section(state, "Performance")
		// Krunker showPing: "Show Ping", interface category, on by default.
		settings_toggle_row(state, "Show Ping", "HudPing", !values.hud.hide_ping, {kind = .HUD_TOGGLE, index = 3})
		settings_fps_row(state)
		settings_section(state, "Players")
		settings_toggle_row(state, "Show nametags", "HudNametags", !values.hud.hide_nametags, {kind = .HUD_TOGGLE, index = 4})
		settings_slider(state, "Nametag size", "HudNametagSize", nametag_scale(values.hud), NAMETAG_SCALE_MIN, NAMETAG_SCALE_MAX, {kind = .NAMETAG_SIZE})
		settings_crosshair_color(state, "Nametag color", NAMETAG_TEAM_COLOR_FIELD)
		settings_crosshair_color(state, "Enemy nametag color", NAMETAG_ENEMY_COLOR_FIELD)
		settings_note(state, state.color_invalid ? "Enter a six-digit color such as #00FF00. Escape discards the color edit." : "Nametag size scales the name only (75-200% of Krunker's size). As in Krunker, names are white, with enemies in team modes #EB5656; FFA names use Nametag color.")
		settings_toggle_row(state, "Show healthbars", "HudHealthbars", !values.hud.hide_healthbars, {kind = .HUD_TOGGLE, index = 5})
		settings_toggle_row(state, "Healthbar border", "HudHealthbarBorder", values.hud.healthbar_border, {kind = .HUD_TOGGLE, index = 7})
		// Krunker healthColE / healthColT (interface category).
		settings_crosshair_color(state, "Enemy healthbar color", HEALTHBAR_ENEMY_COLOR_FIELD)
		settings_crosshair_color(state, "Team healthbar color", HEALTHBAR_TEAM_COLOR_FIELD)
		settings_note(state, state.color_invalid ? "Enter a six-digit color such as #00FF00. Escape discards the color edit." : "Krunker's defaults are #EB5656 for enemies (also their names in team modes) and #9EEB56 for teammates. Click a color to type or paste #RRGGBB.")
		settings_section(state, "Killfeed")
		// Krunker showKills ("Display Kill feed", on) and feedLimit ("Killfeed Limit", 1-10, default 8).
		settings_toggle_row(state, "Show killfeed", "HudKillFeed", !values.hud.hide_kill_feed, {kind = .HUD_TOGGLE, index = 6})
		settings_slider(state, "Killfeed limit", "HudKillFeedLimit", f32(kill_feed_limit(values.hud)), 1, KILL_FEED_MAX_LIMIT, {kind = .KILL_FEED_LIMIT}, step = 1)
		// Krodin's own: scales the whole feed, 1x is Krunker's CSS size.
		settings_slider(state, "Killfeed size", "HudKillFeedSize", kill_feed_size(values.hud), KILL_FEED_MIN_SIZE, KILL_FEED_MAX_SIZE, {kind = .KILL_FEED_SIZE}, step = 0.1)
		settings_damage(state)
		settings_section(state, "Scope")
		// Krunker scopeBorders (Scope window, beside "Scope Border Color"; on by default).
		settings_toggle_row(state, "Scope borders", "HudScopeBorders", !values.hud.hide_scope_borders, {kind = .HUD_TOGGLE, index = 8})
		settings_note(state, "Scope borders fill the screen around the sniper scope with black. Off shows the scope image alone, as Krunker's Scope Borders switch does.")
	}
}

settings_set_message :: proc(state: ^State, message: string, is_error: bool) {
	state.settings_message_length = copy(state.settings_message[:], message)
	state.settings_message_error = is_error
}

settings_message :: proc(state: ^State) -> string { return string(state.settings_message[:state.settings_message_length]) }

settings_import_close :: proc(state: ^State) {
	state.import_open, state.import_length, state.import_overflow = false, 0, false
}

// Mirrors Krunker's importSettingsPopup: a header, a paste field and one
// Import button, plus Krodin's exclude toggles. Enter imports (or flips a
// focused toggle; Tab reaches them); Escape or a click outside closes it.
settings_import_popup :: proc(state: ^State) {
	if !state.import_open { return }
	s := state.scale
	state.control_count = 0 // Settings behind the popup ignore Tab and the mouse.
	if clay.UI(clay.ID("ImportPopup"))({
		layout = {sizing = {width = clay.SizingFixed(640*s)}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(u16(28*s)), childGap = u16(16*s), childAlignment = {x = .Center}},
		backgroundColor = SETTINGS_DARK, cornerRadius = clay.CornerRadiusAll(8*s), border = {color = SETTINGS_LINE, width = clay.BorderOutside(1)},
		floating = {attachTo = .ElementWithId, parentId = clay.ID("Overlay").id, zIndex = 20, attachment = {element = .CenterCenter, parent = .CenterCenter}},
	}) {
		text("Import Settings", 28, s)
		text("Copy Paste Settings Text Here", 19, s, SETTINGS_MUTED)
		value := string(state.import_buffer[:state.import_length])
		if clay.UI(clay.ID("ImportText"))({
			layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(96*s)}, padding = clay.PaddingAll(u16(12*s))},
			backgroundColor = {231, 229, 235, 255}, cornerRadius = clay.CornerRadiusAll(4*s), border = {color = WHITE, width = clay.BorderOutside(2)},
			clip = {horizontal = true, vertical = true},
		}) {
			label := len(value) == 0 ? "Press Ctrl+V to paste, or type here." : fmt.tprintf("%s|", shorten(value, 48))
			text(label, 18, s, len(value) == 0 ? SETTINGS_LINE : SETTINGS_DARK)
		}
		settings_import_exclude_rows(state)
		if state.settings_message_length > 0 && state.settings_message_error { text(settings_message(state), 16, s, {255, 100, 100, 255}) }
		if clay.UI()({layout = {sizing = {width = clay.SizingFixed(380*s)}}}) { settings_button(state, "Import", "ImportConfirm", {kind = .SETTINGS_IMPORT}, selected = true) }
	}
}

SETTINGS_IMPORT_EXCLUDE_LABELS := [Krunker_Import_Group]string{.SENSITIVITY = "Exclude sensitivity", .KEYBINDS = "Exclude keybinds", .SOUND = "Exclude sound"}

// Krodin's import filter: one On/Off toggle per group, like the settings rows.
// Krunker's popup has none; excluded groups keep their current values.
settings_import_exclude_rows :: proc(state: ^State) {
	s := state.scale
	if clay.UI(clay.ID("ImportExclude"))({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = u16(6*s)}}) {
		text("Krodin extra: excluded settings keep their current values.", 16, s, SETTINGS_MUTED)
		for group in Krunker_Import_Group {
			excluded := group in state.import_exclude
			if clay.UI(clay.ID("ImportExcludeRow", u32(group)))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(48*s)}, childAlignment = {y = .Center}}}) {
				text(SETTINGS_IMPORT_EXCLUDE_LABELS[group], 20, s)
				spacer()
				if clay.UI()({layout = {sizing = {width = clay.SizingFixed(128*s)}}}) {
					settings_button(state, excluded ? "On" : "Off", "ImportExcludeToggle", {kind = .SETTINGS_IMPORT_EXCLUDE, index = i32(group)}, selected = excluded)
				}
			}
		}
	}
}

settings_reset_available :: proc(state: ^State) -> bool { return state.settings_defaults != {} }

// Krunker's resetSettings: confirm("Are you sure you want to reset all your
// settings?"), then every setting and key bind returns to its default. Here
// the reset fills the draft only: Save applies and persists it, Cancel in the
// footer discards it. "Reset <tab> only" is a Krodin extra.
settings_reset_popup :: proc(state: ^State) {
	if !state.reset_open { return }
	s := state.scale
	state.control_count = 0 // Settings behind the popup ignore Tab and the mouse.
	if clay.UI(clay.ID("ResetPopup"))({
		layout = {sizing = {width = clay.SizingFixed(640*s)}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(u16(28*s)), childGap = u16(16*s), childAlignment = {x = .Center}},
		backgroundColor = SETTINGS_DARK, cornerRadius = clay.CornerRadiusAll(8*s), border = {color = SETTINGS_LINE, width = clay.BorderOutside(1)},
		floating = {attachTo = .ElementWithId, parentId = clay.ID("Overlay").id, zIndex = 20, attachment = {element = .CenterCenter, parent = .CenterCenter}},
	}) {
		text("Reset Settings", 28, s)
		text("Are you sure you want to reset all your settings?", 19, s)
		text("Every tab returns to its default, key binds included.", 17, s, SETTINGS_MUTED)
		text("Save keeps the reset; Cancel restores your settings.", 17, s, SETTINGS_MUTED)
		if clay.UI()({layout = {sizing = {width = clay.SizingFixed(380*s)}}}) { settings_button(state, "Reset all settings", "ResetConfirm", {kind = .SETTINGS_RESET}, selected = true) }
		if !settings_searching(state) {
			if clay.UI()({layout = {sizing = {width = clay.SizingFixed(380*s)}}}) { settings_button(state, fmt.tprintf("Reset %s only", SETTINGS_TABS[state.settings_tab]), "ResetTab", {kind = .SETTINGS_RESET, index = 1}) }
		}
		if clay.UI()({layout = {sizing = {width = clay.SizingFixed(380*s)}}}) { settings_button(state, "Keep my settings", "ResetCancel", {kind = .SETTINGS_RESET_CLOSE}) }
	}
}

// Escape or a click outside the popup closes it without changing anything.
settings_reset_interact :: proc(state: ^State, input: Input) -> bool {
	if input.escape && !state.previous.escape || input.down && !state.previous.down && !clay.PointerOver(clay.ID("ResetPopup")) {
		state.reset_open, state.pressed, state.focus = false, 0, clay.ID("SettingsReset").id
		return true
	}
	return false // The buttons use the normal press/release and keyboard handling.
}

// Restores the settings one tab shows. Rows shared between tabs (display and
// master volume on Main, Show FPS on Main and HUD) reset from either tab.
settings_reset_tab :: proc(draft: ^Settings_Values, defaults: Settings_Values, tab: Settings_Tab) {
	switch tab {
	case .MAIN:
		draft.mouse_dpi, draft.sensitivity, draft.ads_sensitivity = defaults.mouse_dpi, defaults.sensitivity, defaults.ads_sensitivity
		draft.invert_mouse, draft.advanced_sensitivity = defaults.invert_mouse, defaults.advanced_sensitivity
		draft.audio_volumes[0] = defaults.audio_volumes[0]
		draft.display_mode, draft.resolution_index, draft.fullscreen_index = defaults.display_mode, defaults.resolution_index, defaults.fullscreen_index
		draft.show_fps = defaults.show_fps
	case .INPUT:
		draft.bindings = defaults.bindings
	case .VIDEO:
		draft.display_mode, draft.monitor_index = defaults.display_mode, defaults.monitor_index
		draft.resolution_index, draft.fullscreen_index = defaults.resolution_index, defaults.fullscreen_index
		draft.vsync, draft.menu_fps_limit, draft.game_fps_limit, draft.quality = defaults.vsync, defaults.menu_fps_limit, defaults.game_fps_limit, defaults.quality
	case .VISUALS:
		draft.visuals = defaults.visuals
	case .GAMEPLAY:
		draft.fov, draft.viewmodel, draft.trails, draft.crosshair = defaults.fov, defaults.viewmodel, defaults.trails, defaults.crosshair
		draft.hitmarker, draft.remember_secondary = defaults.hitmarker, defaults.remember_secondary
	case .AUDIO:
		draft.audio_volumes = defaults.audio_volumes
		draft.spatial_audio, draft.distance_falloff = defaults.spatial_audio, defaults.distance_falloff
		draft.levelling, draft.levelling_strength = defaults.levelling, defaults.levelling_strength
	case .HUD:
		draft.hud, draft.show_fps, draft.damage = defaults.hud, defaults.show_fps, defaults.damage
	}
}

settings_import_interact :: proc(state: ^State, input: Input) -> (action: Action, handled: bool) {
	if input.escape && !state.previous.escape {
		settings_import_close(state)
		state.settings_message_length, state.pressed, state.focus = 0, 0, clay.ID("SettingsImport").id
		return {}, true
	}
	if input.clear_text { state.import_length, state.import_overflow = 0, false }
	if input.backspace && !state.previous.backspace && state.import_length > 0 {
		state.import_length -= 1
		state.import_overflow = false
	}
	if len(input.text) > 0 { state.settings_message_length = 0 }
	for i in 0..<len(input.text) {
		c := input.text[i]
		if c < 32 { c = ' ' } // Pasted line breaks and tabs are JSON whitespace.
		if state.import_length >= len(state.import_buffer) { state.import_overflow = true; break }
		state.import_buffer[state.import_length] = c
		state.import_length += 1
	}
	if input.enter && !state.previous.enter {
		// Typed text always goes to the paste field, so Enter flips a focused toggle.
		for control in state.controls[:state.control_count] {
			if control.id.id == state.focus && control.action.kind == .SETTINGS_IMPORT_EXCLUDE { return activate(state, control), true }
		}
		return activate(state, {action = {kind = .SETTINGS_IMPORT}}), true
	}
	if input.down && !state.previous.down && !clay.PointerOver(clay.ID("ImportPopup")) {
		settings_import_close(state)
		state.settings_message_length, state.pressed = 0, 0
		return {}, true
	}
	return {}, false // The Import button uses the normal press/release handling.
}

settings_button :: proc(state: ^State, label, name: string, action: Action, selected: bool = false, align_left: bool = false, enabled: bool = true) {
	s := state.scale
	// Cycling display mode keeps the same focus target as its action changes.
	id := clay.ID(name, action.kind == .DISPLAY_MODE ? 0 : u32(action.index))
	register(state, {id = id, action = action, enabled = enabled})
	color := selected ? SETTINGS_ORANGE : clay.Color{57, 54, 64, 255}
	if enabled && clay.PointerOver(id) { color = selected ? clay.Color{255, 128, 40, 255} : clay.Color{73, 68, 81, 255} }
	if state.pressed == id.id { color = {177, 76, 18, 255} }
	if clay.UI(id)({
		layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(48*s)}, padding = {left = u16(20*s), right = u16(20*s)}, childAlignment = {x = align_left ? .Left : .Center, y = .Center}},
		backgroundColor = color, cornerRadius = clay.CornerRadiusAll(3*s),
		border = {color = state.focus == id.id ? WHITE : SETTINGS_LINE, width = clay.BorderOutside(state.focus == id.id ? 2 : 1)},
	}) { text(label, 21, s, enabled ? WHITE : SETTINGS_MUTED) }
}

settings_scrollbar :: proc(state: ^State) {
	data := clay.GetScrollContainerData(clay.ID("SettingsPanel"))
	if !data.found || data.contentDimensions.height <= data.scrollContainerDimensions.height+1 { return }
	s := state.scale
	height := data.scrollContainerDimensions.height-24*s
	thumb_height := max(32*s, height*data.scrollContainerDimensions.height/data.contentDimensions.height)
	progress := clamp(-data.scrollPosition[1]/(data.contentDimensions.height-data.scrollContainerDimensions.height), 0, 1)
	if clay.UI(clay.ID("SettingsScrollTrack"))({
		layout = {sizing = {width = clay.SizingFixed(max(14,16*s)), height = clay.SizingFixed(height)}, layoutDirection = .TopToBottom}, backgroundColor = SETTINGS_LINE, cornerRadius = clay.CornerRadiusAll(4*s),
		floating = {attachTo = .ElementWithId, parentId = clay.ID("SettingsPanel").id, zIndex = 11, pointerCaptureMode = .Passthrough, attachment = {element = .RightTop, parent = .RightTop}, offset = {-8*s, 12*s}},
	}) {
		if clay.UI()({layout = {sizing = {height = clay.SizingFixed(progress*(height-thumb_height))}}}) {}
		thumb_color := state.scrollbar_dragging ? SETTINGS_ORANGE : clay.PointerOver(clay.ID("SettingsScrollThumb")) ? WHITE : SETTINGS_MUTED
		if clay.UI(clay.ID("SettingsScrollThumb"))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(thumb_height)}}, backgroundColor = thumb_color, cornerRadius = clay.CornerRadiusAll(4*s)}) {}
	}
}

settings_scrollbar_interact :: proc(state: ^State, input: Input) -> bool {
	if (state.page != .SETTINGS && state.page != .CONTROLS) || state.settings_dropdown != .NONE || input.escape {
		state.scrollbar_dragging = false
		return false
	}
	data := clay.GetScrollContainerData(clay.ID("SettingsPanel"))
	track := clay.GetElementData(clay.ID("SettingsScrollTrack"))
	thumb := clay.GetElementData(clay.ID("SettingsScrollThumb"))
	if !data.found || !track.found || !thumb.found {
		state.scrollbar_dragging = false
		return false
	}
	span := data.contentDimensions.height-data.scrollContainerDimensions.height
	travel := track.boundingBox.height-thumb.boundingBox.height
	if span <= 0 || travel <= 0 { state.scrollbar_dragging = false; return false }
	if input.down && !state.previous.down && clay.PointerOver(clay.ID("SettingsScrollTrack")) && contains(track.boundingBox, input.pointer) {
		state.scrollbar_dragging = true
		// Grabbing the thumb preserves its position. Clicking the empty track
		// centers it on the pointer, then lets the same press drag it further.
		state.scrollbar_grab = contains(thumb.boundingBox, input.pointer) ? input.pointer[1]-thumb.boundingBox.y : thumb.boundingBox.height/2
		state.pressed = 0
	}
	if !state.scrollbar_dragging { return false }
	if !input.down {
		state.scrollbar_dragging = false
		return true // Consume the release, even outside the scrollbar.
	}
	progress := clamp((input.pointer[1]-track.boundingBox.y-min(state.scrollbar_grab,thumb.boundingBox.height))/travel, 0, 1)
	data.scrollPosition[1] = -progress*span
	return true
}

settings_section :: proc(state: ^State, label: string) {
	if settings_searching(state) {
		// Defer the heading until a row in this section matches.
		state.search_section, state.search_section_pending = label, true
		state.search_section_match = state.search_tab_match || fuzzy_match(settings_search_query(state), label)
		return
	}
	settings_section_label(label, state.scale)
}

settings_section_label :: proc(label: string, s: f32) {
	if clay.UI()({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(48*s)}, childAlignment = {y = .Center}}}) { text(label, 17, s, SETTINGS_ORANGE) }
}

settings_note :: proc(state: ^State, label: string) {
	if settings_searching(state) { return } // Krunker's results list only settings.
	s := state.scale
	if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}, padding = {top = u16(20*s), bottom = u16(16*s)}}}) { text(label, 16, s, SETTINGS_MUTED) }
}

// These rows reserve the same label column in every category.
settings_row :: proc(state: ^State) -> clay.ElementDeclaration {
	s := state.scale
	return {
		layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(72*s)}, childGap = u16(24*s), childAlignment = {y = .Center}},
		border = {color = {57, 54, 64, 255}, width = {bottom = 1}},
	}
}

settings_label :: proc(label: string, s: f32) {
	if clay.UI()({layout = {sizing = {width = clay.SizingFixed(304*s)}, childAlignment = {y = .Center}}}) { text(label, 21, s) }
}

// Windowed uses the fixed presets; exclusive fullscreen uses the selected
// monitor's video modes. Borderless always covers the monitor at its own size.
settings_resolution_options :: proc(state: ^State, view: View) -> []string {
	switch state.settings_draft.display_mode {
	case 0: return view.resolution_options
	case 2: return view.fullscreen_options
	}
	return nil
}

settings_resolution_label :: proc(state: ^State, view: View) -> string {
	if state.settings_draft.display_mode == 2 && len(view.fullscreen_options) > 0 {
		return view.fullscreen_options[clamp(int(state.settings_draft.fullscreen_index), 0, len(view.fullscreen_options)-1)]
	}
	// Follow the live window until the user explicitly stages a windowed size.
	// The saved preset can differ from a resized or borderless window.
	if len(view.resolution_options) > 0 && (len(view.resolution) == 0 || state.settings_resolution_selected && state.settings_draft.display_mode == 0) {
		return view.resolution_options[clamp(int(state.settings_draft.resolution_index), 0, len(view.resolution_options)-1)]
	}
	return view.resolution
}

settings_display_rows :: proc(state: ^State, view: View) {
	s := state.scale
	values := state.settings_draft
	labels := [3]string{"Windowed", "Borderless", "Fullscreen"}
	if settings_search_show(state, "Video mode") {
		if clay.UI(clay.ID("DisplayModeRow"))(settings_row(state)) {
			settings_label("Video mode", s)
			spacer()
			settings_dropdown_field(state, labels[clamp(values.display_mode, 0, 2)], "DisplayMode", .DISPLAY_MODE)
		}
	}
	if settings_current_tab(state) == .VIDEO && settings_search_show(state, "Monitor") {
		if clay.UI(clay.ID("MonitorRow"))(settings_row(state)) {
			settings_label("Monitor", s)
			spacer()
			label := len(view.monitor_names) > 0 ? view.monitor_names[clamp(int(values.monitor_index), 0, len(view.monitor_names)-1)] : "Primary monitor"
			settings_dropdown_field(state, shorten(label, 28), "Monitor", .MONITOR, len(view.monitor_names) > 0)
		}
	}
	if settings_search_show(state, "Window resolution") {
		if clay.UI(clay.ID("ResolutionRow"))(settings_row(state)) {
			settings_label("Window resolution", s)
			spacer()
			label := settings_resolution_label(state, view)
			settings_dropdown_field(state, label, "Resolution", .RESOLUTION, len(settings_resolution_options(state, view)) > 0)
		}
	}
}

settings_toggle_row :: proc(state: ^State, label, name: string, value: bool, action: Action) {
	if !settings_search_show(state, label) { return }
	if clay.UI(clay.ID(fmt.tprintf("%sRow", name)))(settings_row(state)) {
		settings_label(label, state.scale)
		spacer()
		if clay.UI()({layout = {sizing = {width = clay.SizingFixed(128*state.scale)}}}) {
			settings_button(state, value ? "On" : "Off", name, action, selected = value)
		}
	}
}

settings_fps_row :: proc(state: ^State) {
	if !settings_search_show(state, "Show FPS") { return }
	if clay.UI(clay.ID("FpsRow"))(settings_row(state)) {
		settings_label("Show FPS", state.scale)
		spacer()
		if clay.UI()({layout = {sizing = {width = clay.SizingFixed(128*state.scale)}}}) {
			settings_button(state, state.settings_draft.show_fps ? "On" : "Off", "Fps", {kind = .FPS}, selected = state.settings_draft.show_fps)
		}
	}
}

// Curved sliders: a slider's position is |value|^(1/curve) of its range, so
// with curve > 1 small magnitudes get more of the bar (curve 2: the first 20%
// of a 0-100 slider covers 0-4). Ranges spanning zero curve symmetrically
// around it. Dragging a curved slider snaps to its step. curve <= 1 is linear
// and unsnapped, as before.
slider_progress :: proc(value, minimum, maximum, curve: f32) -> f32 {
	if maximum <= minimum { return 0 }
	if curve <= 1 { return clamp((value - minimum) / (maximum - minimum), 0, 1) }
	if minimum < 0 && maximum > 0 {
		t := value < 0 ? -math.pow(clamp(value / minimum, 0, 1), 1 / curve) : math.pow(clamp(value / maximum, 0, 1), 1 / curve)
		return (t + 1) * 0.5
	}
	return math.pow(clamp((value - minimum) / (maximum - minimum), 0, 1), 1 / curve)
}

slider_value_at :: proc(progress, minimum, maximum, curve, step: f32) -> f32 {
	p := clamp(progress, 0, 1)
	if curve <= 1 { return minimum + p * (maximum - minimum) }
	value: f32
	if minimum < 0 && maximum > 0 {
		t := p * 2 - 1
		value = t < 0 ? -math.pow(-t, curve) * -minimum : math.pow(t, curve) * maximum
	} else {
		value = minimum + math.pow(p, curve) * (maximum - minimum)
	}
	if step > 0 { value = math.round(value / step) * step }
	return clamp(value, minimum, maximum)
}

// zero_label replaces the value text at 0 (e.g. "Unlimited"); search_alias is
// a second name search finds the row by (e.g. Krunker's name for it).
settings_slider :: proc(state: ^State, label, name: string, value, minimum, maximum: f32, action: Action, step: f32 = 0.05, curve: f32 = 1, zero_label := "", search_alias := "") {
	if !settings_search_show(state, label) && (len(search_alias) == 0 || !settings_search_show(state, search_alias)) { return }
	s := state.scale
	if clay.UI(clay.ID(fmt.tprintf("%sRow", name)))(settings_row(state)) {
		settings_label(label, s)
		id := clay.ID(name)
		register(state, {id = id, enabled = true, slider = true, action = action, slider_min = minimum, slider_max = maximum, slider_step = step, slider_curve = curve})
		if clay.UI(id)({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(44*s)}, childAlignment = {y = .Center}}, border = {color = WHITE, width = clay.BorderOutside(state.focus == id.id ? 1 : 0)}}) {
			fill_id := clay.ID(fmt.tprintf("%sFill", name))
			progress := clamp(slider_progress(value, minimum, maximum, curve), 0.001, 0.999)
			if clay.UI(fill_id)({layout = {sizing = {width = clay.SizingPercent(progress), height = clay.SizingFixed(4*s)}}, backgroundColor = SETTINGS_ORANGE}) {
				if clay.UI(clay.ID(fmt.tprintf("%sThumb", name)))({layout = {sizing = {width = clay.SizingFixed(12*s), height = clay.SizingFixed(28*s)}}, backgroundColor = SETTINGS_ORANGE, cornerRadius = clay.CornerRadiusAll(3*s), floating = {attachTo = .ElementWithId, parentId = fill_id.id, zIndex = 11, pointerCaptureMode = .Passthrough, clipTo = .AttachedParent, attachment = {element = .CenterCenter, parent = .RightCenter}}}) {}
			}
			if clay.UI()({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(4*s)}}, backgroundColor = {137, 133, 146, 255}}) {}
		}
		value_id := clay.ID(fmt.tprintf("%sValue", name))
		register(state, {id=value_id, action=action, enabled=true, number=true, slider_min=minimum, slider_max=maximum})
		editing := state.number_edit == .SLIDER && state.number_control.id.id == value_id.id
		if clay.UI(value_id)({
			layout = {sizing = {width = clay.SizingFixed(128*s), height = clay.SizingFixed(44*s)}, padding={left=u16(8*s), right=u16(8*s)}, childAlignment = {x = .Center, y = .Center}},
			backgroundColor = editing && state.number_replace ? SETTINGS_ORANGE : clay.Color{231, 229, 235, 255}, cornerRadius = clay.CornerRadiusAll(4*s),
			border={color=editing && state.number_invalid ? clay.Color{255,70,70,255} : state.focus == value_id.id ? WHITE : SETTINGS_LINE, width=clay.BorderOutside(editing || state.focus == value_id.id ? 2 : 0)},
			clip={horizontal=editing, childOffset=clay.GetScrollOffset()},
		}) {
			label := settings_percent_action(action.kind) ? fmt.tprintf("%g%%", value*100) : fmt.tprintf("%g", value)
			if value == 0 && len(zero_label) > 0 { label = zero_label }
			if editing { label = fmt.tprintf("%s|", string(state.number_buffer[:state.number_length])) }
			text(label, 20, s, SETTINGS_DARK)
		}
	}
}
