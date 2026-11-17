package main

import "core:strings"
import menuui "../menu"
import shared "../shared"
import kproto "../krunker"

// Krunker's in-game chat (krunkbox current.analysis.js):
//   - ZP() near line 273287 appends a line to #chatList, first dropping the
//     oldest while the list holds 35. A line lives chatTimer seconds (0 = no
//     timer) and is then removed outright: Krunker has no fade (the per-frame
//     loop near line 274836 only removes expired elements).
//   - Zr() near line 273395 formats a line: player messages are "<name>: <text>"
//     with the name in white (or the server's name colour) and the text in
//     .chatMsg rgba(255,255,255,0.7); types 1 and 4 are plain .chatMsg text;
//     type 2 is coloured system text (default #fc03ec). Player messages are
//     dropped while Settings > Chat > Show Player Messages is off; the
//     profanity filter (Uy.clean) runs on the text of every type but trades.
//   - Each line carries a tab: -1 every tab, 0 Global, 1 Team; outside team
//     modes Zr forces -1. Only lines for the current tab (Krunker's `ab`,
//     switched by the #chatSwitch button) and -1 are shown.
//   - Binds: chatKey (Enter) focuses #chatInput; pressing it again sends a
//     non-empty value with CHAT_MESSAGE and blurs. Keys typed into the input
//     never reach gameplay binds (keydown handler near line 249667).
// Krunker's CSS (.chatItem): 14px text, 5px/10px padding, 4px radius,
// rgba(0,0,0,chatBGOp) background, 10px left and bottom margins, 240px max
// width; #chatHolder is 280px wide; #chatInput is 18px text on rgba(0,0,0,0.4)
// with the placeholder "Enter Message".
CHAT_MAX_LINES :: 35
CHAT_TEXT_BYTES :: 256
CHAT_NAME_BYTES :: 48
CHAT_SYSTEM_COLOR :: shared.Vec4{0xfc / 255.0, 0x03 / 255.0, 0xec / 255.0, 1}
CHAT_MESSAGE_COLOR :: shared.Vec4{1, 1, 1, 0.7}
CHAT_NAME_COLOR :: shared.Vec4{1, 1, 1, 1}
// Krunker's "You're sending messages too fast. Slow down." (errors.eventBus.rateLimited).
CHAT_TOO_FAST_TEXT :: "You're sending messages too fast. Slow down."

Chat_Line_Kind :: enum { PLAYER, PLAIN, SYSTEM }

Chat_Line :: struct {
	kind: Chat_Line_Kind,
	tab: i32, // -1 every tab, 0 Global, 1 Team.
	name: [CHAT_NAME_BYTES]u8,
	name_length: int,
	text: [CHAT_TEXT_BYTES]u8,
	text_length: int,
	color, name_color: shared.Vec4,
	life: f32, // Seconds left; 0 keeps the line (chatTimer 0).
}

Chat :: struct {
	lines: [CHAT_MAX_LINES]Chat_Line,
	count: int,
	open: bool,
	team: bool, // Krunker's `ab`: false Global, true Team.
	input: [kproto.KRUNKER_CHAT_MAX_LENGTH]u8,
	input_length: int,
	last_send: f64,
	has_sent: bool,
	// Set by the key callbacks while the input is open, consumed once per frame.
	submit, cancel, blur, toggle_team: bool,
	backspace: int,
	caret: f32,
	// The chat key's state last frame, so holding it never reopens the input.
	last_key: bool,
}

chat_line_name :: proc(line: ^Chat_Line) -> string { return string(line.name[:line.name_length]) }
chat_line_text :: proc(line: ^Chat_Line) -> string { return string(line.text[:line.text_length]) }
chat_input_text :: proc(chat: ^Chat) -> string { return string(chat.input[:chat.input_length]) }

// Copies `text` for display: Krodin's UI font is ASCII, so other code points
// and control characters become '?' and spaces.
chat_store :: proc(dst: []u8, text: string) -> int {
	n := 0
	for r in text {
		if n >= len(dst) { break }
		switch {
		case r >= 32 && r < 127: dst[n] = u8(r)
		case r == '\t' || r == '\n' || r == '\r': dst[n] = ' '
		case r < 32 || r == 127: continue
		case: dst[n] = '?'
		}
		n += 1
	}
	return n
}

