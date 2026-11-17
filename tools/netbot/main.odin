// krodin_netbot: a headless test bot for Krodin's dedicated server.
//
// It connects like a real client (same TCP protocol, CONNECT + PLAYER_INPUT
// at 64 Hz), wanders, aims at the nearest enemy and shoots, and holds every
// packet in each direction for half of a simulated round trip, so the server
// sees a player at roughly --latency ms ping. tools/server-bot-test.ps1 starts
// a server plus several bots with random latencies.
//
// Krodin's own tool; Krunker has no equivalent. Run it from the repo root
// (the shared package reads assets/ at startup).
package netbot

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:net"
import "core:os"
import "core:strconv"
import "core:time"
import shared "../../src/shared"

INPUT_RATE :: 64.0 // inputs per second, like a 64 FPS client
EYE_HEIGHT :: 9.0  // shooter's eye above its position (playerHeight 11 minus crouch room)
AIM_HEIGHT :: 6.0  // aim at the target's chest
DEPLOY_AFTER :: 8.0 // seconds down before the bot deploys itself again

Options :: struct {
	host:       string,
	port:       int,
	latency_ms: f64, // simulated round trip; each direction gets half
	jitter_ms:  f64, // +- random extra per packet, order is kept
	seed:       u64,
	duration:   f64, // seconds, 0 = until the server goes away
	name:       string,
	class_id:   i32, // -1 = random rotation class
	report:     f64, // seconds between status lines, 0 = off
	debug:      int, // print this many of the bot's own impacts
}

Delayed :: struct {
	due:  f64,
	data: []byte,
}

// A one-direction delay line. TCP keeps order, so each packet is due no
// earlier than the one before it even when jitter would reorder them.
Delay_Line :: struct {
	items:    [dynamic]Delayed,
	last_due: f64,
}

delay_push :: proc(line: ^Delay_Line, now, one_way_ms, jitter_ms: f64, data: []byte) {
	extra := jitter_ms > 0 ? (rand.float64() * 2 - 1) * jitter_ms : 0
	due := max(now + max(0, one_way_ms + extra) / 1000, line.last_due)
	line.last_due = due
	copy_data := make([]byte, len(data))
	copy(copy_data, data)
	append(&line.items, Delayed{due, copy_data})
}

// Pops the next packet whose time has come, if any. The caller owns the data.
delay_pop :: proc(line: ^Delay_Line, now: f64) -> (data: []byte, ok: bool) {
	if len(line.items) == 0 || line.items[0].due > now { return nil, false }
	data = line.items[0].data
	ordered_remove(&line.items, 0)
	return data, true
}

Seen_Player :: struct {
	id:       u32,
	active:   bool,
	team:     i32,
	position: shared.Vec3,
	health:   f32,
	ammo:     u32,
}

Bot :: struct {
	opts:        Options,
	socket:      net.TCP_Socket,
	connected:   bool,
	outgoing:    Delay_Line,
	incoming:    Delay_Line,
	send_buf:    [dynamic]byte, // bytes released by the delay line, not yet accepted by the socket
	recv_buf:    [8192]byte,
	recv_len:    int,
	ping:        shared.Net_Ping_State,

	me:          Seen_Player,
	have_me:     bool,
	others:      [dynamic]Seen_Player,
	seq:         i32,
	yaw, pitch:  f32,
	move_dir:    i32,
	next_move:   f64,
	dead_since:  f64, // when the bot was last seen go inactive, -1 while alive
	spawned:     bool,
	deaths:      int,
	shots:       int, // inputs with the trigger held
	hits_player: int, // server-confirmed impacts on a player
	hits_world:  int, // server-confirmed impacts on the map (a wall in the way)
	server_full: bool,

	map_inst:    ^shared.Map, // loaded from MATCH_STATE, for line of sight
	map_slot:    i32,
	stuck_check: f64,
	stuck_from:  shared.Vec3,
}

