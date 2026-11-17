package menu

import "core:math"
import clay "../third_party/clay"

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
	// Spectator_On_Death: whom to watch once the followed player dies.
	// Replaces the earlier no_follow_killer toggle (migrated on load).
	on_death: i32,
}

// RANDOM: another living player, picked at random (the default).
// KILLER: the player who killed them (else a random one). STAY: keep
// watching them, and switch only once they are gone from the lobby.
Spectator_On_Death :: enum i32 { RANDOM, KILLER, STAY }
SPECTATOR_ON_DEATH_LABELS := [Spectator_On_Death]string{.RANDOM = "Random player", .KILLER = "Killer", .STAY = "Stay on them"}

DEFAULT_SPECTATOR_SMOOTHING :: f32(0.5)
DEFAULT_SPECTATOR_SETTINGS :: Spectator_Settings{smoothing = DEFAULT_SPECTATOR_SMOOTHING, on_death = i32(Spectator_On_Death.RANDOM)}

Spectator_Toggle :: enum i32 { VIEWMODEL }

spectator_settings_validate :: proc(settings: Spectator_Settings) -> Spectator_Settings {
	result := settings
	if math.is_nan(result.smoothing) || math.is_inf(result.smoothing) { result.smoothing = DEFAULT_SPECTATOR_SMOOTHING }
	result.smoothing = clamp(result.smoothing, 0, 1)
	if result.on_death < 0 || result.on_death > i32(max(Spectator_On_Death)) { result.on_death = DEFAULT_SPECTATOR_SETTINGS.on_death }
	return result
}

settings_spectator :: proc(state: ^State) {
	when KRODIN_SPECTATOR {
		values := state.settings_draft.spectator
		settings_section(state, "Spectator")
		settings_slider(state, "Spectator smoothing", "SpectatorSmoothing", values.smoothing, 0, 1, {kind = .SPECTATOR_SMOOTHING})
		settings_toggle_row(state, "Spectator viewmodel", "SpectatorViewmodel", !values.hide_viewmodel, {kind = .SPECTATOR_TOGGLE, index = i32(Spectator_Toggle.VIEWMODEL)})
		if settings_search_show(state, "On death") {
			if clay.UI(clay.ID("SpectatorOnDeathRow"))(settings_row(state)) {
				settings_label("On death", state.scale)
				spacer()
				on_death := Spectator_On_Death(clamp(values.on_death, 0, i32(max(Spectator_On_Death))))
				settings_dropdown_field(state, SPECTATOR_ON_DEATH_LABELS[on_death], "SpectatorOnDeath", .SPECTATOR_ON_DEATH)
			}
		}
		settings_note(state, "Krodin's own spectator options. Smoothing (default 50%) filters the followed player's view between Krunker's 10 Hz snapshots and whole-degree angles; 0% is Krunker's raw view. Spectator viewmodel draws their weapon in first person. On death picks whom to watch about a second after the followed player dies: a random living player (default), their killer, or stay on them.")
	}
}
