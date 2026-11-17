package dedicated

import "core:fmt"
import "core:net"
import "core:time"
import shared "../../shared"

Net_Client :: struct {
	id:         u32,
	socket:     net.TCP_Socket,
	active:     bool,
	joined:     bool,
	team_result: u8,
	player:     ^shared.Player,
	// Received input commands, simulated in order each tick (input_commands.odin).
	commands:   Command_Stream,
	malformed_inputs: int,
	initial_match_sent: bool,
	recv_buffer: [4096]byte,
	recv_len:    int,
	send_queue:  shared.Net_Send_Queue,
	chat:        Net_Chat_Limit, // chat.odin
}

Net_Server :: struct {
	listener: net.TCP_Socket,
	clients:  [dynamic]^Net_Client,
	next_id:  u32,
	// Connections beyond this are refused before a player is created.
	max_players:   int,
	// Team select allows this many players per team (server team_size).
	team_capacity: int,
	rejected:      int, // connections refused because the server was full
	// Real time for the input time bank; ticks can stall or be skipped, so
	// simulated server time is not used for it.
	clock_start:   time.Tick,
}

// Real seconds since the listener opened.
net_server_now :: proc(ns: ^Net_Server) -> f64 {
	return time.duration_seconds(time.tick_since(ns.clock_start))
}

net_server_flush :: proc(client: ^Net_Client) -> bool {
	if client == nil || !client.active {
		return false
	}

	for {
		pending := shared.net_send_queue_pending(&client.send_queue)
		if len(pending) == 0 {
			return true
		}

		count, err := net.send_tcp(client.socket, pending)
		shared.net_send_queue_consume(&client.send_queue, count)

		if err != nil {
			if err == .Would_Block || err == .Timeout {
				return true
			}
			return false
		}
		if count == 0 {
			return false
		}
	}
}

net_server_send :: proc(client: ^Net_Client, data: []byte) -> bool {
	if client == nil || !client.active || len(data) == 0 {
		return false
	}
	if !shared.net_send_queue_push(&client.send_queue, data) {
		fmt.printf("[Net Server] Client #%d send queue overflow\n", client.id)
		return false
	}
	return net_server_flush(client)
}

// net_server_init listens on bind:port (port 0 picks a free port; see
// net_server_port). max_players and team_capacity come from the settings.
net_server_init :: proc(bind: string, port: int, max_players: int, team_capacity: int) -> (ns: Net_Server, ok: bool) {
	address := net.parse_address(bind)
	if address == nil {
		fmt.eprintf("Invalid bind address %q\n", bind)
		return ns, false
	}
	endpoint := net.Endpoint {
		address = address,
		port    = port,
	}

	listener, err := net.listen_tcp(endpoint)
	if err != nil {
		fmt.eprintf("Failed to listen on %s:%d: %v\n", bind, port, err)
		return ns, false
	}
	net.set_blocking(listener, false)

	ns.listener = listener
	ns.clock_start = time.tick_now()
	ns.next_id = 1
	ns.max_players = max(1, max_players)
	ns.team_capacity = max(1, team_capacity)
	return ns, true
}

net_server_port :: proc(ns: ^Net_Server) -> int {
	endpoint, err := net.bound_endpoint(ns.listener)
	return err == nil ? endpoint.port : 0
}

// net_server_has_room: every accepted connection holds a slot (a player is
// created on accept), so the limit counts connections, joined or not.
net_server_has_room :: proc(ns: ^Net_Server) -> bool {
	return len(ns.clients) < ns.max_players
}

// net_server_refuse tells a connection why it is being closed and closes it.
// One best-effort send is enough: the packet is 8 bytes on a fresh socket.
net_server_refuse :: proc(socket: net.TCP_Socket, reason: shared.Disconnect_Reason) {
	buf: [shared.PACKET_HEADER_SIZE + 1]byte
	if size := shared.packet_serialize_disconnect(buf[:], reason); size > 0 {
		net.send_tcp(socket, buf[:size])
	}
	net.close(socket)
}

