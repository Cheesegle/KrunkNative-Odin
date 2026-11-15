package menu

import "core:math"

// Krunker's "Hitmarker" category (Settings > Display; krunkbox
// current.analysis.js settings list near line 252728, keys hitm, hitmCol,
// hitmKCol, hitOpac, hitmLen, hitmThick, hitmSpac, hitmAnimD, hitmFad).
// Krunker's own marker only changes for kills (Kill Color and 1.2x length);
// headshots differ only by sound there. Headshot color is Krodin's own and
// defaults to the normal color, so the default look matches Krunker.
// Krunker also lists "Anim Speed" (hitmAnimS), but its value only feeds a
// field the renderer never reads, so Krodin leaves it out.
Hitmarker_Control :: enum { OPACITY, LENGTH, THICKNESS, SPACING, ANIM_SIZE, FADE }
Hitmarker_Color :: enum { NORMAL, KILL, HEADSHOT }
Hitmarker_Settings :: struct {
	show: bool,
	values: [Hitmarker_Control]f32,
	colors: [Hitmarker_Color]u32,
}
DEFAULT_HITMARKER_SETTINGS :: Hitmarker_Settings{
	show = true,
	values = {.OPACITY=1, .LENGTH=25, .THICKNESS=7, .SPACING=37, .ANIM_SIZE=0.14, .FADE=0.0062},
	colors = {.NORMAL=0xffffff, .KILL=0xff0000, .HEADSHOT=0xffffff},
}
HITMARKER_LIMITS := [Hitmarker_Control][2]f32{.OPACITY={0,1}, .LENGTH={1,50}, .THICKNESS={1,20}, .SPACING={5,60}, .ANIM_SIZE={0.1,0.5}, .FADE={0.0001,0.01}}
HITMARKER_STEPS := [Hitmarker_Control]f32{.OPACITY=0.1, .LENGTH=1, .THICKNESS=1, .SPACING=1, .ANIM_SIZE=0.01, .FADE=0.0001}
HITMARKER_LABELS := [Hitmarker_Control]string{.OPACITY="Hitmarker opacity", .LENGTH="Hitmarker length", .THICKNESS="Hitmarker thickness", .SPACING="Hitmarker spacing", .ANIM_SIZE="Hitmarker anim size", .FADE="Hitmarker fade speed"}
HITMARKER_IDS := [Hitmarker_Control]string{.OPACITY="HitmarkerOpacity", .LENGTH="HitmarkerLength", .THICKNESS="HitmarkerThickness", .SPACING="HitmarkerSpacing", .ANIM_SIZE="HitmarkerAnimSize", .FADE="HitmarkerFade"}
HITMARKER_COLOR_LABELS := [Hitmarker_Color]string{.NORMAL="Hitmarker color", .KILL="Hitmarker kill color", .HEADSHOT="Hitmarker headshot color"}
// Color edit fields after the crosshair's 1 (color) and 2 (shadow).
HITMARKER_COLOR_FIELDS := [Hitmarker_Color]i32{.NORMAL=3, .KILL=4, .HEADSHOT=5}

hitmarker_settings_validate :: proc(settings: Hitmarker_Settings) -> Hitmarker_Settings {
	// A zero value predates these settings: every size is at least 1.
	if settings == (Hitmarker_Settings{}) { return DEFAULT_HITMARKER_SETTINGS }
	result := settings
	defaults := DEFAULT_HITMARKER_SETTINGS
	for control in Hitmarker_Control {
		value := result.values[control]
		if math.is_nan(value) || math.is_inf(value) { value = defaults.values[control] }
		result.values[control] = clamp(value, HITMARKER_LIMITS[control][0], HITMARKER_LIMITS[control][1])
	}
	for &color in result.colors { color &= 0xffffff }
	return result
}

// How long a marker stays visible at these settings, in seconds.
hitmarker_duration :: proc(settings: Hitmarker_Settings) -> f32 {
	return settings.values[.OPACITY] / settings.values[.FADE] / 1000
}

settings_hitmarker :: proc(state: ^State) {
	settings_section(state, "Hitmarker")
	values := state.settings_draft.hitmarker
	// Krunker: "Show", "Display indicator when hit lands".
	settings_toggle_row(state, "Show hitmarkers", "HitmarkerShow", values.show, {kind=.HITMARKER_TOGGLE})
	for color in Hitmarker_Color { settings_crosshair_color(state, HITMARKER_COLOR_LABELS[color], HITMARKER_COLOR_FIELDS[color]) }
	for control in Hitmarker_Control {
		settings_slider(state, HITMARKER_LABELS[control], HITMARKER_IDS[control], values.values[control], HITMARKER_LIMITS[control][0], HITMARKER_LIMITS[control][1], {kind=.HITMARKER_VALUE, index=i32(control)}, step=HITMARKER_STEPS[control])
	}
	settings_note(state, "A hitmarker appears on every server-confirmed hit and grows by Anim size while it fades by Fade speed each millisecond (defaults last about 0.16 s). Kills use the kill color at 1.2x length. Headshot color is Krodin's own; Krunker marks headshots only by sound.")
}
