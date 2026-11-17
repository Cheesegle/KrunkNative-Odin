package menu

import "core:math"

// The spectator build (-define:KRODIN_SPECTATOR=true, bin\krodin_spectator.exe);
// must match the client's flag. Only that build shows the Spectator rows.
KRODIN_SPECTATOR :: #config(KRODIN_SPECTATOR, false)

// Krodin's own spectator preferences (Krunker has no equivalent settings).
Spectator_Settings :: struct {
	// View filter strength for the followed player, 0 (Krunker's raw linear
	// view) to 1. Saved as given; 0.5 is the default.
	smoothing: f32,
	// Draw the followed player's weapon in first person (Krunker shows none).
	hide_viewmodel: bool,
	// Switch to the player who killed the one you follow.
	no_follow_killer: bool,
}

DEFAULT_SPECTATOR_SMOOTHING :: f32(0.5)
DEFAULT_SPECTATOR_SETTINGS :: Spectator_Settings{smoothing = DEFAULT_SPECTATOR_SMOOTHING}

Spectator_Toggle :: enum i32 { VIEWMODEL, FOLLOW_KILLER }

spectator_settings_validate :: proc(settings: Spectator_Settings) -> Spectator_Settings {
	result := settings
	if math.is_nan(result.smoothing) || math.is_inf(result.smoothing) { result.smoothing = DEFAULT_SPECTATOR_SMOOTHING }
	result.smoothing = clamp(result.smoothing, 0, 1)
	return result
}

settings_spectator :: proc(state: ^State) {
	when KRODIN_SPECTATOR {
		values := state.settings_draft.spectator
		settings_section(state, "Spectator")
		settings_slider(state, "Spectator smoothing", "SpectatorSmoothing", values.smoothing, 0, 1, {kind = .SPECTATOR_SMOOTHING})
		settings_toggle_row(state, "Spectator viewmodel", "SpectatorViewmodel", !values.hide_viewmodel, {kind = .SPECTATOR_TOGGLE, index = i32(Spectator_Toggle.VIEWMODEL)})
		settings_toggle_row(state, "Follow the killer", "SpectatorFollowKiller", !values.no_follow_killer, {kind = .SPECTATOR_TOGGLE, index = i32(Spectator_Toggle.FOLLOW_KILLER)})
		settings_note(state, "Krodin's own spectator options. Smoothing (default 50%) filters the followed player's view between Krunker's 10 Hz snapshots and whole-degree angles; 0% is Krunker's raw view. Spectator viewmodel draws their weapon in first person. Follow the killer switches to whoever kills the player you follow.")
	}
}
