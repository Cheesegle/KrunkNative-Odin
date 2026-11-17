package main

// Chat on the native server over loopback: one client sends, the others
// receive; team-only chat reaches only the sender's team; spam inside the
// 1.5 s interval is refused with a server line to the sender only; invalid
// text is dropped. Port 0 (an OS-chosen loopback port, never 21015) and
// every wait has a deadline.

import "core:fmt"
import "core:net"
import "core:time"
import shared "../shared"
import ded "../server/dedicated"

@(private = "file")
chat_test_fail :: proc(format: string, args: ..any) -> bool {
	fmt.eprintf("Server chat test failed: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	return false
}

Chat_Test_Line :: struct { sender: i32, team: bool, text: string }

// Reads complete CHAT packets from a non-blocking socket into `lines` until
// `want` lines arrived or `deadline` passed since `start`, polling the server.
@(private = "file")
chat_test_read :: proc(server: ^ded.Server, socket: net.TCP_Socket, buffer: ^[dynamic]byte, lines: ^[dynamic]Chat_Test_Line, want: int, deadline: time.Duration, start: time.Tick) {
	chunk: [512]byte
	for len(lines) < want && time.tick_since(start) < deadline {
		ded.net_server_poll(&server.net, &server.game)
		n, err := net.recv_tcp(socket, chunk[:])
		if n > 0 {
			append(buffer, ..chunk[:n])
		} else if err != nil && err != .Would_Block && err != .Timeout {
			return
		} else {
			time.sleep(time.Millisecond)
		}
		for len(buffer) >= shared.PACKET_HEADER_SIZE {
			header, ok := shared.packet_deserialize_header(buffer[:])
			if !ok { clear(buffer); break }
			size := shared.PACKET_HEADER_SIZE + int(header.payload_len)
			if len(buffer) < size { break }
			if header.packet_type == .CHAT {
				if sender, team, text, chat_ok := shared.packet_deserialize_chat(buffer[:size]); chat_ok {
					append(lines, Chat_Test_Line{sender, team, fmt.aprintf("%s", text)})
				}
			}
			remove_range(buffer, 0, size)
		}
	}
}

@(private = "file")
chat_test_send :: proc(socket: net.TCP_Socket, text: string, team: bool) -> bool {
	buf: [shared.NET_CHAT_REQUEST_MAX_SIZE]byte
	size := shared.packet_serialize_chat_request(buf[:], text, team)
	if size == 0 { return false }
	sent, err := net.send_tcp(socket, buf[:size])
	return err == nil && sent == size
}

test_server_chat :: proc() -> bool {
	// Packets: round trips and validation.
	{
		buf: [shared.NET_CHAT_MAX_SIZE]byte
		size := shared.packet_serialize_chat_request(buf[:], "gg wp", true)
		text, team, ok := shared.packet_deserialize_chat_request(buf[:size])
		if !ok || text != "gg wp" || !team { return chat_test_fail("chat request round trip") }
		size = shared.packet_serialize_chat(buf[:], 7, false, "nice")
		sender, line_team, line, line_ok := shared.packet_deserialize_chat(buf[:size])
		if !line_ok || sender != 7 || line_team || line != "nice" { return chat_test_fail("chat line round trip") }
		long: [shared.NET_CHAT_MAX_LENGTH + 1]byte
		for &c in long { c = 'a' }
		if shared.packet_serialize_chat_request(buf[:], string(long[:]), false) != 0 || shared.packet_serialize_chat_request(buf[:], string(long[:70]), false) == 0 {
			return chat_test_fail("chat length limit is not 70")
		}
		if shared.packet_serialize_chat_request(buf[:], "   ", false) != 0 || shared.packet_serialize_chat_request(buf[:], "bad\x07", false) != 0 || shared.packet_serialize_chat_request(buf[:], "", false) != 0 {
			return chat_test_fail("blank or control-character chat was accepted")
		}
		// A forged request: the length byte disagrees with the payload.
		size = shared.packet_serialize_chat_request(buf[:], "hello", false)
		buf[shared.PACKET_HEADER_SIZE + 1] = 3
		if _, _, forged := shared.packet_deserialize_chat_request(buf[:size]); forged { return chat_test_fail("mismatched chat length accepted") }
		limit: ded.Net_Chat_Limit
		t0 := time.tick_now()
		if !ded.net_chat_allow(&limit, t0) || ded.net_chat_allow(&limit, time.tick_add(t0, 1499 * time.Millisecond)) || !ded.net_chat_allow(&limit, time.tick_add(t0, 1500 * time.Millisecond)) {
			return chat_test_fail("chat interval is not 1.5 s")
		}
	}

	settings := ded.server_settings_default()
	ded.server_settings_apply_args(&settings, []string{"--bind", "127.0.0.1", "--port", "0", "--max-players", "4", "--maps", "burg"}, nil)
	ded.server_settings_validate(&settings, nil)
	server := new(ded.Server)
	defer free(server)
	if !ded.server_init(server, settings, nil, true) {
		ded.server_destroy(server)
		return chat_test_fail("chat: could not listen on loopback")
	}
	defer ded.server_destroy(server)
	port := ded.net_server_port(&server.net)
	if port == 0 || port == 21015 { return chat_test_fail("chat: bad port %d", port) }

	sockets: [3]net.TCP_Socket
	open: [3]bool
	buffers: [3][dynamic]byte
	lines: [3][dynamic]Chat_Test_Line
	defer {
		for socket, i in sockets { if open[i] { net.close(socket) } }
		for i in 0..<3 {
			delete(buffers[i])
			for line in lines[i] { delete(line.text) }
			delete(lines[i])
		}
	}
	start := time.tick_now()
	for i in 0..<3 {
		s, err := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = port})
		if err != nil { return chat_test_fail("chat: dial %d failed: %v", i, err) }
		sockets[i], open[i] = s, true
		net.set_blocking(s, false)
		// Accept in dial order so client i is server.net.clients[i].
		for len(server.net.clients) < i + 1 && time.tick_since(start) < 3 * time.Second {
			ded.net_server_poll(&server.net, &server.game)
			time.sleep(time.Millisecond)
		}
	}
	if len(server.net.clients) != 3 { return chat_test_fail("chat: %d clients connected, want 3", len(server.net.clients)) }
	// Teams: clients 0 and 1 are team 1, client 2 is team 2.
	for client, i in server.net.clients { client.player.team = i < 2 ? 1 : 2 }
	uid0 := server.net.clients[0].player.uid

	// Global chat reaches everyone, the sender included.
	if !chat_test_send(sockets[0], "hello all", false) { return chat_test_fail("chat: send failed") }
	for i in 0..<3 { chat_test_read(server, sockets[i], &buffers[i], &lines[i], 1, 3 * time.Second, start) }
	for i in 0..<3 {
		if len(lines[i]) != 1 || lines[i][0].sender != uid0 || lines[i][0].team || lines[i][0].text != "hello all" {
			return chat_test_fail("chat: client %d got %v for a global message", i, lines[i][:])
		}
	}

	// Spam inside 1.5 s: refused, and only the sender hears why.
	if !chat_test_send(sockets[0], "spam", false) { return chat_test_fail("chat: spam send failed") }
	chat_test_read(server, sockets[0], &buffers[0], &lines[0], 2, 4 * time.Second, start)
	if len(lines[0]) != 2 || lines[0][1].sender != shared.NET_CHAT_SYSTEM || lines[0][1].text != ded.NET_CHAT_TOO_FAST {
		return chat_test_fail("chat: spam was not refused with a server line: %v", lines[0][:])
	}

	// Team-only chat after the interval: team 1 (clients 0 and 1) only.
	server.net.clients[0].chat = {}
	if !chat_test_send(sockets[0], "push B", true) { return chat_test_fail("chat: team send failed") }
	chat_test_read(server, sockets[0], &buffers[0], &lines[0], 3, 5 * time.Second, start)
	chat_test_read(server, sockets[1], &buffers[1], &lines[1], 2, 5 * time.Second, start)
	if len(lines[0]) != 3 || lines[0][2].text != "push B" || !lines[0][2].team || len(lines[1]) != 2 || lines[1][1].text != "push B" || !lines[1][1].team {
		return chat_test_fail("chat: team message missing for team 1: %v / %v", lines[0][:], lines[1][:])
	}
	// Client 2 (team 2) and the spam refusal: it must get nothing new.
	listen_start := time.tick_now()
	chat_test_read(server, sockets[2], &buffers[2], &lines[2], 2, 300 * time.Millisecond, listen_start)
	if len(lines[2]) != 1 { return chat_test_fail("chat: the other team heard team or refused chat: %v", lines[2][:]) }

	// Invalid text from a raw socket is dropped, not broadcast.
	server.net.clients[1].chat = {}
	raw: [shared.NET_CHAT_REQUEST_MAX_SIZE]byte
	size := shared.packet_serialize_chat_request(raw[:], "hello", false)
	raw[shared.PACKET_HEADER_SIZE + 2] = 0x07
	net.send_tcp(sockets[1], raw[:size])
	listen_start = time.tick_now()
	chat_test_read(server, sockets[2], &buffers[2], &lines[2], 2, 300 * time.Millisecond, listen_start)
	if len(lines[2]) != 1 || len(server.net.clients) != 3 { return chat_test_fail("chat: invalid text was broadcast or dropped a client") }

	fmt.println("Server chat tests OK")
	return true
}
