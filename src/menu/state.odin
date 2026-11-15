package menu

import "core:fmt"
import "base:runtime"
import clay "../third_party/clay"

Page :: enum { HOME, SETTINGS, CONTROLS, SESSION, CLASSES, LOADOUT }
Lobby_Presentation :: enum { STANDARD, COMPETITIVE }
// The client owns clipboard access and session changes. The menu emits actions
// and renders requested selections separately from confirmed lobby state.
Action_Kind :: enum { NONE, PLAY, QUIT, JOIN_LINK, LOGIN, CANCEL_JOIN, FORGET_BROWSER_SESSION, PASTE, COPY_INVITE, LEAVE_SESSION, LOCAL_PRACTICE, SELECT_TEAM, SELECT_CLASS, SELECT_SECONDARY, INSPECT_CLASS, EDIT_INVITE, DISPLAY_MODE, RESOLUTION, SENSITIVITY, FPS, AUDIO_VOLUME, SETTINGS_TAB, SETTINGS_SAVE, SETTINGS_CANCEL, BIND_KEY, HUD_TOGGLE, VSYNC, MONITOR, SETTINGS_DROPDOWN, RESOLUTION_SELECT, VISUAL_VALUE, VISUAL_TOGGLE, VISUAL_RESET, TEXTURE_FILTER, ANISOTROPY, QUALITY_TOGGLE, LIGHTING, SHADOW_QUALITY, SETTINGS_NUMBER, FOV, ADVANCED_SENSITIVITY, INVERT_MOUSE, VIEWMODEL_VALUE, VIEWMODEL_TOGGLE, TRAILS_TOGGLE, CROSSHAIR_TYPE, CROSSHAIR_VALUE, CROSSHAIR_TOGGLE, CROSSHAIR_COLOR, SETTINGS_IMPORT_OPEN, SETTINGS_IMPORT, SETTINGS_EXPORT, SETTINGS_RESET_OPEN, SETTINGS_RESET, SETTINGS_RESET_CLOSE, SETTINGS_SEARCH, MENU_FPS_LIMIT, NIGHT_STRENGTH }
Action :: struct { kind: Action_Kind, index: i32, value: f32 }
Settings_Tab :: enum { MAIN, INPUT, VIDEO, VISUALS, GAMEPLAY, AUDIO, HUD }
Settings_Dropdown :: enum { NONE, DISPLAY_MODE, MONITOR, RESOLUTION, TEXTURE_FILTER, ANISOTROPY, CROSSHAIR_TYPE, MENU_FPS_LIMIT, LIGHTING, SHADOW_QUALITY }
// Stored as "hide" flags so settings files without a key keep the item shown;
// hide_ping inverts Krunker's showPing (default true) so the zero value matches.
HUD_Settings :: struct { hide_timer, hide_round_score, hide_game_score, hide_ping, hide_nametags, hide_healthbars: bool }
Settings_Values :: struct {
	display_mode, resolution_index, monitor_index: i32,
	fullscreen_index: i32, // Index into View.fullscreen_options.
	fov: f32,
	sensitivity, mouse_dpi: f32,
	ads_sensitivity: f32,
	advanced_sensitivity, invert_mouse: bool,
	audio_volumes: [4]f32,
	show_fps: bool,
	vsync: bool,
	menu_fps_limit: i32, // See MENU_FPS_LIMITS.
	bindings: Bindings,
	hud: HUD_Settings,
	visuals: Visual_Settings,
	quality: Quality_Settings,
	viewmodel: Viewmodel_Settings,
	trails: Trail_Settings,
	crosshair: Crosshair_Settings,
}
Class :: struct { id: i32, name, weapon: string, health: i32, speed: f32, wall_jump, available: bool, reason: string, used, limit: int, portrait, weapon_icon: rawptr }
Secondary :: struct { id: i32, name: string, icon: rawptr }
Player :: struct { name, class_name: string, team: i32, is_you: bool }
Team :: struct { id: i32, name: string, capacity: int, available: bool, reason: string, score: u32 }
View :: struct {
	presentation: Lobby_Presentation,
	ranked, team_selection: bool,
	browser_access_supported, auth_pending: bool,
	classes: []Class,
	selected_class: i32,
	secondaries: []Secondary,
	selected_secondary: i32,
	secondary_name, secondary_reason: string,
	secondary_pending: bool,
	live_class_changes: bool,
	respawn_remaining: f32,
	confirmed_class, confirmed_team, requested_team: i32,
	team_pending, class_pending, local_practice, has_life, connecting: bool,
	players: []Player,
	teams: [2]Team,
	play_reason, selection_status, lobby_name, match_status, current_invite: string,
	online, active, spawn_pending, ready: bool,
	map_name, mode, resolution: string,
	// Status is supplied by the client after a join attempt. The menu only
	// renders it; an empty value uses the default paste hint.
	join_status: string,
	player_count: int,
	display_mode: i32,
	resolution_index: i32,
	resolution_options: []string,
	// Exclusive fullscreen sizes for the selected monitor, largest first.
	fullscreen_index: i32,
	fullscreen_options: []string,
	monitor_index: i32,
	monitor_names: []string,
	vsync: bool,
	menu_fps_limit: i32,
	bindings: Bindings,
	hud: HUD_Settings,
	visuals: Visual_Settings,
	quality: Quality_Settings,
	viewmodel: Viewmodel_Settings,
	trails: Trail_Settings,
	crosshair: Crosshair_Settings,
	max_anisotropy: f32,
	fov: f32,
	sensitivity, mouse_dpi: f32,
	ads_sensitivity: f32,
	advanced_sensitivity, invert_mouse: bool,
	audio_volumes: [4]f32,
	show_fps: bool,
	// What Reset restores: the client's defaults for a missing settings file
	// (client_settings_defaults through client_settings_validate, plus the
	// audio defaults). Reset stays disabled while this is the zero value.
	settings_defaults: Settings_Values,
}
Input :: struct {
	pointer: clay.Vector2,
	down, tab, shift, enter, escape, left, right: bool,
	backspace, clear_text, paste: bool,
	text: string,
	scroll: clay.Vector2,
	up, down_key: bool,
	binding_pressed: i32,
}
Control :: struct { id: clay.ElementId, action: Action, enabled, slider, number: bool, slider_min, slider_max, slider_step, slider_curve: f32 }
State :: struct {
	page: Page,
	ctx: ^clay.Context,
	memory: []u8,
	// Search results can list rows from every settings tab at once.
	controls: [256]Control,
	control_count: int,
	focus, pressed: u32,
	return_focus: u32,
	loadout_parent: Page,
	loadout_return_focus: u32,
	invite_buffer: [2048]u8,
	invite_length: int,
	previous: Input,
	scale: f32,
	errors: int,
	settings_tab: Settings_Tab,
	settings_active: bool,
	scrollbar_dragging: bool,
	scrollbar_grab: f32,
	settings_draft: Settings_Values,
	settings_resolution_count, settings_fullscreen_count: i32,
	settings_resolution_selected: bool,
	binding_capture: i32, // action*2 + slot + 1; zero when not listening.
	binding_reserved: bool,
	settings_dropdown: Settings_Dropdown,
	dropdown_return_focus: u32,
	// The dropdown option last scrolled into view; 0 when the popup opens.
	dropdown_revealed_focus: u32,
	number_edit: Settings_Number,
	number_control: Control,
	number_buffer: [24]u8,
	number_length: int,
	number_replace, number_invalid, number_changed: bool,
	color_edit: i32, // 0 = none, 1 = crosshair, 2 = shadow.
	color_buffer: [16]u8,
	color_length: int,
	color_replace, color_invalid: bool,
	crosshair_preview: Crosshair_Preview,
	// Krunker's "Import Settings" popup. Krunker exports compact JSON; loadouts
	// can make it several kilobytes, so the field holds up to 64 KiB.
	import_open, import_overflow: bool,
	// Krunker's resetSettings asks confirm("settings.reset.confirm") first.
	reset_open: bool,
	settings_defaults: Settings_Values, // Copied from View every frame.
	import_buffer: [65536]u8,
	import_length: int,
	settings_message: [160]u8,
	settings_message_length: int,
	settings_message_error: bool,
	// Settings search text lasts for one visit to the menu and is never saved.
	search_buffer: [SEARCH_MAX]u8,
	search_length: int,
	// Per-frame bookkeeping while search results are laid out.
	search_tab: Settings_Tab,
	search_section: string,
	search_tab_pending, search_section_pending, search_tab_match, search_section_match, search_found: bool,
}

