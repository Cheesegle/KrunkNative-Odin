package main

import "core:fmt"
import "core:math"
import "core:strings"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import clay "../third_party/clay"
import menuui "../menu"
import shared "../shared"
import kproto "../krunker"

// Krunker sizes its HUD by scaleUI (0.7 on desktop) where Krodin's ui.scale
// uses 1.5 (ui_update), so Krunker's CSS pixels are ui.scale * 1.5 / 0.7.
CHAT_KRUNKER_SCALE :: 1.5 / 0.7
// Krodin's own placement: #chatHolder's container rules are not in the dumps,
// so the box sits 20 px above Krodin's bottom-left class/health panel
// (overlay.odin: 35 px inset plus the 103 px class icon), at its left edge.
CHAT_BOTTOM_INSET :: 35 + 103 + 20
CHAT_LEFT_INSET :: 20

// The bound chat key, read directly: gameplay reads (client_action_down) are
// off while the input is open.
client_chat_key_down :: proc(client: ^Client, read: proc(glfw.WindowHandle, i32) -> bool = client_binding_down) -> bool {
	for code in client.bindings[.CHAT] {
		if code != 0 && code != menuui.BINDING_SCROLL && read(client.window, code) { return true }
	}
	return false
}

client_chat_teams :: proc(client: ^Client) -> bool {
	return client.game.mode != nil && client.game.mode.config.teams
}

// GLFW key events while the input is open. Text arrives through the character
// callback (menu_character); these are the editing and closing keys.
client_chat_key :: proc(client: ^Client, key, action: i32) {
	chat := &client.chat
	if !chat.open || action == glfw.RELEASE { return }
	switch key {
	case glfw.KEY_BACKSPACE: chat.backspace += 1 // Repeats while held.
	case glfw.KEY_ESCAPE: if action == glfw.PRESS { chat.cancel = true }
	case glfw.KEY_ENTER, glfw.KEY_KP_ENTER: if action == glfw.PRESS { chat.submit = true }
	// Krodin's own: Krunker switches Global/Team with the #chatSwitch button.
	case glfw.KEY_TAB: if action == glfw.PRESS { chat.toggle_team = true }
	case:
		// Krunker: pressing the chat bind while typing sends (pressButton).
		if action == glfw.PRESS && (client.bindings[.CHAT][0] == key || client.bindings[.CHAT][1] == key) { chat.submit = true }
	}
}

// A mouse press while typing: the chat bind sends; any other button closes the
// input and keeps its text, as clicking the game blurs Krunker's #chatInput.
client_chat_mouse :: proc(client: ^Client, button, action: i32) {
	chat := &client.chat
	if !chat.open || action != glfw.PRESS { return }
	code := -button - 1
	if client.bindings[.CHAT][0] == code || client.bindings[.CHAT][1] == code { chat.submit = true } else { chat.blur = true }
}

// Characters typed while the input is open. Nothing typed after a send is kept,
// like Krunker's input, which is blurred by the keydown that sent it.
client_chat_character :: proc(client: ^Client, codepoint: rune) -> bool {
	chat := &client.chat
	if !chat.open { return false }
	if !chat.submit && !chat.cancel { chat_type(chat, codepoint) }
	return true
}

// Opens and closes the input and runs queued edits once per frame. Returns
// whether Escape closed the input this frame, so it does not open the menu.
client_chat_update :: proc(client: ^Client, now: f64, read: proc(glfw.WindowHandle, i32) -> bool = client_binding_down) -> (escape_used: bool) {
	chat := &client.chat
	key := client_chat_key_down(client, read)
	defer chat.last_key = key
	if chat.open {
		chat_apply_backspace(chat)
		if chat.toggle_team { chat.toggle_team = false; client_chat_switch_tab(client) }
		if chat.cancel {
			chat_close(chat, true)
			escape_used = true
		} else if !client.mouse_state.locked || chat.blur {
			chat_close(chat, false)
		} else if chat.submit {
			chat.submit = false
			client_chat_submit(client, now)
		}
		return
	}
	if client.mouse_state.locked && key && !chat.last_key { chat_open(chat) }
	return
}