chat_remove :: proc(chat: ^Chat, index: int) {
	if index < 0 || index >= chat.count { return }
	copy(chat.lines[index:chat.count - 1], chat.lines[index + 1:chat.count])
	chat.count -= 1
}

// ZP: drop the oldest lines while 35 are listed, then append with chatTimer.
chat_push :: proc(chat: ^Chat, line: Chat_Line, settings: menuui.Chat_Settings) {
	for chat.count >= CHAT_MAX_LINES { chat_remove(chat, 0) }
	chat.lines[chat.count] = line
	chat.lines[chat.count].life = menuui.chat_settings_validate(settings).timer
	chat.count += 1
}

chat_clear :: proc(chat: ^Chat) {
	chat.lines = {}
	chat.count = 0
}

chat_tick :: proc(chat: ^Chat, delta: f32) {
	chat.caret += delta
	for i := 0; i < chat.count; {
		line := &chat.lines[i]
		if line.life > 0 {
			line.life -= delta
			if line.life <= 0 { chat_remove(chat, i); continue }
		}
		i += 1
	}
}

// Zr's filter: Uy.clean splits on \b and, for each token that equals a listed
// word (case-insensitive), drops /[^a-zA-Z0-9|\$|\@]|\^/ characters and turns
// every remaining word character into '*'. Allocated in the temp allocator.
chat_filter_clean :: proc(text: string) -> string {
	word :: proc(c: u8) -> bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' }
	builder := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(text) {
		start := i
		if !word(text[i]) {
			for i < len(text) && !word(text[i]) { i += 1 }
			strings.write_string(&builder, text[start:i])
			continue
		}
		for i < len(text) && word(text[i]) { i += 1 }
		token := text[start:i]
		if !chat_filter_listed(token) { strings.write_string(&builder, token); continue }
		for c in transmute([]u8)token { if c != '_' { strings.write_byte(&builder, '*') } }
	}
	return strings.to_string(builder)
}

chat_filter_listed :: proc(token: string) -> bool {
	if len(token) == 0 || len(token) > 32 { return false }
	lower: [32]u8
	for c, i in transmute([]u8)token { lower[i] = c >= 'A' && c <= 'Z' ? c + 32 : c }
	key := string(lower[:len(token)])
	for listed in CHAT_FILTER_WORDS { if listed == key { return true } }
	return false
}

// Krodin's own: ranked lobbies never show a server link. Any token that names
// a Krunker game server (a krunker.io link, a ws/wss address or a game=
// parameter) is replaced. Allocated in the temp allocator.
CHAT_HIDDEN_LINK :: "[link hidden]"
chat_hide_server_links :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(text) {
		if text[i] == ' ' { strings.write_byte(&builder, ' '); i += 1; continue }
		start := i
		for i < len(text) && text[i] != ' ' { i += 1 }
		token := text[start:i]
		if chat_server_link(token) { strings.write_string(&builder, CHAT_HIDDEN_LINK) } else { strings.write_string(&builder, token) }
	}
	return strings.to_string(builder)
}

chat_server_link :: proc(token: string) -> bool {
	lower := strings.to_lower(token, context.temp_allocator)
	return strings.contains(lower, "krunker.io") || strings.contains(lower, "ws://") || strings.contains(lower, "wss://") || strings.contains(lower, "game=") || strings.contains(lower, "gameid=")
}

Chat_Add :: struct {
	kind: Chat_Line_Kind,
	tab: i32,
	name, text: string,
	color, name_color: shared.Vec4,
}

