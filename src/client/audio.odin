package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import ma "vendor:miniaudio"
import shared "../shared"

// WEAPONS matches Krunker's "Weapon Volume" (gunsVolume, sound category 3):
// gunshots, melee swings, reloads and explosions, for every player.
Audio_Channel :: enum { EFFECTS, FOOTSTEPS, UI, WEAPONS }
MAX_AUDIO_VOICES :: 64

Audio_Sample :: struct { sound: ma.sound, ready: bool, path: cstring }
Audio_Voice :: struct {
	sound: ma.sound,
	node: Spatial_Node,
	sample: ^Audio_Sample,
	channel: Audio_Channel,
	gain: f32,
	priority: int,
	serial: u64,
	// Spatial voices keep their world position; the listener moves under them.
	spatial, stereo_source: bool,
	position: shared.Vec3,
	ref_distance: f32,
	on_bus: bool,                 // Routed through the levelling bus (everything but UI).
	starts_at: u64,               // Engine frame a delayed sound begins; busy until then.
}
Audio_System :: struct {
	engine: ma.engine,
	samples: map[string]^Audio_Sample,
	voices: [MAX_AUDIO_VOICES]Audio_Voice,
	settings: Audio_Settings,
	listener: Audio_Listener,
	nodes_ready: bool,
	hrtf: ^Hrtf_Set,
	levelling: Levelling_Node,
	// Surround: the engine opens the device's own channel layout. Otherwise the
	// mix is stereo. `device_channels` is what the output device offers.
	layout: Surround_Layout,
	surround: bool,
	requested_surround, no_device: bool,
	device_channels: int,
	serial, hit_revision, health_drop_revision: u64,
	steals: int,
	clock, last_health_drop: f64, // Seconds; drives Krunker's damage-sound throttle.
	variation: u32,
}

audio_weapon_path :: proc(weapon: ^shared.Weapon) -> string {
	if weapon == nil { return "" }
	name := len(weapon.sound) > 0 ? weapon.sound : weapon.src
	if weapon.melee && len(weapon.sound) == 0 { name = "swsh_def_0" }
	if name == "weapon-7" { name = "weapon_7" }
	if len(name) == 0 { return "" }
	if strings.contains(name, ".") { return fmt.tprintf("%s%s", shared.assets_path(), name) }
	return fmt.tprintf("%ssound/%s.mp3", shared.assets_path(), name)
}

audio_load_sample :: proc(audio: ^Audio_System, path: string) -> ^Audio_Sample {
	if len(path) == 0 { return nil }
	if sample, found := audio.samples[path]; found { return sample }
	sample := new(Audio_Sample)
	audio.samples[strings.clone(path)] = sample
	cpath := strings.clone_to_cstring(path)
	sample.path = cpath
	result := ma.sound_init_from_file(&audio.engine, cpath, {.DECODE}, nil, nil, &sample.sound)
	sample.ready = result == .SUCCESS
	shared.asset_trace(path, sample.ready)
	if !sample.ready { fmt.eprintf("[Audio] Cannot load %s (%v); this effect will be silent.\n", path, result) }
	return sample
}

// Surround opens the device at its native channel count (`channels` stands
// in for the device when `no_device` is set, as in offline tests); every
// other mode mixes to stereo.
audio_create :: proc(weapons: []^shared.Weapon, settings: Audio_Settings, no_device: bool = false, sample_rate: u32 = 48000, channels: u32 = 2) -> ^Audio_System {
	audio := new(Audio_System)
	audio.requested_surround, audio.no_device = settings.spatial == .SURROUND, no_device
	if !audio_engine_open(audio, sample_rate, audio.requested_surround ? (no_device ? channels : 0) : 2) {
		free(audio)
		return nil
	}
	audio.samples = make(map[string]^Audio_Sample)
	audio.hrtf = hrtf_load(ma.engine_get_sample_rate(&audio.engine))
	audio.nodes_ready = levelling_node_init(&audio.engine, &audio.levelling)
	layout := audio.surround ? &audio.layout : nil
	for &voice in audio.voices {
		if !audio.nodes_ready { break }
		if !spatial_node_init(&audio.engine, &voice.node, audio.hrtf, layout, cast(^ma.node)&audio.levelling) { audio.nodes_ready = false }
		voice.on_bus = true
	}
	if !audio.nodes_ready { fmt.eprintln("[Audio] Spatial mixer unavailable; positional effects are disabled.") }
	audio.listener = {forward = {0, 0, -1}}
	audio.last_health_drop = -1e9
	// Short effects decode before gameplay, never on the first trigger pull.
	manifest_path := shared.concat(shared.assets_path(), "config/sound-assets.txt")
	defer delete(manifest_path)
	manifest, err := os.read_entire_file_from_path(manifest_path, context.allocator)
	shared.asset_trace(manifest_path, err == nil)
	if err == nil {
		contents := string(manifest)
		for raw_line in strings.split_lines_iterator(&contents) {
			line := strings.trim_space(raw_line)
			if len(line) == 0 || strings.has_prefix(line, "#") { continue }
			audio_load_sample(audio, fmt.tprintf("%s%s", shared.assets_path(), line))
		}
		delete(manifest)
	} else { fmt.eprintln("[Audio] Sound manifest missing; effects will load on demand.") }
	for weapon in weapons { if weapon != nil { audio_load_sample(audio, audio_weapon_path(weapon)) } }
	audio_set_settings(audio, settings)
	fmt.printf("[Audio] Spatial mixer ready: %d cached effects, %d voices, %d output channels (%v).\n",
		len(audio.samples), MAX_AUDIO_VOICES, ma.engine_get_channels(&audio.engine), audio_effective_spatial(audio))
	return audio
}

