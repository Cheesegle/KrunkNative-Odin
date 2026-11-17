package main

// Native input pipeline (protocol 11): the PLAYER_INPUT batch codec, command
// validation, the server's per-client command stream (duplicates, ack, the
// speedhack time bank), a single-command shot using that command's aim, a
// loopback burst against a real listener, and replay vectors that run the
// server's queued per-command path against client prediction at several
// netRates and tick rates.

import "core:fmt"
import "core:math"
import "core:net"
import "core:time"

import shared "../shared"
import ded "../server/dedicated"

@(private = "file")
input_test_fail :: proc(format: string, args: ..any) -> bool {
	fmt.eprint("Input pipeline test failed: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	return false
}

test_input_batch_protocol :: proc() -> bool {
	commands: [5]shared.Input
	for &c, i in commands {
		c = {seq = i32(1000 + i), delta = f32(i + 1) / 1000, move_dir = i32(i) - 1, x_dir = shared.input_angle_quantize(-1.2 + f32(i) * 0.5),
			y_dir = shared.input_angle_quantize(3.1 - f32(i) * 1.3), shoot = i == 2, scope = i % 2 == 0, jump = i == 1, crouch = i == 3, reload = i == 4, swap = u8(i % 4)}
	}
	commands[3].view_stamped, commands[3].view_tick, commands[3].view_frac = true, 123456, 0.5
	buf: [shared.INPUT_BATCH_MAX_PACKET]byte
	size := shared.packet_serialize_input_batch(buf[:], commands[:])
	if size != shared.PACKET_HEADER_SIZE + shared.INPUT_BATCH_HEADER_SIZE + 5 * shared.INPUT_COMMAND_WIRE_SIZE + shared.INPUT_STAMP_WIRE_SIZE {
		return input_test_fail("batch size %d", size)
	}
	out: [shared.INPUT_BATCH_MAX_COMMANDS]shared.Input
	count, ok := shared.packet_deserialize_input_batch(buf[:size], out[:])
	if !ok || count != 5 { return input_test_fail("round trip decode ok=%v count=%d", ok, count) }
	for c, i in commands {
		d := out[i]
		if d.seq != c.seq || d.delta != c.delta || d.move_dir != c.move_dir || d.x_dir != c.x_dir || d.y_dir != c.y_dir ||
			d.shoot != c.shoot || d.scope != c.scope || d.jump != c.jump || d.crouch != c.crouch || d.reload != c.reload || d.swap != c.swap || d.view_stamped != c.view_stamped {
			return input_test_fail("command %d did not round-trip: %v vs %v", i, d, c)
		}
	}
	if out[3].view_tick != 123456 || math.abs(out[3].view_frac - 0.5) > 1.0 / 65535 {
		return input_test_fail("view stamp %d %f", out[3].view_tick, out[3].view_frac)
	}

	// The encoder refuses what the decoder would reject.
	gap := commands
	gap[2].seq += 1
	if shared.packet_serialize_input_batch(buf[:], gap[:]) != 0 { return input_test_fail("non-consecutive seqs encoded") }
	if shared.packet_serialize_input_batch(buf[:], commands[:0]) != 0 { return input_test_fail("an empty batch encoded") }
	many: [shared.INPUT_BATCH_MAX_COMMANDS + 1]shared.Input
	for &c, i in many { c.seq, c.move_dir, c.delta = i32(i), -1, 0.004 }
	if shared.packet_serialize_input_batch(buf[:], many[:]) != 0 { return input_test_fail("an oversized batch encoded") }
	full := shared.packet_serialize_input_batch(buf[:], many[:shared.INPUT_BATCH_MAX_COMMANDS])
	if n, full_ok := shared.packet_deserialize_input_batch(buf[:full], out[:]); !full_ok || n != shared.INPUT_BATCH_MAX_COMMANDS {
		return input_test_fail("a full %d-command batch did not decode", shared.INPUT_BATCH_MAX_COMMANDS)
	}
	if _, small_ok := shared.packet_deserialize_input_batch(buf[:full], out[:3]); small_ok { return input_test_fail("decoded more commands than the output holds") }

	// Malformed packets are rejected whole.
	size = shared.packet_serialize_input_batch(buf[:], commands[:])
	good := buf
	Case :: struct { name: string, edit: proc(b: []byte, size: int) -> int }
	cases := []Case{
		{"truncated", proc(b: []byte, size: int) -> int { return size - 1 }},
		{"count 0", proc(b: []byte, size: int) -> int { b[shared.PACKET_HEADER_SIZE] = 0; return size }},
		{"count over the cap", proc(b: []byte, size: int) -> int { b[shared.PACKET_HEADER_SIZE] = shared.INPUT_BATCH_MAX_COMMANDS + 1; return size }},
		{"count past the payload", proc(b: []byte, size: int) -> int { b[shared.PACKET_HEADER_SIZE] = 6; return size }},
		{"count short of the payload", proc(b: []byte, size: int) -> int { b[shared.PACKET_HEADER_SIZE] = 4; return size }},
		{"trailing byte", proc(b: []byte, size: int) -> int { b[5] += 1; b[size] = 0; return size + 1 }},
		{"stamp bit without a stamp", proc(b: []byte, size: int) -> int {
			last := size - shared.INPUT_COMMAND_WIRE_SIZE
			b[last + 6] |= shared.INPUT_BUTTON_STAMP
			return size
		}},
		{"wrong packet type", proc(b: []byte, size: int) -> int { b[4] = u8(shared.Packet_Type.GAME_STATE); return size }},
		{"bad magic", proc(b: []byte, size: int) -> int { b[0] ~= 0xff; return size }},
		{"header shorter than the batch header", proc(b: []byte, size: int) -> int { b[5], b[6] = 3, 0; return shared.PACKET_HEADER_SIZE + 3 }},
	}
	for c in cases {
		b := good
		n := c.edit(b[:], size)
		if _, bad_ok := shared.packet_deserialize_input_batch(b[:n], out[:]); bad_ok {
			return input_test_fail("malformed batch (%s) decoded", c.name)
		}
	}
	fmt.println("Input batch protocol tests OK")
	return true
}

test_input_validation :: proc() -> bool {
	nan := math.nan_f32()
	inf := math.inf_f32(1)
	Bad :: struct { input: shared.Input, want: shared.Input_Command_Error }
	bad := []Bad{
		{{delta = 0.004, x_dir = nan}, .NON_FINITE},
		{{delta = 0.004, y_dir = inf}, .NON_FINITE},
		{{delta = nan}, .NON_FINITE},
		{{delta = 0.004, move_dir = 8}, .MOVE_DIR},
		{{delta = 0.004, move_dir = -2}, .MOVE_DIR},
		{{delta = 0.004, swap = 4}, .SWAP},
	}
	for b in bad {
		c := b.input
		if got := shared.input_command_sanitize(&c); got != b.want {
			return input_test_fail("sanitize(%v) = %v, want %v", b.input, got, b.want)
		}
	}
	c := shared.Input{delta = 0, move_dir = 7, x_dir = 3, y_dir = 100, swap = 3, predicted_weapon_impulse = {1, 1, 1}}
	if shared.input_command_sanitize(&c) != .NONE || c.delta != 0.001 || c.x_dir != math.PI / 2 || math.abs(c.y_dir) > math.PI || c.predicted_weapon_impulse != {} {
		return input_test_fail("normalised command %v", c)
	}
	c = {delta = 0.5, move_dir = -1, y_dir = 3.142}
	if shared.input_command_sanitize(&c) != .NONE || c.delta != 0.033 || c.y_dir != 3.142 {
		return input_test_fail("a 500 ms command must clamp to 33 ms and a wrapped yaw stay as sent: %v", c)
	}

	// A stream drops invalid commands but still acks them.
	game: shared.Game
	map_inst := input_test_map()
	defer delete(map_inst.objects)
	player := physics_game_init(&game, &map_inst, false)
	game.server = rawptr(&game)
	defer shared.game_destroy(&game)
	cs: ded.Command_Stream
	ded.command_stream_init(&cs, 0)
	defer ded.command_stream_destroy(&cs)
	if ded.command_stream_push(&cs, {seq = 1, delta = 0.004, move_dir = 9}) != .INVALID { return input_test_fail("move_dir 9 accepted") }
	if ded.command_stream_push(&cs, {seq = 2, delta = 0.004, move_dir = 0}) != .QUEUED { return input_test_fail("valid command refused") }
	if ded.command_stream_run(&cs, player, &game, 0) != 1 || player.input_seq != 2 || cs.stats.invalid != 1 {
		return input_test_fail("invalid commands: simulated %d ack %d invalid %d", cs.stats.simulated, player.input_seq, cs.stats.invalid)
	}
	fmt.println("Input validation tests OK")
	return true
}

@(private = "file")
input_test_map :: proc() -> shared.Map {
	map_inst := shared.Map{death_y = -100, config = shared.Map_Config{speed = {1, 1, 1}, air_accel = 1, ladder_accel = 1, slide_time = 1, slide_accel = 1}}
	@(static) objects: [3]shared.Object
	objects[0] = {active = true, collision_type = .BOX, position = {0, 0, 0}, scale = {400, 1, 400}}
	// A wall to run into and a step to jump onto, so the vectors collide.
	objects[1] = {active = true, collision_type = .BOX, position = {30, 1, 0}, scale = {2, 30, 400}}
	objects[2] = {active = true, collision_type = .BOX, position = {-12, 1, -12}, scale = {8, 3, 8}}
	for &o in objects { append(&map_inst.objects, &o) }
	return map_inst
}

test_input_command_stream :: proc() -> bool {
	game: shared.Game
	map_inst := input_test_map()
	defer delete(map_inst.objects)
	player := physics_game_init(&game, &map_inst, false)
	game.server = rawptr(&game)
	defer shared.game_destroy(&game)
	player.position = {0, 1, 0}

	cs: ded.Command_Stream
	ded.command_stream_init(&cs, 0)
	defer ded.command_stream_destroy(&cs)

	// Redundant copies (a resent tail) are handled once.
	for seq in 0 ..< 5 { ded.command_stream_push(&cs, {seq = i32(seq), delta = 0.004, move_dir = 0}) }
	for seq in 3 ..< 7 { ded.command_stream_push(&cs, {seq = i32(seq), delta = 0.004, move_dir = 0}) }
	if len(cs.queue) != 7 || cs.stats.duplicates != 2 { return input_test_fail("dedupe: queue %d duplicates %d", len(cs.queue), cs.stats.duplicates) }
	if ded.command_stream_run(&cs, player, &game, 0.1) != 7 || player.input_seq != 6 {
		return input_test_fail("dedupe run: ack %d", player.input_seq)
	}
	if ded.command_stream_push(&cs, {seq = 2, delta = 0.004}) != .DUPLICATE { return input_test_fail("an old seq after the run was accepted") }
	if !ded.command_seq_after(min(i32), max(i32)) { return input_test_fail("seq wrap") }

	// Speedhack: 1 s of commands arriving at once may only use the 250 ms bank.
	ded.command_stream_destroy(&cs)
	cs = {}
	ded.command_stream_init(&cs, 10)
	for seq in 0 ..< 100 { ded.command_stream_push(&cs, {seq = i32(seq), delta = 0.010, move_dir = 0}) }
	ran := ded.command_stream_run(&cs, player, &game, 10)
	if ran != 25 || cs.stats.speed_rejected != 75 || player.input_seq != 99 {
		return input_test_fail("speedhack burst: simulated %d rejected %d ack %d", ran, cs.stats.speed_rejected, player.input_seq)
	}
	// Idle time does not bank: after 5 s idle, 2x speed still gets only 250 ms extra.
	sim_ms, real_s := 0, 15.0
	seq := i32(100)
	for _ in 0 ..< 100 {
		real_s += 0.02
		for _ in 0 ..< 4 { ded.command_stream_push(&cs, {seq = seq, delta = 0.010, move_dir = 0}); seq += 1 } // 40 ms per 20 ms
		sim_ms += 10 * ded.command_stream_run(&cs, player, &game, real_s)
	}
	if sim_ms > 2000 + 250 + 1 || sim_ms < 2000 {
		return input_test_fail("2x speedhack over 2 s simulated %d ms", sim_ms)
	}
	// An honest client at 144 Hz with integer-ms durations and jittery
	// delivery (bursts after up to 200 ms stalls) loses nothing.
	ded.command_stream_destroy(&cs)
	cs = {}
	ded.command_stream_init(&cs, 0)
	remainder: f64
	sent, now := 0, 0.0
	pending: [dynamic]shared.Input
	defer delete(pending)
	for frame in 0 ..< 144 * 10 {
		now += 1.0 / 144
		append(&pending, shared.Input{seq = i32(frame), delta = shared.input_command_duration_ms(144, 1, &remainder) / 1000, move_dir = -1})
		stall := frame % 300 > 270 // ~200 ms with nothing delivered, then a burst
		if !stall {
			for c in pending { ded.command_stream_push(&cs, c) }
			clear(&pending)
			sent += ded.command_stream_run(&cs, player, &game, now)
		}
	}
	if sent != 144 * 10 - len(pending) || cs.stats.speed_rejected != 0 {
		return input_test_fail("honest client: simulated %d of %d, rejected %d", sent, 144 * 10 - len(pending), cs.stats.speed_rejected)
	}

	// Commands for a dead player are dropped but acked.
	player.active = false
	ded.command_stream_push(&cs, {seq = 5000, delta = 0.004})
	if ded.command_stream_run(&cs, player, &game, now + 1) != 0 || player.input_seq != 5000 { return input_test_fail("dead player ack %d", player.input_seq) }
	player.active = true

	// The queue is bounded.
	for i in 0 ..< ded.COMMAND_QUEUE_LIMIT + 10 { ded.command_stream_push(&cs, {seq = i32(6000 + i), delta = 0.001}) }
	if len(cs.queue) != ded.COMMAND_QUEUE_LIMIT || cs.stats.overflow != 10 { return input_test_fail("queue limit: %d queued, %d overflow", len(cs.queue), cs.stats.overflow) }
	ded.command_stream_run(&cs, player, &game, now + 2)

	fmt.println("Input command stream tests OK")
	return true
}

// A shoot press that lasts one command fires inside that command, with that
// command's aim, even when later commands in the same batch look elsewhere.
test_input_single_command_shot :: proc() -> bool {
	game: shared.Game
	map_inst := shared.Map{death_y = -100, config = shared.Map_Config{speed = {1, 1, 1}, air_accel = 1}}
	floor := shared.Object{active = true, collision_type = .BOX, position = {0, 0, 0}, scale = {400, 1, 400}}
	append(&map_inst.objects, &floor)
	defer delete(map_inst.objects)
	shooter := physics_game_init(&game, &map_inst, false)
	game.server = rawptr(&game)
	defer shared.game_destroy(&game)
	game.match.phase = .LIVE
	game.move_lock = false
	shooter.position = {0, 1, 0}
	shooter.team = 1
	target := shared.player_init(&game)
	shared.game_players_add(&game, target)
	shared.player_spawn(target, 0)
	target.team = 2
	target.position = {0, 1, -15}
	start_health := target.health

	cs: ded.Command_Stream
	ded.command_stream_init(&cs, 0)
	defer ded.command_stream_destroy(&cs)
	// Yaw 0 looks down -z at the target; PI/2 looks down -x, away from it.
	away := shared.input_angle_quantize(math.PI / 2)
	batch := [5]shared.Input{
		{seq = 0, delta = 0.004, move_dir = -1, y_dir = away},
		{seq = 1, delta = 0.004, move_dir = -1, y_dir = away},
		{seq = 2, delta = 0.004, move_dir = -1, y_dir = 0, x_dir = 0, shoot = true},
		{seq = 3, delta = 0.004, move_dir = -1, y_dir = away},
		{seq = 4, delta = 0.004, move_dir = -1, y_dir = away},
	}
	buf: [shared.INPUT_BATCH_MAX_PACKET]byte
	size := shared.packet_serialize_input_batch(buf[:], batch[:])
	out: [shared.INPUT_BATCH_MAX_COMMANDS]shared.Input
	count, _ := shared.packet_deserialize_input_batch(buf[:size], out[:])
	for c in out[:count] { ded.command_stream_push(&cs, c) }
	ded.command_stream_run(&cs, shooter, &game, 0)

	hit := false
	for impact in game.impacts { if impact.kind == .Player { hit = true } }
	if shooter.shot_seq != 1 || !hit || target.health >= start_health || shooter.input_seq != 4 {
		return input_test_fail("one-command shot: shots %d, player hit %v, target health %.0f of %.0f, ack %d",
			shooter.shot_seq, hit, target.health, start_health, shooter.input_seq)
	}
	if math.abs(shooter.direction.y - away) > 0.0001 { return input_test_fail("later commands must still turn the player") }
	fmt.println("Input single-command shot test OK")
	return true
}

// A real listener on a free loopback port (never 21015): one client deploys
// and sends a burst whose middle command clicks. The server must fire it.
test_input_loopback_burst :: proc() -> bool {
	settings := ded.server_settings_default()
	ded.server_settings_apply_args(&settings, []string{"--bind", "127.0.0.1", "--port", "0", "--maps", "burg"}, nil)
	ded.server_settings_validate(&settings, nil)
	server := new(ded.Server)
	defer free(server)
	if !ded.server_init(server, settings, nil, true) {
		ded.server_destroy(server)
		return input_test_fail("loopback: could not listen")
	}
	defer ded.server_destroy(server)
	server.game.match.phase = .LIVE
	server.game.move_lock = false
	port := ded.net_server_port(&server.net)
	if port == 0 || port == 21015 { return input_test_fail("loopback: port %d", port) }
	socket, err := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = port})
	if err != nil { return input_test_fail("loopback: dial %v", err) }
	defer net.close(socket)

	buf: [shared.INPUT_BATCH_MAX_PACKET]byte
	size := shared.packet_serialize_connect(buf[:], 0)
	net.send_tcp(socket, buf[:size])
	start := time.tick_now()
	deadline :: 5 * time.Second
	client: ^ded.Net_Client
	for time.tick_since(start) < deadline {
		ded.server_step(server)
		if len(server.net.clients) == 1 && server.net.clients[0].joined && server.net.clients[0].player.active {
			client = server.net.clients[0]
			break
		}
		time.sleep(time.Millisecond)
	}
	if client == nil { return input_test_fail("loopback: the client never deployed") }
	// The weapon must be ready (swap timer from spawning) before the click.
	client.player.swap_timer = 0
	shots_before := client.player.shot_seq

	burst: [12]shared.Input
	for &c, i in burst {
		c = {seq = i32(i), delta = 0.004, move_dir = 0, x_dir = 0, y_dir = shared.input_angle_quantize(0.3), shoot = i == 6}
	}
	// Send it as two batches, the second resending a two-command tail.
	size = shared.packet_serialize_input_batch(buf[:], burst[:8])
	net.send_tcp(socket, buf[:size])
	size = shared.packet_serialize_input_batch(buf[:], burst[6:])
	net.send_tcp(socket, buf[:size])
	for time.tick_since(start) < deadline && client.player.input_seq != 11 {
		ded.server_step(server)
		time.sleep(time.Millisecond)
	}
	if client.player.input_seq != 11 || client.player.shot_seq != shots_before + 1 || client.commands.stats.duplicates != 2 || client.commands.stats.simulated != 12 {
		return input_test_fail("loopback burst: ack %d, shots %d (was %d), duplicates %d, simulated %d",
			client.player.input_seq, client.player.shot_seq, shots_before, client.commands.stats.duplicates, client.commands.stats.simulated)
	}
	fmt.println("Input loopback burst test OK")
	return true
}