// net_server_drop_client tears down a client that has left: the player is
// removed from the authoritative sim (so the client never sees a ghost) and
// the Net_Client record is freed. Callers must also remove the pointer from
// ns.clients.
net_server_drop_client :: proc(ns: ^Net_Server, game: ^shared.Game, client: ^Net_Client) {
	client.active = false
	if client.player != nil {
		if client.joined {
			shared.game_players_remove(game, client.player)
		}
		shared.player_destroy(client.player)
		client.player = nil
	}
	net.close(client.socket)
	command_stream_destroy(&client.commands)
	free(client)
}

net_server_poll :: proc(ns: ^Net_Server, game: ^shared.Game) {
	// Poll for new client connections (non-blocking accept check)
	client_socket, _, err := net.accept_tcp(ns.listener)
	if err == nil && !net_server_has_room(ns) {
		ns.rejected += 1
		fmt.printf("[Net Server] Refused a connection: server full (%d/%d)\n", len(ns.clients), ns.max_players)
		net_server_refuse(client_socket, .SERVER_FULL)
	} else if err == nil {
		net.set_blocking(client_socket, false)
		// Tiny per-player snapshots must not sit in the Nagle buffer while the
		// peer's delayed ACK (40 ms on Windows) holds them back.
		net.set_option(client_socket, .TCP_Nodelay, true)

		client := new(Net_Client)
		client.id = ns.next_id
		ns.next_id += 1
		client.socket = client_socket
		client.active = true
		client.player = shared.player_init(game)
		client.player.uid = i32(client.id)
		command_stream_init(&client.commands, net_server_now(ns))

		append(&ns.clients, client)
		fmt.printf("[Net Server] Client #%d connected!\n", client.id)
	}

	// Poll incoming data for each client. Dropped clients are removed in place
	// (the swapped-in last element is re-examined), so the loop stays safe.
	i := 0
	for i < len(ns.clients) {
		client := ns.clients[i]

		if client.active {
			if !net_server_flush(client) {
				fmt.printf("[Net Server] Client #%d send error\n", client.id)
				client.active = false
			}
		}

		if client.active {
			available := client.recv_buffer[client.recv_len:]
			bytes_read, read_err := net.recv_tcp(client.socket, available)

			if bytes_read > 0 {
				client.recv_len += bytes_read
				for client.recv_len >= shared.PACKET_HEADER_SIZE {
					header, h_ok := shared.packet_deserialize_header(client.recv_buffer[:client.recv_len])
					if !h_ok {
						client.active = false
						break
					}
					packet_size := shared.PACKET_HEADER_SIZE + int(header.payload_len)
					if packet_size > len(client.recv_buffer) {
						client.active = false
						break
					}
					if client.recv_len < packet_size {
						break
					}
					packet := client.recv_buffer[:packet_size]
					#partial switch header.packet_type {
					case .CONNECT:
						if class_id, secondary_id, version, connect_ok := shared.packet_deserialize_loadout(packet); connect_ok && version == shared.PROTOCOL_VERSION && class_id >= 0 && class_id < i32(len(game.classes)) && client.player != nil {
							if !client.joined {
								shared.game_players_add(game, client.player)
							}
							shared.player_spawn(client.player, class_id, shared.secondary_weapon_id(game.weapons, secondary_id))
							client.joined = true
							fmt.printf("[Net Server] Client #%d spawned as class %d on team %d\n", client.id, class_id, client.player.team)
						} else if connect_ok && version != shared.PROTOCOL_VERSION {
							fmt.printf("[Net Server] Client #%d protocol mismatch (client %d, server %d)\n", client.id, version, shared.PROTOCOL_VERSION)
							client.active = false
						}
					case .TEAM_REQUEST:
						if team, valid := shared.packet_deserialize_team_request(packet); valid {
							count := 0
							for other in ns.clients { if other != client && other.active && other.player != nil && other.player.team == team { count += 1 } }
							allowed := game.config.select_team && (team == 0 || count < ns.team_capacity)
							client.team_result = allowed ? 1 : 2
							if allowed {
								client.player.team = team
								client.player.active = false
							}
						}
					case .PLAYER_INPUT:
						commands: [shared.INPUT_BATCH_MAX_COMMANDS]shared.Input
						if count, input_ok := shared.packet_deserialize_input_batch(packet, commands[:]); input_ok {
							if client.joined {
								for command in commands[:count] {
									command_stream_push(&client.commands, command)
								}
							}
						} else {
							// A malformed batch is dropped whole; the stream itself stays
							// framed, so the connection is kept.
							client.malformed_inputs += 1
							if client.malformed_inputs == 1 || client.malformed_inputs % 100 == 0 {
								fmt.printf("[Net Server] Client #%d sent %d malformed input batches\n", client.id, client.malformed_inputs)
							}
						}
					case .PING:
						// Echo the probe unchanged so the client can time the round trip.
						if _, ping_ok := shared.packet_deserialize_ping(packet); ping_ok && !net_server_send(client, packet) {
							client.active = false
						}
					case .CHAT:
						net_server_chat(ns, client, packet)
					case .DISCONNECT:
						client.active = false
						fmt.printf("[Net Server] Client #%d requested disconnect\n", client.id)
					}

					client.recv_len -= packet_size
					if client.recv_len > 0 {
						copy(client.recv_buffer[:client.recv_len], client.recv_buffer[packet_size:packet_size + client.recv_len])
					}
				}
			} else if read_err == nil {
				// 0 bytes with no error is a graceful FIN from the peer.
				fmt.printf("[Net Server] Client #%d closed the connection\n", client.id)
				client.active = false
			} else if read_err != .Would_Block && read_err != .Timeout {
				// Reset/closed/invalid socket: the peer vanished without a
				// DISCONNECT packet. Marking it dead here stops the server from
				// broadcasting to (and leaking) a ghost client forever.
				fmt.printf("[Net Server] Client #%d dropped (recv error %v)\n", client.id, read_err)
				client.active = false
			}
		}

		if !client.active {
			net_server_drop_client(ns, game, client)
			unordered_remove(&ns.clients, i)
			continue
		}
		i += 1
	}
}