// Tests may run a real-time engine on miniaudio's null backend (no output).
audio_test_context: ^ma.context_type

@(private="file")
audio_engine_open :: proc(audio: ^Audio_System, sample_rate, channels: u32) -> bool {
	config := ma.engine_config_init()
	config.channels, config.sampleRate = channels, sample_rate
	config.noDevice = b32(audio.no_device)
	config.pContext = audio_test_context
	if audio.no_device && config.channels == 0 { config.channels = 2 }
	result := ma.engine_init(&config, &audio.engine)
	if result != .SUCCESS {
		fmt.eprintf("[Audio] Output unavailable (%v); continuing without sound.\n", result)
		return false
	}
	engine_channels := int(ma.engine_get_channels(&audio.engine))
	audio.device_channels = engine_channels
	if device := ma.engine_get_device(&audio.engine); device != nil {
		audio.device_channels = max(int(device.playback.internalChannels), engine_channels)
	}
	audio.surround = false
	if engine_channels > 2 {
		ok: bool
		if device := ma.engine_get_device(&audio.engine); device != nil {
			audio.layout, ok = surround_layout_from_map(device.playback.channelMap[:engine_channels])
		} else {
			audio.layout, ok = surround_layout_standard(engine_channels)
		}
		if !ok {
			// No usable speaker ring (e.g. quad without a front pair): mix in stereo.
			ma.engine_uninit(&audio.engine)
			fmt.eprintf("[Audio] Unsupported %d-channel layout; using stereo.\n", engine_channels)
			return audio_engine_open(audio, sample_rate, 2)
		}
		audio.surround = true
	}
	return true
}

// The panning actually in use: Surround needs a multichannel device and HRTF
// its data set; both fall back to Stereo.
audio_effective_spatial :: proc(audio: ^Audio_System) -> Spatial_Mode {
	if audio == nil { return .STEREO }
	if audio.surround { return .SURROUND }
	if audio.settings.spatial == .HRTF && audio.hrtf != nil { return .HRTF }
	return .STEREO
}

// Switching into or out of Surround changes the engine's channel count.
audio_needs_reopen :: proc(audio: ^Audio_System, settings: Audio_Settings) -> bool {
	return audio != nil && audio.requested_surround != (settings.spatial == .SURROUND)
}

audio_stop_all :: proc(audio: ^Audio_System) {
	if audio == nil { return }
	for &voice in audio.voices { if voice.sample != nil { ma.sound_stop(&voice.sound) } }
}

audio_destroy :: proc(audio: ^Audio_System) {
	if audio == nil { return }
	for &voice in audio.voices { if voice.sample != nil { ma.sound_uninit(&voice.sound) } }
	for &voice in audio.voices { spatial_node_uninit(&voice.node) }
	levelling_node_uninit(&audio.levelling)
	hrtf_destroy(audio.hrtf)
	for path, sample in audio.samples {
		if sample.ready { ma.sound_uninit(&sample.sound) }
		delete(sample.path)
		free(sample)
		delete(path)
	}
	delete(audio.samples)
	ma.engine_uninit(&audio.engine)
	free(audio)
}

audio_channel_gain :: proc(settings: Audio_Settings, channel: Audio_Channel) -> f32 {
	switch channel {
	case .EFFECTS: return settings.effects
	case .FOOTSTEPS: return settings.footsteps
	case .UI: return settings.ui
	case .WEAPONS: return settings.weapons
	}
	return 0
}

audio_set_settings :: proc(audio: ^Audio_System, settings: Audio_Settings) {
	if audio == nil { return }
	audio.settings = settings
	ma.engine_set_volume(&audio.engine, settings.master)
	if audio.nodes_ready { levelling_node_configure(&audio.levelling, settings.levelling, settings.levelling_strength) }
	audio_update_spatial_voices(audio)
	for &voice in audio.voices {
		if voice.sample != nil { ma.sound_set_volume(&voice.sound, voice.gain * audio_channel_gain(settings, voice.channel)) }
	}
}