// window.switchChat: Team and Global exist only in team modes; the switch
// announces the new tab. Krunker says "... Text & Voice Chat"; Krodin has no
// voice chat.
client_chat_switch_tab :: proc(client: ^Client) {
	chat := &client.chat
	if !client_chat_teams(client) { chat.team = false; return }
	chat.team = !chat.team
	chat_system(chat, client.hud_settings.chat, chat.team ? "Team Text Chat" : "Global Text Chat")
}

client_chat_submit :: proc(client: ^Client, now: f64) {
	chat := &client.chat
	if chat.input_length == 0 { chat_close(chat, true); return } // Krunker: if (chatInput.value != "").
	if !chat_send_allowed(chat, now) {
		chat_system(chat, client.hud_settings.chat, CHAT_TOO_FAST_TEXT)
		return // The text stays in the box to send again.
	}
	text := strings.clone(chat_input_text(chat), context.temp_allocator)
	team := chat_tab(chat, client_chat_teams(client)) == 1
	chat_close(chat, true)
	chat_mark_sent(chat, now)
	switch {
	case client.krunker.connected:
		// Krodin's own: a ranked lobby's server link must never leave the client.
		if client.krunker_world.is_ranked && chat_has_server_link(text) {
			chat_system(chat, client.hud_settings.chat, "Server links can't be sent in ranked matches.")
			return
		}
		krunker_ws_queue_chat(&client.krunker, text, team)
		if !krunker_ws_flush_chat(&client.krunker) { client.krunker.connected = false; krunker_ws_set_status(client, "Krunker WebSocket send failed.") }
	case client.net.connected:
		// Krodin's native server checks length, rate and team itself and echoes
		// the message back to us with everyone else's.
		clean := kproto.krunker_chat_clean_outgoing(text)
		if !shared.net_chat_text_valid(clean) { return }
		if !net_client_send_chat(&client.net, clean, team) { client.net.connected = false }
	case:
		client_chat_local(client, text, team)
	}
}

chat_has_server_link :: proc(text: string) -> bool {
	for token in strings.split(text, " ", context.temp_allocator) { if chat_server_link(token) { return true } }
	return false
}

// Krodin's own: Local Practice has no server, so the box echoes your messages
// on this PC and answers its own commands.
client_chat_local :: proc(client: ^Client, text: string, team: bool) {
	chat := &client.chat
	settings := client.hud_settings.chat
	if strings.has_prefix(text, "/") {
		end := strings.index_byte(text, ' ')
		command := strings.to_lower(end < 0 ? text : text[:end], context.temp_allocator)
		switch command {
		case "/help": chat_system(chat, settings, "Krodin Local Practice chat stays on this PC. Commands: /help, /clear.")
		case "/clear": chat_clear(chat)
		case: chat_system(chat, settings, fmt.tprintf("Unknown command: %s. Type /help for Krodin's practice commands.", command))
		}
		return
	}
	chat_add(chat, settings, {kind = .PLAYER, tab = team ? 1 : 0, name = "You", text = text}, client_chat_teams(client))
}

// A CHAT line from Krodin's native server. Names follow the scoreboard: "You",
// otherwise "Player <uid>"; the server's own lines are system text.
client_chat_receive_native :: proc(client: ^Client, sender: i32, team: bool, text: string) {
	if sender == shared.NET_CHAT_SYSTEM {
		chat_system(&client.chat, client.hud_settings.chat, text)
		return
	}
	name := fmt.tprintf("Player %d", sender)
	if player := client_find_player(client, sender); player != nil && player.is_you { name = "You" }
	chat_add(&client.chat, client.hud_settings.chat, {kind = .PLAYER, tab = team ? 1 : 0, name = name, text = text}, client_chat_teams(client))
}