// net_server_broadcast_chat sends one chat line to every connected client, or
// with team > 0 only to that team's players (team-only chat).
net_server_broadcast_chat :: proc(ns: ^Net_Server, sender: i32, team: i32, text: string) {
	buf: [shared.NET_CHAT_MAX_SIZE]byte
	size := shared.packet_serialize_chat(buf[:], sender, team > 0, text)
	if size == 0 { return }
	for other in ns.clients {
		if !other.active || team > 0 && (other.player == nil || other.player.team != team) { continue }
		if !net_server_send(other, buf[:size]) { other.active = false }
	}
}

// net_server_run_commands simulates every command each client sent since the
// last tick, in order, each with its own duration. It runs in the network
// phase, before the world update.
net_server_run_commands :: proc(ns: ^Net_Server, game: ^shared.Game) {
	now := net_server_now(ns)
	for client in ns.clients {
		if !client.active { continue }
		command_stream_run(&client.commands, client.joined ? client.player : nil, game, now)
		command_stream_log(&client.commands, client.id, now)
	}
}

net_server_broadcast_match :: proc(ns: ^Net_Server, game: ^shared.Game) {
	state := shared.packet_match_state_from_game(game)
	state.send_rate = f32(game.config.tick_rate) / f32(shared.SNAPSHOT_RATE_DIVISOR)
	// Largest packet here is MATCH_STATE with a full roster: 7 header + 42 + 32*4.
	match_buf: [256]byte
	match_size := shared.packet_serialize_match_state(match_buf[:], &state)
	if match_size == 0 {
		return
	}
	player_buf: [shared.PACKET_HEADER_SIZE + shared.PACKET_PLAYER_STATE_PAYLOAD_SIZE]byte
	impact_buf: [shared.PACKET_HEADER_SIZE + shared.PACKET_BULLET_IMPACT_PAYLOAD_SIZE]byte
	kill_buf: [shared.PACKET_HEADER_SIZE + shared.PACKET_KILL_FEED_PAYLOAD_SIZE]byte

	for client in ns.clients {
		if !client.active {
			continue
		}
		// Keep the match frame immutable across recipients. Player snapshots are
		// recipient-specific (`is_you`) and use a separate serialization buffer.
		if !net_server_send(client, match_buf[:match_size]) {
			client.active = false
			continue
		}
		client.initial_match_sent = true
		lobby := shared.Lobby_State{local_id = client.id, team = client.player.team, capacity = i32(ns.team_capacity), select_team = game.config.select_team, team_result = client.team_result, team_names = {game.config.team1_name, game.config.team2_name}}
		for other in ns.clients {
			if !other.active || other.player == nil || lobby.count >= shared.MAX_PLAYERS_PER_MATCH { continue }
			lobby.players[lobby.count] = {id = other.id, team = other.player.team, class_id = other.joined ? other.player.class_index : -1}
			lobby.count += 1
		}
		lobby_buf: [512]byte
		lobby_size := shared.packet_serialize_lobby(lobby_buf[:], &lobby)
		if !net_server_send(client, lobby_buf[:lobby_size]) { client.active = false; continue }
		client.team_result = 0
		if !client.joined {
			continue
		}

		for player in game.players {
			player_state := net_server_player_state(player, player == client.player)
			state_size := shared.packet_serialize_state(player_buf[:], &player_state)
			if state_size > 0 {
				if !net_server_send(client, player_buf[:state_size]) {
					client.active = false
					break
				}
			}
		}
		if !client.active {
			continue
		}
		for &impact in game.impacts {
			impact_size := shared.packet_serialize_bullet_impact(impact_buf[:], &impact)
			if impact_size > 0 && !net_server_send(client, impact_buf[:impact_size]) {
				client.active = false
				break
			}
		}
		if !client.active {
			continue
		}
		for &event in game.kill_events {
			kill_size := shared.packet_serialize_kill_feed(kill_buf[:], &event)
			if kill_size > 0 && !net_server_send(client, kill_buf[:kill_size]) {
				client.active = false
				break
			}
		}
	}
	// Impacts and kills are reliable TCP events. Once every active joined client
	// has had them queued, retain only new ones generated before the next snapshot.
	clear(&game.impacts)
	clear(&game.kill_events)
}

