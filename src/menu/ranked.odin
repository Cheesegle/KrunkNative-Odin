package menu

import "core:fmt"
import clay "../third_party/clay"

// Krunker's ranked queue (game.min.js, class DLe "dx" and the ranked menu
// component DXe). Krunker queues a fixed map list, preferredMaps
// [0,2,4,11,14,17,42], in either the player's region (C2().regionAcronym,
// "eu" when unset) or, with "All regions" (s_rankedAllRegions), every key of
// {as, eu, na}. Krodin picks one of these in a dropdown; choosing maps is
// Krodin's own.
RANKED_MAPS := [?]i32{0, 2, 4, 11, 14, 17, 42}
RANKED_MAP_NAMES := [?]string{"Burg", "Sandstorm", "Undergrowth", "Industry", "Site", "Bureau", "Frontier"}
RANKED_REGIONS := [?]string{"as", "eu", "na"}
RANKED_DEFAULT_REGION :: 1 // Krunker's C2() falls back to "eu".
// Region dropdown entries: one region (RANKED_REGIONS order) or all of them.
RANKED_REGION_CHOICES := [?]string{"Asia", "Europe", "North America", "All regions"}
RANKED_ALL_REGIONS_CHOICE :: 3

// Stored in client-settings.json. Zero values (older files) mean Krunker's
// defaults: the default region and every ranked map.
Ranked_Preferences :: struct {
	region_mask: u32, // One bit, RANKED_REGIONS[i]; 0 is the default region.
	all_regions: bool, // Krunker's "All regions" (s_rankedAllRegions, default false).
	excluded_maps: u32, // Bit i leaves RANKED_MAPS[i] out of the queue.
}

// The dropdown entry: 0-2 one region, RANKED_ALL_REGIONS_CHOICE all of them.
// Older saves could tick several regions; those queue all regions.
ranked_region_choice :: proc(prefs: Ranked_Preferences) -> i32 {
	mask := prefs.region_mask & (1 << len(RANKED_REGIONS) - 1)
	if prefs.all_regions || mask & (mask - 1) != 0 { return RANKED_ALL_REGIONS_CHOICE }
	for i in 0 ..< len(RANKED_REGIONS) { if mask == 1 << u32(i) { return i32(i) } }
	return RANKED_DEFAULT_REGION
}

ranked_set_region :: proc(prefs: ^Ranked_Preferences, choice: i32) {
	if choice < 0 || choice > RANKED_ALL_REGIONS_CHOICE { return }
	if choice == RANKED_ALL_REGIONS_CHOICE { prefs.region_mask, prefs.all_regions = 0, true }
	else { prefs.region_mask, prefs.all_regions = 1 << u32(choice), false }
}

ranked_map_mask :: proc(prefs: Ranked_Preferences) -> u32 {
	all := u32(1 << len(RANKED_MAPS) - 1)
	mask := all &~ prefs.excluded_maps
	return mask == 0 ? all : mask
}

ranked_preferences_validate :: proc(prefs: Ranked_Preferences) -> Ranked_Preferences {
	all := u32(1 << len(RANKED_MAPS) - 1)
	excluded := prefs.excluded_maps & all
	if excluded == all { excluded = 0 }
	result := Ranked_Preferences{excluded_maps = excluded}
	// An unset region stays 0 (the default, Europe) so older files round-trip.
	if prefs.all_regions || prefs.region_mask & (1 << len(RANKED_REGIONS) - 1) != 0 { ranked_set_region(&result, ranked_region_choice(prefs)) }
	return result
}

// Toggles a map; the last selected one stays selected, as the queue needs one.

ranked_toggle_map :: proc(prefs: ^Ranked_Preferences, index: i32) {
	if index < 0 || int(index) >= len(RANKED_MAPS) { return }
	excluded := prefs.excluded_maps ~ (1 << u32(index))
	if excluded & u32(1 << len(RANKED_MAPS) - 1) != u32(1 << len(RANKED_MAPS) - 1) { prefs.excluded_maps = excluded }
}

// Krunker's qs states, plus CONNECTING for the "LOADING..." button while the
// socket opens and the server has not answered QUEUED yet.
Ranked_Phase :: enum { IDLE, CONNECTING, SEARCHING, FOUND }
Ranked_Tone :: enum { INFO, WARNING, ERROR }

Ranked_View :: struct {
	logged_in, login_pending, login_supported: bool,
	checking: bool, // Krunker's fetchIsPlayerInRankedMatch on opening the menu.
	phase: Ranked_Phase,
	elapsed: int, // Seconds in queue.
	rejoin: bool, // Already in a ranked match: the button reads REJOIN.
	status: string,
	tone: Ranked_Tone,
	popup_title, popup_text: string,
	prefs: Ranked_Preferences,
}

// Krunker's formatTime: m:ss.
ranked_format_time :: proc(seconds: int) -> string {
	value := max(seconds, 0)
	return fmt.tprintf("%d:%02d", value / 60, value % 60)
}

// Krunker's rankedMatchMakingStatus line (updateGlobalStatus), which stays
// visible outside the ranked menu while a queue runs.
ranked_global_status :: proc(view: Ranked_View) -> string {
	switch view.phase {
	case .IDLE, .CONNECTING: return ""
	case .SEARCHING: return fmt.tprintf("Searching for match... (%s)", ranked_format_time(view.elapsed))
	case .FOUND: return "Match found!"
	}
	return ""
}

// Krunker's footer button text.
ranked_button_label :: proc(view: Ranked_View) -> string {
	if view.checking || view.phase == .CONNECTING { return "LOADING..." }
	if view.rejoin { return "REJOIN" }
	#partial switch view.phase {
	case .SEARCHING: return "CANCEL"
	case .FOUND: return "MATCH FOUND"
	}
	return "FIND MATCH"
}

