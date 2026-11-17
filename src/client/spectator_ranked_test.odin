package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import menuui "../menu"
import clay "../third_party/clay"

when ODIN_TEST {
	@(private = "file")
	g_ranked_joins: int

	@(private = "file")
	spectator_ranked_join :: proc(client: ^Client, url: string) -> bool { g_ranked_joins += 1; return true }

	// Ranked forbids spectators, so the spectator build has no ranked entry
	// point: no queue start, rejoin, match join or menu check reaches a
	// socket. Normal and dev builds keep the queue.
	@(test)
	spectator_build_refuses_the_ranked_queue :: proc(t: ^testing.T) {
		testing.expect(t, ranked_allowed() == !KRODIN_SPECTATOR, "ranked is off only in the spectator build")
		// Never touch the machine's saved login or the network: no account
		// access (as the ranked tests stub it) and no ranked API origin.
		previous_select, previous_api := ranked_access_select, ranked_api_origin
		ranked_access_select = proc(client: ^Client, now: i64) -> bool { return false }
		ranked_api_origin = ""
		defer { ranked_access_select, ranked_api_origin = previous_select, previous_api }
		g_ranked_joins = 0
		client: Client
		defer { delete(client.ranked.rejoin_url) }
		// A leftover REJOIN offer (a keybind or stale menu action pressing
		// the ranked button) must not join a match from the spectator build.
		// Only the recording join is ever passed, never the live one.
		client.ranked.rejoin, client.ranked.rejoin_url = true, strings.clone("eu1.krunker.io")
		ranked_queue_action(&client, spectator_ranked_join)
		ranked_join_server(&client, "eu1.krunker.io", spectator_ranked_join)
		ranked_open(&client)
		testing.expect(t, g_ranked_joins == 0, "no join without account access in any build")
		if KRODIN_SPECTATOR {
			testing.expect(t, g_ranked_joins == 0 && client.ranked.popup == .NONE && client.ranked.phase == .IDLE, "no join, no prompt")
			testing.expect(t, client.ranked.job == nil && client.ranked.check == nil, "no queue socket and no connection check")
			testing.expect(t, !ranked_queue_begin(&client) && client.ranked.job == nil, "the queue never starts")
			// A FOUND match left in the state (a deep link into the queue) is not joined either.
			client.ranked.phase = .FOUND
			ranked_tick(&client, spectator_ranked_join)
			testing.expect(t, g_ranked_joins == 0, "ranked_tick never joins")
			client.ranked.phase = .IDLE
		} else {
			// Without account access the normal build reaches the join path and
			// asks to log in again (the socket itself needs a token).
			testing.expect(t, client.ranked.popup == .LOGIN_EXPIRED, "the normal build still offers ranked")
		}
	}

	// The home menu: the Ranked button only outside the spectator build.
	// Writes bin/spectator/home_menu_<build>_<W>x<H>.png.
	@(test)
	spectator_home_menu_has_no_ranked_button :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(1280, 720, "Home", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		ui := ui_init()
		defer { ui_fini(ui); resource_cache_fini() }
		state: menuui.State
		if !testing.expect(t, menuui.init(&state, menu_measure_text, ui)) do return
		defer menuui.fini(&state)

		// Activating the ranked action directly (a leftover control) opens
		// the ranked page only outside the spectator build.
		action := menuui.activate(&state, {action = {kind = .RANKED_OPEN}})
		testing.expect(t, (state.page == .RANKED) == !KRODIN_SPECTATOR && (action.kind == .RANKED_OPEN) == !KRODIN_SPECTATOR, "RANKED_OPEN is refused in the spectator build")
		state.page = .HOME

		view := menuui.View{resolution = "1280 x 720", sensitivity = 1, bindings = menuui.default_bindings(), visuals = menuui.DEFAULT_VISUAL_SETTINGS}
		os.make_directory("bin/spectator")
		build := KRODIN_SPECTATOR ? "spectator" : "client"
		for size in ([?][2]i32{{1280, 720}, {1920, 1080}}) {
			glfw.SetWindowSize(window, size[0], size[1])
			glfw.PollEvents()
			framebuffer, color: u32
			gl.GenFramebuffers(1, &framebuffer)
			gl.GenTextures(1, &color)
			gl.BindFramebuffer(gl.FRAMEBUFFER, framebuffer)
			gl.BindTexture(gl.TEXTURE_2D, color)
			gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGB8, size[0], size[1], 0, gl.RGB, gl.UNSIGNED_BYTE, nil)
			gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, color, 0)
			gl.BindTexture(gl.TEXTURE_2D, 0)
			g_active_texture = 0
			gl.Viewport(0, 0, size[0], size[1])
			ui_update(ui, f32(size[0]), f32(size[1]))
			menuui.build(&state, view, {}, ui.width, ui.height, 1.0/60.0)
			commands := menuui.build(&state, view, {}, ui.width, ui.height, 1.0/60.0)
			testing.expect(t, state.errors == 0 && state.page == .HOME)
			ranked_control := false
			for control in state.controls[:state.control_count] { if control.action.kind == .RANKED_OPEN { ranked_control = true } }
			ranked_label := false
			for command in commands.internalArray[:commands.length] {
				if command.commandType != .Text { continue }
				text := command.renderData.text.stringContents
				if string(text.chars[:text.length]) == "Ranked" { ranked_label = true }
			}
			testing.expectf(t, ranked_control == !KRODIN_SPECTATOR && ranked_label == !KRODIN_SPECTATOR && clay.GetElementData(clay.ID("Ranked")).found == !KRODIN_SPECTATOR,
				"Ranked button shown=%v/%v in the %s build at %v", ranked_control, ranked_label, build, size)
			gl.ClearColor(0.17, 0.17, 0.17, 1)
			ui_flush()
			gl.Clear(gl.COLOR_BUFFER_BIT)
			menu_render_commands(ui, commands)
			pixels := make([]u8, int(size[0]*size[1]*3))
			gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
			ui_flush()
			gl.ReadPixels(0, 0, size[0], size[1], gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
			testing.expect(t, stbi.write_png(fmt.ctprintf("bin/spectator/home_menu_%s_%dx%d.png", build, size[0], size[1]), size[0], size[1], 3, &pixels[(size[1]-1)*size[0]*3], -size[0]*3) != 0)
			delete(pixels)
			gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
			gl.DeleteTextures(1, &color)
			gl.DeleteFramebuffers(1, &framebuffer)
		}
	}
}
