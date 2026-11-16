package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import ma "vendor:miniaudio"
import shared "../shared"
import menuui "../menu"

when ODIN_TEST {
	// Per-channel RMS of an offline render after ramps settle.
	audio_mix_measure :: proc(audio: ^Audio_System, frames: int = 9600, skip: int = 2400) -> (rms: [SURROUND_MAX_CHANNELS]f64) {
		channels := int(ma.engine_get_channels(&audio.engine))
		buffer := make([]f32, (frames + skip) * channels)
		defer delete(buffer)
		ma.engine_read_pcm_frames(&audio.engine, raw_data(buffer), u64(frames + skip), nil)
		for i in skip ..< frames + skip {
			for c in 0 ..< channels { v := f64(buffer[i*channels + c]); rms[c] += v*v }
		}
		for &r in rms { r = math.sqrt(r / f64(frames)) }
		return
	}

	audio_mix_play_azimuth :: proc(audio: ^Audio_System, path: string, azimuth: f32, distance: f32 = 10) -> [SURROUND_MAX_CHANNELS]f64 {
		audio_stop_all(audio)
		audio_mix_measure(audio, 512, 0)
		a := math.to_radians(azimuth)
		audio_play(audio, path, position = {distance*math.sin(a), 0, -distance*math.cos(a)}, spatial = true)
		return audio_mix_measure(audio)
	}

	@(test)
	audio_surround_pans_across_speakers :: proc(t: ^testing.T) {
		path := "bin/audio-surround-tone.wav"
		defer os.remove(path)
		if !testing.expect(t, audio_spatial_write_tone(path, 48000, 1)) { return }
		tone := 0.5 / math.SQRT_TWO * KRUNKER_3D_VOLUME // A 0.5 sine within refDistance.
		Case :: struct { azimuth: f32, gains: [SURROUND_MAX_CHANNELS]f64 }
		// Channel order (miniaudio's Microsoft maps): 5.1 FL FR FC LFE SL SR;
		// 7.1 FL FR FC LFE BL BR SL SR. cos/sin pairwise constant-power gains.
		c675, s675 := math.cos(67.5 * math.PI / 180), math.sin(67.5 * math.PI / 180)
		layouts := [2]struct { channels: u32, cases: []Case }{
			{6, []Case{
				{0, {0, 0, 1, 0, 0, 0, 0, 0}}, {30, {0, 1, 0, 0, 0, 0, 0, 0}}, {-30, {1, 0, 0, 0, 0, 0, 0, 0}},
				{90, {0, c675, 0, 0, 0, s675, 0, 0}}, {-90, {c675, 0, 0, 0, s675, 0, 0, 0}},
				{110, {0, 0, 0, 0, 0, 1, 0, 0}}, {-110, {0, 0, 0, 0, 1, 0, 0, 0}},
				{180, {0, 0, 0, 0, math.SQRT_TWO/2, math.SQRT_TWO/2, 0, 0}},
			}},
			{8, []Case{
				{0, {0, 0, 1, 0, 0, 0, 0, 0}}, {30, {0, 1, 0, 0, 0, 0, 0, 0}}, {-30, {1, 0, 0, 0, 0, 0, 0, 0}},
				{90, {0, 0, 0, 0, 0, 0, 0, 1}}, {-90, {0, 0, 0, 0, 0, 0, 1, 0}},
				{110, {0, 0, 0, 0, 0, 0.5, 0, math.sqrt(f64(3))/2}}, {-110, {0, 0, 0, 0, 0.5, 0, math.sqrt(f64(3))/2, 0}},
				{180, {0, 0, 0, 0, math.SQRT_TWO/2, math.SQRT_TWO/2, 0, 0}},
			}},
		}
		for layout in layouts {
			audio := audio_create(nil, audio_test_settings(spatial = .SURROUND), true, 48000, layout.channels)
			if !testing.expect(t, audio != nil) { return }
			defer audio_destroy(audio)
			testing.expectf(t, audio.surround && ma.engine_get_channels(&audio.engine) == layout.channels && audio_effective_spatial(audio) == .SURROUND,
				"%d channels must open a surround mix", layout.channels)
			camera := camera_init(1)
			audio_update_listener(audio, &camera)
			for c in layout.cases {
				rms := audio_mix_play_azimuth(audio, path, c.azimuth)
				for ch in 0 ..< int(layout.channels) {
					expected := tone * c.gains[ch]
					testing.expectf(t, abs(rms[ch] - expected) < 0.01*tone + 0.03*expected,
						"%d ch, %.0f deg: channel %d is %.4f, expected %.4f", layout.channels, c.azimuth, ch, rms[ch], expected)
				}
			}
			// LFE never receives positional audio, and non-spatial sounds stay on the front pair.
			audio_stop_all(audio)
			audio_mix_measure(audio, 512, 0)
			audio_play(audio, path)
			rms := audio_mix_measure(audio)
			testing.expectf(t, abs(rms[0] - 0.5/math.SQRT_TWO) < 0.01 && abs(rms[1] - rms[0]) < 1e-4, "local sounds play unchanged on FL/FR (%v)", rms)
			for ch in 2 ..< int(layout.channels) { testing.expectf(t, rms[ch] < 1e-6, "local sounds must not reach channel %d", ch) }
		}
		// Stereo device: Surround falls back to the equal-power stereo panner.
		fallback := audio_create(nil, audio_test_settings(spatial = .SURROUND), true, 48000, 2)
		if !testing.expect(t, fallback != nil) { return }
		defer audio_destroy(fallback)
		testing.expect(t, !fallback.surround && audio_effective_spatial(fallback) == .STEREO && fallback.device_channels == 2, "a stereo device must use Stereo")
		camera := camera_init(1)
		audio_update_listener(fallback, &camera)
		right := audio_mix_play_azimuth(fallback, path, 90)
		front := audio_mix_play_azimuth(fallback, path, 0)
		testing.expectf(t, right[0] < 1e-4 && abs(right[1] - tone) < 0.01, "fallback right: %v", right)
		testing.expectf(t, abs(front[0] - tone/math.SQRT_TWO) < 0.01 && abs(front[1] - front[0]) < 1e-4, "fallback front: %v", front)
		testing.expect_value(t, menuui.spatial_audio_label(2, 2), "Surround (stereo device: using Stereo)")
		testing.expect_value(t, menuui.spatial_audio_label(2, 6), "Surround (5.1)")
		testing.expect_value(t, menuui.spatial_audio_label(2, 8), "Surround (7.1)")
	}

	@(test)
	audio_distance_falloff_modes :: proc(t: ^testing.T) {
		testing.expect(t, audio_distance_gain(10, 25, .KRUNKER) == 1 && abs(audio_distance_gain(100, 25, .KRUNKER) - 0.25) < 1e-6, "Krunker: 25/d")
		testing.expect(t, audio_distance_gain(10, 25, .REDUCED) == 1 && abs(audio_distance_gain(100, 25, .REDUCED) - 0.5) < 1e-6 && abs(audio_distance_gain(400, 25, .REDUCED) - 1.0/6) < 1e-6,
			"Reduced: rolloff 1/3 (half level at 100 units)")
		testing.expect(t, audio_distance_gain(5000, 25, .OFF) == 1, "Off: no attenuation")
		path := "bin/audio-falloff-tone.wav"
		defer os.remove(path)
		if !testing.expect(t, audio_spatial_write_tone(path, 48000, 1)) { return }
		modes := [?]Spatial_Mode{.STEREO, .HRTF, .SURROUND}
		falloffs := [?]Distance_Falloff{.KRUNKER, .REDUCED, .OFF}
		expected := [?]f64{0.25, 0.5, 1}
		for mode in modes {
			settings := audio_test_settings(spatial = mode)
			audio := audio_create(nil, settings, true, 48000, 6)
			if !testing.expect(t, audio != nil) { return }
			defer audio_destroy(audio)
			camera := camera_init(1)
			audio_update_listener(audio, &camera)
			for falloff, f in falloffs {
				settings.falloff = falloff
				audio_set_settings(audio, settings)
				near := audio_mix_play_azimuth(audio, path, 0, 10)
				far := audio_mix_play_azimuth(audio, path, 0, 100)
				near_e, far_e: f64
				for ch in 0 ..< SURROUND_MAX_CHANNELS { near_e += near[ch]*near[ch]; far_e += far[ch]*far[ch] }
				ratio := math.sqrt(far_e / near_e)
				testing.expectf(t, abs(ratio - expected[f]) < 0.02, "%v %v: 100 units must be %.2f of near (%.3f)", mode, falloff, expected[f], ratio)
			}
			// Range culls still apply with falloff off.
			testing.expect(t, !audio_play_effect(audio, "step_0", .FOOTSTEPS, position = {0, 0, -200}, spatial = true, range = KRUNKER_STEP_RANGE), "culls stay")
		}
	}

	audio_levelling_test_node :: proc(strength: f32 = DEFAULT_LEVELLING_STRENGTH) -> ^Levelling_Node {
		node := new(Levelling_Node)
		levelling_node_prepare(node, 2, 48000)
		levelling_node_configure(node, true, strength)
		return node
	}

	// Renders `seconds` of a 1 kHz sine at `amplitude` and returns the output
	// peak and the RMS gain (dB) over the last `window` seconds.
	audio_levelling_run :: proc(node: ^Levelling_Node, amplitude, seconds: f32, window: f32 = 0.1, phase: ^int = nil) -> (peak: f32, gain_db: f64) {
		frames := int(seconds * 48000)
		input := make([]f32, frames*2); defer delete(input)
		output := make([]f32, frames*2); defer delete(output)
		start := phase != nil ? phase^ : 0
		for i in 0 ..< frames {
			v := amplitude * math.sin(2 * math.PI * 1000 * f32(start + i) / 48000)
			input[i*2], input[i*2+1] = v, v
		}
		if phase != nil { phase^ += frames }
		for offset := 0; offset < frames; offset += 480 {
			n := min(480, frames - offset)
			levelling_render(node, raw_data(input[offset*2:]), raw_data(output[offset*2:]), n)
		}
		in_e, out_e: f64
		tail := int(window * 48000)
		for i in 0 ..< frames {
			peak = max(peak, abs(output[i*2]), abs(output[i*2+1]))
			if i >= frames - tail { in_e += f64(input[i*2])*f64(input[i*2]); out_e += f64(output[i*2])*f64(output[i*2]) }
		}
		gain_db = 10 * math.log10(out_e / max(in_e, 1e-30))
		return
	}

	@(test)
	audio_levelling_compresses_lifts_and_limits :: proc(t: ^testing.T) {
		curve := levelling_curve(DEFAULT_LEVELLING_STRENGTH)
		testing.expect(t, abs(curve.threshold_db + 20) < 1e-4 && abs(curve.ratio - 3.5) < 1e-4, "default strength: -20 dBFS, 3.5:1")
		// Loud input is pulled down; quiet input is lifted by the makeup gain.
		loud := audio_levelling_test_node(); defer free(loud)
		loud_peak, loud_gain := audio_levelling_run(loud, 1.0, 1)
		testing.expectf(t, loud_gain < -3 && loud_peak <= 1, "a full-scale shot must be reduced (%.1f dB, peak %.3f)", loud_gain, loud_peak)
		quiet := audio_levelling_test_node(); defer free(quiet)
		_, quiet_gain := audio_levelling_run(quiet, 0.01, 1)
		testing.expectf(t, abs(quiet_gain - f64(curve.makeup_db)) < 0.5, "a distant sound must be lifted by %.1f dB (%.1f dB)", curve.makeup_db, quiet_gain)
		// No clipping: a sudden full-scale burst after silence (worst case for the attack).
		burst := audio_levelling_test_node(1); defer free(burst)
		phase := 0
		audio_levelling_run(burst, 0.001, 0.5, phase = &phase)
		burst_peak, _ := audio_levelling_run(burst, 4.0, 0.3, phase = &phase) // +12 dB over full scale.
		testing.expectf(t, burst_peak <= 1.0, "the limiter must hold the bus at or below full scale (peak %.4f)", burst_peak)
		// Attack: within 50 ms of a loud onset the gain is within 1.5 dB of its steady value.
		attack := audio_levelling_test_node(); defer free(attack)
		phase = 0
		audio_levelling_run(attack, 0.01, 0.5, phase = &phase)
		_, after_attack := audio_levelling_run(attack, 1.0, 0.05, 0.005, &phase)
		_, steady_loud := audio_levelling_run(attack, 1.0, 0.5, phase = &phase)
		testing.expectf(t, abs(after_attack - steady_loud) < 1.5, "attack must settle within 50 ms (%.1f vs %.1f dB)", after_attack, steady_loud)
		// Release: 100 ms after the shot the lift is still recovering; by 1.5 s it is back.
		_, early := audio_levelling_run(attack, 0.01, 0.1, 0.01, &phase)
		_, late := audio_levelling_run(attack, 0.01, 1.4, 0.05, &phase)
		testing.expectf(t, early < f64(curve.makeup_db) - 3, "release must be gradual, not a jump (%.1f dB at 100 ms)", early)
		testing.expectf(t, abs(late - f64(curve.makeup_db)) < 1, "release must recover the lift (%.1f dB at 1.5 s)", late)
		// Off: bit-exact passthrough.
		off := audio_levelling_test_node(); defer free(off)
		levelling_node_configure(off, false, 1)
		input := [8]f32{0.9, -0.9, 0.1, -0.2, 1.5, -1.5, 0, 0.3}
		output: [8]f32
		levelling_render(off, &input[0], &output[0], 4)
		testing.expect(t, input == output, "levelling off must not touch the mix")
	}

	@(test)
	audio_weapon_volume_scales_weapon_sounds_only :: proc(t: ^testing.T) {
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		audio := audio_create(config.weapons, audio_test_settings(spatial = .STEREO), true)
		if !testing.expect(t, audio != nil) { return }
		defer audio_destroy(audio)
		client := Client{audio = audio}
		client.game.weapons = config.weapons
		me := shared.Player{uid = 1}
		client.me = &me
		weapon_id: i32 = -1
		for weapon, i in config.weapons { if weapon != nil && !weapon.melee { weapon_id = i32(i); break } }
		events := [?]shared.Presentation_Event{
			{kind = .FIRE, uid = 1, weapon_id = weapon_id}, {kind = .RELOAD, uid = 1},
			{kind = .EXPLOSION, position = {0, 0, -5}}, {kind = .HIT, uid = 1}, {kind = .STEP, uid = 1},
		}
		channels := [?]Audio_Channel{.WEAPONS, .WEAPONS, .WEAPONS, .EFFECTS, .FOOTSTEPS}
		for event, i in events {
			audio_stop_all(audio)
			before := audio.serial
			client_audio_present(&client, event)
			voice: ^Audio_Voice
			for &v in audio.voices { if v.serial == before + 1 { voice = &v } }
			if !testing.expectf(t, voice != nil, "%v must play", event.kind) { continue }
			testing.expectf(t, voice.channel == channels[i], "%v plays on %v (got %v)", event.kind, channels[i], voice.channel)
		}
		// The slider scales weapon voices only.
		settings := audio_test_settings(spatial = .STEREO, weapons = 0.25)
		audio_set_settings(audio, settings)
		for &v in audio.voices {
			if v.sample == nil { continue }
			expected := v.gain * audio_channel_gain(settings, v.channel)
			testing.expect(t, abs(ma.sound_get_volume(&v.sound) - expected) < 1e-6)
		}
		testing.expect(t, audio_channel_gain(settings, .WEAPONS) == 0.25 && audio_channel_gain(settings, .EFFECTS) == 1, "only weapons follow Weapon volume")
		settings.weapons = 0
		audio_set_settings(audio, settings)
		testing.expect(t, !audio_play(audio, audio_weapon_path(config.weapons[weapon_id]), .WEAPONS), "muted weapons take no voice")
		testing.expect(t, audio_play_effect(audio, "hit_0"), "hit feedback is not a weapon sound")
	}

	@(test)
	audio_mix_settings_persist_and_reset :: proc(t: ^testing.T) {
		path := "bin/audio-settings-mix-test.json"
		defer os.remove(path)
		settings := Audio_Settings{master = 0.5, effects = 1, footsteps = 1, ui = 1, weapons = 0.7, spatial = .SURROUND, falloff = .REDUCED, levelling = true, levelling_strength = 0.8}
		testing.expect(t, audio_settings_save(settings, path) && audio_settings_load(path) == settings, "every audio setting survives restarting")
		testing.expect(t, os.write_entire_file(path, string(`{"master":1,"effects":1,"footsteps":1,"ui":1,"spatial":"HRTF"}`)) == nil)
		old := audio_settings_load(path)
		testing.expect(t, old.weapons == KRUNKER_WEAPON_VOLUME && old.falloff == .KRUNKER && !old.levelling && old.levelling_strength == DEFAULT_LEVELLING_STRENGTH,
			"older files get Krunker's 30% weapon volume, Krunker falloff and levelling off")
		testing.expect(t, DEFAULT_AUDIO_SETTINGS.weapons == 0.3 && DEFAULT_AUDIO_SETTINGS.falloff == .KRUNKER && !DEFAULT_AUDIO_SETTINGS.levelling, "defaults")
		// Reset (Audio tab) restores every audio option.
		defaults := client_settings_default_values()
		draft := defaults
		draft.audio_volumes = {0.1, 0.1, 0.1, 0.1, 0.1}
		draft.spatial_audio, draft.distance_falloff, draft.levelling, draft.levelling_strength = 2, 2, true, 1
		menuui.settings_reset_tab(&draft, defaults, .AUDIO)
		testing.expect(t, draft == defaults && client_audio_settings_from_values(draft) == DEFAULT_AUDIO_SETTINGS, "Reset restores the audio defaults")
		// Krunker's gunsVolume maps to Weapon volume; the other options stay Krodin-only.
		values := defaults
		values.spatial_audio, values.distance_falloff, values.levelling = 1, 2, true
		_, err := menuui.krunker_settings_import(&values, `{"gunsVolume":0.6}`)
		testing.expect(t, len(err) == 0 && values.audio_volumes[4] == 0.6 && values.spatial_audio == 1 && values.distance_falloff == 2 && values.levelling, "import maps gunsVolume only")
		exported := menuui.krunker_settings_export(values, context.temp_allocator)
		testing.expectf(t, contains(exported, `"gunsVolume":0.6`) && !contains(exported, "falloff") && !contains(exported, "levelling"), "export: %s", exported)
		values.audio_volumes[4] = 0.3
		testing.expect(t, !contains(menuui.krunker_settings_export(values, context.temp_allocator), "gunsVolume"), "Krunker's default is not exported")
	}

	@(private="file")
	contains :: proc(s, sub: string) -> bool {
		for i in 0 ..= len(s) - len(sub) { if len(sub) <= len(s) && s[i:i+len(sub)] == sub { return true } }
		return false
	}

	// Offline 5.1 / 7.1 demo: a gunshot circling the listener (two laps in 8 s).
	// odin test src/client -define:AUDIO_SPATIAL_DEMO=true -define:ODIN_TEST_NAMES=main.audio_surround_demo_render
	when #config(AUDIO_SPATIAL_DEMO, false) {
		@(test)
		audio_surround_demo_render :: proc(t: ^testing.T) {
			os.make_directory("bin/spatial-audio")
			Demo :: struct { channels: u32, mask: u32, name: string }
			demos := [?]Demo{{6, 0x60F, "gunshot_circle_5_1.wav"}, {8, 0x63F, "gunshot_circle_7_1.wav"}}
			for demo in demos {
				audio := audio_create(nil, audio_test_settings(spatial = .SURROUND), true, 48000, demo.channels)
				if !testing.expect(t, audio != nil && audio.surround) { return }
				defer audio_destroy(audio)
				camera := camera_init(1)
				audio_update_listener(audio, &camera)
				rate, seconds, channels := 48000, 8, int(demo.channels)
				pcm := make([]f32, rate*seconds*channels)
				defer delete(pcm)
				for shot in 0 ..< seconds*4 {
					phase := math.mod(f32(shot) / 4, 4) / 4 * 2 * math.PI
					audio_play(audio, "assets/sound/weapon_1.mp3", position = {15*math.sin(phase), 0, -15*math.cos(phase)}, spatial = true, priority = 4)
					frames := rate / 4
					ma.engine_read_pcm_frames(&audio.engine, &pcm[shot*frames*channels], u64(frames), nil)
				}
				peak: f32
				for v in pcm { peak = max(peak, abs(v)) }
				scale := 0.89 / max(peak, 1e-6)
				// WAVE_FORMAT_EXTENSIBLE with the speaker mask matching the channel order.
				bytes := make([]u8, 68 + len(pcm)*2)
				defer delete(bytes)
				put_u32 :: proc(b: []u8, at: int, v: u32) { b[at], b[at+1], b[at+2], b[at+3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24) }
				put_u16 :: proc(b: []u8, at: int, v: u16) { b[at], b[at+1] = u8(v), u8(v >> 8) }
				copy(bytes[0:], "RIFF"); put_u32(bytes, 4, u32(60 + len(pcm)*2)); copy(bytes[8:], "WAVEfmt ")
				put_u32(bytes, 16, 40); put_u16(bytes, 20, 0xFFFE); put_u16(bytes, 22, u16(channels))
				put_u32(bytes, 24, u32(rate)); put_u32(bytes, 28, u32(rate*channels*2)); put_u16(bytes, 32, u16(channels*2)); put_u16(bytes, 34, 16)
				put_u16(bytes, 36, 22); put_u16(bytes, 38, 16); put_u32(bytes, 40, demo.mask)
				pcm_guid := [16]u8{0x01, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71}
				copy(bytes[44:], pcm_guid[:])
				copy(bytes[60:], "data"); put_u32(bytes, 64, u32(len(pcm)*2))
				for v, i in pcm { put_u16(bytes, 68 + i*2, transmute(u16)i16(clamp(v * scale, -1, 1) * 32767)) }
				out := fmt.tprintf("bin/spatial-audio/%s", demo.name)
				testing.expect(t, os.write_entire_file(out, bytes) == nil, out)
				fmt.printf("[Audio demo] wrote %s\n", out)
			}
		}
	}
}
