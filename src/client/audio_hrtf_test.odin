package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import ma "vendor:miniaudio"
import shared "../shared"
import menuui "../menu"

when ODIN_TEST {
	// Deterministic white noise (LCG) written as 16-bit mono WAV.
	audio_hrtf_write_noise :: proc(path: string, sample_rate: int, seconds: f32, amplitude: f32 = 0.3) -> bool {
		frames := int(f32(sample_rate) * seconds)
		bytes := make([]u8, 44 + frames*2)
		defer delete(bytes)
		put_u32 :: proc(b: []u8, at: int, v: u32) { b[at], b[at+1], b[at+2], b[at+3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24) }
		put_u16 :: proc(b: []u8, at: int, v: u16) { b[at], b[at+1] = u8(v), u8(v >> 8) }
		copy(bytes[0:], "RIFF"); put_u32(bytes, 4, u32(36 + frames*2)); copy(bytes[8:], "WAVEfmt ")
		put_u32(bytes, 16, 16); put_u16(bytes, 20, 1); put_u16(bytes, 22, 1)
		put_u32(bytes, 24, u32(sample_rate)); put_u32(bytes, 28, u32(sample_rate * 2))
		put_u16(bytes, 32, 2); put_u16(bytes, 34, 16)
		copy(bytes[36:], "data"); put_u32(bytes, 40, u32(frames*2))
		state: u32 = 0x1234567
		for i in 0 ..< frames {
			state = state*1664525 + 1013904223
			value := i16(amplitude * 32767 * (f32(state >> 8) / f32(1 << 24) * 2 - 1))
			put_u16(bytes, 44 + i*2, transmute(u16)value)
		}
		return os.write_entire_file(path, bytes) == nil
	}

	// Magnitude (dB) of a time-reversed FIR at one frequency.
	audio_hrtf_magnitude_db :: proc(reversed: [HRTF_TAPS]f32, sample_rate, frequency: f32) -> f64 {
		re, im: f64
		for n in 0 ..< HRTF_TAPS {
			w := 2 * math.PI * f64(frequency) * f64(n) / f64(sample_rate)
			h := f64(reversed[HRTF_TAPS - 1 - n])
			re += h * math.cos(w); im -= h * math.sin(w)
		}
		return 10 * math.log10(re*re + im*im + 1e-12)
	}

	// RMS difference (dB) between two filters' magnitude responses over a band.
	audio_hrtf_spectral_distance :: proc(a, b: [HRTF_TAPS]f32, sample_rate, low, high: f32) -> f64 {
		sum: f64
		steps := 48
		for s in 0 ..< steps {
			f := low * math.pow(high / low, f32(s) / f32(steps - 1))
			d := audio_hrtf_magnitude_db(a, sample_rate, f) - audio_hrtf_magnitude_db(b, sample_rate, f)
			sum += d * d
		}
		return math.sqrt(sum / f64(steps))
	}

	// Lag (in samples) maximising the cross-correlation of left against right;
	// positive when the left ear hears the sound later.
	audio_hrtf_itd_samples :: proc(buffer: []f32, frames, max_lag: int) -> int {
		best, best_lag := f64(-1e30), 0
		for lag in -max_lag ..= max_lag {
			sum: f64
			for i in max_lag ..< frames - max_lag { sum += f64(buffer[(i + lag)*2]) * f64(buffer[i*2 + 1]) }
			if sum > best { best, best_lag = sum, lag }
		}
		return best_lag
	}

	@(test)
	audio_hrtf_dataset_loads_at_both_rates :: proc(t: ^testing.T) {
		rates := [?]u32{44100, 48000}
		itd: [2]f32
		for rate, r in rates {
			set := hrtf_load(rate)
			if !testing.expectf(t, set != nil, "KEMAR set must load at %d Hz", rate) { return }
			defer hrtf_destroy(set)
			directions := 0
			for ring in set.rings { directions += len(ring.azimuths) }
			testing.expectf(t, len(set.rings) == 14 && directions == 710, "rings %d directions %d", len(set.rings), directions)
			right: Hrtf_Filter
			hrtf_lookup(set, 90, 0, &right)
			itd[r] = (right.delay[0] - right.delay[1]) / f32(rate)
			testing.expectf(t, itd[r] > 0.0005 && itd[r] < 0.0009, "%d Hz: a source at the right reaches the left ear 0.5-0.9 ms later (%.3f ms)", rate, itd[r]*1000)
			left: Hrtf_Filter
			hrtf_lookup(set, -90, 0, &left)
			testing.expect(t, abs(left.delay[1] - right.delay[0]) < 1e-4 && abs(left.delay[0] - right.delay[1]) < 1e-4, "left and right mirror each other")
			// Front/back: the pinna shapes high frequencies differently from the front and behind.
			front, back: Hrtf_Filter
			hrtf_lookup(set, 0, 0, &front)
			hrtf_lookup(set, 180, 0, &back)
			// Front and back arrive with matching ITD/ILD; only the spectrum tells them apart.
			high := audio_hrtf_spectral_distance(front.fir[0], back.fir[0], f32(rate), 2000, 14000)
			low := audio_hrtf_spectral_distance(front.fir[0], back.fir[0], f32(rate), 200, 800)
			testing.expectf(t, high > 4 && high > 2*low, "%d Hz: front and behind must differ spectrally above 2 kHz (%.1f dB vs %.1f dB below 800 Hz)", rate, high, low)
			// Interpolation stays continuous across a measured azimuth.
			a, b: Hrtf_Filter
			hrtf_lookup(set, 44.99, 0, &a)
			hrtf_lookup(set, 45.01, 0, &b)
			diff: f32
			for ear in 0 ..< 2 { for k in 0 ..< HRTF_TAPS { diff = max(diff, abs(a.fir[ear][k] - b.fir[ear][k])) } }
			testing.expectf(t, diff < 0.01, "interpolation must be continuous (%.4f)", diff)
		}
		testing.expectf(t, abs(itd[0] - itd[1]) < 0.00003, "ITD must not depend on the output rate (%.4f vs %.4f ms)", itd[0]*1000, itd[1]*1000)
		testing.expect(t, hrtf_parse(transmute([]u8)string("KHRT-broken"), 48000) == nil, "corrupt data must be rejected")
	}

	@(test)
	audio_hrtf_renders_itd_and_ild :: proc(t: ^testing.T) {
		rates := [?]u32{44100, 48000}
		for rate in rates {
			path := fmt.tprintf("bin/audio-hrtf-noise-%d.wav", rate)
			defer os.remove(path)
			if !testing.expect(t, audio_hrtf_write_noise(path, int(rate), 1)) { return }
			audio := audio_create(nil, audio_test_settings(), true, rate)
			if !testing.expect(t, audio != nil && audio.hrtf != nil) { return }
			defer audio_destroy(audio)
			camera := camera_init(1)
			audio_update_listener(audio, &camera)
			frames := int(rate) / 4
			buffer := make([]f32, frames*2)
			defer delete(buffer)
			sides := [2]f32{1, -1}
			for side in sides {
				audio_stop_all(audio)
				ma.engine_read_pcm_frames(&audio.engine, raw_data(buffer), u64(frames), nil)
				testing.expect(t, audio_play(audio, path, position = {10*side, 0, 0}, spatial = true))
				ma.engine_read_pcm_frames(&audio.engine, raw_data(buffer), u64(frames), nil)
				left, right: f64
				for i in 0 ..< frames { left += f64(buffer[i*2])*f64(buffer[i*2]); right += f64(buffer[i*2+1])*f64(buffer[i*2+1]) }
				ild := 10 * math.log10(side > 0 ? right/left : left/right)
				lag := audio_hrtf_itd_samples(buffer, frames, 60)
				itd := f32(lag) / f32(rate) * side
				label := side > 0 ? "right" : "left"
				testing.expectf(t, ild > 6, "%d Hz %s: the near ear must be louder (ILD %.1f dB)", rate, label, ild)
				testing.expectf(t, itd > 0.0004 && itd < 0.0009, "%d Hz %s: the far ear must lag by 0.4-0.9 ms (lag %d samples)", rate, label, lag)
			}
		}
	}

	// Drive a node directly (no engine) so every block is under the test's control.
	audio_hrtf_render_node :: proc(node: ^Spatial_Node, azimuths: []f32, block: int, signal: []f32) -> (max_step: f32) {
		output := make([]f32, block*2)
		defer delete(output)
		previous: [2]f32
		first := true
		for azimuth, b in azimuths {
			spatial_node_publish(node, {spatial = true, hrtf = true, gain = 0.5, azimuth = azimuth}, b == 0)
			spatial_node_render(node, raw_data(signal[b*block*2:]), raw_data(output), block)
			for i in 0 ..< block {
				for ear in 0 ..< 2 {
					v := output[i*2 + ear]
					if !first { max_step = max(max_step, abs(v - previous[ear])) }
					previous[ear] = v
				}
				first = false
			}
		}
		return
	}

	@(test)
	audio_hrtf_direction_changes_are_smooth :: proc(t: ^testing.T) {
		set := hrtf_load(48000)
		if !testing.expect(t, set != nil) { return }
		defer hrtf_destroy(set)
		block, blocks := 480, 40
		signal := make([]f32, block*blocks*2)
		defer delete(signal)
		for i in 0 ..< block*blocks {
			v := 0.5 * math.sin(2 * math.PI * 500 * f32(i) / 48000)
			signal[i*2], signal[i*2+1] = v, v
		}
		static_max: f32
		for azimuth in ([?]f32{0, 90, -90, 180, 45}) {
			node := new(Spatial_Node); defer free(node)
			node.hrtf_set = set
			azimuths := make([]f32, blocks); defer delete(azimuths)
			for &a in azimuths { a = azimuth }
			static_max = max(static_max, audio_hrtf_render_node(node, azimuths, block, signal))
		}
		// Worst case: the direction jumps every 10 ms block.
		node := new(Spatial_Node); defer free(node)
		node.hrtf_set = set
		jumps := make([]f32, blocks); defer delete(jumps)
		pattern := [?]f32{0, 90, -90, 180, 45}
		for &a, i in jumps { a = pattern[i % len(pattern)] }
		jump_max := audio_hrtf_render_node(node, jumps, block, signal)
		// A ramped delay shifts pitch slightly (<10%) while turning; a hard filter switch
		// would jump by the signal amplitude (over 10x the steady step).
		testing.expectf(t, jump_max <= static_max * 1.35, "direction jumps must crossfade without clicks (step %.4f vs steady %.4f)", jump_max, static_max)
		// Non-spatial voices bypass the HRTF bit for bit.
		bypass := new(Spatial_Node); defer free(bypass)
		bypass.hrtf_set = set
		spatial_node_publish(bypass, {hrtf = true}, true)
		output := make([]f32, block*2); defer delete(output)
		spatial_node_render(bypass, raw_data(signal), raw_data(output), block)
		same := true
		for v, i in output { if v != signal[i] { same = false } }
		testing.expect(t, same, "non-spatial audio must pass through untouched")
	}

	@(test)
	audio_hrtf_settings_persist_and_import_is_neutral :: proc(t: ^testing.T) {
		path := "bin/audio-settings-hrtf-test.json"
		defer os.remove(path)
		testing.expect(t, DEFAULT_AUDIO_SETTINGS.spatial == .HRTF, "HRTF is the default, matching Krunker's panner")
		settings := Audio_Settings{master = 0.5, effects = 1, footsteps = 1, ui = 1, spatial = .STEREO}
		testing.expect(t, audio_settings_save(settings, path) && audio_settings_load(path) == settings, "the spatial mode must survive restarting")
		data, err := os.read_entire_file_from_path(path, context.allocator)
		testing.expect(t, err == nil && strings.contains(string(data), `"STEREO"`), "the mode is stored by name")
		delete(data)
		testing.expect(t, os.write_entire_file(path, string(`{"master":1,"effects":1,"footsteps":1,"ui":1}`)) == nil)
		testing.expect(t, audio_settings_load(path).spatial == .HRTF, "older settings files default to HRTF")
		testing.expect(t, os.write_entire_file(path, string(`{"master":1,"effects":1,"footsteps":1,"ui":1,"spatial":"QUADRAPHONIC"}`)) == nil)
		testing.expect(t, audio_settings_load(path).spatial == .HRTF, "unknown modes fall back to HRTF")
		// Krunker has no spatial-audio setting: importing or exporting must not touch it.
		values := menuui.Settings_Values{fov = menuui.DEFAULT_FOV, sensitivity = 1, mouse_dpi = 1600, audio_volumes = {0.8, 1, 0.8, 0.6, 0.3}, spatial_audio = 1}
		_, import_error := menuui.krunker_settings_import(&values, KRUNKER_SAMPLE_EXPORT)
		testing.expect(t, len(import_error) == 0 && values.spatial_audio == 1, "a Krunker import keeps the chosen spatial mode")
		exported := menuui.krunker_settings_export(values, context.temp_allocator)
		testing.expect(t, !strings.contains(exported, "spatial") && !strings.contains(exported, "hrtf"), "exports stay Krunker-compatible")
		// Settings > Audio > Spatial audio: the dropdown edits the draft and Save applies it.
		client := Client{audio_settings = DEFAULT_AUDIO_SETTINGS}
		client.menu.page = .SETTINGS
		menuui.prepare_settings(&client.menu, menuui.View{audio_volumes = {0.8, 1, 0.8, 0.6, 0.3}, spatial_audio = i32(client.audio_settings.spatial)})
		testing.expect(t, client.menu.settings_draft.spatial_audio == 0, "the draft starts from the saved mode")
		menuui.activate(&client.menu, {action = {kind = .SPATIAL_AUDIO, index = 1}})
		testing.expect(t, client.audio_settings.spatial == .HRTF, "choosing a mode only edits the draft")
		menu_apply_action(&client, {kind = .SETTINGS_SAVE})
		testing.expect(t, client.audio_settings.spatial == .STEREO && client.audio_settings_dirty, "Save applies and persists the spatial mode")
	}

	@(test)
	audio_hrtf_cpu_benchmark :: proc(t: ^testing.T) {
		path := "bin/audio-hrtf-bench.wav"
		defer os.remove(path)
		if !testing.expect(t, audio_hrtf_write_noise(path, 48000, 4)) { return }
		// Every mode with levelling off and on; HRTF also while turning (all voices crossfade).
		Run :: struct { mode: Spatial_Mode, turning, levelling: bool }
		runs := [?]Run{
			{.STEREO, false, false}, {.STEREO, false, true}, {.HRTF, false, false}, {.HRTF, false, true},
			{.HRTF, true, false}, {.HRTF, true, true}, {.SURROUND, false, false}, {.SURROUND, false, true},
		}
		for run in runs {
			settings := audio_test_settings(spatial = run.mode)
			settings.levelling = run.levelling
			audio := audio_create(nil, settings, true, 48000, 8)
			if !testing.expect(t, audio != nil) { return }
			defer audio_destroy(audio)
			camera := camera_init(1)
			audio_update_listener(audio, &camera)
			for i in 0 ..< MAX_AUDIO_VOICES {
				angle := f32(i) * 2 * math.PI / MAX_AUDIO_VOICES
				testing.expect(t, audio_play(audio, path, position = {40*math.cos(angle), f32(i % 5) - 2, 40*math.sin(angle)}, spatial = true, priority = 4))
			}
			channels := int(ma.engine_get_channels(&audio.engine))
			buffer := make([]f32, 480*channels)
			defer delete(buffer)
			callbacks := 200
			ma.engine_read_pcm_frames(&audio.engine, raw_data(buffer), 480, nil)
			start := time.tick_now()
			for c in 0 ..< callbacks {
				if run.turning {
					camera.rotation.y = f32(c) * 0.05   // ~3 degrees per 10 ms: every voice crossfades.
					audio_update_listener(audio, &camera)
				}
				ma.engine_read_pcm_frames(&audio.engine, raw_data(buffer), 480, nil)
			}
			us := f64(time.duration_microseconds(time.tick_since(start))) / f64(callbacks)
			fmt.printf("[Audio bench] %v%s, levelling %s, %d ch: %d voices, %.1f us per 480-frame (10 ms) callback at 48 kHz\n",
				run.mode, run.turning ? " (listener turning)" : "", run.levelling ? "on" : "off", channels, MAX_AUDIO_VOICES, us)
			// The real-time budget is 10 000 us. Timing is only asserted for optimised
			// builds; -o:none test runs just report it.
			when ODIN_OPTIMIZATION_MODE != .None {
				testing.expectf(t, us < 2500, "%v mixing must stay far below real time (%.1f us)", run.mode, us)
			}
		}
	}

	// Offline listening demo: a gunshot circling the listener, stereo vs HRTF.
	// odin test src/client -define:AUDIO_SPATIAL_DEMO=true -define:ODIN_TEST_NAMES=main.audio_spatial_demo_render
	when #config(AUDIO_SPATIAL_DEMO, false) {
		@(test)
		audio_spatial_demo_render :: proc(t: ^testing.T) {
			os.make_directory("bin/spatial-audio")
			modes := [?]Spatial_Mode{.STEREO, .HRTF}
			names := [?]string{"gunshot_circle_stereo.wav", "gunshot_circle_hrtf.wav"}
			rate, seconds := 48000, 16
			renders: [2][]f32
			peak: f32
			for mode, m in modes {
				audio := audio_create(nil, audio_test_settings(spatial = mode), true)
				if !testing.expect(t, audio != nil) { return }
				defer audio_destroy(audio)
				camera := camera_init(1)
				audio_update_listener(audio, &camera)
				pcm := make([]f32, rate*seconds*2)
				renders[m] = pcm
				// 0-8 s: two horizontal laps clockwise (front, right, behind, left) at
				// 15 units. 8-16 s: two vertical laps (front, above, behind, below).
				shots := seconds * 4
				for shot in 0 ..< shots {
					seconds_in := f32(shot) / 4
					phase := math.mod(seconds_in, 4) / 4 * 2 * math.PI
					position: shared.Vec3
					if seconds_in < 8 { position = {15*math.sin(phase), 0, -15*math.cos(phase)} }
					else { position = {0, 15*math.sin(phase), -15*math.cos(phase)} }
					audio_play(audio, "assets/sound/weapon_1.mp3", position = position, spatial = true, priority = 4)
					frames := rate / 4
					ma.engine_read_pcm_frames(&audio.engine, &pcm[shot*frames*2], u64(frames), nil)
				}
				for v in pcm { peak = max(peak, abs(v)) }
			}
			// One gain for both files (peak at -1 dBFS) keeps their loudness comparable.
			scale := 0.89 / max(peak, 1e-6)
			for pcm, m in renders {
				defer delete(pcm)
				bytes := make([]u8, 44 + len(pcm)*2)
				defer delete(bytes)
				put_u32 :: proc(b: []u8, at: int, v: u32) { b[at], b[at+1], b[at+2], b[at+3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24) }
				put_u16 :: proc(b: []u8, at: int, v: u16) { b[at], b[at+1] = u8(v), u8(v >> 8) }
				copy(bytes[0:], "RIFF"); put_u32(bytes, 4, u32(36 + len(pcm)*2)); copy(bytes[8:], "WAVEfmt ")
				put_u32(bytes, 16, 16); put_u16(bytes, 20, 1); put_u16(bytes, 22, 2)
				put_u32(bytes, 24, u32(rate)); put_u32(bytes, 28, u32(rate*4)); put_u16(bytes, 32, 4); put_u16(bytes, 34, 16)
				copy(bytes[36:], "data"); put_u32(bytes, 40, u32(len(pcm)*2))
				for v, i in pcm { put_u16(bytes, 44 + i*2, transmute(u16)i16(clamp(v * scale, -1, 1) * 32767)) }
				out := fmt.tprintf("bin/spatial-audio/%s", names[m])
				testing.expect(t, os.write_entire_file(out, bytes) == nil, out)
				fmt.printf("[Audio demo] wrote %s\n", out)
			}
		}
	}
}
