package krunker

// Krunker's in-game chat packets (krunkbox current.analysis.js):
//   - client -> server CHAT_MESSAGE "ct" (opcode table near line 112123), sent
//     by WW() near line 271072 as Zt.send(Oa.CHAT_MESSAGE, ab, text): `ab` is
//     the chat tab (0 Global, 1 Team; window.switchChat) and `text` is the
//     #chatInput value (maxlength="70" in index.html). Empty text is not sent.
//   - server -> client ADD_CHAT "ch" (near line 112276), handled by Zr(e, a,
//     t, r, n, s, o, l) near line 273395. Its arguments, in order:
//       [0] tab: -1 every tab, 0 Global, 1 Team (forced to -1 outside team modes)
//       [1] sender name (nil for system lines)
//       [2] text
//       [3] type: 0/nil "<name>: <text>", 1 and 4 plain text, 2 coloured
//           system text (default #fc03ec), 3 trade request
//       [4] text colour for type 2 ("#rrggbb")
//       [5] name colour (Settings > Loadout "Chat Name Color")
//       [6] the sender's account id, checked against the local mute list
//       [7] optional actions (e.g. [Join Queue] buttons)
//     Krunker's replay code (game.min.js `r.type=="ch"`) rewrites data[1] and
//     data[6], confirming the name and account-id positions.

KRUNKER_CHAT_SEND_OPCODE :: "ct"
KRUNKER_CHAT_RECV_OPCODE :: "ch"
// #chatInput maxlength="70" (both dumps' index.html).
KRUNKER_CHAT_MAX_LENGTH :: 70
// Krunker's chat-bind messages (g_t near line 273592): Date.now() - N4e <= 1500
// returns without sending. Krodin applies the same interval to typed chat.
KRUNKER_CHAT_SEND_INTERVAL :: 1.5

Krunker_Chat_Type :: enum i32 { PLAYER = 0, PLAIN = 1, SYSTEM = 2, TRADE = 3, NOTICE = 4 }

// A decoded "ch" packet. The strings point into the decoded packet.
Krunker_Chat_Message :: struct {
	tab: i32,
	name: string,
	text: string,
	type: Krunker_Chat_Type,
	color, name_color: string,
	account_id: i64,
	has_account: bool,
}

@(private = "file")
chat_int :: proc(value: Krunker_Msgpack_Value) -> (number: i64, ok: bool) {
	#partial switch v in value {
	case i64: return v, true
	case f64: return i64(v), true
	case bool: return v ? 1 : 0, true
	}
	return 0, false
}

// Decodes ["ch", tab, name, text, type, color, nameColor, accountId, actions].
// Missing trailing arguments take Zr's defaults (tab 0, player message).
krunker_chat_decode :: proc(packet: []Krunker_Msgpack_Value) -> (message: Krunker_Chat_Message, ok: bool) {
	if len(packet) < 4 { return }
	opcode, is_text := packet[0].(string)
	if !is_text || opcode != KRUNKER_CHAT_RECV_OPCODE { return }
	if tab, valid := chat_int(packet[1]); valid { message.tab = i32(clamp(tab, -1, 1)) }
	if name, valid := packet[2].(string); valid { message.name = name }
	// Zr runs is(t) on any value; a non-string text (an i18n key array is "chi") is skipped.
	text, text_ok := packet[3].(string)
	if !text_ok { return }
	message.text = text
	if len(packet) > 4 {
		if kind, valid := chat_int(packet[4]); valid && kind >= 0 && kind <= 4 { message.type = Krunker_Chat_Type(kind) }
	}
	if len(packet) > 5 { if color, valid := packet[5].(string); valid { message.color = color } }
	if len(packet) > 6 { if color, valid := packet[6].(string); valid { message.name_color = color } }
	if len(packet) > 7 { message.account_id, message.has_account = chat_int(packet[7]) }
	return message, true
}

// The text a "ct" packet carries: ASCII printable only (Krodin's chat font and
// input are ASCII), at most KRUNKER_CHAT_MAX_LENGTH bytes. Allocated in `allocator`.
krunker_chat_clean_outgoing :: proc(text: string, allocator := context.temp_allocator) -> string {
	out := make([dynamic]u8, 0, min(len(text), KRUNKER_CHAT_MAX_LENGTH), allocator)
	for i in 0..<len(text) {
		if len(out) >= KRUNKER_CHAT_MAX_LENGTH { break }
		c := text[i]
		if c >= 32 && c < 127 { append(&out, c) }
	}
	return string(out[:])
}

// Encodes ["ct", tab, text] with the trailer `counter` (the caller advances
// its counter with krunker_msgpack_counter_next only after a full send).
krunker_chat_encode :: proc(text: string, team: bool, counter: u8) -> ([]byte, bool) {
	clean := krunker_chat_clean_outgoing(text)
	if len(clean) == 0 { return nil, false }
	args := [2]Krunker_Msgpack_Value{krunker_msgpack_int(team ? 1 : 0), krunker_msgpack_string(clean)}
	return krunker_msgpack_encode_packet(KRUNKER_CHAT_SEND_OPCODE, args[:], counter)
}
