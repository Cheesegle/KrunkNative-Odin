package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import kproto "../krunker"
import menuui "../menu"
import shared "../shared"

when ODIN_TEST {
	@(private = "file")
	read_text :: proc(path: string) -> string {
		data, err := os.read_entire_file(path, context.temp_allocator)
		return err == nil ? string(data) : ""
	}

	// The report has its sections, quotes settings and history, and never
	// contains a token, wherever one shows up (network lines, any section).
	@(test)
	crash_report_sections_present_and_redacted :: proc(t: ^testing.T) {
		old_diag, old_client, old_recent := g_diag, g_client, kproto.network_log_recent
		defer { g_diag, g_client, kproto.network_log_recent = old_diag, old_client, old_recent }
		defer kproto.network_log_clear_secrets()
		g_diag = {}
		g_diag.gpu_renderer_len = copy(g_diag.gpu_renderer[:], "Intel(R) UHD Graphics")
		g_diag.gpu_vendor_len = copy(g_diag.gpu_vendor[:], "Intel")
		g_diag.gl_reset_detection = true
		g_diag.gl_reset_last_check = time.tick_now()
		guest_secret := "GuestSecretValue1234567890"
		kproto.network_log_secret(guest_secret)
		g_diag.system_len = copy(g_diag.system_text[:], fmt.tprintf("Windows: 11 Professional 25H2 (10.0.26200.1)\nCPU: Test CPU %s\n", guest_secret))
		g_diag.monitor_len = copy(g_diag.monitor_text[:], "  0: Test Monitor, 1920x1080 @ 144 Hz, scale 125%, at 0,0, primary\n")

		client := new(Client)
		defer free(client)
		g_client = client
		client.display_mode = .Fullscreen
		client.fullscreen_resolution = {1920, 1080}
		client.vsync = true
		client.game_fps_limit = 240
		client.menu_fps_limit = menuui.MENU_FPS_LIMIT_MONITOR
		client.quality_settings = {shadows = true, shadow_quality = i32(menuui.Shadow_Quality.SHARP), lighting = i32(menuui.Lighting_Quality.HIGH)}
		client.visual_settings.night_mode = true
		client.audio_settings.spatial = .SURROUND

		for i in 0 ..< 300 { diag_frame_time(f32(i % 7) + 6.9) }
		diag_frame_time(612.5)
		diag_event(.FOCUS_LOST)
		diag_event(.WM_DISPLAYCHANGE, 1920, 1080)
		diag_event(.DISPLAY_MODE_APPLIED, i32(Display_Mode.Fullscreen), 1920 << 16 | 1080)
		diagnostics_watch(true, false)
		diag_event(.MAP_LOADED, 812)
		phase_frame_begin()
		phase_mark(.SWAP_BUFFERS)

		// Raw lines as a bug might let through; the report redacts them again.
		kproto.network_log_remember(`[Krunker][guest-auth] {"accessToken":"AccessTokenValueXYZ","ok":true}`)
		kproto.network_log_remember(fmt.tprintf("[Krunker][join] matchmaker url=wss://x/?token=%s&region=eu", guest_secret))
		kproto.network_log_remember("[Krunker][join] bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJlX3ZhbHVl done")

		path := "bin/crash-report-test/hang.log"
		os.remove(path)
		info := Crash_Info{title = "hang report (main loop stopped for 6 seconds)", stall_tick = time.tick_now(), live = true}
		if !testing.expect(t, crash_log_write(path, info), "the report must be written") do return
		report := read_text(path)
		for expected in ([]string{
			"Krodin hang report", "GPU reset: none detected",
			"== What happened ==", "== System ==", "== Settings ==", "== Recent frames ==", "== Recent events ==",
			"== Frame phases ==", "== GL messages ==", "== Network log",
			"Windows: 11", "GPU: Intel(R) UHD Graphics", "GL context: reset notification on", "Test Monitor, 1920x1080 @ 144 Hz",
			"RAM free:", "Display mode: Fullscreen (exclusive)", "Fullscreen size: 1920x1080", "V-Sync: on", "Game FPS limit: 240",
			"Menu FPS limit: monitor refresh rate", "Shadows: on", "Shadow quality: Sharp", "Lighting: High", "Night mode: on",
			"Spatial audio: Surround", "Settings menu open: yes",
			"Last 120 frame times", "612.5", "focus lost", "WM_DISPLAYCHANGE (1920x1080)", "display mode applied (fullscreen 1920x1080)",
			"settings menu opened", "map loaded (812 ms)", "main loop stopped", "swap buffers", "[Krunker][guest-auth]",
		}) {
			testing.expectf(t, strings.contains(report, expected), "report is missing %q:\n%s", expected, report)
		}
		for secret in ([]string{guest_secret, "AccessTokenValueXYZ", "eyJhbGciOiJIUzI1NiJ9", "c2lnbmF0dXJlX3ZhbHVl"}) {
			testing.expectf(t, !strings.contains(report, secret), "report leaks %q:\n%s", secret, report)
		}
		testing.expect(t, strings.contains(report, "[REDACTED"), "redaction markers show where tokens were")
		// Exactly the newest 120 frame times: 12 per row, 10 rows.
		frames_at := strings.index(report, "== Recent frames ==")
		events_at := strings.index(report, "== Recent events ==")
		if testing.expect(t, frames_at >= 0 && events_at > frames_at) {
			rows := strings.count(report[frames_at:events_at], "\n  ")
			testing.expect_value(t, rows, 10)
		}

		// A GPU reset goes first, prominently.
		testing.expect_value(t, gpu_reset_poll(GL_GUILTY_CONTEXT_RESET), u32(GL_GUILTY_CONTEXT_RESET))
		testing.expect_value(t, gpu_reset_poll(GL_GUILTY_CONTEXT_RESET), u32(0)) // Reported once.
		buffer: [REPORT_BUFFER_SIZE]u8
		text := crash_report_format(buffer[:], info)
		testing.expect(t, strings.has_prefix(text[strings.index(text, "\n") + 1:], "Build:"))
		testing.expectf(t, strings.contains(text, "*** GPU reset detected: guilty"), "reset line missing:\n%s", text)
		testing.expect(t, strings.index(text, "GPU reset detected") < strings.index(text, "== What happened =="), "the reset line comes before the sections")
		testing.expect(t, strings.contains(text, "GPU reset detected (guilty)"), "the reset is in the event history")
	}

	@(test)
	gpu_reset_report_and_message :: proc(t: ^testing.T) {
		old_diag := g_diag
		defer g_diag = old_diag
		g_diag = {}
		buffer: [256]u8
		testing.expect_value(t, gpu_reset_line(buffer[:], 0), "")
		testing.expect(t, strings.has_prefix(gpu_reset_line(buffer[:], GL_GUILTY_CONTEXT_RESET), "GPU reset detected: guilty"))
		testing.expect(t, strings.has_prefix(gpu_reset_line(buffer[:], GL_INNOCENT_CONTEXT_RESET), "GPU reset detected: innocent"))
		testing.expect(t, strings.has_prefix(gpu_reset_line(buffer[:], GL_UNKNOWN_CONTEXT_RESET), "GPU reset detected: unknown"))
		testing.expect(t, strings.has_prefix(gpu_reset_line(buffer[:], 0x1234), "GPU reset detected: unknown"))
		// Vulkan reports a lost device through the same flow.
		testing.expect(t, strings.contains(gpu_reset_line(buffer[:], GPU_RESET_DEVICE_LOST), "VK_ERROR_DEVICE_LOST"))
		testing.expect_value(t, gpu_reset_status_name(GPU_RESET_DEVICE_LOST), "device lost")

		testing.expect_value(t, gpu_reset_poll(0), u32(0))
		testing.expect_value(t, gpu_reset_poll(GL_INNOCENT_CONTEXT_RESET), u32(GL_INNOCENT_CONTEXT_RESET))
		path := "bin/crash-report-test/gpu-reset.log"
		os.remove(path)
		message_buffer: [1024]u8
		message := gpu_reset_handle(GL_INNOCENT_CONTEXT_RESET, path, message_buffer[:])
		testing.expect(t, strings.contains(message, "GPU reset detected: innocent"), message)
		testing.expect(t, strings.contains(message, "will close now"), "the player is told what happens next")
		report := read_text(path)
		testing.expectf(t, strings.contains(report, "Krodin GPU reset report") && strings.contains(report, "*** GPU reset detected: innocent"), "report:\n%s", report)
	}

	// The robust context is requested first; a failed creation retries
	// without it, and --no-gl-robustness never asks.
	@(private = "file")
	fake_window_calls: [dynamic; 4]bool
	@(private = "file")
	fake_window_robust_fails: bool

	@(private = "file")
	fake_create_window :: proc(width, height: i32, title: cstring, robust: bool) -> glfw.WindowHandle {
		append(&fake_window_calls, robust)
		if robust && fake_window_robust_fails { return nil }
		return glfw.WindowHandle(uintptr(0x1000))
	}

	@(test)
	client_create_window_falls_back_without_robustness :: proc(t: ^testing.T) {
		fake := fake_create_window
		clear(&fake_window_calls); fake_window_robust_fails = true
		window, robust := client_create_window(64, 64, "test", true, fake)
		testing.expect(t, window != nil && !robust, "falls back to a plain context")
		testing.expect(t, len(fake_window_calls) == 2 && fake_window_calls[0] && !fake_window_calls[1])

		clear(&fake_window_calls); fake_window_robust_fails = false
		window, robust = client_create_window(64, 64, "test", true, fake)
		testing.expect(t, window != nil && robust && len(fake_window_calls) == 1 && fake_window_calls[0])

		clear(&fake_window_calls)
		window, robust = client_create_window(64, 64, "test", false, fake)
		testing.expect(t, window != nil && !robust && len(fake_window_calls) == 1 && !fake_window_calls[0])
	}

	// A real hidden window with reset notification renders the map exactly
	// like a plain one, passes the batching self-test, and reports no reset.
	@(test)
	robust_context_renders_like_plain_context :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		old_lighting := g_lighting_config
		defer g_lighting_config = old_lighting
		old_diag := g_diag
		defer g_diag = old_diag

		Result :: struct { ok, granted, self_test: bool, status: u32, pixels: []u8, ms: f64 }
		render :: proc(t: ^testing.T, robust: bool) -> (result: Result) {
			if !testing.expect(t, bool(glfw.Init())) do return
			defer glfw.Terminate()
			glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
			glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
			glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
			glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
			window, _ := client_create_window(64, 64, "Robustness", robust)
			if !testing.expect(t, window != nil) do return
			defer glfw.DestroyWindow(window)
			glfw.MakeContextCurrent(window)
			gl.load_up_to(4, 5, glfw.gl_set_proc_address)
			gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
			defer resource_cache_fini()
			result.granted = gl_context_loses_on_reset()

			client := new(Client)
			defer free(client)
			client^ = Client{scene = scene_init(), render_batching = true}
			old_client := g_client
			g_client = client
			defer g_client = old_client
			map_inst, ok := shared.map_load_from_file("assets/maps/burg.json")
			if !testing.expect(t, ok && map_inst != nil) {
				scene_fini(client.scene)
				return
			}
			client.game.map_inst = map_inst
			client_load_current_map(client)
			result.self_test = client.batch_self_test_done && client.render_batching

			w, h := i32(320), i32(180)
			target := bench_target_init(w, h)
			camera := map_batch_self_test_camera(map_inst)
			gl.BindFramebuffer(gl.FRAMEBUFFER, u32(target.target))
			gl.Viewport(0, 0, w, h)
			gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
			result.pixels = make([]u8, int(w * h * 3))
			start := time.tick_now()
			FRAMES :: 60
			for _ in 0 ..< FRAMES {
				ui_flush()
				gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
				scene_render(client.scene, &camera, f32(w), f32(h), 0)
			}
			ui_flush()
			gl.ReadPixels(0, 0, w, h, gl.RGB, gl.UNSIGNED_BYTE, raw_data(result.pixels))
			result.ms = time.duration_milliseconds(time.tick_since(start)) / FRAMES
			result.status = u32(gl.GetGraphicsResetStatus())
			gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
			bench_target_fini(&target)
			client_unload_map(client)
			map_batch_destroy(client.scene)
			shared.map_destroy(map_inst)
			scene_fini(client.scene)
			result.ok = true
			return
		}
		plain := render(t, false)
		defer delete(plain.pixels)
		robust := render(t, true)
		defer delete(robust.pixels)
		if !testing.expect(t, plain.ok && robust.ok) do return
		testing.expect(t, !plain.granted, "a plain context has no reset notification")
		if !robust.granted { log.infof("This driver did not grant GL_LOSE_CONTEXT_ON_RESET; the game falls back cleanly") }
		testing.expect(t, plain.self_test && robust.self_test, "the batching self-test passes in both contexts")
		testing.expect_value(t, robust.status, u32(0))
		testing.expect(t, len(plain.pixels) == len(robust.pixels) && mem.compare(plain.pixels, robust.pixels) == 0, "robust and plain contexts render identical pixels")
		log.infof("burg 320x180 render: plain %.3f ms, robust %.3f ms per frame (reset notification granted: %v)", plain.ms, robust.ms, robust.granted)
	}

	// The history rings are fixed arrays written in place: nothing allocates
	// per frame, however many frames and events go by.
	@(test)
	diagnostics_rings_are_fixed_size :: proc(t: ^testing.T) {
		old_diag := g_diag
		defer g_diag = old_diag
		g_diag = {}
		#assert(type_of(g_diag.frame_ms) == [FRAME_TIME_RING_SIZE]f32)
		#assert(type_of(g_diag.events) == [EVENT_RING_SIZE]Diag_Event)
		#assert(FRAME_TIME_RING_SIZE >= REPORT_FRAME_TIMES && EVENT_RING_SIZE >= REPORT_EVENTS)
		tracking: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracking, context.allocator)
		defer mem.tracking_allocator_destroy(&tracking)
		context.allocator = mem.tracking_allocator(&tracking)
		context.temp_allocator = mem.tracking_allocator(&tracking)
		for i in 0 ..< 10_000 {
			phase_frame_begin()
			phase_mark(.TICK)
			diag_frame_time(f32(i))
			diagnostics_watch(i % 100 < 50, i % 300 < 10)
			if i % 37 == 0 { diag_event(.FOCUS_LOST, i32(i)) }
			phase_mark(.SWAP_BUFFERS)
		}
		testing.expect_value(t, tracking.total_allocation_count, i64(0))
		testing.expect_value(t, g_diag.frame_ms_head, u32(10_000))
		newest := g_diag.frame_ms[(g_diag.frame_ms_head - 1) % FRAME_TIME_RING_SIZE]
		testing.expect_value(t, newest, f32(9999))
		testing.expect_value(t, g_diag.frame_ms[(g_diag.frame_ms_head - FRAME_TIME_RING_SIZE) % FRAME_TIME_RING_SIZE], f32(10_000 - FRAME_TIME_RING_SIZE))
		testing.expect(t, g_diag.event_head > EVENT_RING_SIZE, "the event ring wrapped")
		testing.expect_value(t, g_diag.events[(g_diag.event_head - 1) % EVENT_RING_SIZE].kind, Diag_Event_Kind.FOCUS_LOST) // i = 9990
	}

	// Recovery and "still hung" lines are appended to an existing report.
	@(test)
	hang_recovery_line_is_appended :: proc(t: ^testing.T) {
		path := "bin/crash-report-test/recovery.log"
		testing.expect(t, crash_file_write(path, transmute([]u8)string("Krodin hang report\n")))
		testing.expect(t, crash_log_append(path, "\n== Recovery ==\nMain loop recovered after 7.4 s (frame 12 finished).\n"))
		report := read_text(path)
		testing.expectf(t, strings.has_prefix(report, "Krodin hang report\n") && strings.contains(report, "Main loop recovered after 7.4 s"), "%s", report)
	}
}
