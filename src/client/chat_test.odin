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
import kproto "../krunker"

when ODIN_TEST {
	@(private = "file")
	chat_test_sent: [dynamic][]byte
	@(private = "file")
	chat_test_result: Krunker_Send_Result

	@(private = "file")
	chat_test_send :: proc(state: ^Krunker_WS_State, packet: []byte) -> Krunker_Send_Result {
		if chat_test_result == .SENT { append(&chat_test_sent, slice_clone(packet)) }
		return chat_test_result
	}

	@(private = "file")
	slice_clone :: proc(bytes: []byte) -> []byte {
		out := make([]byte, len(bytes))
		copy(out, bytes)
		return out
	}

	@(private = "file")
	chat_test_sent_clear :: proc() {
		for packet in chat_test_sent { delete(packet) }
		delete(chat_test_sent)
		chat_test_sent = nil
	}

	@(test)
	chat_ct_packet_encodes_krunker_arguments :: proc(t: ^testing.T) {
		// ["ct", 0, "gg wp"] with the trailer counter 225 (0xe1 -> 0x0e 0x01).
		packet, ok := kproto.krunker_chat_encode("gg wp", false, 225)
		if !testing.expect(t, ok) { return }
		defer delete(packet)
		expected := []byte{0x93, 0xa2, 'c', 't', 0x00, 0xa5, 'g', 'g', ' ', 'w', 'p', 0x0e, 0x01}
		testing.expectf(t, len(packet) == len(expected) && string(packet) == string(expected), "ct bytes %v", packet)
		team, team_ok := kproto.krunker_chat_encode("push b", true, 0)
		defer delete(team)
		testing.expect(t, team_ok && team[4] == 0x01, "the Team tab sends ab = 1")

		// Round trip through the decoder: [opcode, tab, text].
		messages, counter, err := kproto.krunker_msgpack_decode_packet(packet)
		testing.expect(t, len(err) == 0 && counter == 225 && len(messages) == 1)
		args, is_array := messages[0].([]kproto.Krunker_Msgpack_Value)
		testing.expect(t, is_array && len(args) == 3 && args[0].(string) == "ct" && args[1].(i64) == 0 && args[2].(string) == "gg wp")

		// Empty text is not sent (WW only runs for a non-empty #chatInput).
		_, empty_ok := kproto.krunker_chat_encode("", false, 0)
		testing.expect(t, !empty_ok)
	}

	@(test)
	chat_length_limit_is_krunkers_maxlength :: proc(t: ^testing.T) {
		long := strings.repeat("a", 90, context.temp_allocator)
		clean := kproto.krunker_chat_clean_outgoing(long)
		testing.expect_value(t, len(clean), kproto.KRUNKER_CHAT_MAX_LENGTH)
		testing.expect_value(t, kproto.krunker_chat_clean_outgoing("h\x01ié!"), "hi!")
		packet, ok := kproto.krunker_chat_encode(long, false, 3)
		defer delete(packet)
		testing.expect(t, ok && packet[5] == 0xd9 && packet[6] == 70, "the encoded text is capped at 70 bytes")

		// The input box stops at 70 characters too.
		chat: Chat
		chat_open(&chat)
		for _ in 0..<90 { chat_type(&chat, 'x') }
		testing.expect_value(t, chat.input_length, 70)
		testing.expect(t, !chat_type(&chat, 'y'))
		chat.backspace = 3
		chat_apply_backspace(&chat)
		testing.expect_value(t, chat.input_length, 67)
		testing.expect(t, !chat_type(&chat, 0x7f) && !chat_type(&chat, '\n'), "control characters are not typed")
	}

	@(test)
	chat_ch_packet_decodes_and_displays :: proc(t: ^testing.T) {
		client: Client
		defer chat_test_client_free(&client)
		client.hud_settings.chat = menuui.DEFAULT_CHAT_SETTINGS
		client.krunker.connected = true
		// A player message: [tab, name, text, type, color, nameColor, accountId].
		player, ok := kproto.krunker_msgpack_encode_packet("ch", []kproto.Krunker_Msgpack_Value{i64(0), "Sidney", "nice shot", i64(0), kproto.Krunker_Msgpack_Nil{}, "#ffcc00", i64(4242)}, 9)
		if !testing.expect(t, ok) { return }
		defer delete(player)
		messages, _, _ := kproto.krunker_msgpack_decode_packet(player)
		decoded, decoded_ok := kproto.krunker_chat_decode(messages[0].([]kproto.Krunker_Msgpack_Value))
		testing.expect(t, decoded_ok && decoded.tab == 0 && decoded.name == "Sidney" && decoded.text == "nice shot" && decoded.type == .PLAYER && decoded.name_color == "#ffcc00" && decoded.has_account && decoded.account_id == 4242)

		// The server's own lines, as Krunker sends them: send("ch", 0, null, "Claimed 5 KR", 2).
		system, system_ok := kproto.krunker_msgpack_encode_packet("ch", []kproto.Krunker_Msgpack_Value{i64(-1), kproto.Krunker_Msgpack_Nil{}, "Claimed 5 KR", i64(2), "#5ce05a"}, 10)
		if !testing.expect(t, system_ok) { return }
		defer delete(system)
		krunker_ws_apply_world(&client, player)
		krunker_ws_apply_world(&client, system)
		testing.expect_value(t, client.chat.count, 2)
		line := &client.chat.lines[0]
		testing.expect(t, line.kind == .PLAYER && chat_line_name(line) == "Sidney" && chat_line_text(line) == "nice shot")
		testing.expect(t, line.name_color == chat_parse_color("#ffcc00") && line.color == CHAT_MESSAGE_COLOR)
		testing.expect(t, line.tab == -1, "outside team modes every line belongs to every tab")
		sys := &client.chat.lines[1]
		testing.expect(t, sys.kind == .SYSTEM && chat_line_text(sys) == "Claimed 5 KR" && sys.color == chat_parse_color("#5ce05a"))
		// A system line without a colour uses Krunker's #fc03ec.
		chat_system(&client.chat, client.hud_settings.chat, "Link Copied.")
		testing.expect(t, client.chat.lines[2].color == CHAT_SYSTEM_COLOR)

		// Malformed packets never add lines.
		_, bad := kproto.krunker_chat_decode([]kproto.Krunker_Msgpack_Value{"ch", i64(0)})
		_, wrong := kproto.krunker_chat_decode([]kproto.Krunker_Msgpack_Value{"ct", i64(0), "x", "y"})
		testing.expect(t, !bad && !wrong)
	}

	@(test)
	chat_live_send_uses_shared_counter_and_never_logs_text :: proc(t: ^testing.T) {
		kproto.network_log_close()
		saved_path := kproto.network_log_path
		kproto.network_log_path = "bin/chat-test-network.log"
		os.remove(kproto.network_log_path)
		defer { kproto.network_log_close(); os.remove("bin/chat-test-network.log"); kproto.network_log_path = saved_path }
		defer chat_test_sent_clear()
		state := Krunker_WS_State{connected = true, ah_num = 7}
		defer { for item in state.chat_outbox { delete(item.text) }; delete(state.chat_outbox) }

		secret := "eyJhbGciOiJIUzI1NiJ9.secretpayload.signature"
		krunker_ws_queue_chat(&state, secret, false)
		// A would-block send keeps the message and the counter.
		chat_test_result = .AGAIN
		testing.expect(t, krunker_ws_flush_chat(&state, chat_test_send) && len(state.chat_outbox) == 1 && state.ah_num == 7)
		chat_test_result = .SENT
		testing.expect(t, krunker_ws_flush_chat(&state, chat_test_send))
		testing.expect(t, len(chat_test_sent) == 1 && len(state.chat_outbox) == 0)
		next := kproto.krunker_msgpack_counter_next(7, "ct")
		testing.expect_value(t, state.ah_num, next)
		packet := chat_test_sent[0]
		testing.expect(t, packet[len(packet)-2] == next >> 4 && packet[len(packet)-1] == next & 15, "the trailer carries the advanced counter")
		chat_test_result = .FAILED
		krunker_ws_queue_chat(&state, "x", true)
		testing.expect(t, !krunker_ws_flush_chat(&state, chat_test_send), "a failed send reports the socket as broken")
		chat_test_result = .SENT

		kproto.network_log_close()
		log, err := os.read_entire_file_from_path(kproto.network_log_path, context.temp_allocator)
		testing.expect(t, err == nil && strings.contains(string(log), "SENT ct tab=0"), "sends are logged")
		testing.expect(t, !strings.contains(string(log), "secretpayload") && !strings.contains(string(log), "eyJ"), "chat text never reaches the network log")
	}

	@(private = "file")
	chat_test_client_free :: proc(client: ^Client) {
		krunker_ws_disconnect(&client.krunker)
		kproto.krunker_world_reset(&client.krunker_world)
	}

	@(private = "file")
	chat_test_all_down :: proc(window: glfw.WindowHandle, code: i32) -> bool { return true }
	@(private = "file")
	chat_test_none_down :: proc(window: glfw.WindowHandle, code: i32) -> bool { return false }
	@(private = "file")
	chat_test_enter_down :: proc(window: glfw.WindowHandle, code: i32) -> bool { return code == glfw.KEY_ENTER }

	@(test)
	chat_input_captures_keys_from_gameplay_binds :: proc(t: ^testing.T) {
		client: Client
		client.bindings = menuui.default_bindings()
		client.hud_settings.chat = menuui.DEFAULT_CHAT_SETTINGS
		client.mouse_state.locked = true
		testing.expect_value(t, client.bindings[.CHAT][0], i32(glfw.KEY_ENTER))

		testing.expect(t, client_action_down(&client, .FORWARD, chat_test_all_down), "binds work before chat opens")
		// Enter opens the input once; holding it does not reopen after a send.
		testing.expect(t, !client_chat_update(&client, 1, chat_test_enter_down) && client.chat.open)
		for action in menuui.Binding_Action {
			testing.expectf(t, !client_action_down(&client, action, chat_test_all_down), "%v must not fire while typing", action)
		}
		bound, _ := client_gameplay_bound_input(&client, chat_test_all_down)
		testing.expect(t, bound.move_dir == -1 && !bound.jump && !bound.shoot && !bound.crouch && !bound.reload && bound.swap == 0, "no gameplay input while typing")
		client.scoreboard_open = true
		client_scoreboard_update(&client, chat_test_all_down)
		testing.expect(t, !client.scoreboard_open, "the leaderboard bind is captured too")

		// Typed keys go to the box, including W, A, S, D and Space.
		for c in "wasd go" { client_chat_character(&client, c) }
		testing.expect_value(t, chat_input_text(&client.chat), "wasd go")
		// Escape cancels: the text is dropped and the menu is not opened.
		client_chat_key(&client, glfw.KEY_ESCAPE, glfw.PRESS)
		testing.expect(t, client_chat_update(&client, 2, chat_test_none_down), "Escape is reported as used by chat")
		testing.expect(t, !client.chat.open && client.chat.input_length == 0)
		testing.expect(t, client_action_down(&client, .FORWARD, chat_test_all_down), "binds work again after closing")

		// Enter sends (Local Practice echoes it) and closes; a held Enter does not reopen.
		client_chat_update(&client, 3, chat_test_enter_down)
		testing.expect(t, client.chat.open, "Enter reopens after being released")
		for c in "hello" { client_chat_character(&client, c) }
		client_chat_key(&client, glfw.KEY_ENTER, glfw.PRESS)
		client_chat_update(&client, 3.1, chat_test_enter_down)
		testing.expect(t, !client.chat.open && client.chat.count == 1 && chat_line_text(&client.chat.lines[0]) == "hello")
		client_chat_update(&client, 3.2, chat_test_enter_down)
		testing.expect(t, !client.chat.open, "holding Enter after sending does not reopen chat")

		// A letter chat bind: pressing it while typing sends, and its character is not typed.
		client.bindings[.CHAT] = {'T', 0}
		t_down :: proc(window: glfw.WindowHandle, code: i32) -> bool { return code == 'T' }
		client_chat_update(&client, 5, chat_test_none_down)
		client_chat_update(&client, 5.1, t_down)
		testing.expect(t, client.chat.open && client.chat.input_length == 0, "the opening T is not typed")
		for c in "gg" { client_chat_character(&client, c) }
		client_chat_key(&client, 'T', glfw.PRESS)
		client_chat_character(&client, 't')
		client_chat_update(&client, 5.2, t_down)
		testing.expect(t, !client.chat.open && chat_line_text(&client.chat.lines[client.chat.count-1]) == "gg")

		// A click closes the box but keeps the draft, like a blurred #chatInput.
		client.bindings[.CHAT] = {glfw.KEY_ENTER, 0}
		client_chat_update(&client, 9, chat_test_none_down)
		client_chat_update(&client, 9.1, chat_test_enter_down)
		for c in "draft" { client_chat_character(&client, c) }
		client_chat_mouse(&client, glfw.MOUSE_BUTTON_LEFT, glfw.PRESS)
		client_chat_update(&client, 9.2, chat_test_none_down)
		testing.expect(t, !client.chat.open && chat_input_text(&client.chat) == "draft")
		// Leaving the game (cursor unlocked) closes it too.
		client_chat_update(&client, 9.3, chat_test_enter_down)
		client.mouse_state.locked = false
		client_chat_update(&client, 9.4, chat_test_enter_down)
		testing.expect(t, !client.chat.open)
		client_chat_update(&client, 9.5, chat_test_none_down)
		client_chat_update(&client, 9.6, chat_test_enter_down)
		testing.expect(t, !client.chat.open, "chat only opens in game")
	}

	@(test)
	chat_rate_limit_and_local_practice :: proc(t: ^testing.T) {
		client: Client
		client.bindings = menuui.default_bindings()
		client.hud_settings.chat = menuui.DEFAULT_CHAT_SETTINGS
		client.mouse_state.locked = true
		send :: proc(client: ^Client, text: string, now: f64) {
			if !client.chat.open { chat_open(&client.chat) }
			client.chat.input_length = 0
			for c in text { chat_type(&client.chat, c) }
			client_chat_submit(client, now)
		}
		send(&client, "first", 10)
		testing.expect(t, client.chat.count == 1 && chat_line_name(&client.chat.lines[0]) == "You", "Local Practice echoes your message")
		send(&client, "second", 11.4)
		testing.expect(t, client.chat.count == 2 && chat_line_text(&client.chat.lines[1]) == CHAT_TOO_FAST_TEXT, "a send within 1.5 s is refused")
		testing.expect(t, client.chat.open && chat_input_text(&client.chat) == "second", "the refused text stays in the box")
		client_chat_submit(&client, 11.6)
		testing.expect(t, !client.chat.open && chat_line_text(&client.chat.lines[2]) == "second")

		send(&client, "/dance now", 20)
		testing.expect(t, strings.has_prefix(chat_line_text(&client.chat.lines[3]), "Unknown command: /dance") && client.chat.lines[3].kind == .SYSTEM)
		send(&client, "/help", 22)
		testing.expect(t, strings.contains(chat_line_text(&client.chat.lines[4]), "Krodin"))
		send(&client, "/clear", 24)
		testing.expect_value(t, client.chat.count, 0)

		// Live lobbies queue a ct packet instead of echoing.
		client.krunker.connected = true
		defer krunker_ws_disconnect(&client.krunker)
		send(&client, "glhf", 30)
		testing.expect(t, client.chat.count == 0 && len(client.krunker.chat_outbox) == 1 && client.krunker.chat_outbox[0].text == "glhf")
		// Ranked: a server link is never sent.
		client.krunker_world.is_ranked = true
		send(&client, "join https://krunker.io/?game=FRA:abcd", 40)
		testing.expect(t, len(client.krunker.chat_outbox) == 1 && strings.contains(chat_line_text(&client.chat.lines[0]), "ranked"))
	}

	@(test)
	chat_filter_and_message_settings :: proc(t: ^testing.T) {
		// Uy.clean: whole tokens only, case-insensitive; a_s_s loses its underscores.
		testing.expect_value(t, chat_filter_clean("what the SHIT, a_s_s classic"), "what the ****, *** classic")
		testing.expect_value(t, chat_filter_clean("grass assassin"), "grass assassin")
		testing.expect_value(t, chat_filter_clean("--fuck--"), "--****--")

		chat: Chat
		settings := menuui.DEFAULT_CHAT_SETTINGS
		chat_add(&chat, settings, {kind = .PLAYER, name = "A", text = "oh shit"}, false)
		testing.expect_value(t, chat_line_text(&chat.lines[0]), "oh shit")
		settings.filter = true
		chat_add(&chat, settings, {kind = .PLAYER, name = "A", text = "oh shit"}, false)
		testing.expect_value(t, chat_line_text(&chat.lines[1]), "oh ****")
		// Show Player Messages off drops player lines but never system lines.
		settings.hide_messages = true
		testing.expect(t, !chat_add(&chat, settings, {kind = .PLAYER, name = "A", text = "hi"}, false))
		testing.expect(t, chat_add(&chat, settings, {kind = .SYSTEM, text = "Claimed 5 KR"}, false))
		testing.expect_value(t, chat.count, 3)

		// Ranked hides server links.
		chat_add(&chat, settings, {kind = .SYSTEM, text = "go wss://x.krunker.io/ws?gameId=1 now"}, false, ranked = true)
		testing.expect_value(t, chat_line_text(&chat.lines[3]), "go [link hidden] now")

		// 35 lines at most; chatTimer removes lines after its seconds (no fade).
		clear_chat: Chat
		settings = menuui.DEFAULT_CHAT_SETTINGS
		for i in 0..<40 { chat_add(&clear_chat, settings, {kind = .PLAIN, text = fmt.tprintf("line %d", i)}, false) }
		testing.expect(t, clear_chat.count == CHAT_MAX_LINES && chat_line_text(&clear_chat.lines[0]) == "line 5")
		chat_tick(&clear_chat, 3600)
		testing.expect_value(t, clear_chat.count, CHAT_MAX_LINES) // chatTimer 0 keeps lines.
		settings.timer = 2
		chat_add(&clear_chat, settings, {kind = .PLAIN, text = "timed"}, false)
		chat_tick(&clear_chat, 1.9)
		testing.expect(t, chat_line_text(&clear_chat.lines[clear_chat.count-1]) == "timed")
		chat_tick(&clear_chat, 0.2)
		testing.expect(t, chat_line_text(&clear_chat.lines[clear_chat.count-1]) != "timed")

		// Team modes keep Krunker's tabs: Global hides Team lines and vice versa.
		tabs: Chat
		chat_add(&tabs, settings, {kind = .PLAYER, name = "A", text = "all", tab = 0}, true)
		chat_add(&tabs, settings, {kind = .PLAYER, name = "B", text = "team", tab = 1}, true)
		testing.expect(t, chat_line_visible(&tabs, &tabs.lines[0], true) && !chat_line_visible(&tabs, &tabs.lines[1], true))
		tabs.team = true
		testing.expect(t, !chat_line_visible(&tabs, &tabs.lines[0], true) && chat_line_visible(&tabs, &tabs.lines[1], true))
		// Non-ASCII text is drawable.
		chat_add(&tabs, settings, {kind = .PLAIN, text = "café\x07!"}, true)
		testing.expect_value(t, chat_line_text(&tabs.lines[2]), "caf?!")
	}

	@(test)
	chat_settings_persist_import_export_and_reset :: proc(t: ^testing.T) {
		defaults := client_settings_default_values()
		testing.expect(t, defaults.hud.chat == menuui.DEFAULT_CHAT_SETTINGS && defaults.bindings[.CHAT] == {257, 0})
		testing.expect(t, menuui.DEFAULT_CHAT_SETTINGS == menuui.Chat_Settings{opacity = 1, background = 0.2, height = 2.5})

		// The menu stages Krunker's slider steps and the select.
		client := Client{}
		client.menu.page = .SETTINGS
		menuui.prepare_settings(&client.menu, menuui.View{hud = {chat = menuui.DEFAULT_CHAT_SETTINGS}})
		menuui.activate(&client.menu, {action = {kind = .CHAT_VALUE, index = i32(menuui.Chat_Control.HEIGHT), value = 3.44}})
		menuui.activate(&client.menu, {action = {kind = .CHAT_VALUE, index = i32(menuui.Chat_Control.TIMER), value = 2.3}})
		menuui.activate(&client.menu, {action = {kind = .CHAT_VALUE, index = i32(menuui.Chat_Control.OPACITY), value = 7}})
		menuui.activate(&client.menu, {action = {kind = .CHAT_TOGGLE, index = i32(menuui.Chat_Toggle.FILTER)}})
		menuui.activate(&client.menu, {action = {kind = .CHAT_MODE, index = 1}})
		chat := client.menu.settings_draft.hud.chat
		testing.expectf(t, abs(chat.height - 3.4) < 0.001 && chat.timer == 2.5 && chat.opacity == 1 && chat.filter && chat.mode == 1, "draft %v", chat)
		testing.expect(t, abs(menuui.settings_slider_value(&client.menu, {}, {kind = .CHAT_VALUE, index = i32(menuui.Chat_Control.HEIGHT)}) - 3.4) < 0.001)
		testing.expect(t, client.hud_settings.chat == {}, "nothing applies before Save")
		menu_apply_action(&client, {kind = .SETTINGS_SAVE})
		testing.expect(t, client.hud_settings.chat.filter && client.hud_settings.chat.mode == 1)

		// Settings > HUD > Reset restores Krunker's chat defaults.
		draft := client.menu.settings_draft
		menuui.settings_reset_tab(&draft, defaults, .HUD)
		testing.expect(t, draft.hud.chat == menuui.DEFAULT_CHAT_SETTINGS)
		draft = client.menu.settings_draft
		draft.bindings[.CHAT] = {'T', 0}
		menuui.settings_reset_tab(&draft, defaults, .INPUT)
		testing.expect(t, draft.bindings[.CHAT] == {257, 0})

		// Krunker import/export: the chat keys and chatKey.
		values := defaults
		_, err := menuui.krunker_settings_import(&values, `{"shwChat":1,"chatFilter":true,"showMessages":false,"chatOp":0.5,"chatBGOp":0,"chatTextOutline":true,"chatHeight":4,"chatTimer":3.5,"controls":{"chatKey":84}}`)
		testing.expect(t, len(err) == 0)
		imported := values.hud.chat
		testing.expectf(t, imported == menuui.Chat_Settings{mode = 1, filter = true, hide_messages = true, opacity = 0.5, background = 0, text_outline = true, height = 4, timer = 3.5}, "imported %v", imported)
		testing.expect(t, values.bindings[.CHAT][0] == 'T')
		exported := menuui.krunker_settings_export(values)
		defer delete(exported)
		for key in ([]string{`"shwChat":1`, `"chatFilter":true`, `"showMessages":false`, `"chatOp":0.5`, `"chatBGOp":0,`, `"chatTextOutline":true`, `"chatHeight":4`, `"chatTimer":3.5`, `"chatKey":84`}) {
			testing.expectf(t, strings.contains(exported, key), "export has %s: %s", key, exported)
		}
		default_export := menuui.krunker_settings_export(defaults)
		defer delete(default_export)
		testing.expectf(t, !strings.contains(default_export, "chat") && !strings.contains(default_export, "shwChat") && !strings.contains(default_export, "showMessages"), "defaults are not exported: %s", default_export)
		// Out-of-range values clamp like Krunker's sliders.
		clamped := defaults
		menuui.krunker_settings_import(&clamped, `{"chatHeight":9,"chatTimer":-2,"shwChat":7}`)
		testing.expect(t, clamped.hud.chat.height == 5 && clamped.hud.chat.timer == 0 && clamped.hud.chat.mode == 2)

		// client-settings.json: files without "chat" (or the CHAT bind) get the defaults.
		path := "bin/chat-settings-test.json"
		defer os.remove(path)
		legacy := `{"version":1,"hud":{"hide_kill_feed":true},"bindings":{"JUMP":[86,0]}}`
		testing.expect(t, os.write_entire_file(path, transmute([]u8)legacy) == nil)
		loaded := client_settings_load(path)
		testing.expect(t, loaded.hud.chat == menuui.DEFAULT_CHAT_SETTINGS && loaded.hud.hide_kill_feed && loaded.bindings[.CHAT] == {257, 0})
		loaded.hud.chat.timer, loaded.hud.chat.mode = 4.5, 2
		testing.expect(t, client_settings_save(loaded, path))
		again := client_settings_load(path)
		testing.expect(t, again.hud.chat.timer == 4.5 && again.hud.chat.mode == 2 && again.hud.chat.height == 2.5)
	}

	@(private = "file")
	chat_frame :: proc(client: ^Client, pixels: []u8) {
		gpu_clear(color = true, depth = true)
		ui_update(client.ui, f32(client.viewport_width), f32(client.viewport_height))
		chat_render(client)
		test_read_rgb(0, 0, client.viewport_width, client.viewport_height, raw_data(pixels))
	}

	// Changed pixels' bounds (top-down screen pixels).
	@(private = "file")
	chat_bounds :: proc(client: ^Client, before, after: []u8) -> (left, top, right, bottom: f32, changed: int) {
		w, h := int(client.viewport_width), int(client.viewport_height)
		left, top = f32(w), f32(h)
		for y in 0..<h {
			for x in 0..<w {
				o := ((h-1-y)*w + x)*3
				if before[o] == after[o] && before[o+1] == after[o+1] && before[o+2] == after[o+2] { continue }
				changed += 1
				left, right, top, bottom = min(left, f32(x)), max(right, f32(x)), min(top, f32(y)), max(bottom, f32(y))
			}
		}
		return
	}

	@(test)
	chat_renders_closed_and_typing :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		test_gpu := test_gpu_open(640, 360, "Chat")
		if !testing.expect(t, test_gpu.ok, "no GPU device for the test") do return
		defer test_gpu_close(&test_gpu, t)
		g_test_gpu = &test_gpu
		window := test_gpu.window
		gpu_set_clear_color({0.42, 0.55, 0.62})
		framebuffer: Gpu_Render_Target
		defer test_gpu_target_destroy(&framebuffer)
		client := Client{ui = ui_init()}
		defer { overlay_fini(); ui_fini(client.ui); resource_cache_fini() }
		os.make_directory("bin/chat")

		settings := menuui.DEFAULT_CHAT_SETTINGS
		settings.timer = 6 // Lines leave after chatTimer seconds; Krunker removes them without a fade.
		client.hud_settings.chat = settings
		fill :: proc(client: ^Client, settings: menuui.Chat_Settings) {
			chat_clear(&client.chat)
			chat_add(&client.chat, settings, {kind = .SYSTEM, text = "Global Text Chat"}, false)
			chat_add(&client.chat, settings, {kind = .PLAYER, name = "Sidney_Prescott", text = "anyone else lagging on this map?"}, false)
			chat_add(&client.chat, settings, {kind = .PLAYER, name = "Ash_Ketchum_420", text = "gg", name_color = chat_parse_color("#ffcc00")}, false)
			chat_add(&client.chat, settings, {kind = .PLAIN, text = "Rocketeer joined the game"}, false)
			chat_add(&client.chat, settings, {kind = .PLAYER, name = "You", text = "this is a much longer message that has to wrap onto a second row"}, false)
			chat_add(&client.chat, settings, {kind = .SYSTEM, text = "Claimed 5 KR", color = chat_parse_color("#5ce05a")}, false)
			// Ages: the oldest lines are about to expire.
			for i in 0..<client.chat.count { client.chat.lines[i].life = 6.4 - f32(client.chat.count - i) }
		}
		for size in ([?][2]i32{{1280, 720}, {1920, 1080}}) {
			w, h := size[0], size[1]
			test_gpu_target_destroy(&framebuffer)
			framebuffer = test_gpu_target(w, h)
			if !testing.expect(t, framebuffer != 0) { return }
			test_gpu_use_target(framebuffer, w, h)
			g_active_texture = 0
			client.viewport_width, client.viewport_height = w, h
			gpu_set_target(test_gpu_current_target(), w, h)
			empty := make([]u8, int(w*h*3)); defer delete(empty)
			closed := make([]u8, len(empty)); defer delete(closed)
			typing := make([]u8, len(empty)); defer delete(typing)
			chat_clear(&client.chat)
			chat_close(&client.chat, true)
			chat_frame(&client, empty)

			fill(&client, settings)
			chat_tick(&client.chat, 0.5) // The oldest line has expired.
			testing.expect_value(t, client.chat.count, 5)
			chat_frame(&client, closed)
			left, top, right, bottom, changed := chat_bounds(&client, empty, closed)
			label := fmt.tprintf("%dx%d closed", w, h)
			s := client.ui.scale
			k := s * CHAT_KRUNKER_SCALE
			testing.expectf(t, changed > 0, "%s: chat draws", label)
			testing.expectf(t, left >= 20*s + 10*k - 2 && right <= 20*s + 280*k, "%s: inside #chatHolder (%v..%v)", label, left, right)
			testing.expectf(t, bottom < f32(h) - CHAT_BOTTOM_INSET*s && top > f32(h) - CHAT_BOTTOM_INSET*s - 40*k - 250*k, "%s: above the class panel and within 250 px (%v..%v)", label, top, bottom)
			testing.expectf(t, right < f32(w)*0.5, "%s: bottom-left only", label)
			stbi.write_png(fmt.ctprintf("bin/chat/chat-closed-%dx%d.png", w, h), w, h, 3, &closed[(h-1)*w*3], -w*3)

			// Typing: the input box appears under the list.
			chat_open(&client.chat)
			for c in "nice, push B together" { chat_type(&client.chat, c) }
			chat_frame(&client, typing)
			_, _, typing_right, typing_bottom, typing_changed := chat_bounds(&client, empty, typing)
			testing.expectf(t, typing_changed > changed && typing_bottom > bottom, "%s typing: the input draws below the list", label)
			testing.expectf(t, abs(typing_bottom - (f32(h) - CHAT_BOTTOM_INSET*s)) <= 2 && typing_right <= 20*s + 280*k + 1, "%s typing: input at the holder's bottom edge (%v)", label, typing_bottom)
			stbi.write_png(fmt.ctprintf("bin/chat/chat-typing-%dx%d.png", w, h), w, h, 3, &typing[(h-1)*w*3], -w*3)

			// While Focused hides the list until typing; Off hides it always.
			chat_close(&client.chat, true)
			client.hud_settings.chat.mode = i32(menuui.Chat_Mode.WHILE_FOCUSED)
			hidden := make([]u8, len(empty)); defer delete(hidden)
			chat_frame(&client, hidden)
			_, _, _, _, hidden_changed := chat_bounds(&client, empty, hidden)
			testing.expectf(t, hidden_changed == 0, "%s: While Focused hides the closed chat", label)
			client.hud_settings.chat = settings
		}
		testing.expect(t, test_gpu_no_error())
	}
}