prepare_settings :: proc(state: ^State, view: View) {
	if state.page != .SETTINGS && state.page != .CONTROLS {
		state.settings_active = false
		state.scrollbar_dragging = false
		state.binding_capture, state.settings_dropdown = 0, .NONE
		state.number_edit = .NONE
		state.color_edit = 0
		settings_import_close(state)
		state.reset_open = false
		state.settings_message_length = 0
		state.search_length = 0
		return
	}
	state.settings_defaults = view.settings_defaults
	if !state.settings_active {
		state.settings_resolution_selected = false
		state.settings_draft = {display_mode = view.display_mode, resolution_index = view.resolution_index, fullscreen_index = view.fullscreen_index,
			fov = fov_validate(view.fov), sensitivity = view.sensitivity, mouse_dpi = mouse_dpi_validate(view.mouse_dpi), audio_volumes = view.audio_volumes, show_fps = view.show_fps,
			ads_sensitivity = ads_sensitivity_validate(view.ads_sensitivity, view.sensitivity, view.mouse_dpi), advanced_sensitivity = view.advanced_sensitivity, invert_mouse = view.invert_mouse,
			monitor_index = view.monitor_index, vsync = view.vsync, menu_fps_limit = menu_fps_limit_validate(view.menu_fps_limit), bindings = view.bindings, hud = view.hud, visuals = view.visuals, quality = view.quality,
			viewmodel = viewmodel_settings_validate(view.viewmodel), trails = view.trails, crosshair = crosshair_settings_validate(view.crosshair)}
		state.settings_active = true
	}
	state.settings_resolution_count = i32(len(view.resolution_options))
	state.settings_fullscreen_count = i32(len(view.fullscreen_options))
	if state.page == .CONTROLS { state.settings_tab = .INPUT }
}