// The GAME_STATE snapshot of one player; is_you marks the recipient's own.
net_server_player_state :: proc(player: ^shared.Player, is_you: bool) -> shared.Packet_Player_State {
	weapon_id: u8
	active_ammo: u32
	if player.loadout_index >= 0 && player.loadout_index < player.loadout_size {
		weapon_id = u8(player.loadout[player.loadout_index])
		active_ammo = player.ammo[player.loadout_index]
	}
	return {
		player_id = u32(player.uid),
		active = player.active,
		is_you = is_you,
		team = player.team,
		class_id = player.class_index,
		secondary_id = player.secondary_id,
		position = player.position,
		velocity = player.velocity,
		x_dir = player.direction.x,
		y_dir = player.direction.y,
		on_ground = player.on_ground,
		on_ladder = player.on_ladder,
		on_ramp = player.on_ramp,
		on_terrain = player.on_terrain,
		terrain_slipping = player.terrain_slipping,
		did_jump = player.did_jump,
		did_wall_jump = player.did_wall_jump,
		can_slide = player.can_slide,
		on_wall = player.on_wall,
		wall_jump_count = u8(clamp(player.wall_jump_count, 0, 255)),
		can_slide_timer = player.can_slide_timer,
		cylinder_velocity = {player.x_vel_cylinder, player.z_vel_cylinder},
		crouch_val = player.crouch_val,
		aim_val = player.aim_val,
		slide_timer = player.slide_timer,
		jump_timer = player.jump_timer,
		health = player.health,
		max_health = player.max_health,
		weapon_id = weapon_id,
		active_ammo = active_ammo,
		shot_seq = player.shot_seq,
		ack_seq = player.input_seq,
		spread_plus = player.spread_plus,
		projectile_shot_seq = player.projectile_shot_seq,
		score = player.score,
		kills = player.kills,
		deaths = player.deaths,
	}
}

// net_server_close tells every client why (when a reason is given), closes
// all sockets and frees the client records.
net_server_close :: proc(ns: ^Net_Server, reason := shared.Disconnect_Reason.NONE) {
	for client in ns.clients {
		if client.active {
			if reason != .NONE {
				buf: [shared.PACKET_HEADER_SIZE + 1]byte
				if size := shared.packet_serialize_disconnect(buf[:], reason); size > 0 {
					net_server_send(client, buf[:size])
				}
			}
			net.close(client.socket)
		}
		if !client.joined && client.player != nil {
			shared.player_destroy(client.player)
		}
		command_stream_destroy(&client.commands)
		free(client)
	}
	delete(ns.clients)
	net.close(ns.listener)
}