// Adds a line the way Zr does. `teams` is whether the mode has teams; outside
// team modes every line belongs to every tab. Returns whether a line was added.
chat_add :: proc(chat: ^Chat, settings: menuui.Chat_Settings, entry: Chat_Add, teams: bool, ranked: bool = false) -> bool {
	settings := menuui.chat_settings_validate(settings)
	if entry.kind == .PLAYER && settings.hide_messages { return false }
	text := entry.text
	if settings.filter { text = chat_filter_clean(text) }
	if ranked { text = chat_hide_server_links(text) }
	line := Chat_Line{kind = entry.kind, tab = teams ? clamp(entry.tab, -1, 1) : -1, color = entry.color, name_color = entry.name_color}
	if line.color == (shared.Vec4{}) { line.color = entry.kind == .SYSTEM ? CHAT_SYSTEM_COLOR : CHAT_MESSAGE_COLOR }
	if line.name_color == (shared.Vec4{}) { line.name_color = CHAT_NAME_COLOR }
	name := len(entry.name) > 0 ? entry.name : "unknown" // Zr: is(a || "unknown").
	if entry.kind == .PLAYER { line.name_length = chat_store(line.name[:], name) }
	line.text_length = chat_store(line.text[:], text)
	chat_push(chat, line, settings)
	return true
}

chat_system :: proc(chat: ^Chat, settings: menuui.Chat_Settings, text: string, color: shared.Vec4 = {}) {
	chat_add(chat, settings, {kind = .SYSTEM, tab = -1, text = text, color = color}, false)
}

// CSS colours as Krunker sends them: "#rgb" or "#rrggbb"; anything else is unset.
chat_parse_color :: proc(text: string) -> shared.Vec4 {
	hex := strings.trim_space(text)
	if len(hex) == 0 || hex[0] != '#' { return {} }
	digit :: proc(c: u8) -> (u32, bool) {
		switch c {
		case '0'..='9': return u32(c - '0'), true
		case 'a'..='f': return u32(c - 'a' + 10), true
		case 'A'..='F': return u32(c - 'A' + 10), true
		}
		return 0, false
	}
	value: u32
	switch len(hex) {
	case 4:
		for c in transmute([]u8)hex[1:] { d, ok := digit(c); if !ok { return {} }; value = value << 8 | d << 4 | d }
	case 7:
		for c in transmute([]u8)hex[1:] { d, ok := digit(c); if !ok { return {} }; value = value << 4 | d }
	case: return {}
	}
	return shared.hex_to_vec(i32(value))
}

// The chat's current tab for a mode: Team only exists in team modes.
chat_tab :: proc(chat: ^Chat, teams: bool) -> i32 { return teams && chat.team ? 1 : 0 }

chat_line_visible :: proc(chat: ^Chat, line: ^Chat_Line, teams: bool) -> bool {
	return line.tab == -1 || line.tab == chat_tab(chat, teams)
}

chat_open :: proc(chat: ^Chat) {
	chat.open = true
	chat.submit, chat.cancel, chat.blur, chat.toggle_team, chat.backspace = false, false, false, false, 0
	chat.caret = 0
}

// Escape cancels and clears; other closes (a click, leaving the game) keep the
// text in the box like Krunker's blurred #chatInput.
chat_close :: proc(chat: ^Chat, clear_input: bool) {
	chat.open = false
	chat.submit, chat.cancel, chat.blur, chat.toggle_team, chat.backspace = false, false, false, false, 0
	if clear_input { chat.input_length = 0 }
}

// Typed characters: printable ASCII up to #chatInput's maxlength of 70.
chat_type :: proc(chat: ^Chat, c: rune) -> bool {
	if !chat.open || c < 32 || c >= 127 || chat.input_length >= len(chat.input) { return false }
	chat.input[chat.input_length] = u8(c)
	chat.input_length += 1
	chat.caret = 0
	return true
}

chat_apply_backspace :: proc(chat: ^Chat) {
	chat.input_length = max(0, chat.input_length - chat.backspace)
	if chat.backspace > 0 { chat.caret = 0 }
	chat.backspace = 0
}

// Krunker's send interval (see kproto.KRUNKER_CHAT_SEND_INTERVAL).
chat_send_allowed :: proc(chat: ^Chat, now: f64) -> bool {
	return !chat.has_sent || now - chat.last_send > kproto.KRUNKER_CHAT_SEND_INTERVAL
}

chat_mark_sent :: proc(chat: ^Chat, now: f64) { chat.last_send, chat.has_sent = now, true }