usage :: proc() {
	fmt.println("krodin_netbot: headless test bot for krodin_server")
	fmt.println("  --host <ip/name>   server host (default 127.0.0.1)")
	fmt.println("  --port <n>         server port (default 21015)")
	fmt.println("  --latency <ms>     simulated round-trip latency (default 40)")
	fmt.println("  --jitter <ms>      +- random jitter per packet (default 2)")
	fmt.println("  --seed <n>         random seed (default: time based)")
	fmt.println("  --duration <s>     quit after this many seconds (default 0 = run until the server closes)")
	fmt.println("  --name <text>      label used in this bot's log lines")
	fmt.println("  --class <id>       class id (default random)")
	fmt.println("  --debug <n>        print the first n impacts of this bot's own shots")
	fmt.println("  --report <s>       seconds between status lines (default 10, 0 = off)")
}

parse_options :: proc(args: []string) -> (opts: Options, ok: bool) {
	opts = Options{host = "127.0.0.1", port = 21015, latency_ms = 40, jitter_ms = 2, seed = u64(time.now()._nsec), name = "bot", class_id = -1, report = 10}
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--help" || arg == "-h" { return opts, false }
		if i + 1 >= len(args) { fmt.eprintf("missing value for %s\n", arg); return opts, false }
		value := args[i + 1]
		i += 1
		valid := true
		switch arg {
		case "--host":     opts.host = value
		case "--name":     opts.name = value
		case "--port":     n, k := strconv.parse_int(value); opts.port, valid = n, k && n > 0 && n < 65536
		case "--latency":  f, k := strconv.parse_f64(value); opts.latency_ms, valid = f, k && f >= 0 && f <= 2000
		case "--jitter":   f, k := strconv.parse_f64(value); opts.jitter_ms, valid = f, k && f >= 0 && f <= 500
		case "--seed":     n, k := strconv.parse_u64(value); opts.seed, valid = n, k
		case "--duration": f, k := strconv.parse_f64(value); opts.duration, valid = f, k && f >= 0
		case "--report":   f, k := strconv.parse_f64(value); opts.report, valid = f, k && f >= 0
		case "--debug":    n, k := strconv.parse_int(value); opts.debug, valid = n, k && n >= 0
		case "--class":    n, k := strconv.parse_int(value); opts.class_id, valid = i32(n), k
		case:
			fmt.eprintf("unknown option %s\n", arg)
			return opts, false
		}
		if !valid { fmt.eprintf("bad value for %s: %s\n", arg, value); return opts, false }
	}
	return opts, true
}

// Queues one serialized packet behind the simulated outgoing delay.
bot_send :: proc(bot: ^Bot, now: f64, data: []byte) {
	if len(data) > 0 { delay_push(&bot.outgoing, now, bot.opts.latency_ms / 2, bot.opts.jitter_ms, data) }
}

bot_flush :: proc(bot: ^Bot, now: f64) {
	for {
		data, ok := delay_pop(&bot.outgoing, now)
		if !ok { break }
		append(&bot.send_buf, ..data)
		delete(data)
	}
	for len(bot.send_buf) > 0 {
		n, err := net.send_tcp(bot.socket, bot.send_buf[:])
		if n > 0 { remove_range(&bot.send_buf, 0, n) }
		if err == .Would_Block || err == .Timeout { return }
		if err != nil || n == 0 { bot.connected = false; return }
	}
}

