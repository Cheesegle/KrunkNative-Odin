package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import shared "../shared"
import kproto "../krunker"

when ODIN_TEST {
	@(private = "file")
	countdown_near :: proc(a, b: f32, tolerance: f32 = 1e-3) -> bool { return abs(a - b) <= tolerance }

	@(test)
	round_countdown_animates_like_animate_text :: proc(t: ^testing.T) {
		size, opacity := round_countdown_style(0)
		testing.expect(t, size == 300 && opacity == 1, "starts at 300px, opaque")
		size, _ = round_countdown_style(0.075)
		testing.expect(t, countdown_near(size, 210), "shrinks 1.2px per ms")
		size, _ = round_countdown_style(0.15)
		testing.expect(t, countdown_near(size, 120), "down to 0.4x after 150 ms")
		size, opacity = round_countdown_style(0.4)
		testing.expect(t, countdown_near(size, 120) && opacity == 1, "holds at the minimum")
		_, opacity = round_countdown_style(0.65)
		testing.expect(t, countdown_near(opacity, 0.5), "fades over the last 100 ms")
		_, opacity = round_countdown_style(0.7)
		testing.expect(t, opacity == 0)
	}

	@(test)
	round_countdown_counts_the_last_three_seconds :: proc(t: ^testing.T) {
		testing.expect(t, round_countdown_number(3.01) == 0 && round_countdown_number(3) == 3 && round_countdown_number(2.01) == 3)
		testing.expect(t, round_countdown_number(2) == 2 && round_countdown_number(0.4) == 1 && round_countdown_number(0) == 0 && round_countdown_number(-1) == 0)
	}

	// Local Practice: the real warmup clock (game_update_match) drives 3-2-1,
	// each number once, then the match goes live.
	@(test)
	round_countdown_local_practice_warmup :: proc(t: ^testing.T) {
		client := new(Client); defer free(client)
		client.local_practice, client.game.ready = true, true
		client.game.match = {phase = .WARMUP, phase_remaining = 3.5}
		shown: [dynamic]i32; defer delete(shown)
		times: [dynamic]f64; defer delete(times)
		now: f64 = 10
		went_live: f64
		for _ in 0..<50 { // 5 s in 0.1 s steps
			// The warmup branch only; a live match would need a map.
			if client.game.match.phase == .WARMUP { shared.game_update_match(&client.game, 0.1) }
			now += 0.1
			if went_live == 0 && client.game.match.phase == .LIVE { went_live = now }
			before := client.round_countdown.started
			client_round_countdown_update(client, now)
			if client.round_countdown.started != before {
				append(&shown, client.round_countdown.number)
				append(&times, now)
			}
		}
		testing.expectf(t, len(shown) == 3 && shown[0] == 3 && shown[1] == 2 && shown[2] == 1, "3-2-1 once each, got %v", shown)
		if len(times) == 3 {
			testing.expectf(t, abs(times[0] - 10.5) < 0.11 && abs(times[1] - 11.5) < 0.11 && abs(times[2] - 12.5) < 0.11, "one second apart, ending a second before live: %v", times)
			testing.expect(t, abs(went_live - 13.5) < 0.11, "the match goes live as the 1 ends")
		}
		testing.expect(t, !client.round_countdown.visible, "gone once the 700 ms life is over")
		// A live match never counts down.
		client.round_countdown = {}
		client.game.match = {phase = .LIVE, phase_remaining = 2, time_remaining = 2}
		client_round_countdown_update(client, 20)
		testing.expect(t, !client.round_countdown.visible)
	}

	// Native server: MATCH_STATE carries the warmup left in time_remaining.
	@(test)
	round_countdown_native_match_state_warmup :: proc(t: ^testing.T) {
		server: shared.Game
		server.match = {phase = .WARMUP, phase_remaining = 2.4, time_remaining = 240}
		state := shared.packet_match_state_from_game(&server)
		buf: [256]byte
		size := shared.packet_serialize_match_state(buf[:], &state)
		decoded, ok := shared.packet_deserialize_match_state(buf[:size])
		testing.expect(t, ok && decoded.time_remaining == 2.4)
		client := new(Client); defer free(client)
		client.net.connected, client.game.ready = true, true
		client.game.match.time_remaining = 240
		shared.packet_apply_match_state(&client.game, &decoded)
		testing.expect(t, client.game.match.phase == .WARMUP && countdown_near(client.game.match.phase_remaining, 2.4) && client.game.match.time_remaining == 240, "the match clock is kept")
		client_round_countdown_update(client, 1)
		testing.expect(t, client.round_countdown.visible && client.round_countdown.number == 3)
		// LIVE: time_remaining is the match clock again.
		server.match = {phase = .LIVE, time_remaining = 239}
		state = shared.packet_match_state_from_game(&server)
		shared.packet_apply_match_state(&client.game, &state)
		testing.expect(t, client.game.match.time_remaining == 239)
		testing.expect(t, client_round_countdown_derived(client, 2) == 0)
	}

	@(test)
	round_countdown_live_gmsg :: proc(t: ^testing.T) {
		client := new(Client); defer free(client)
		client.krunker.connected = true
		world := &client.krunker_world
		defer kproto.krunker_world_reset(world)
		world.received_at = 100
		// The server's own number: shown at once, whatever the timer says.
		testing.expect(t, kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"gmsg", "match starting in", "0:03", i64(3)}))
		testing.expect(t, world.countdown == .STARTING && world.countdown_number == 3 && world.countdown_number_revision == 1)
		client_round_countdown_update(client, 100)
		testing.expect(t, client.round_countdown.visible && client.round_countdown.number == 3 && client.round_countdown.started == 100)
		// The timer reaching 2 does not double up the server's numbers...
		client_round_countdown_update(client, 101.1)
		testing.expect(t, client.round_countdown.number == 3, "a recent server number suppresses Krodin's")
		world.received_at = 101.2
		testing.expect(t, kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"gmsg", "match starting in", "0:02", i64(2)}))
		client_round_countdown_update(client, 101.2)
		testing.expect(t, client.round_countdown.number == 2 && client.round_countdown.started == 101.2)
		// No number, a zero or a fraction: nothing from the server.
		testing.expect(t, kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"gmsg", "intermission", "0:10", i64(0)}))
		testing.expect(t, kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"gmsg", "intermission", "0:10", f64(1.5)}))
		testing.expect(t, world.countdown_number_revision == 2)

		// Krodin's fallback for an intermission without server numbers.
		world.received_at = 200
		testing.expect(t, kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"gmsg", "intermission", "0:05"}))
		client_round_countdown_update(client, 201.9)
		testing.expect(t, !client.round_countdown.visible || client.round_countdown.started < 200)
		client_round_countdown_update(client, 202.1)
		testing.expect(t, client.round_countdown.visible && client.round_countdown.number == 3 && client.round_countdown.started == 202.1)
		client_round_countdown_update(client, 203.1)
		testing.expect(t, client.round_countdown.number == 2)
		client_round_countdown_update(client, 204.1)
		testing.expect(t, client.round_countdown.number == 1)
		// ulm (moves unlocked) ends it.
		testing.expect(t, kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"ulm"}))
		testing.expect(t, client_round_countdown_derived(client, 204.5) == 0)
		// A reconnect resets the world's counter without a phantom number.
		world.countdown_number_revision = 0
		client.round_countdown.visible = false
		client_round_countdown_update(client, 300)
		testing.expect(t, !client.round_countdown.visible)
	}

	// Hidden-window frames of one number's life at 1280x720 and 1920x1080.
	// Writes bin/round-countdown/<size>-<moment>.png.
	@(test)
	round_countdown_renders_number_life :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		test_gpu := test_gpu_open(320, 180, "Countdown")
		if !testing.expect(t, test_gpu.ok, "no GPU device for the test") do return
		defer test_gpu_close(&test_gpu, t)
		g_test_gpu = &test_gpu
		window := test_gpu.window
		os.make_directory("bin/round-countdown")
		client := new(Client); defer free(client)
		client.ui = ui_init()
		defer { overlay_fini(); ui_fini(client.ui); resource_cache_fini() }

		Moment :: struct { name: string, number: i32, t: f64 }
		moments := [?]Moment{
			{"3-appear", 3, 0},
			{"3-shrinking", 3, 0.075},
			{"3-settled", 3, 0.3},
			{"2-settled", 2, 0.3},
			{"1-settled", 1, 0.3},
			{"1-fading", 1, 0.65},
		}
		sizes := [2][2]i32{{1280, 720}, {1920, 1080}}
		for size in sizes {
			W, H := size[0], size[1]
			framebuffer := test_gpu_target(W, H)
			test_gpu_use_target(framebuffer, W, H)
			g_active_texture = 0
			client.viewport_width, client.viewport_height = W, H
			gpu_set_target(test_gpu_current_target(), W, H)
			// White text pixels and dark stroke pixels in each frame.
			bright := make([]int, len(moments)); defer delete(bright)
			dark := make([]int, len(moments)); defer delete(dark)
			top_of_white: int
			for moment, i in moments {
				client.round_countdown = {number = moment.number, started = 50, visible = true}
				gpu_set_clear_color({0.38, 0.55, 0.72}) // a stand-in sky
				gpu_clear(color = true, depth = false)
				ui_update(client.ui, f32(W), f32(H))
				round_countdown_render(client, 50 + moment.t)
				pixels := make([]u8, int(W*H*3)); defer delete(pixels)
				test_read_rgb(0, 0, W, H, raw_data(pixels))
				path := fmt.ctprintf("bin/round-countdown/%dx%d-%s.png", W, H, moment.name)
				testing.expect(t, stbi.write_png(path, W, H, 3, &pixels[(H-1)*W*3], -W*3) != 0)
				for y in 0..<int(H) {
					for x in 0..<int(W) {
						o := ((int(H)-1-y)*int(W)+x)*3
						r, g, b := int(pixels[o]), int(pixels[o+1]), int(pixels[o+2])
						if r > 230 && g > 230 && b > 230 {
							bright[i] += 1
							if i == 2 && (top_of_white == 0 || y < top_of_white) { top_of_white = y }
						}
						if r < 70 && g < 70 && b < 70 { dark[i] += 1 }
					}
				}
			}
			testing.expectf(t, bright[0] > bright[1] && bright[1] > bright[2]*2, "%dx%d: the number shrinks from 300px to 120px (%v)", W, H, bright)
			testing.expectf(t, bright[2] > 0 && dark[2] > 0, "%dx%d: white digits with the #363636 stroke", W, H)
			testing.expectf(t, bright[5] == 0 && dark[5] < dark[4], "%dx%d: the last 100 ms fade out", W, H)
			// timerText sits at 26% of the height.
			digit_height := int(f32(120) * min(f32(W)/2550, f32(H)/1350))
			testing.expectf(t, abs(top_of_white - (int(f32(H)*0.26) - digit_height/2)) < digit_height/2, "%dx%d: centred on 26%% of the height (top %d)", W, H, top_of_white)
			test_gpu_target_destroy(&framebuffer)
		}
		testing.expect(t, test_gpu_no_error())
	}
}