error_handler :: proc "c" (data: clay.ErrorData) {
	context = runtime.default_context()
	state := cast(^State)data.userData
	state.errors += 1
	fmt.eprintf("[Menu] %s\n", string(data.errorText.chars[:data.errorText.length]))
}

init :: proc(state: ^State, measure: proc "c" (clay.StringSlice, ^clay.TextElementConfig, rawptr) -> clay.Dimensions, user: rawptr) -> bool {
	clay.SetMaxElementCount(2048)
	clay.SetMaxMeasureTextCacheWordCount(4096)
	state.memory = make([]u8, int(clay.MinMemorySize()))
	arena := clay.CreateArenaWithCapacityAndMemory(uint(len(state.memory)), raw_data(state.memory))
	state.ctx = clay.Initialize(arena, {1280, 720}, {handler = error_handler, userData = state})
	clay.SetMeasureTextFunction(measure, user)
	return state.ctx != nil && state.errors == 0
}

fini :: proc(state: ^State) {
	if clay.GetCurrentContext() == state.ctx { clay.SetCurrentContext(nil) }
	delete(state.memory)
	state.memory = nil
	state.ctx = nil
}

contains :: proc(box: clay.BoundingBox, point: clay.Vector2) -> bool {
	return point[0] >= box.x && point[1] >= box.y && point[0] < box.x + box.width && point[1] < box.y + box.height
}

register :: proc(state: ^State, control: Control) {
	assert(state.control_count < len(state.controls))
	state.controls[state.control_count] = control
	state.control_count += 1
}