// Reads whatever arrived and puts each whole packet behind the incoming delay.
bot_receive :: proc(bot: ^Bot, now: f64) {
	for bot.connected {
		n, err := net.recv_tcp(bot.socket, bot.recv_buf[bot.recv_len:])
		if n > 0 {
			bot.recv_len += n
		} else if err == nil {
			bot.connected = false // server closed the connection
			return
		} else if err == .Would_Block || err == .Timeout {
			break
		} else {
			bot.connected = false
			return
		}
		for bot.recv_len >= shared.PACKET_HEADER_SIZE {
			header, h_ok := shared.packet_deserialize_header(bot.recv_buf[:bot.recv_len])
			size := shared.PACKET_HEADER_SIZE + int(header.payload_len)
			if !h_ok || size > len(bot.recv_buf) { bot.connected = false; return }
			if bot.recv_len < size { break }
			delay_push(&bot.incoming, now, bot.opts.latency_ms / 2, bot.opts.jitter_ms, bot.recv_buf[:size])
			bot.recv_len -= size
			copy(bot.recv_buf[:bot.recv_len], bot.recv_buf[size:size + bot.recv_len])
		}
		if bot.recv_len == len(bot.recv_buf) { bot.connected = false; return }
	}
}

bot_handle :: proc(bot: ^Bot, now: f64, packet: []byte) {
	header, _ := shared.packet_deserialize_header(packet)
	#partial switch header.packet_type {
	case .GAME_STATE:
		state, ok := shared.packet_deserialize_state(packet)
		if !ok { return }
		seen := Seen_Player{state.player_id, state.active, state.team, state.position, state.health, state.active_ammo}
		if state.is_you {
			if bot.have_me && bot.me.active && !state.active { bot.deaths += 1 }
			if !state.active && (bot.dead_since < 0 || bot.me.active || !bot.have_me) { bot.dead_since = now }
			if state.active { bot.dead_since = -1 }
			bot.me, bot.have_me = seen, true
			return
		}
		for &other in bot.others {
			if other.id == seen.id { other = seen; return }
		}
		append(&bot.others, seen)
	case .BULLET_IMPACT:
		impact, ok := shared.packet_deserialize_bullet_impact(packet)
		if !ok || !bot.have_me || u32(impact.shooter_uid) != bot.me.id { return }
		if bot.hits_player + bot.hits_world < bot.opts.debug {
			fmt.printf("[%s] impact %v at %v from %v; me %v yaw %.3f pitch %.3f\n", bot.opts.name, impact.kind, impact.position, impact.origin, bot.me.position, bot.yaw, bot.pitch)
		}
		#partial switch impact.kind {
		case .Player: bot.hits_player += 1
		case .World:  bot.hits_world += 1
		}
	case .MATCH_STATE:
		state, ok := shared.packet_deserialize_match_state(packet)
		if !ok || (bot.map_inst != nil && state.map_index == bot.map_slot) { return }
		// map_index is a slot in ROTATION_MAPS, as for the real client.
		if state.map_index >= 0 && int(state.map_index) < len(shared.ROTATION_MAPS) {
			bot.map_inst = shared.load_default_map(shared.ROTATION_MAPS[state.map_index])
			bot.map_slot = state.map_index
			clear(&bot.others)
		}
	case .PING:
		if seq, ok := shared.packet_deserialize_ping(packet); ok { shared.net_ping_receive(&bot.ping, seq, now) }
	case .DISCONNECT:
		if reason, ok := shared.packet_deserialize_disconnect(packet); ok && reason == .SERVER_FULL {
			bot.server_full = true
		}
	}
}

bot_spawn :: proc(bot: ^Bot, now: f64) {
	class_id := bot.opts.class_id
	if class_id < 0 { class_id = shared.ROTATION_CLASSES[rand.int_max(len(shared.ROTATION_CLASSES))] }
	buf: [32]byte
	bot_send(bot, now, buf[:shared.packet_serialize_connect(buf[:], class_id)])
	bot.spawned = true
}

// True when no shot-blocking map object lies between the two points (the
// same ray-vs-box test the server's hitscan uses).
bot_line_of_sight :: proc(bot: ^Bot, from, to: shared.Vec3) -> bool {
	if bot.map_inst == nil { return true }
	dir := to - from
	for object in bot.map_inst.objects {
		if !shared.map_object_blocks_shots(object) { continue }
		if t, _, hit := shared.ray_box_hit(from, dir, object.position, object.scale); hit && t >= 0 && t < 1 { return false }
	}
	return true
}