// ADD_CHAT from a live lobby. Chat text is never written to the network log.
krunker_client_receive_chat :: proc(client: ^Client, packet: []kproto.Krunker_Msgpack_Value) {
	message, ok := kproto.krunker_chat_decode(packet)
	if !ok || message.type == .TRADE { return } // Trade requests need Krunker's trade window.
	kind: Chat_Line_Kind
	switch message.type {
	case .PLAYER: kind = .PLAYER
	case .PLAIN, .NOTICE: kind = .PLAIN
	case .SYSTEM, .TRADE: kind = .SYSTEM
	}
	entry := Chat_Add{kind = kind, tab = message.tab, name = message.name, text = message.text, name_color = chat_parse_color(message.name_color)}
	if kind == .SYSTEM { entry.color = chat_parse_color(message.color) }
	chat_add(&client.chat, client.hud_settings.chat, entry, client_chat_teams(client), client.krunker_world.is_ranked)
}

// One wrapped piece of a chat line: text from one colour run on one row.
Chat_Piece :: struct {
	text: string,
	color: shared.Vec4,
	x: f32,
	row: int,
}

// Lays a line out like a .chatItem: runs wrap at word boundaries inside the
// 240 px pill (220 px of text); a word wider than that breaks by character.
chat_layout_line :: proc(ui: ^UI, line: ^Chat_Line, size, max_width: f32) -> (pieces: [dynamic]Chat_Piece, rows: int, width: f32) {
	pieces = make([dynamic]Chat_Piece, context.temp_allocator)
	Run :: struct { text: string, color: shared.Vec4 }
	runs: [3]Run
	run_count := 0
	if line.kind == .PLAYER {
		runs[0] = Run{chat_line_name(line), line.name_color}
		runs[1] = Run{": ", CHAT_NAME_COLOR}
		runs[2] = Run{chat_line_text(line), line.color}
		run_count = 3
	} else {
		runs[0] = Run{chat_line_text(line), line.color}
		run_count = 1
	}
	x: f32
	row := 0
	for run in runs[:run_count] {
		text := run.text
		for len(text) > 0 {
			// A chunk is a word and the spaces after it.
			end := 0
			for end < len(text) && text[end] != ' ' { end += 1 }
			for end < len(text) && text[end] == ' ' { end += 1 }
			chunk := text[:end]
			word := strings.trim_right(chunk, " ")
			chunk_width := ui_measure_text(ui, chunk, size)
			if x > 0 && x + ui_measure_text(ui, word, size) > max_width {
				row += 1; x = 0
			}
			if x == 0 && ui_measure_text(ui, word, size) > max_width {
				// Break the word by character.
				count := 0
				for count < len(chunk) && ui_measure_text(ui, chunk[:count + 1], size) <= max_width { count += 1 }
				count = max(count, 1)
				append(&pieces, Chat_Piece{text = chunk[:count], color = run.color, x = 0, row = row})
				width = max(width, ui_measure_text(ui, chunk[:count], size))
				text = text[count:]
				if len(text) > 0 { row += 1 }
				continue
			}
			append(&pieces, Chat_Piece{text = chunk, color = run.color, x = x, row = row})
			width = max(width, x + ui_measure_text(ui, word, size))
			x += chunk_width
			text = text[end:]
		}
	}
	return pieces, row + 1, width
}

// The font's CSS "normal" line height and baseline for `size` pixels.
chat_font_metrics :: proc(size: f32) -> (line_height, baseline: f32) {
	ascent, descent, gap: i32
	stb_font_metrics(&ascent, &descent, &gap)
	units := f32(max(1, ascent - descent))
	return size * f32(ascent - descent + gap) / units, size * (f32(gap) * 0.5 + f32(ascent)) / units
}