// Resolve interactions after layout, against this frame's actual rectangles.
// Pointer press captures a control; release activates it only over that control.
interact :: proc(state: ^State, input: Input, view: View) -> Action {
	clay.SetCurrentContext(state.ctx)
	clay.SetPointerState(input.pointer, input.down)
	defer state.previous = input
	if state.color_edit != 0 && settings_color_interact(state, input) { return {} }
	if state.import_open {
		if action, handled := settings_import_interact(state, input); handled { return action }
	}
	if state.reset_open && settings_reset_interact(state, input) { return {} }
	if state.number_edit != .NONE && settings_number_interact(state, input) { return {} }
	// Capture runs before menu shortcuts: Enter, Tab, arrows and mouse buttons
	// can all be rebound without activating another control behind the listener.
	if state.binding_capture != 0 {
		code := input.binding_pressed
		if input.escape && !state.previous.escape || code == 256 { state.binding_capture, state.binding_reserved = 0, false; return {} }
		if code == 0 { return {} }
		if code == 96 { state.binding_reserved = true; return {} }
		if code == 261 { code = 0 }
		if !binding_valid(code) { return {} }
		action := Binding_Action((state.binding_capture-1)/2)
		slot := (state.binding_capture-1)%2
		state.settings_draft.bindings[action][slot] = code
		if state.settings_draft.bindings[action][1-slot] == code { state.settings_draft.bindings[action][1-slot] = 0 }
		state.binding_capture, state.binding_reserved, state.pressed = 0, false, 0
		return {}
	}
	if state.settings_dropdown != .NONE {
		if input.escape && !state.previous.escape {
			state.settings_dropdown, state.focus = .NONE, state.dropdown_return_focus
			return {}
		}
		if input.down && !state.previous.down && !clay.PointerOver(clay.ID("SettingsOptions")) {
			state.settings_dropdown, state.focus, state.pressed = .NONE, state.dropdown_return_focus, 0
			return {}
		}
	}
	if settings_scrollbar_interact(state, input) { return {} }
	focused_index := -1
	for control, i in state.controls[:state.control_count] {
		if control.id.id == state.focus && control.enabled { focused_index = i }
	}
	// With text or focus in the search field, Escape clears the search and leaves
	// the field instead of closing Settings, as Escape only closes the import popup.
	if input.escape && !state.previous.escape && (state.page == .SETTINGS || state.page == .CONTROLS) && (state.search_length > 0 || settings_search_focused(state)) {
		settings_search_clear(state)
		state.pressed = 0
		if settings_search_focused(state) { state.focus = 0 }
		return {}
	}
	if input.escape && !state.previous.escape {
		state.pressed = 0
		if state.page == .SETTINGS || state.page == .CONTROLS {
			return activate(state, {action = {kind = .SETTINGS_CANCEL}})
		}
		if state.page != .HOME {
			state.page, state.focus = back_page(state), back_focus(state)
		} else if view.active {
			return {kind = .PLAY}
		}
		return {}
	}
	if settings_search_focused(state) { settings_search_input(state, input) }
	if state.focus == clay.ID("Invite").id {
		if input.paste && !state.previous.paste { return {kind = .PASTE} }
		if input.clear_text { state.invite_length = 0 }
		if input.backspace && !state.previous.backspace && state.invite_length > 0 { state.invite_length -= 1 }
		for c in input.text {
			// Backtick remains available for the client's map rotation shortcut.
			if c >= 32 && c < 127 && c != '`' && state.invite_length < len(state.invite_buffer) {
				state.invite_buffer[state.invite_length] = u8(c); state.invite_length += 1
			}
		}
		if input.enter && !state.previous.enter { return {kind = .JOIN_LINK} }
	}
	if input.tab && !state.previous.tab || state.settings_dropdown != .NONE && (input.up && !state.previous.up || input.down_key && !state.previous.down_key) {
		step := input.shift || input.up ? -1 : 1
		if focused_index < 0 { focused_index = input.shift ? 0 : -1 }
		for _ in 0 ..< state.control_count {
			focused_index = (focused_index + step + state.control_count) % state.control_count
			if state.controls[focused_index].enabled {
				state.focus = state.controls[focused_index].id.id
				focus_visible(state.controls[focused_index], state.page)
				break
			}
		}
	}
	if input.enter && !state.previous.enter && focused_index >= 0 {
		control := state.controls[focused_index]
		if !control.slider { return activate(state, control) }
	}
	if focused_index >= 0 && state.controls[focused_index].slider {
		direction := (input.right && !state.previous.right ? 1 : 0) - (input.left && !state.previous.left ? 1 : 0)
		if direction != 0 {
			control := state.controls[focused_index]
			value := settings_slider_value(state, view, control.action)
			action := control.action
			action.value = clamp(value + f32(direction) * control.slider_step, control.slider_min, control.slider_max)
			return activate(state, {action = action})
		}
	}
	for control in state.controls[:state.control_count] {
		if !control.enabled { continue }
		data := clay.GetElementData(control.id)
		over := data.found && contains(data.boundingBox, input.pointer) && clay.PointerOver(control.id)
		if input.down && !state.previous.down && over {
			state.pressed = control.id.id
			state.focus = control.id.id
		}
		if state.pressed == control.id.id {
			if control.slider && input.down {
				progress := clamp((input.pointer[0] - data.boundingBox.x) / data.boundingBox.width, 0, 1)
				action := control.action
				action.value = slider_value_at(progress, control.slider_min, control.slider_max, control.slider_curve, control.slider_step)
				return activate(state, {action = action})
			}
			if !input.down && state.previous.down && over {
				state.pressed = 0
				if control.slider { return {} }
				return activate(state, control)
			}
		}
	}
	if !input.down { state.pressed = 0 }
	return {}
}