bot_eye :: proc(bot: ^Bot) -> shared.Vec3 { return bot.me.position + {0, EYE_HEIGHT, 0} }
bot_aim_point :: proc(target: Seen_Player) -> shared.Vec3 { return target.position + {0, AIM_HEIGHT, 0} }

// Nearest living enemy (any other player when teams are off), preferring one
// the bot can actually see.
bot_target :: proc(bot: ^Bot) -> (target: Seen_Player, visible, found: bool) {
	best := f32(math.F32_MAX)
	best_visible := f32(math.F32_MAX)
	eye := bot_eye(bot)
	for other in bot.others {
		if !other.active || other.health <= 0 { continue }
		if bot.me.team != 0 && other.team == bot.me.team { continue }
		d := other.position - bot.me.position
		dist := d.x * d.x + d.y * d.y + d.z * d.z
		if dist < best_visible && bot_line_of_sight(bot, eye, bot_aim_point(other)) {
			best_visible, target, visible, found = dist, other, true, true
		} else if !visible && dist < best {
			best, target, found = dist, other, true
		}
	}
	return
}

bot_input :: proc(bot: ^Bot, now: f64) {
	input := shared.Input{move_dir = -1, delta = f32(1.0 / INPUT_RATE)}

	target, visible, has_target := bot_target(bot)
	distance := f32(0)
	if has_target {
		d := target.position - bot.me.position
		distance = math.sqrt(d.x * d.x + d.z * d.z)
	}

	// Unstick: if it barely moved while walking, turn somewhere else and jump.
	if now >= bot.stuck_check {
		moved := bot.me.position - bot.stuck_from
		if bot.move_dir >= 0 && moved.x * moved.x + moved.z * moved.z < 2 {
			bot.move_dir = i32(rand.int_max(8))
			bot.next_move = now + 0.6 + rand.float64() * 0.6
			input.jump = true
		}
		bot.stuck_from, bot.stuck_check = bot.me.position, now + 0.5
	}

	if now >= bot.next_move {
		// Close in on the nearest enemy (forward or a forward diagonal), then
		// strafe around them like a player; wander when nobody is around.
		if has_target && (distance > 45 || !visible) {
			forward := [3]i32{0, 1, 7}
			bot.move_dir = forward[rand.int_max(3)]
		} else {
			bot.move_dir = rand.float32() < 0.15 ? -1 : i32(rand.int_max(8))
		}
		bot.next_move = now + 0.3 + rand.float64() * 0.9
	}
	input.move_dir = bot.move_dir
	// Jump now and then, and over whatever is blocking the way.
	input.jump = input.jump || rand.float32() < 0.02
	input.crouch = rand.float32() < 0.005
	input.reload = bot.me.ammo == 0

	if has_target {
		d := bot_aim_point(target) - bot_eye(bot)
		// The shot direction is (-sin(yaw)cos(pitch), sin(pitch), -cos(yaw)cos(pitch)).
		aim_yaw := math.atan2(-d.x, -d.z)
		aim_pitch := math.atan2(d.y, distance)
		// Turn at a human-ish speed with a small aim error.
		turn := f32(8.0 / INPUT_RATE)
		bot.yaw += clamp(shared.normalize_angle(aim_yaw - bot.yaw), -turn, turn) + (rand.float32() - 0.5) * 0.01
		bot.pitch += clamp(aim_pitch - bot.pitch, -turn, turn)
		on_target := abs(shared.normalize_angle(aim_yaw - bot.yaw)) < 0.08
		input.scope = visible && distance < 120
		input.shoot = visible && on_target && distance < 120 && !input.reload && rand.float32() < 0.7
	} else {
		bot.yaw += 0.6 / INPUT_RATE
		bot.pitch *= 0.9
	}
	bot.yaw = shared.normalize_angle(bot.yaw)
	bot.pitch = clamp(bot.pitch, -1.4, 1.4)
	input.x_dir, input.y_dir = bot.pitch, bot.yaw
	if input.shoot { bot.shots += 1 }

	bot.seq += 1
	input.seq = bot.seq
	buf: [32]byte
	bot_send(bot, now, buf[:shared.packet_serialize_input(buf[:], &input)])
}

