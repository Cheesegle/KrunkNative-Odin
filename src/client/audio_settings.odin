package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import menuui "../menu"

// HRTF: binaural (headphones), the panning model Krunker uses (Howler's
// PannerNode default, panningModel 'HRTF'). Stereo: WebAudio equal-power
// panning. Surround: pairwise constant-power panning over a 5.1 / 7.1 device,
// falling back to Stereo on a stereo device.
Spatial_Mode :: enum u8 { HRTF, STEREO, SURROUND }

// Krunker: the inverse model Krunker uses (refDistance 25, rolloff 1).
// Reduced: same curve with rolloff 1/3, so distant sounds stay louder.
// Off: no distance attenuation; range culls still apply.
Distance_Falloff :: enum u8 { KRUNKER, REDUCED, OFF }

Audio_Settings :: struct {
	master, effects, footsteps, ui: f32,
	// Krunker's "Weapon Volume" (gunsVolume): default 0.3, range 0..1.
	weapons: f32,
	spatial: Spatial_Mode,
	falloff: Distance_Falloff,
	// Loudness levelling: a compressor and limiter on the effects bus.
	levelling: bool,
	levelling_strength: f32,
}
DEFAULT_LEVELLING_STRENGTH :: 0.5
KRUNKER_WEAPON_VOLUME :: 0.3
DEFAULT_AUDIO_SETTINGS :: Audio_Settings{
	master = 0.8, effects = 1, footsteps = 0.8, ui = 0.6, weapons = KRUNKER_WEAPON_VOLUME,
	spatial = .HRTF, falloff = .KRUNKER, levelling = false, levelling_strength = DEFAULT_LEVELLING_STRENGTH,
}
AUDIO_SETTINGS_PATH :: "audio-settings.json"

audio_settings_clamp :: proc(settings: Audio_Settings) -> Audio_Settings {
	result := settings
	result.master, result.effects = clamp(settings.master, 0, 1), clamp(settings.effects, 0, 1)
	result.footsteps, result.ui = clamp(settings.footsteps, 0, 1), clamp(settings.ui, 0, 1)
	result.weapons = settings.weapons == settings.weapons ? clamp(settings.weapons, 0, 1) : KRUNKER_WEAPON_VOLUME
	if result.spatial < min(Spatial_Mode) || result.spatial > max(Spatial_Mode) { result.spatial = DEFAULT_AUDIO_SETTINGS.spatial }
	if result.falloff < min(Distance_Falloff) || result.falloff > max(Distance_Falloff) { result.falloff = DEFAULT_AUDIO_SETTINGS.falloff }
	strength := settings.levelling_strength
	result.levelling_strength = strength == strength ? clamp(strength, 0, 1) : DEFAULT_LEVELLING_STRENGTH // NaN-safe.
	return result
}

audio_settings_load :: proc(path: string = AUDIO_SETTINGS_PATH) -> Audio_Settings {
	settings := DEFAULT_AUDIO_SETTINGS
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil { return settings }
	defer delete(data)
	if json.unmarshal(data, &settings) != nil {
		fmt.eprintln("[Audio] Invalid audio settings; using defaults.")
		return DEFAULT_AUDIO_SETTINGS
	}
	return audio_settings_clamp(settings)
}

audio_settings_save :: proc(settings: Audio_Settings, path: string = AUDIO_SETTINGS_PATH) -> bool {
	data, err := json.marshal(audio_settings_clamp(settings), {use_enum_names = true})
	if err != nil { return false }
	defer delete(data)
	if os.write_entire_file(path, data) != nil {
		fmt.eprintln("[Audio] Could not save volume settings.")
		return false
	}
	return true
}

// Settings > Audio draft to the persisted audio settings.
client_audio_settings_from_values :: proc(values: menuui.Settings_Values) -> Audio_Settings {
	v := values.audio_volumes
	return audio_settings_clamp({
		master = v[0], effects = v[1], footsteps = v[2], ui = v[3], weapons = v[4],
		spatial = Spatial_Mode(clamp(values.spatial_audio, 0, 2)),
		falloff = Distance_Falloff(clamp(values.distance_falloff, 0, 2)),
		levelling = values.levelling, levelling_strength = values.levelling_strength,
	})
}