activate :: proc(state: ^State, control: Control) -> Action {
	if control.number {
		state.number_control = control
		settings_number_begin(state, .SLIDER)
		return {}
	}
	if control.action.kind == .CROSSHAIR_COLOR {
		settings_color_begin(state, control.action.index)
		return {}
	}
	if control.action.kind == .SETTINGS_NUMBER {
		settings_number_begin(state, Settings_Number(control.action.index))
		return {}
	}
	if control.action.kind == .BIND_KEY {
		state.binding_capture, state.binding_reserved = control.action.index+1, false
		state.pressed = 0
		return {}
	}
	if control.action.kind == .SETTINGS_DROPDOWN {
		state.settings_dropdown = Settings_Dropdown(control.action.index)
		data := clay.GetScrollContainerData(clay.ID("SettingsOptions"))
		if data.found { data.scrollPosition^ = {} }
		state.dropdown_revealed_focus = 0
		state.dropdown_return_focus = control.id.id
		index: i32
		switch state.settings_dropdown {
		case .NONE:
		case .DISPLAY_MODE: index = state.settings_draft.display_mode
		case .MONITOR: index = state.settings_draft.monitor_index
		case .RESOLUTION: index = state.settings_draft.display_mode == 2 ? state.settings_draft.fullscreen_index : state.settings_draft.resolution_index
		case .TEXTURE_FILTER: index = state.settings_draft.quality.smooth_textures ? 1 : 0
		case .LIGHTING: index = clamp(state.settings_draft.quality.lighting, 0, 3)
		case .SHADOW_QUALITY: index = clamp(state.settings_draft.quality.shadow_quality, 0, 1)
		case .CROSSHAIR_TYPE: index = 0
		case .ANISOTROPY:
			for value, i in ([5]i32{0, 2, 4, 8, 16}) { if value == state.settings_draft.quality.anisotropy { index = i32(i) } }
		case .MENU_FPS_LIMIT: index = menu_fps_limit_index(state.settings_draft.menu_fps_limit)
		}
		state.focus = clay.ID("SettingsOption", u32(index)).id
		return {}
	}
	if control.action.kind == .SETTINGS_IMPORT_OPEN {
		state.import_open, state.import_length, state.import_overflow = true, 0, false
		state.settings_message_length, state.pressed = 0, 0
		state.focus = clay.ID("ImportConfirm").id
		return {}
	}
	if control.action.kind == .SETTINGS_RESET_OPEN {
		if !settings_reset_available(state) { return {} }
		state.reset_open, state.pressed, state.settings_message_length = true, 0, 0
		state.binding_capture, state.binding_reserved, state.settings_dropdown = 0, false, .NONE
		state.focus = clay.ID("ResetConfirm").id
		return {}
	}
	if control.action.kind == .SETTINGS_RESET_CLOSE {
		state.reset_open, state.pressed, state.focus = false, 0, clay.ID("SettingsReset").id
		return {}
	}
	if control.action.kind == .SETTINGS_RESET {
		state.reset_open, state.pressed, state.focus = false, 0, clay.ID("SettingsReset").id
		if !settings_reset_available(state) { return {} }
		if control.action.index == 1 {
			settings_reset_tab(&state.settings_draft, state.settings_defaults, state.settings_tab)
			settings_set_message(state, fmt.tprintf("%s reset to defaults. Save keeps them; Cancel restores your settings.", SETTINGS_TABS[state.settings_tab]), false)
		} else {
			state.settings_draft = state.settings_defaults
			settings_set_message(state, "All settings reset to defaults. Save keeps them; Cancel restores your settings.", false)
		}
		return {}
	}
	if control.action.kind == .SETTINGS_IMPORT {
		state.pressed = 0
		if state.import_overflow { settings_set_message(state, "Settings text is too long.", true); return {} }
		result, error := krunker_settings_import(&state.settings_draft, string(state.import_buffer[:state.import_length]))
		if len(error) > 0 { settings_set_message(state, error, true); return {} }
		settings_import_close(state)
		state.focus = clay.ID("SettingsImport").id
		settings_set_message(state, fmt.tprintf("Imported %d Krunker settings. Ignored %d unsupported.", result.imported, result.ignored), false)
		return {kind = .SETTINGS_IMPORT} // The client applies and saves the draft, as Save does.
	}
	if control.action.kind == .SETTINGS_SEARCH {
		state.pressed = 0
		return {} // Clicking the field focuses it; typing is handled in interact.
	}
	if control.action.kind == .SETTINGS_TAB {
		state.search_length = 0 // Krunker's changeTab clears the search field.
		state.settings_tab = Settings_Tab(control.action.index)
		state.scrollbar_dragging = false
		state.page = .SETTINGS
		state.pressed = 0
		data := clay.GetScrollContainerData(clay.ID("SettingsPanel"))
		if data.found { data.scrollPosition^ = {} }
		return {}
	}
	if control.action.kind == .SETTINGS_SAVE || control.action.kind == .SETTINGS_CANCEL {
		state.page, state.focus, state.pressed = .HOME, state.return_focus, 0
		state.settings_active = false
		state.scrollbar_dragging = false
		state.binding_capture, state.settings_dropdown = 0, .NONE
		state.number_edit = .NONE
		state.color_edit, state.color_invalid = 0, false
		state.binding_reserved = false
		settings_import_close(state)
		state.reset_open = false
		state.settings_message_length = 0
		state.search_length = 0
		return control.action if control.action.kind == .SETTINGS_SAVE else Action{}
	}
	if state.settings_active {
		if state.settings_dropdown != .NONE {
			state.settings_dropdown, state.focus = .NONE, state.dropdown_return_focus
		}
		#partial switch control.action.kind {
		case .DISPLAY_MODE: state.settings_draft.display_mode = control.action.index; return {}
		case .VISUAL_VALUE:
			if control.action.index >= 0 && control.action.index < i32(Visual_Control.FOG_DISTANCE) {
				state.settings_draft.visuals.values[Visual_Control(control.action.index)] = control.action.value
			}
			return {}
		case .VISUAL_TOGGLE:
			switch control.action.index {
			case 0: state.settings_draft.visuals.hide_cats = !state.settings_draft.visuals.hide_cats
			case 1: state.settings_draft.visuals.hide_extra_props = !state.settings_draft.visuals.hide_extra_props
			case 2: state.settings_draft.visuals.night_mode = !state.settings_draft.visuals.night_mode
			}
			return {}
		case .NIGHT_STRENGTH:
			if value := control.action.value; value == value { state.settings_draft.visuals.night_strength = clamp(value, 0, 1) } // Skips NaN.
			return {}
		case .VISUAL_RESET:
			state.settings_draft.visuals = DEFAULT_VISUAL_SETTINGS
			return {}
		case .TEXTURE_FILTER: state.settings_draft.quality.smooth_textures = control.action.index == 1; return {}
		case .ANISOTROPY: state.settings_draft.quality.anisotropy = ANISOTROPY_LEVELS[clamp(control.action.index, 0, 4)]; return {}
		case .LIGHTING: state.settings_draft.quality.lighting = clamp(control.action.index, 0, 3); return {}
		case .SHADOW_QUALITY: state.settings_draft.quality.shadow_quality = clamp(control.action.index, 0, 1); return {}
		case .QUALITY_TOGGLE:
			quality := &state.settings_draft.quality
			switch Quality_Toggle(control.action.index) {
			case .SHADOWS: quality.shadows = !quality.shadows
			case .SOFT_SHADOWS: quality.soft_shadows = !quality.soft_shadows
			case .HIGH_RES_SHADOWS: quality.high_res_shadows = !quality.high_res_shadows
			case .DYNAMIC_SHADOWS: quality.dynamic_shadows = !quality.dynamic_shadows
			case .SELF_SHADOW: quality.self_shadow = !quality.self_shadow
			}
			return {}
		case .MONITOR: state.settings_draft.monitor_index = control.action.index; return {}
		case .RESOLUTION_SELECT:
			if state.settings_draft.display_mode == 2 {
				state.settings_draft.fullscreen_index = control.action.index
			} else {
				state.settings_draft.resolution_index = control.action.index
			}
			state.settings_resolution_selected = true
			return {}
		case .VSYNC: state.settings_draft.vsync = !state.settings_draft.vsync; return {}
		case .MENU_FPS_LIMIT: state.settings_draft.menu_fps_limit = MENU_FPS_LIMITS[clamp(control.action.index, 0, len(MENU_FPS_LIMITS)-1)]; return {}
		case .HUD_TOGGLE:
			switch control.action.index {
			case 0: state.settings_draft.hud.hide_timer = !state.settings_draft.hud.hide_timer
			case 1: state.settings_draft.hud.hide_round_score = !state.settings_draft.hud.hide_round_score
			case 2: state.settings_draft.hud.hide_game_score = !state.settings_draft.hud.hide_game_score
			case 3: state.settings_draft.hud.hide_ping = !state.settings_draft.hud.hide_ping
			case 4: state.settings_draft.hud.hide_nametags = !state.settings_draft.hud.hide_nametags
			case 5: state.settings_draft.hud.hide_healthbars = !state.settings_draft.hud.hide_healthbars
			}
			return {}
		case .RESOLUTION:
			fullscreen := state.settings_draft.display_mode == 2
			count := fullscreen ? state.settings_fullscreen_count : state.settings_resolution_count
			index := fullscreen ? &state.settings_draft.fullscreen_index : &state.settings_draft.resolution_index
			if count > 0 {
				index^ = (index^ + control.action.index + count) % count
				state.settings_resolution_selected = true
			}
			return {}
		case .SENSITIVITY: state.settings_draft.sensitivity = control.action.value; return {}
		case .ADVANCED_SENSITIVITY: state.settings_draft.advanced_sensitivity = !state.settings_draft.advanced_sensitivity; return {}
		case .INVERT_MOUSE: state.settings_draft.invert_mouse = !state.settings_draft.invert_mouse; return {}
		case .FOV: state.settings_draft.fov = fov_validate(control.action.value); return {}
		case .VIEWMODEL_VALUE:
			if control.action.index >= 0 && control.action.index < i32(len(Viewmodel_Control)) {
				state.settings_draft.viewmodel.values[Viewmodel_Control(control.action.index)] = control.action.value
				state.settings_draft.viewmodel = viewmodel_settings_validate(state.settings_draft.viewmodel)
			}
			return {}
		case .VIEWMODEL_TOGGLE:
			if control.action.index >= 0 && control.action.index < i32(len(Viewmodel_Toggle)) {
				toggle := Viewmodel_Toggle(control.action.index)
				state.settings_draft.viewmodel.toggles[toggle] = !state.settings_draft.viewmodel.toggles[toggle]
			}
			return {}
		case .TRAILS_TOGGLE:
			if control.action.index == 0 { state.settings_draft.trails.hide_others = !state.settings_draft.trails.hide_others }
			if control.action.index == 1 { state.settings_draft.trails.hide_yours = !state.settings_draft.trails.hide_yours }
			return {}
		case .CROSSHAIR_TYPE: state.settings_draft.crosshair.kind = .PRECISION; return {}
		case .CROSSHAIR_VALUE:
			if control.action.index >= 0 && control.action.index < i32(len(Crosshair_Control)) {
				state.settings_draft.crosshair.values[Crosshair_Control(control.action.index)] = control.action.value
				state.settings_draft.crosshair = crosshair_settings_validate(state.settings_draft.crosshair)
			}
			return {}
		case .CROSSHAIR_TOGGLE:
			if control.action.index >= 0 && control.action.index < i32(len(Crosshair_Toggle)) {
				toggle := Crosshair_Toggle(control.action.index)
				state.settings_draft.crosshair.toggles[toggle] = !state.settings_draft.crosshair.toggles[toggle]
			}
			return {}
		case .AUDIO_VOLUME: state.settings_draft.audio_volumes[control.action.index] = control.action.value; return {}
		case .FPS: state.settings_draft.show_fps = !state.settings_draft.show_fps; return {}
		}
	}
	if control.action.kind == .INSPECT_CLASS || control.action.kind == .EDIT_INVITE { return {} }
	// Navigation changes the menu page without dispatching a gameplay action.
	if control.action.kind == .NONE {
		previous_page := state.page
		if state.page == .HOME { state.return_focus = control.id.id }
		state.page = Page(control.action.index)
		state.focus = state.page == .HOME ? state.return_focus : previous_page == .LOADOUT && state.page == state.loadout_parent ? state.loadout_return_focus : 0
		return {}
	}
	return control.action
}