main :: proc() {
	opts, ok := parse_options(os.args[1:])
	if !ok { usage(); os.exit(2) }
	rand.reset(opts.seed)
	bot_sleep_begin()
	defer bot_sleep_end()

	socket, err := net.dial_tcp(opts.host, opts.port)
	if err != nil {
		fmt.eprintf("[%s] could not connect to %s:%d: %v\n", opts.name, opts.host, opts.port, err)
		os.exit(1)
	}
	net.set_blocking(socket, false)
	net.set_option(socket, .TCP_Nodelay, true)
	bot := Bot{opts = opts, socket = socket, connected = true, dead_since = -1}
	fmt.printf("[%s] connected to %s:%d, simulated latency %.0f ms (+-%.0f jitter)\n", opts.name, opts.host, opts.port, opts.latency_ms, opts.jitter_ms)

	start := time.tick_now()
	clock :: proc(start: time.Tick) -> f64 { return time.duration_seconds(time.tick_since(start)) }
	next_input, next_report := 0.0, opts.report
	bot_spawn(&bot, 0)

	for bot.connected {
		now := clock(start)
		if opts.duration > 0 && now >= opts.duration { break }

		bot_receive(&bot, now)
		for {
			packet, ready := delay_pop(&bot.incoming, now)
			if !ready { break }
			bot_handle(&bot, now, packet)
			delete(packet)
		}

		// Dead players respawn on their own (auto_respawn), so the bot waits.
		// After a map change the server waits for a fresh CONNECT, like the
		// client's Deploy, so a bot still down after DEPLOY_AFTER deploys again.
		if bot.have_me && !bot.me.active && bot.dead_since >= 0 && now - bot.dead_since >= DEPLOY_AFTER {
			bot_spawn(&bot, now)
			bot.dead_since = now
		}

		if seq, due := shared.net_ping_due(&bot.ping, now); due {
			buf: [shared.NET_PING_PACKET_SIZE]byte
			bot_send(&bot, now, buf[:shared.packet_serialize_ping(buf[:], seq)])
		}
		for now >= next_input {
			if bot.have_me && bot.me.active { bot_input(&bot, now) }
			next_input += 1.0 / INPUT_RATE
			if now - next_input > 0.25 { next_input = now } // don't burst after a stall
		}
		bot_flush(&bot, now)

		if opts.report > 0 && now >= next_report {
			next_report += opts.report
			fmt.printf("[%s] ping %d ms (target %.0f), alive=%v hp=%.0f, deaths %d, trigger %d, hits %d player / %d wall, sees %d players\n",
				opts.name, bot.ping.rtt_ms, opts.latency_ms, bot.me.active, bot.me.health, bot.deaths, bot.shots, bot.hits_player, bot.hits_world, len(bot.others))
		}
		bot_sleep(time.Millisecond)
	}

	if bot.server_full {
		fmt.printf("[%s] server is full\n", opts.name)
	} else if !bot.connected {
		fmt.printf("[%s] disconnected by the server\n", opts.name)
	} else {
		buf: [shared.PACKET_HEADER_SIZE + 1]byte
		if n := shared.packet_serialize_disconnect(buf[:]); n > 0 { net.send_tcp(bot.socket, buf[:n]) }
	}
	net.close(bot.socket)
	fmt.printf("[%s] done: deaths %d, trigger %d, hits %d player / %d wall\n", opts.name, bot.deaths, bot.shots, bot.hits_player, bot.hits_world)
}