// Krunker drives Howler's listener with Howler.pos(eye) and
// Howler.orientation(sin(yaw+PI), pitch, cos(yaw+PI)) with the default +Y up.
// The pitch is used directly as the Y component (not sin/cos), exactly as Krunker does.
audio_set_listener :: proc(audio: ^Audio_System, position: shared.Vec3, yaw, pitch: f32) {
	if audio == nil { return }
	audio.listener = {position = position, forward = {math.sin(yaw + math.PI), pitch, math.cos(yaw + math.PI)}}
	audio_update_spatial_voices(audio)
}

audio_update_listener :: proc(audio: ^Audio_System, camera: ^Camera) {
	if camera == nil { return }
	audio_set_listener(audio, camera.position, camera.rotation.y, camera.rotation.x)
}

// Recompute direction and distance gain for every playing positional voice.
audio_update_spatial_voices :: proc(audio: ^Audio_System) {
	if !audio.nodes_ready { return }
	for &voice in audio.voices {
		if voice.sample == nil || !voice.spatial || !bool(ma.sound_is_playing(&voice.sound)) { continue }
		spatial_node_publish(&voice.node, audio_voice_params(audio, &voice), false)
	}
}

audio_voice_params :: proc(audio: ^Audio_System, voice: ^Audio_Voice) -> Spatial_Params {
	if !voice.spatial { return {} }
	params := audio_spatial_params(audio.listener, voice.position, voice.ref_distance, voice.stereo_source, audio.settings.falloff)
	params.hrtf = audio_effective_spatial(audio) == .HRTF
	// Binaural rendering feeds each ear one channel of a stereo effect; the
	// equal-power panner passes both at unity when the source is ahead.
	if params.hrtf && params.stereo_source { params.gain *= math.SQRT_TWO }
	return params
}

audio_spatial_params :: proc(listener: Audio_Listener, position: shared.Vec3, ref_distance: f32, stereo_source: bool, falloff: Distance_Falloff = .KRUNKER) -> Spatial_Params {
	azimuth, elevation := audio_azimuth_elevation(listener, position)
	delta := position - listener.position
	distance := math.sqrt(delta.x*delta.x + delta.y*delta.y + delta.z*delta.z)
	return {
		spatial = true, stereo_source = stereo_source,
		gain = KRUNKER_3D_VOLUME * audio_distance_gain(distance, ref_distance, falloff),
		azimuth = azimuth, elevation = elevation,
	}
}

audio_distance_gain :: proc "contextless" (distance, ref_distance: f32, falloff: Distance_Falloff) -> f32 {
	switch falloff {
	case .KRUNKER: return audio_inverse_distance_gain(distance, ref_distance, KRUNKER_ROLLOFF)
	case .REDUCED: return audio_inverse_distance_gain(distance, ref_distance, REDUCED_ROLLOFF)
	case .OFF: return 1
	}
	return 1
}