ranked_region_label :: proc(prefs: Ranked_Preferences) -> string {
	return fmt.tprintf("Region: %s", RANKED_REGION_CHOICES[ranked_region_choice(prefs)])
}

RANKED_TONE_COLORS := [Ranked_Tone]clay.Color{.INFO = {92, 224, 90, 255}, .WARNING = {255, 204, 51, 255}, .ERROR = {255, 57, 57, 255}}

ranked_page :: proc(state: ^State, view: View) {
	s := state.scale
	ranked := view.ranked_queue
	if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}, childGap = u16(16*s), childAlignment = {y = .Center}}}) {
		text("Ranked", 32, s)
		spacer()
		text(ranked_region_label(ranked.prefs), 18, s, MUTED)
	}
	if !ranked.logged_in {
		if clay.UI(clay.ID("RankedLogin"))({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(u16(24*s)), childGap = u16(16*s)}, backgroundColor = PANEL, cornerRadius = clay.CornerRadiusAll(4*s)}) {
			text("Log in to play ranked", 26, s)
			text("You must be logged in to access Ranked Mode. Guest access cannot queue.", 18, s, MUTED)
			if ranked.login_supported {
				if clay.UI()({layout = {sizing = {width = clay.SizingFixed(240*s)}}}) {
					button(state, ranked.login_pending ? "Logging in..." : "Login", "RankedLoginButton", {kind = .LOGIN}, primary = true, enabled = !ranked.login_pending && !view.connecting)
				}
			} else {
				text("Set KRUNKER_ACCESS_TOKEN to an account token, then reopen Ranked.", 16, s, MUTED)
			}
			if len(view.join_status) > 0 { text(view.join_status, 16, s, MUTED) }
		}
		spacer()
		return
	}
	idle := ranked.phase == .IDLE && !ranked.checking
	choice := ranked_region_choice(ranked.prefs)
	state.ranked_region = choice
	// Locked while queued, like the map choices.
	if !idle && state.settings_dropdown == .RANKED_REGION { state.settings_dropdown = .NONE }
	if clay.UI(clay.ID("RankedRegionRow"))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(52*s)}, childGap = u16(16*s), childAlignment = {y = .Center}}}) {
		text("Region", 20, s, MUTED)
		spacer()
		settings_dropdown_field(state, RANKED_REGION_CHOICES[choice], "RankedRegion", .RANKED_REGION, enabled = idle)
	}
	text("Maps (Krodin extra: Krunker always queues all seven)", 20, s, MUTED)
	if clay.UI(clay.ID("RankedMaps"))({layout = {sizing = {width = clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = u16(12*s)}}) {
		mask := ranked_map_mask(ranked.prefs)
		for start := 0; start < len(RANKED_MAPS); start += 4 {
			if clay.UI()({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(52*s)}, childGap = u16(12*s)}}) {
				for i in start ..< min(start+4, len(RANKED_MAPS)) {
					on := mask & (1 << u32(i)) != 0
					button(state, fmt.tprintf("%s %s", on ? "[x]" : "[ ]", RANKED_MAP_NAMES[i]), "RankedMap", {kind = .RANKED_MAP, index = i32(i)}, selected = on, enabled = idle)
				}
				if start+4 > len(RANKED_MAPS) { spacer() }
			}
		}
	}
	spacer()
	if clay.UI(clay.ID("RankedFooter"))({layout = {sizing = {width = clay.SizingGrow(), height = clay.SizingFixed(64*s)}, padding = clay.PaddingAll(u16(8*s)), childGap = u16(16*s), childAlignment = {y = .Center}}, backgroundColor = PANEL, cornerRadius = clay.CornerRadiusAll(4*s)}) {
		if clay.UI(clay.ID("RankedStatus"))({layout = {sizing = {width = clay.SizingGrow()}, childAlignment = {y = .Center}}}) {
			text(ranked.status, 20, s, RANKED_TONE_COLORS[ranked.tone])
		}
		if clay.UI()({layout = {sizing = {width = clay.SizingFixed(240*s)}}}) {
			busy := ranked.checking || ranked.phase == .CONNECTING || ranked.phase == .FOUND
			button(state, ranked_button_label(ranked), "RankedQueue", {kind = .RANKED_QUEUE}, primary = true, enabled = !busy && len(ranked.popup_title) == 0)
		}
	}
	if len(ranked.popup_title) > 0 {
		// Krunker's modal: only OK can be used while it shows.
		if state.settings_dropdown == .RANKED_REGION { state.settings_dropdown = .NONE }
		state.control_count = 0
		if clay.UI(clay.ID("RankedPopup"))({layout = {sizing = {width = clay.SizingFixed(520*s)}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(u16(28*s)), childGap = u16(16*s), childAlignment = {x = .Center}}, backgroundColor = {28, 32, 39, 255}, cornerRadius = clay.CornerRadiusAll(6*s), border = {color = RANKED_TONE_COLORS[ranked.tone], width = clay.BorderOutside(2)}, floating = {attachTo = .ElementWithId, parentId = clay.ID("Overlay").id, zIndex = 20, attachment = {element = .CenterCenter, parent = .CenterCenter}}}) {
			text(ranked.popup_title, 28, s)
			text(ranked.popup_text, 18, s, MUTED)
			if clay.UI()({layout = {sizing = {width = clay.SizingFixed(200*s)}}}) {
				button(state, "OK", "RankedPopupOk", {kind = .RANKED_POPUP_CLOSE}, primary = true)
			}
		}
	}
	// The Settings dropdown popup, floating above the map choices.
	if state.settings_dropdown == .RANKED_REGION { settings_dropdown_menu(state, view) }
}
