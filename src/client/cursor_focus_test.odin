package main

import "base:runtime"
import "core:testing"
import glfw "vendor:glfw"

when ODIN_TEST {
	@(test)
	cursor_focus_state_releases_on_focus_loss :: proc(t: ^testing.T) {
		state: Cursor_Focus
		testing.expect(t, cursor_focus_may_capture(&state) && !cursor_focus_take_release(&state, true), "a focused window plays normally")
		cursor_focus_event(&state, false)
		testing.expect(t, !cursor_focus_may_capture(&state), "no capture while unfocused (spawn finishing during alt-tab)")
		testing.expect(t, cursor_focus_take_release(&state, true), "losing focus while playing leaves play")
		testing.expect(t, !cursor_focus_take_release(&state, true), "the loss is handled once")
		cursor_focus_event(&state, true)
		testing.expect(t, cursor_focus_may_capture(&state) && !cursor_focus_take_release(&state, true), "focus back: capture allowed again, nothing pending")
		// A loss and regain within one frame still pauses, as Krunker's lost
		// pointer lock does.
		cursor_focus_event(&state, false)
		cursor_focus_event(&state, true)
		testing.expect(t, cursor_focus_may_capture(&state) && cursor_focus_take_release(&state, true), "a quick alt-tab still pauses")
		// In a menu the cursor is already free; nothing to do.
		cursor_focus_event(&state, false)
		testing.expect(t, !cursor_focus_take_release(&state, false), "menus are left alone")
	}

	// The GLFW side: a captured window that loses focus ends in CURSOR_NORMAL
	// on the main menu, so GLFW stops answering WM_SETCURSOR with its blank
	// cursor. Uses the real focus callback on a hidden window.
	@(test)
	cursor_focus_loss_frees_glfw_cursor :: proc(t: ^testing.T) {
		context = runtime.default_context()
		if !testing.expect(t, bool(glfw.Init())) do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		window := glfw.CreateWindow(320, 240, "Cursor focus", nil, nil)
		if !testing.expect(t, window != nil) do return
		defer glfw.DestroyWindow(window)
		client := Client{window = window}
		g_client = &client
		defer g_client = nil
		client.menu.page = .CLASSES
		glfw.SetInputMode(window, glfw.CURSOR, glfw.CURSOR_DISABLED)
		client.mouse_state.locked = true
		testing.expect(t, !client_cursor_focus_update(&client) && glfw.GetInputMode(window, glfw.CURSOR) == glfw.CURSOR_DISABLED, "no focus change: play continues")

		client_window_focus_changed(window, 0)
		testing.expect(t, client_cursor_focus_update(&client), "focus loss while playing pauses")
		testing.expect(t, glfw.GetInputMode(window, glfw.CURSOR) == glfw.CURSOR_NORMAL && !client.mouse_state.locked, "the cursor is NORMAL again")
		testing.expect(t, client.menu.page == .HOME && client.menu.previous.escape, "the pause menu shows, as after Escape")

		// Other windows' focus events don't count.
		client_window_focus_changed(nil, 0)
		client_window_focus_changed(window, 1)
		testing.expect(t, cursor_focus_may_capture(&client.cursor_focus) && !client_cursor_focus_update(&client), "regaining focus doesn't recapture by itself")
		testing.expect(t, glfw.GetInputMode(window, glfw.CURSOR) == glfw.CURSOR_NORMAL)
	}
}