// The mixer runs in miniaudio's C thread. Its only Odin code is Spatial_Node,
// which reads per-voice parameters through a sequence lock and never touches
// gameplay memory. Voices share decoded samples and have bounded cost.
audio_play :: proc(audio: ^Audio_System, path: string, channel: Audio_Channel = .EFFECTS,
	gain: f32 = 1, position: shared.Vec3 = {}, spatial: bool = false, range: f32 = KRUNKER_MAX_DISTANCE, priority: int = 2,
	ref_distance: f32 = KRUNKER_REF_DISTANCE, delay: f32 = 0) -> bool {
	if audio == nil || audio.settings.master <= 0 || audio_channel_gain(audio.settings, channel) <= 0 { return false }
	if spatial && !audio.nodes_ready { return false }
	if spatial {
		delta := position - audio.listener.position
		if delta.x*delta.x + delta.y*delta.y + delta.z*delta.z > range*range { return false }
	}
	sample := audio_load_sample(audio, path)
	if sample == nil || !sample.ready { return false }
	chosen := -1
	for &voice, i in audio.voices {
		if !audio_voice_busy(audio, &voice) { chosen = i; break }
		if chosen < 0 || voice.priority < audio.voices[chosen].priority ||
			voice.priority == audio.voices[chosen].priority && voice.serial < audio.voices[chosen].serial { chosen = i }
	}
	voice := &audio.voices[chosen]
	if audio_voice_busy(audio, voice) {
		if voice.priority > priority { return false }
		audio.steals += 1 // A still-playing sound is cut short; tests assert this stays rare.
	}
	if voice.sample != sample {
		if voice.sample != nil { ma.sound_uninit(&voice.sound); voice.sample = nil }
		// miniaudio's own spatializer is bypassed: every voice feeds its Spatial_Node
		// in stereo, which applies the panner (or passes non-spatial audio through).
		// The resource manager shares the decoded data with the cached sample.
		config := ma.sound_config_init_2(&audio.engine)
		config.pFilePath = sample.path
		config.flags = {.DECODE, .NO_SPATIALIZATION, .NO_DEFAULT_ATTACHMENT}
		config.channelsOut = audio.nodes_ready ? 2 : 0
		if ma.sound_init_ex(&audio.engine, &config, &voice.sound) != .SUCCESS { return false }
		target := audio.nodes_ready ? cast(^ma.node)&voice.node : ma.engine_get_endpoint(&audio.engine)
		if ma.node_attach_output_bus(cast(^ma.node)&voice.sound, 0, target, 0) != .SUCCESS {
			ma.sound_uninit(&voice.sound)
			return false
		}
		voice.sample = sample
	} else { ma.sound_stop(&voice.sound) }
	ma.sound_seek_to_pcm_frame(&voice.sound, 0)
	voice.channel, voice.gain, voice.priority = channel, gain, priority
	voice.spatial, voice.position, voice.ref_distance = spatial, position, ref_distance
	voice.stereo_source = audio_sample_is_stereo(sample)
	// UI clicks skip loudness levelling; everything else shares the effects bus.
	if audio.nodes_ready && voice.on_bus != (channel != .UI) {
		voice.on_bus = channel != .UI
		target := voice.on_bus ? cast(^ma.node)&audio.levelling : ma.engine_get_endpoint(&audio.engine)
		ma.node_attach_output_bus(cast(^ma.node)&voice.node, 0, target, 0)
	}
	audio.serial += 1
	voice.serial = audio.serial
	ma.sound_set_volume(&voice.sound, gain * audio_channel_gain(audio.settings, channel))
	// A reused voice must not inherit the previous sound's direction or filter
	// state; the reset flag makes the mixer snap instead of ramping from it.
	if audio.nodes_ready {
		spatial_node_publish(&voice.node, audio_voice_params(audio, voice), true)
	}
	// Every play is a new instance from the start, like Howler. A delay schedules
	// the start on the mixer clock; until then the voice still counts as busy.
	voice.starts_at = 0
	if delay > 0 {
		voice.starts_at = ma.engine_get_time_in_pcm_frames(&audio.engine) + u64(delay * f32(ma.engine_get_sample_rate(&audio.engine)))
		ma.sound_set_start_time_in_pcm_frames(&voice.sound, voice.starts_at)
	} else {
		ma.sound_set_start_time_in_pcm_frames(&voice.sound, 0)
	}
	return ma.sound_start(&voice.sound) == .SUCCESS
}

audio_voice_busy :: proc(audio: ^Audio_System, voice: ^Audio_Voice) -> bool {
	if voice.sample == nil { return false }
	return bool(ma.sound_is_playing(&voice.sound)) || voice.starts_at > ma.engine_get_time_in_pcm_frames(&audio.engine)
}

// Krunker's CHANGE_HEALTH: on a local health drop, play takedmg_0/1 at 0.45
// unless the previous drop was under 500 ms ago (the timer restarts on every
// drop, so sustained fire only sounds after a pause). Krunker also shakes the
// camera by 0.02; Krodin has no camera shake yet.
KRUNKER_DAMAGE_SOUND_GAP :: 0.5
audio_health_drop :: proc(audio: ^Audio_System) {
	if audio == nil { return }
	if audio.clock - audio.last_health_drop > KRUNKER_DAMAGE_SOUND_GAP {
		audio_play_effect(audio, fmt.tprintf("takedmg_%d", audio.variation % 2), .EFFECTS, 0.45, priority = 4)
		audio.variation += 1
	}
	audio.last_health_drop = audio.clock
}

audio_sample_is_stereo :: proc(sample: ^Audio_Sample) -> bool {
	format: ma.format
	channels, rate: u32
	if ma.sound_get_data_format(&sample.sound, &format, &channels, &rate, nil, 0) != .SUCCESS { return true }
	return channels >= 2
}

audio_play_effect :: proc(audio: ^Audio_System, name: string, channel: Audio_Channel = .EFFECTS,
	gain: f32 = 1, position: shared.Vec3 = {}, spatial: bool = false, range: f32 = KRUNKER_MAX_DISTANCE, priority: int = 2) -> bool {
	return audio_play(audio, fmt.tprintf("%ssound/%s.mp3", shared.assets_path(), name), channel, gain, position, spatial, range, priority)
}
