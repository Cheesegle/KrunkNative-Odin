package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import menuui "../menu"

when ODIN_TEST {
	@(private="file")
	game_fps_test_client :: proc(client: ^Client) {
		client^ = {sensitivity = 1, audio_settings = DEFAULT_AUDIO_SETTINGS, visual_settings = menuui.DEFAULT_VISUAL_SETTINGS}
		client.monitor_cache.valid, client.monitor_cache.idle_frame_interval = true, 1.0/240
	}

	// A deterministic clock: sleeps overshoot by a pseudo-random amount up to
	// max_overshoot, yields advance by 20 us, and frames add their own work.
	@(private="file")
	Fake_Clock :: struct { t, max_overshoot: f64, seed: u32, sleeps, yields: int }

	@(private="file")
	fake_random :: proc(c: ^Fake_Clock) -> f64 {
		c.seed = c.seed*1664525 + 1013904223
		return f64(c.seed >> 8) / f64(1 << 24)
	}

	@(private="file")
	fake_clock :: proc(c: ^Fake_Clock, margin: f64 = FRAME_LIMIT_SPIN_MARGIN) -> Frame_Clock {
		return {
			data = c,
			now = proc(data: rawptr) -> f64 { return (^Fake_Clock)(data).t },
			sleep = proc(data: rawptr, seconds: f64) {
				c := (^Fake_Clock)(data)
				c.t += seconds + fake_random(c)*c.max_overshoot
				c.sleeps += 1
			},
			yield = proc(data: rawptr) { c := (^Fake_Clock)(data); c.t += 0.00002; c.yields += 1 },
			spin_margin = margin,
		}
	}

	@(test)
	game_fps_limit_values :: proc(t: ^testing.T) {
		// Krunker's Frame Cap: 0 = unlimited, 0-1200, non-zero values below 10 become 10.
		testing.expect(t, menuui.game_fps_limit_validate(0) == 0 && menuui.game_fps_limit_validate(-5) == 0, "0 and below are unlimited")
		testing.expect(t, menuui.game_fps_limit_validate(1) == 10 && menuui.game_fps_limit_validate(9) == 10, "Krunker raises non-zero caps below 10 to 10")
		testing.expect(t, menuui.game_fps_limit_validate(144) == 144 && menuui.game_fps_limit_validate(165) == 165, "typed values need not be multiples of 10")
		testing.expect(t, menuui.game_fps_limit_validate(5000) == 1200, "Krunker's maximum is 1200")
		testing.expect(t, menuui.game_fps_limit_from_value(143.6) == 144 && menuui.game_fps_limit_from_value(0.2) == 0 && menuui.game_fps_limit_from_value(5) == 10, "slider values round to whole frames")
		nan: f32 = 0
		nan = nan / nan
		testing.expect(t, menuui.game_fps_limit_from_value(nan) == 0 && menuui.game_fps_limit_from_value(1e30) == 1200, "NaN and huge values stay valid")
	}

	@(test)
	game_fps_limit_persistence :: proc(t: ^testing.T) {
		testing.expect(t, client_settings_defaults().game_fps_limit == 0 && client_settings_default_values().game_fps_limit == 0, "the default is unlimited, as in Krunker")
		path := "bin/client-settings-game-fps-test.json"
		defer os.remove(path)
		for limit in ([?]i32{0, 10, 60, 144, 240, 1200}) {
			settings := client_settings_defaults()
			settings.game_fps_limit = limit
			testing.expect(t, client_settings_save(settings, path))
			testing.expectf(t, client_settings_load(path).game_fps_limit == limit, "game FPS limit %d must survive restarting", limit)
		}
		testing.expect(t, os.write_entire_file(path, `{"version":1,"sensitivity":1.235,"menu_fps_limit":60}`) == nil)
		loaded := client_settings_load(path)
		testing.expect(t, loaded.game_fps_limit == 0 && loaded.menu_fps_limit == 60, "older settings files get unlimited and keep the menu limit")
		testing.expect(t, os.write_entire_file(path, `{"version":1,"game_fps_limit":5}`) == nil)
		testing.expect(t, client_settings_load(path).game_fps_limit == 10, "a cap below 10 loads as 10")
		testing.expect(t, os.write_entire_file(path, `{"version":1,"game_fps_limit":99999}`) == nil)
		testing.expect(t, client_settings_load(path).game_fps_limit == 1200, "a cap above 1200 loads as 1200")
		client: Client
		game_fps_test_client(&client)
		client.game_fps_limit = 240
		testing.expect(t, client_settings_snapshot(&client).game_fps_limit == 240, "the saved snapshot includes the game FPS limit")
	}

	@(test)
	game_fps_limit_interval :: proc(t: ^testing.T) {
		client: Client
		game_fps_test_client(&client)
		client.menu_fps_limit = 60
		client.game_fps_limit = 0
		client.mouse_state.locked = true
		testing.expect(t, client_game_frame_interval(&client) == 0 && client_idle_frame_interval(&client) == 0, "unlimited gameplay stays uncapped")
		client.game_fps_limit = 144
		testing.expect(t, abs(client_game_frame_interval(&client) - 1.0/144) < 1e-12, "the game limit paces captured play")
		testing.expect(t, client_idle_frame_interval(&client) == 0, "the menu limit never applies in play")
		client.mouse_state.locked = false
		testing.expect(t, client_game_frame_interval(&client) == 0, "the game limit never applies in menus")
		testing.expect(t, abs(client_idle_frame_interval(&client) - 1.0/60) < 1e-12, "menus keep their own limit")
		// Readiness flags (cleared during Krunker warmup) must not matter.
		client.mouse_state.locked = true
		client.krunker.connected, client.krunker_world.ready, client.game.ready = true, false, false
		testing.expect(t, abs(client_game_frame_interval(&client) - 1.0/144) < 1e-12, "the cap is decided by cursor capture alone")
		client.game_fps_limit = 3
		testing.expect(t, abs(client_game_frame_interval(&client) - 1.0/10) < 1e-12, "an unvalidated limit is still validated")

		clock_state := Fake_Clock{t = 5}
		clock := fake_clock(&clock_state)
		client.game_frame_deadline = 4
		client_frame_limit(&client.game_frame_deadline, 5, 0, clock)
		testing.expect(t, client.game_frame_deadline == 0 && clock_state.t == 5 && clock_state.sleeps == 0 && clock_state.yields == 0, "limit 0 waits for nothing and resets the schedule")
	}

	@(test)
	game_fps_limit_pacing_fake_clock :: proc(t: ^testing.T) {
		for rate in ([?]f64{60, 144, 240, 1000}) {
			interval := 1 / rate
			c := Fake_Clock{t = 100, max_overshoot = 0.0008, seed = 7}
			clock := fake_clock(&c)
			deadline: f64
			// The first deadline is one interval after the frame's start.
			client_frame_limit(&deadline, c.t, interval, clock)
			testing.expectf(t, abs(deadline - (100 + interval)) < 1e-12 && c.t >= deadline && c.t < deadline + 0.0001, "%v FPS: the first frame ends on its deadline", rate)

			// Steady frames: every start-to-start period is the interval, with
			// no drift over many frames, even though sleeps overshoot.
			N :: 2000
			first := c.t
			worst: f64
			for i in 0..<N {
				frame_start := c.t
				c.t += interval * 0.3 * fake_random(&c) // Frame work.
				client_frame_limit(&deadline, frame_start, interval, clock)
				worst = max(worst, abs(c.t - frame_start - interval))
				_ = i
			}
			mean := (c.t - first) / N
			testing.expectf(t, abs(mean - interval) < 1e-7, "%v FPS: mean period %.9f must equal %.9f", rate, mean, interval)
			testing.expectf(t, worst < 0.00005, "%v FPS: every period within 50 us (worst %.6f)", rate, worst)
		}

		// Drift correction: sleeps that overshoot past the spin margin make
		// single frames late, but the schedule is kept, so the next frame is
		// short and the mean rate holds.
		{
			interval := 1.0 / 240
			c := Fake_Clock{t = 0, max_overshoot = 0.0016, seed = 3}
			clock := fake_clock(&c)
			deadline: f64
			first := c.t
			N :: 2400
			for _ in 0..<N {
				frame_start := c.t
				c.t += 0.001
				client_frame_limit(&deadline, frame_start, interval, clock)
			}
			mean := (c.t - first) / N
			testing.expectf(t, abs(mean - interval) < 1e-6, "late wakeups must not lower the rate: mean %.9f vs %.9f", mean, interval)
		}

		// A long frame restarts the schedule instead of bursting to catch up.
		{
			interval := 1.0 / 144
			c := Fake_Clock{t = 0, seed = 11}
			clock := fake_clock(&c)
			deadline: f64
			for _ in 0..<10 { s := c.t; client_frame_limit(&deadline, s, interval, clock) }
			hitch_start := c.t
			c.t += interval * 3
			client_frame_limit(&deadline, hitch_start, interval, clock)
			testing.expect(t, c.t - hitch_start >= interval * 3 - 1e-9 && c.t - hitch_start < interval * 3 + 1e-9, "a long frame takes its own time and is not padded")
			after := c.t
			client_frame_limit(&deadline, after, interval, clock)
			testing.expectf(t, c.t - after >= interval - 1e-9, "the frame after a hitch is not shortened (%.6f)", c.t - after)
		}
	}

	@(test)
	game_fps_limit_draft :: proc(t: ^testing.T) {
		client: Client
		game_fps_test_client(&client)
		client.game_fps_limit = 0
		view := menuui.View{sensitivity = 1, game_fps_limit = client.game_fps_limit, visuals = menuui.DEFAULT_VISUAL_SETTINGS}
		state := &client.menu
		state.page = .SETTINGS
		menuui.prepare_settings(state, view)
		menuui.activate(state, {action = {kind = .GAME_FPS_LIMIT, value = 143.7}})
		testing.expect(t, state.settings_draft.game_fps_limit == 144 && client.game_fps_limit == 0, "the slider stages the limit in the draft")
		menuui.activate(state, {action = {kind = .SETTINGS_CANCEL}})
		testing.expect(t, client.game_fps_limit == 0 && !client.settings_dirty, "Cancel discards it")
		state.page = .SETTINGS
		menuui.prepare_settings(state, view)
		menuui.activate(state, {action = {kind = .GAME_FPS_LIMIT, value = 240}})
		menu_apply_action(&client, menuui.activate(state, {action = {kind = .SETTINGS_SAVE}}))
		testing.expect(t, client.game_fps_limit == 240 && client.settings_dirty && client_settings_snapshot(&client).game_fps_limit == 240, "Save applies and persists it")

		// Reset on the Video tab restores unlimited and leaves the menu limit's own default.
		draft := client_settings_default_values()
		draft.game_fps_limit, draft.menu_fps_limit = 240, 30
		menuui.settings_reset_tab(&draft, client_settings_default_values(), .VIDEO)
		testing.expect(t, draft.game_fps_limit == 0 && draft.menu_fps_limit == menuui.MENU_FPS_LIMIT_MONITOR, "Video reset restores both limits")
		draft.game_fps_limit = 240
		menuui.settings_reset_tab(&draft, client_settings_default_values(), .GAMEPLAY)
		testing.expect(t, draft.game_fps_limit == 240, "other tabs leave the game FPS limit alone")
	}

	@(test)
	game_fps_limit_krunker_mapping :: proc(t: ^testing.T) {
		values := client_settings_default_values()
		values.game_fps_limit = 60
		_, error := menuui.krunker_settings_import(&values, `{"updateRate":144}`)
		testing.expect(t, len(error) == 0 && values.game_fps_limit == 144, "Krunker's updateRate imports as the game FPS limit")
		_, _ = menuui.krunker_settings_import(&values, `{"updateRate":5}`)
		testing.expect(t, values.game_fps_limit == 10, "Krunker raises 5 to 10")
		_, _ = menuui.krunker_settings_import(&values, `{"updateRate":9000}`)
		testing.expect(t, values.game_fps_limit == 1200, "imports clamp to Krunker's 1200")
		_, _ = menuui.krunker_settings_import(&values, `{"fov":100}`)
		testing.expect(t, values.game_fps_limit == 0, "a missing updateRate resets to Krunker's default, unlimited")

		values.game_fps_limit = 240
		text := menuui.krunker_settings_export(values, context.temp_allocator)
		testing.expectf(t, strings.contains(text, `"updateRate":240`), "export writes updateRate: %s", text)
		values.game_fps_limit = 0
		text = menuui.krunker_settings_export(values, context.temp_allocator)
		testing.expect(t, !strings.contains(text, "updateRate"), "export omits the default, as Krunker does")
	}

	// Real time: the limiter must hit 120 and 240 FPS within 3% on average with
	// no frame taking twice its interval. About two seconds in total.
	@(test)
	game_fps_limit_pacing_real_time :: proc(t: ^testing.T) {
		client_set_timer_precision()
		defer client_restore_timer_precision()
		Real_Clock :: struct { start: time.Tick }
		real := Real_Clock{start = time.tick_now()}
		clock := client_frame_clock()
		clock.data = &real
		clock.now = proc(data: rawptr) -> f64 { return time.duration_seconds(time.tick_since((^Real_Clock)(data).start)) }
		for rate in ([?]f64{120, 240}) {
			interval := 1 / rate
			deadline: f64
			frames := int(rate) // One second each.
			long_frames: int
			longest: f64
			first := clock.now(clock.data)
			previous := first
			for _ in 0..<frames {
				frame_start := clock.now(clock.data)
				client_frame_limit(&deadline, frame_start, interval, clock)
				now := clock.now(clock.data)
				period := now - previous
				previous = now
				longest = max(longest, period)
				if period > 2 * interval { long_frames += 1 }
			}
			achieved := f64(frames) / (previous - first)
			error := abs(achieved - rate) / rate
			fmt.printf("[Game FPS limit] target %.0f achieved %.2f FPS (error %.2f%%), longest frame %.2f ms, high resolution timer %v\n", rate, achieved, error*100, longest*1000, client_precise_sleep_high_resolution())
			testing.expectf(t, error < 0.03, "%v FPS: achieved %.2f FPS, more than 3%% off", rate, achieved)
			testing.expectf(t, long_frames == 0, "%v FPS: %d frames took over twice the interval (longest %.2f ms)", rate, long_frames, longest*1000)
		}
	}
}