back_page :: proc(state: ^State) -> Page {
	if state.page == .LOADOUT { return state.loadout_parent }
	if state.page == .CONTROLS { return .SETTINGS }
	return .HOME
}

back_focus :: proc(state: ^State) -> u32 {
	return state.page == .LOADOUT ? state.loadout_return_focus : state.return_focus
}

focus_visible :: proc(control: Control, page: Page) {
	container: string
	if control.action.kind == .SELECT_CLASS || control.action.kind == .INSPECT_CLASS {
		if page == .HOME { container = "ClassStrip" }
		if page == .CLASSES { container = "ClassPicker" }
	}
	if (page == .SETTINGS || page == .CONTROLS) && (control.slider || control.number || control.action.kind == .SETTINGS_DROPDOWN || control.action.kind == .SETTINGS_NUMBER || control.action.kind == .BIND_KEY || control.action.kind == .HUD_TOGGLE || control.action.kind == .VSYNC || control.action.kind == .FPS || control.action.kind == .VISUAL_RESET || control.action.kind == .VISUAL_TOGGLE || control.action.kind == .QUALITY_TOGGLE || control.action.kind == .ADVANCED_SENSITIVITY || control.action.kind == .INVERT_MOUSE || control.action.kind == .VIEWMODEL_TOGGLE || control.action.kind == .TRAILS_TOGGLE || control.action.kind == .CROSSHAIR_TOGGLE || control.action.kind == .CROSSHAIR_COLOR) { container = "SettingsPanel" }
	if control.action.kind == .DISPLAY_MODE || control.action.kind == .MONITOR || control.action.kind == .RESOLUTION_SELECT || control.action.kind == .TEXTURE_FILTER || control.action.kind == .ANISOTROPY || control.action.kind == .MENU_FPS_LIMIT || control.action.kind == .LIGHTING || control.action.kind == .SHADOW_QUALITY { container = "SettingsOptions" }
	if control.action.kind == .SELECT_SECONDARY { container = "SecondaryPicker" }
	if len(container) == 0 { return }
	data := clay.GetScrollContainerData(clay.ID(container))
	if !data.found { return }
	parent := clay.GetElementData(clay.ID(container)).boundingBox
	box := clay.GetElementData(control.id).boundingBox
	if container == "ClassStrip" {
		offset: f32
		if box.x < parent.x { offset = parent.x - box.x }
		if box.x + box.width > parent.x + parent.width { offset = parent.x + parent.width - box.x - box.width }
		data.scrollPosition[0] = clamp(data.scrollPosition[0] + offset, min(0, data.scrollContainerDimensions.width - data.contentDimensions.width), 0)
		return
	}
	offset: f32
	if box.y < parent.y { offset = parent.y - box.y }
	if box.y + box.height > parent.y + parent.height { offset = parent.y + parent.height - box.y - box.height }
	data.scrollPosition[1] = clamp(data.scrollPosition[1] + offset, min(0, data.scrollContainerDimensions.height - data.contentDimensions.height), 0)
}

invite :: proc(state: ^State) -> string { return string(state.invite_buffer[:state.invite_length]) }
set_invite :: proc(state: ^State, value: string) {
	state.invite_length = min(len(value), len(state.invite_buffer))
	copy(state.invite_buffer[:state.invite_length], transmute([]u8)value[:state.invite_length])
}