// Replay vectors: the server's queued per-command path (batch codec, command
// stream, fixed server ticks) and client prediction (each command predicted
// once, as it is built) must end in bit-identical positions and velocities,
// at netRates 60/144/240/360 and server ticks 64/128.
test_input_replay_vectors :: proc() -> bool {
	for tick_rate in ([2]int{64, 128}) {
		for rate in ([4]i32{60, 144, 240, 360}) {
			if !input_replay_vector(tick_rate, rate) { return false }
		}
	}
	fmt.println("Input replay vector tests OK")
	return true
}

@(private = "file")
input_replay_vector :: proc(tick_rate: int, rate: i32) -> bool {
	server_map := input_test_map()
	client_map := input_test_map()
	defer delete(server_map.objects)
	defer delete(client_map.objects)
	server_game, client_game: shared.Game
	server_player := physics_game_init(&server_game, &server_map, false)
	server_game.server = rawptr(&server_game)
	client_player := physics_game_init(&client_game, &client_map, true)
	defer shared.game_destroy(&server_game)
	defer shared.game_destroy(&client_game)
	server_player.position, client_player.position = {-6, 1, 0}, {-6, 1, 0}
	server_player.last_position, client_player.last_position = server_player.position, client_player.position

	cs: ded.Command_Stream
	ded.command_stream_init(&cs, 0)
	defer ded.command_stream_destroy(&cs)
	In_Flight :: struct { at: f64, data: [shared.INPUT_BATCH_MAX_PACKET]byte, size: int }
	wire: [dynamic]In_Flight
	defer delete(wire)
	history: [dynamic]shared.Input
	defer delete(history)

	FRAME :: 1.0 / 165.0
	LATENCY :: 0.04
	tick_dt := 1.0 / f64(tick_rate)
	step := 1.0 / f64(rate)
	remainder, elapsed, now, server_now: f64
	seq: i32
	sent_through: i32 = -1
	server_ticks := 0
	for frame in 0 ..< 165 * 3 {
		now += FRAME
		elapsed += FRAME
		t := f32(now)
		for elapsed + 1e-7 >= step {
			c := shared.Input{seq = seq, move_dir = i32(frame / 40) % 8, x_dir = 0.3 * math.sin(t), y_dir = 0.7 * t,
				jump = frame % 70 < 3, crouch = frame % 150 > 120, shoot = frame % 30 < 4}
			c.delta = shared.input_command_duration_ms(f64(rate), 1, &remainder) / 1000
			shared.input_command_quantize(&c)
			shared.player_proc_input(client_player, &c, true, false, true)
			append(&history, c)
			seq += 1
			elapsed = max(0, elapsed - step)
		}
		// Send what is new plus a two-command redundant tail.
		first := max(0, int(sent_through) + 1 - 2)
		if int(seq) > int(sent_through) + 1 {
			for start := first; start < int(seq); start += shared.INPUT_BATCH_MAX_COMMANDS {
				end := min(int(seq), start + shared.INPUT_BATCH_MAX_COMMANDS)
				f := In_Flight{at = now + LATENCY}
				f.size = shared.packet_serialize_input_batch(f.data[:], history[start:end])
				append(&wire, f)
			}
			sent_through = seq - 1
		}
		for server_now + tick_dt <= now {
			server_now += tick_dt
			server_ticks += 1
			out: [shared.INPUT_BATCH_MAX_COMMANDS]shared.Input
			for len(wire) > 0 && wire[0].at <= server_now {
				count, ok := shared.packet_deserialize_input_batch(wire[0].data[:wire[0].size], out[:])
				if !ok { return input_test_fail("replay %d Hz: batch did not decode", rate) }
				for c in out[:count] { ded.command_stream_push(&cs, c) }
				ordered_remove(&wire, 0)
			}
			server_game.now = f32(server_now)
			ded.command_stream_run(&cs, server_player, &server_game, server_now)
			shared.game_tick(&server_game, f32(server_now), f32(tick_dt))
			if len(server_game.impacts) > 64 { clear(&server_game.impacts) }
		}
	}
	// Deliver the rest and let the server catch up.
	for len(wire) > 0 {
		server_now += tick_dt
		out: [shared.INPUT_BATCH_MAX_COMMANDS]shared.Input
		for len(wire) > 0 && wire[0].at <= server_now {
			count, _ := shared.packet_deserialize_input_batch(wire[0].data[:wire[0].size], out[:])
			for c in out[:count] { ded.command_stream_push(&cs, c) }
			ordered_remove(&wire, 0)
		}
		ded.command_stream_run(&cs, server_player, &server_game, server_now)
		shared.game_tick(&server_game, f32(server_now), f32(tick_dt))
	}
	exact := server_player.position == client_player.position && server_player.velocity == client_player.velocity && server_player.on_ground == client_player.on_ground
	fmt.printf("  replay %3d Hz commands, %3d tick: %d commands, %d ticks, %d simulated, rejected %d, |dpos| %.9f, |dvel| %.9f, exact %v\n",
		rate, tick_rate, seq, server_ticks, cs.stats.simulated, cs.stats.speed_rejected,
		input_length(server_player.position - client_player.position), input_length(server_player.velocity - client_player.velocity), exact)
	if !exact || cs.stats.simulated != int(seq) || server_player.input_seq != seq - 1 || server_player.shot_seq == 0 {
		return input_test_fail("replay %d Hz at %d tick: server %v / %v, client %v / %v, simulated %d of %d, shots %d",
			rate, tick_rate, server_player.position, server_player.velocity, client_player.position, client_player.velocity, cs.stats.simulated, seq, server_player.shot_seq)
	}
	return true
}

@(private = "file")
input_length :: proc(v: shared.Vec3) -> f32 { return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) }

test_input_pipeline :: proc() -> bool {
	return test_input_batch_protocol() && test_input_validation() && test_input_command_stream() &&
		test_input_single_command_shot() && test_input_replay_vectors() && test_input_loopback_burst()
}