chat_draw_text :: proc(ui: ^UI, color: shared.Vec4, text: string, x, y, size, k: f32, outline: bool, opacity: f32) {
	if outline {
		// .chatTextOutline: 1px text-shadow in rgba(0,0,0,0.5) on four diagonals.
		shadow := shared.Vec4{0, 0, 0, 0.5 * opacity}
		for offset in ([4][2]f32{{-1, -1}, {1, -1}, {-1, 1}, {1, 1}}) { ui_fill_text(ui, shadow, text, x + offset[0] * k, y + offset[1] * k, size) }
	}
	ui_fill_text(ui, {color.r, color.g, color.b, color.a * opacity}, text, x, y, size)
}

// Draws #chatList (shwChat: always, or only while typing) and, while typing,
// #chatInput. Lines are newest at the bottom; older ones scroll out of the
// chatHeight box at the top.
chat_render :: proc(client: ^Client) {
	chat := &client.chat
	ui := client.ui
	settings := menuui.chat_settings_validate(client.hud_settings.chat)
	s := ui.scale
	k := s * CHAT_KRUNKER_SCALE
	left := CHAT_LEFT_INSET * s
	bottom := ui.height - CHAT_BOTTOM_INSET * s
	input_size := 18 * k
	input_line, input_baseline := chat_font_metrics(input_size)
	input_height := input_line + 10 * k
	list_bottom := bottom - input_height
	teams := client_chat_teams(client)
	mode := menuui.Chat_Mode(settings.mode)
	if (mode == .ALWAYS || mode == .WHILE_FOCUSED && chat.open) && settings.height > 0 && settings.opacity > 0 && chat.count > 0 {
		list_height := settings.height * 100 * k
		size := 14 * k
		line_height, baseline := chat_font_metrics(size)
		ui_clip_set(ui, clay.BoundingBox{left, list_bottom - list_height, 280 * k, list_height})
		y := list_bottom
		for i := chat.count - 1; i >= 0 && y > list_bottom - list_height; i -= 1 {
			line := &chat.lines[i]
			if !chat_line_visible(chat, line, teams) { continue }
			pieces, rows, width := chat_layout_line(ui, line, size, 220 * k)
			pill_height := f32(rows) * line_height + 10 * k
			y -= 10 * k // .chatItem margin-bottom
			top := y - pill_height
			x := left + 10 * k // margin-left
			if settings.background > 0 { ui_round_rect(ui, {0, 0, 0, settings.background * settings.opacity}, x, top, width + 20 * k, pill_height, 4 * k) }
			for piece in pieces {
				chat_draw_text(ui, piece.color, piece.text, x + 10 * k + piece.x, top + 5 * k + f32(piece.row) * line_height + baseline, size, k, settings.text_outline, settings.opacity)
			}
			y = top
		}
		ui_clip_clear(ui)
	}
	if !chat.open { return }
	width := 280 * k
	top := bottom - input_height
	ui_fill_rect(ui, {0, 0, 0, 0.4}, left, top, width, input_height)
	x := left + 10 * k
	text_y := top + 5 * k + input_baseline
	if teams {
		// Krodin's tab label, standing in for Krunker's #chatSwitch icon.
		label := chat.team ? "[Team] " : "[All] "
		x += ui_fill_text(ui, chat.team ? shared.Vec4{0x9e / 255.0, 0xeb / 255.0, 0x56 / 255.0, 1} : CHAT_MESSAGE_COLOR, label, x, text_y, input_size)
	}
	room := left + width - 10 * k - x
	if chat.input_length == 0 {
		ui_fill_text(ui, {1, 1, 1, 0.7}, "Enter Message", x, text_y, input_size)
	} else {
		text := chat_input_text(chat)
		// Keep the end of a long message (and the caret) in view.
		for len(text) > 1 && ui_measure_text(ui, text, input_size) > room - 8 * k { text = text[1:] }
		x += ui_fill_text(ui, {1, 1, 1, 1}, text, x, text_y, input_size)
	}
	if math.mod(chat.caret, 1.0) < 0.5 { ui_fill_text(ui, {1, 1, 1, 1}, "|", x, text_y, input_size) }
}
