package main

import "core:testing"
import menuui "../menu"
import shared "../shared"

when ODIN_TEST {
	@(test)
	chat_native_lines_display :: proc(t: ^testing.T) {
		client: Client
		client.hud_settings.chat = menuui.DEFAULT_CHAT_SETTINGS
		client_chat_receive_native(&client, 4, false, "hello all")
		client_chat_receive_native(&client, shared.NET_CHAT_SYSTEM, false, "You're sending messages too fast. Slow down.")
		testing.expect_value(t, client.chat.count, 2)
		testing.expect(t, client.chat.lines[0].kind == .PLAYER && chat_line_name(&client.chat.lines[0]) == "Player 4" && chat_line_text(&client.chat.lines[0]) == "hello all")
		testing.expect(t, client.chat.lines[1].kind == .SYSTEM && client.chat.lines[1].color == CHAT_SYSTEM_COLOR)

		// The packet the client sends, and the one it reads back.
		buf: [shared.NET_CHAT_MAX_SIZE]byte
		size := shared.packet_serialize_chat(buf[:], 4, true, "push B")
		sender, team, text, ok := shared.packet_deserialize_chat(buf[:size])
		testing.expect(t, ok && sender == 4 && team && text == "push B")
	}
}
