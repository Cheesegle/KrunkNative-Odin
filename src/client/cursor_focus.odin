package main

import glfw "vendor:glfw"

// The game releases the cursor when the window loses focus.
//
// Testers lost the cursor in Borderless after alt-tab. The cause: Krodin kept
// GLFW in CURSOR_DISABLED when the window lost focus, and GLFW 3.4 (Win32
// updateCursorImage) answers every WM_SETCURSOR for a window in that mode with
// its transparent cursor, whether or not the window is focused. Windows sends
// WM_SETCURSOR to whatever window is under the pointer. An exclusive
// fullscreen window is minimised when it loses focus (GLFW's auto-iconify),
// so the pointer never rests on it. A borderless window stays on screen and
// covers the whole monitor, so after alt-tab the pointer was invisible
// everywhere the game showed, menus included. The same happened when a spawn
// finished while alt-tabbed out of the menu, because the game then captured
// the cursor without having focus.
//
// Krunker leaves play when the browser drops pointer lock, which alt-tab
// does: its pointerlockchange handler sets controls.enabled false and shows
// the menu (krunkbox game.min.js `document.addEventListener("pointerlockchange"`).
// Krodin now does the same. Losing focus while playing opens the pause menu
// with CURSOR_NORMAL, as Escape does, and the game doesn't capture the cursor
// while the window is unfocused.
Cursor_Focus :: struct {
	unfocused:       bool, // the last focus event was a loss
	release_pending: bool, // focus was lost since the last tick
}

// From GLFW's window focus callback.
cursor_focus_event :: proc "contextless" (state: ^Cursor_Focus, focused: bool) {
	state.unfocused = !focused
	if !focused { state.release_pending = true }
}

// Once per tick: true when focus was lost while the cursor is captured, so
// the game must leave play. Consumes the pending loss either way.
cursor_focus_take_release :: proc(state: ^Cursor_Focus, locked: bool) -> bool {
	pending := state.release_pending
	state.release_pending = false
	return pending && locked
}

// The game captures the cursor on its own (a spawn finishing after Play) only
// while the window has focus; otherwise it stays in the menu.
cursor_focus_may_capture :: proc(state: ^Cursor_Focus) -> bool { return !state.unfocused }

// Escape's pause: free the cursor and show the main menu.
client_pause_to_menu :: proc(client: ^Client) {
	if client.window != nil {
		glfw.SetInputMode(client.window, glfw.CURSOR, glfw.CURSOR_NORMAL)
		client.menu.previous.down = glfw.GetMouseButton(client.window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS
	}
	client.mouse_state.locked = false
	client.menu.page = .HOME
	client.menu.pressed = 0
	client.menu.previous.escape = true
}

// Leaves play when focus was lost since the last tick.
client_cursor_focus_update :: proc(client: ^Client) -> bool {
	if !cursor_focus_take_release(&client.cursor_focus, client.mouse_state.locked) { return false }
	client_pause_to_menu(client)
	return true
}
