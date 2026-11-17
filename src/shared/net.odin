package shared

import "core:encoding/endian"

PACKET_MAGIC :: 0x4B52554E // 'KRUN'
PACKET_HEADER_SIZE :: 7
PROTOCOL_VERSION :: 11 // 11: PLAYER_INPUT carries a batch of fixed-duration commands (net_input.odin)
PACKET_PLAYER_STATE_PAYLOAD_SIZE :: 122 // 11: + can_slide_timer and the cylinder push velocity
PACKET_BULLET_IMPACT_PAYLOAD_SIZE :: 49
// victim, killer, weapon (i32 each) + flags. Older clients skip the unknown
// packet type by its payload length, so this needs no PROTOCOL_VERSION bump.
PACKET_KILL_FEED_PAYLOAD_SIZE :: 13
MAX_PLAYERS_PER_MATCH :: 32
// The server broadcasts one snapshot per N simulation ticks.
SNAPSHOT_RATE_DIVISOR :: 2
NET_SEND_QUEUE_CAPACITY :: 64 * 1024

// TCP may accept only a prefix before a non-blocking socket reports
// Would_Block. Keep that prefix accounted for and retry the exact remaining
// bytes later so packet boundaries are never corrupted.
Net_Send_Queue :: struct {
	data:  [NET_SEND_QUEUE_CAPACITY]byte,
	start: int,
	end:   int,
}

net_send_queue_pending :: proc(queue: ^Net_Send_Queue) -> []byte {
	if queue == nil || queue.start >= queue.end {
		return nil
	}
	return queue.data[queue.start:queue.end]
}

net_send_queue_push :: proc(queue: ^Net_Send_Queue, data: []byte) -> bool {
	if queue == nil || len(data) == 0 {
		return queue != nil
	}

	pending := queue.end - queue.start
	if len(data) > NET_SEND_QUEUE_CAPACITY - pending {
		return false
	}

	if queue.end + len(data) > NET_SEND_QUEUE_CAPACITY {
		copy(queue.data[:pending], queue.data[queue.start:queue.end])
		queue.start = 0
		queue.end = pending
	}

	copy(queue.data[queue.end:queue.end + len(data)], data)
	queue.end += len(data)
	return true
}

net_send_queue_consume :: proc(queue: ^Net_Send_Queue, count: int) {
	if queue == nil || count <= 0 {
		return
	}

	pending := queue.end - queue.start
	queue.start += min(count, pending)
	if queue.start >= queue.end {
		queue.start = 0
		queue.end = 0
	}
}

Packet_Type :: enum u8 {
	CONNECT      = 1,
	DISCONNECT   = 2,
	PLAYER_INPUT = 3, // a batch of input commands, see net_input.odin
	GAME_STATE   = 4,
	PING         = 5,
	CHAT         = 6,
	MATCH_STATE  = 7,
	BULLET_IMPACT = 8,
	TEAM_REQUEST = 9,
	LOBBY_STATE = 10,
	KILL_FEED = 11,
}

Packet_Header :: struct {
	magic:       u32,
	packet_type: Packet_Type,
	payload_len: u16,
}

packet_serialize_connect :: proc(buf: []byte, class_id: i32, secondary_id: i32 = 2) -> int {
	if len(buf) < PACKET_HEADER_SIZE + 10 {
		return 0
	}
	endian.put_u32(buf[0:4], .Little, PACKET_MAGIC)
	buf[4] = u8(Packet_Type.CONNECT)
	endian.put_u16(buf[5:7], .Little, 10)
	endian.put_u16(buf[PACKET_HEADER_SIZE:PACKET_HEADER_SIZE + 2], .Little, PROTOCOL_VERSION)
	endian.put_i32(buf[PACKET_HEADER_SIZE + 2:PACKET_HEADER_SIZE + 6], .Little, class_id)
	endian.put_i32(buf[PACKET_HEADER_SIZE + 6:PACKET_HEADER_SIZE + 10], .Little, secondary_id)
	return PACKET_HEADER_SIZE + 10
}

packet_deserialize_connect :: proc(buf: []byte) -> (class_id: i32, version: u16, ok: bool) {
	class_id, _, version, ok = packet_deserialize_loadout(buf)
	return
}

packet_deserialize_loadout :: proc(buf: []byte) -> (class_id, secondary_id: i32, version: u16, ok: bool) {
	header, header_ok := packet_deserialize_header(buf)
	if !header_ok || header.packet_type != .CONNECT || (header.payload_len != 10 && header.payload_len != 6) || len(buf) != PACKET_HEADER_SIZE + int(header.payload_len) {
		return 0, 2, 0, false
	}
	version, _ = endian.get_u16(buf[PACKET_HEADER_SIZE:PACKET_HEADER_SIZE + 2], .Little)
	class_id, _ = endian.get_i32(buf[PACKET_HEADER_SIZE + 2:PACKET_HEADER_SIZE + 6], .Little)
	secondary_id = 2
	if header.payload_len == 10 { secondary_id, _ = endian.get_i32(buf[PACKET_HEADER_SIZE + 6:PACKET_HEADER_SIZE + 10], .Little) }
	return class_id, secondary_id, version, header.payload_len == 10 || version < PROTOCOL_VERSION
}

// Matches the C Player snapshot layout used for GAME_STATE.
Packet_Player_State :: struct {
	player_id: u32,
	active:    bool,
	is_you:    bool,
	team:      i32,
	class_id:  i32,
	secondary_id: i32,
	position:  Vec3,
	velocity:  Vec3,
	x_dir:     f32,
	y_dir:     f32,
	on_ground: bool,
	on_ladder: bool,
	on_ramp: bool,
	on_terrain: bool,
	terrain_slipping: bool,
	did_jump: bool,
	did_wall_jump: bool,
	can_slide: bool,
	on_wall: u8,
	wall_jump_count: u8, // wall jumps since landing, so prediction honours the class limit
	// Read by the next movement step but not derivable from the rest, so a
	// replay from this snapshot must start from them (Krunker's l sync sends
	// the same values).
	can_slide_timer: f32,
	cylinder_velocity: Vec2, // x_vel_cylinder, z_vel_cylinder
	crouch_val: f32,
	aim_val: f32,
	slide_timer: f32,
	jump_timer: f32,
	health:    f32,
	max_health: i32,
	weapon_id: u8,
	active_ammo: u32,
	shot_seq:   u32,
	ack_seq:   i32,
	spread_plus: f32,
	projectile_shot_seq: u32,
	// Scoreboard statistics; the server owns them, clients only display them.
	score, kills, deaths: u32,
}

// Why the server closed a connection. Sent as an optional 1-byte DISCONNECT
// payload; a client's own DISCONNECT stays empty. Older clients skip the
// packet by its length, so this needs no PROTOCOL_VERSION bump.
Disconnect_Reason :: enum u8 {
	NONE        = 0,
	SERVER_FULL = 1,
	SHUTDOWN    = 2,
}

packet_serialize_disconnect :: proc(buf: []byte, reason := Disconnect_Reason.NONE) -> int {
	payload := reason == .NONE ? 0 : 1
	if len(buf) < PACKET_HEADER_SIZE + payload {
		return 0
	}
	endian.put_u32(buf[0:4], .Little, PACKET_MAGIC)
	buf[4] = u8(Packet_Type.DISCONNECT)
	endian.put_u16(buf[5:7], .Little, u16(payload))
	if payload > 0 {
		buf[PACKET_HEADER_SIZE] = u8(reason)
	}
	return PACKET_HEADER_SIZE + payload
}

packet_deserialize_disconnect :: proc(buf: []byte) -> (reason: Disconnect_Reason, ok: bool) {
	header, header_ok := packet_deserialize_header(buf)
	if !header_ok || header.packet_type != .DISCONNECT || len(buf) != PACKET_HEADER_SIZE + int(header.payload_len) {
		return .NONE, false
	}
	if header.payload_len == 0 {
		return .NONE, true
	}
	value := buf[PACKET_HEADER_SIZE]
	if value > u8(max(Disconnect_Reason)) {
		return .NONE, true
	}
	return Disconnect_Reason(value), true
}

Packet_Match_State :: struct {
	phase:               Match_Phase,
	map_index:           i32,
	time_remaining:      f32,
	team1_score:         u32,
	team2_score:         u32,
	active_object_index: i32,
	active_zone:         i32,
	owner_team:          i32,
	contested:           bool,
	rotation_remaining:  f32,
	// Snapshot cadence the server is actually using; the client must
	// interpolate at this rate so motion stays smooth at any tick_rate.
	send_rate:           f32,
	player_count:        i32,
	player_ids:          [MAX_PLAYERS_PER_MATCH]u32,
}

packet_serialize_state :: proc(buf: []byte, state: ^Packet_Player_State) -> int {
	header_size := PACKET_HEADER_SIZE
	payload_size := PACKET_PLAYER_STATE_PAYLOAD_SIZE

	if len(buf) < header_size + payload_size {
		return 0
	}

	header := Packet_Header {
		magic       = PACKET_MAGIC,
		packet_type = .GAME_STATE,
		payload_len = u16(payload_size),
	}

	endian.put_u32(buf[0:4], .Little, header.magic)
	buf[4] = u8(header.packet_type)
	endian.put_u16(buf[5:7], .Little, header.payload_len)

	offset := header_size

	endian.put_u32(buf[offset:offset + 4], .Little, state.player_id)
	offset += 4
	buf[offset] = state.active ? 1 : 0
	offset += 1
	buf[offset] = state.is_you ? 1 : 0
	offset += 1
	endian.put_i32(buf[offset:offset + 4], .Little, state.team)
	offset += 4
	endian.put_i32(buf[offset:offset + 4], .Little, state.class_id)
	offset += 4

	endian.put_f32(buf[offset:offset + 4], .Little, state.position.x)
	endian.put_f32(buf[offset + 4:offset + 8], .Little, state.position.y)
	endian.put_f32(buf[offset + 8:offset + 12], .Little, state.position.z)
	offset += 12

	endian.put_f32(buf[offset:offset + 4], .Little, state.velocity.x)
	endian.put_f32(buf[offset + 4:offset + 8], .Little, state.velocity.y)
	endian.put_f32(buf[offset + 8:offset + 12], .Little, state.velocity.z)
	offset += 12

	endian.put_f32(buf[offset:offset + 4], .Little, state.x_dir)
	offset += 4

	endian.put_f32(buf[offset:offset + 4], .Little, state.y_dir)
	offset += 4

	movement_flags: u8
	movement_flags |= state.on_ground ? 1 : 0
	movement_flags |= state.on_ladder ? 2 : 0
	movement_flags |= state.on_ramp ? 4 : 0
	movement_flags |= state.on_terrain ? 8 : 0
	movement_flags |= state.terrain_slipping ? 16 : 0
	movement_flags |= state.did_jump ? 32 : 0
	movement_flags |= state.did_wall_jump ? 64 : 0
	movement_flags |= state.can_slide ? 128 : 0
	buf[offset] = movement_flags
	offset += 1
	buf[offset] = state.on_wall
	offset += 1

	endian.put_f32(buf[offset:offset + 4], .Little, state.crouch_val)
	offset += 4
	endian.put_f32(buf[offset:offset + 4], .Little, state.aim_val)
	offset += 4
	endian.put_f32(buf[offset:offset + 4], .Little, state.slide_timer)
	offset += 4
	endian.put_f32(buf[offset:offset + 4], .Little, state.jump_timer)
	offset += 4

	endian.put_f32(buf[offset:offset + 4], .Little, state.health)
	offset += 4
	endian.put_i32(buf[offset:offset + 4], .Little, state.max_health)
	offset += 4

	buf[offset] = state.weapon_id
	offset += 1
	endian.put_u32(buf[offset:offset + 4], .Little, state.active_ammo)
	offset += 4
	endian.put_u32(buf[offset:offset + 4], .Little, state.shot_seq)
	offset += 4
	endian.put_i32(buf[offset:offset + 4], .Little, state.ack_seq)
	offset += 4
	endian.put_f32(buf[offset:offset + 4], .Little, state.spread_plus)
	offset += 4
	endian.put_u32(buf[offset:offset + 4], .Little, state.projectile_shot_seq)
	offset += 4
	endian.put_i32(buf[offset:offset + 4], .Little, state.secondary_id)
	offset += 4
	endian.put_u32(buf[offset:offset + 4], .Little, state.score)
	endian.put_u32(buf[offset + 4:offset + 8], .Little, state.kills)
	endian.put_u32(buf[offset + 8:offset + 12], .Little, state.deaths)
	offset += 12
	buf[offset] = state.wall_jump_count
	offset += 1
	endian.put_f32(buf[offset:offset + 4], .Little, state.can_slide_timer)
	endian.put_f32(buf[offset + 4:offset + 8], .Little, state.cylinder_velocity.x)
	endian.put_f32(buf[offset + 8:offset + 12], .Little, state.cylinder_velocity.y)
	offset += 12

	return offset
}

packet_deserialize_state :: proc(buf: []byte) -> (state: Packet_Player_State, ok: bool) {
	header_size := PACKET_HEADER_SIZE
	payload_size := PACKET_PLAYER_STATE_PAYLOAD_SIZE

	header, header_ok := packet_deserialize_header(buf)
	if !header_ok || header.packet_type != .GAME_STATE || header.payload_len != u16(payload_size) || len(buf) != header_size + payload_size {
		return {}, false
	}

	offset := header_size

	state.player_id, _ = endian.get_u32(buf[offset:offset + 4], .Little)
	offset += 4
	state.active = buf[offset] != 0
	offset += 1
	state.is_you = buf[offset] != 0
	offset += 1
	state.team, _ = endian.get_i32(buf[offset:offset + 4], .Little)
	offset += 4
	state.class_id, _ = endian.get_i32(buf[offset:offset + 4], .Little)
	offset += 4

	state.position.x, _ = endian.get_f32(buf[offset:offset + 4], .Little)
	state.position.y, _ = endian.get_f32(buf[offset + 4:offset + 8], .Little)
	state.position.z, _ = endian.get_f32(buf[offset + 8:offset + 12], .Little)
	offset += 12

	state.velocity.x, _ = endian.get_f32(buf[offset:offset + 4], .Little)
	state.velocity.y, _ = endian.get_f32(buf[offset + 4:offset + 8], .Little)
	state.velocity.z, _ = endian.get_f32(buf[offset + 8:offset + 12], .Little)
	offset += 12

	state.x_dir, _ = endian.get_f32(buf[offset:offset + 4], .Little)
	offset += 4

	state.y_dir, _ = endian.get_f32(buf[offset:offset + 4], .Little)
	offset += 4

	movement_flags := buf[offset]
	offset += 1
	state.on_ground = (movement_flags & 1) != 0
	state.on_ladder = (movement_flags & 2) != 0
	state.on_ramp = (movement_flags & 4) != 0
	state.on_terrain = (movement_flags & 8) != 0
	state.terrain_slipping = (movement_flags & 16) != 0
	state.did_jump = (movement_flags & 32) != 0
	state.did_wall_jump = (movement_flags & 64) != 0
	state.can_slide = (movement_flags & 128) != 0
	state.on_wall = buf[offset]
	offset += 1

	state.crouch_val, _ = endian.get_f32(buf[offset:offset + 4], .Little)
	offset += 4
	state.aim_val, _ = endian.get_f32(buf[offset:offset + 4], .Little)
	offset += 4
	state.slide_timer, _ = endian.get_f32(buf[offset:offset + 4], .Little)
	offset += 4
	state.jump_timer, _ = endian.get_f32(buf[offset:offset + 4], .Little)
	offset += 4

	state.health, _ = endian.get_f32(buf[offset:offset + 4], .Little)
	offset += 4
	state.max_health, _ = endian.get_i32(buf[offset:offset + 4], .Little)
	offset += 4

	state.weapon_id = buf[offset]
	offset += 1
	state.active_ammo, _ = endian.get_u32(buf[offset:offset + 4], .Little)
	offset += 4
	state.shot_seq, _ = endian.get_u32(buf[offset:offset + 4], .Little)
	offset += 4
	state.ack_seq, _ = endian.get_i32(buf[offset:offset + 4], .Little)
	offset += 4
	state.spread_plus, _ = endian.get_f32(buf[offset:offset + 4], .Little)
	offset += 4
	state.projectile_shot_seq, _ = endian.get_u32(buf[offset:offset + 4], .Little)
	offset += 4
	state.secondary_id, _ = endian.get_i32(buf[offset:offset + 4], .Little)
	offset += 4
	state.score, _ = endian.get_u32(buf[offset:offset + 4], .Little)
	state.kills, _ = endian.get_u32(buf[offset + 4:offset + 8], .Little)
	state.deaths, _ = endian.get_u32(buf[offset + 8:offset + 12], .Little)
	state.wall_jump_count = buf[offset + 12]
	offset += 13
	state.can_slide_timer, _ = endian.get_f32(buf[offset:offset + 4], .Little)
	state.cylinder_velocity.x, _ = endian.get_f32(buf[offset + 4:offset + 8], .Little)
	state.cylinder_velocity.y, _ = endian.get_f32(buf[offset + 8:offset + 12], .Little)

	return state, true
}

packet_serialize_bullet_impact :: proc(buf: []byte, impact: ^Bullet_Impact) -> int {
	payload_size := PACKET_BULLET_IMPACT_PAYLOAD_SIZE
	if impact == nil || len(buf) < PACKET_HEADER_SIZE + payload_size {
		return 0
	}

	endian.put_u32(buf[0:4], .Little, PACKET_MAGIC)
	buf[4] = u8(Packet_Type.BULLET_IMPACT)
	endian.put_u16(buf[5:7], .Little, u16(payload_size))

	offset := PACKET_HEADER_SIZE
	endian.put_f32(buf[offset:offset + 4], .Little, impact.origin.x)
	endian.put_f32(buf[offset + 4:offset + 8], .Little, impact.origin.y)
	endian.put_f32(buf[offset + 8:offset + 12], .Little, impact.origin.z)
	offset += 12
	endian.put_f32(buf[offset:offset + 4], .Little, impact.position.x)
	endian.put_f32(buf[offset + 4:offset + 8], .Little, impact.position.y)
	endian.put_f32(buf[offset + 8:offset + 12], .Little, impact.position.z)
	offset += 12
	endian.put_f32(buf[offset:offset + 4], .Little, impact.normal.x)
	endian.put_f32(buf[offset + 4:offset + 8], .Little, impact.normal.y)
	endian.put_f32(buf[offset + 8:offset + 12], .Little, impact.normal.z)
	offset += 12
	buf[offset] = u8(impact.kind)
	endian.put_u32(buf[offset + 1:offset + 5], .Little, transmute(u32)impact.shooter_uid)
	endian.put_u32(buf[offset + 5:offset + 9], .Little, transmute(u32)impact.weapon_id)
	endian.put_u32(buf[offset + 9:offset + 13], .Little, transmute(u32)impact.object_index)

	return PACKET_HEADER_SIZE + payload_size
}

packet_deserialize_bullet_impact :: proc(buf: []byte) -> (impact: Bullet_Impact, ok: bool) {
	header, header_ok := packet_deserialize_header(buf)
	if !header_ok ||
	   header.packet_type != .BULLET_IMPACT ||
	   header.payload_len != u16(PACKET_BULLET_IMPACT_PAYLOAD_SIZE) ||
	   len(buf) != PACKET_HEADER_SIZE + PACKET_BULLET_IMPACT_PAYLOAD_SIZE {
		return {}, false
	}

	offset := PACKET_HEADER_SIZE
	impact.origin.x, _ = endian.get_f32(buf[offset:offset + 4], .Little)
	impact.origin.y, _ = endian.get_f32(buf[offset + 4:offset + 8], .Little)
	impact.origin.z, _ = endian.get_f32(buf[offset + 8:offset + 12], .Little)
	offset += 12
	impact.position.x, _ = endian.get_f32(buf[offset:offset + 4], .Little)
	impact.position.y, _ = endian.get_f32(buf[offset + 4:offset + 8], .Little)
	impact.position.z, _ = endian.get_f32(buf[offset + 8:offset + 12], .Little)
	offset += 12
	impact.normal.x, _ = endian.get_f32(buf[offset:offset + 4], .Little)
	impact.normal.y, _ = endian.get_f32(buf[offset + 4:offset + 8], .Little)
	impact.normal.z, _ = endian.get_f32(buf[offset + 8:offset + 12], .Little)
	offset += 12
	if buf[offset] > u8(Bullet_Hit_Kind.Player) { return {}, false }
	impact.kind = Bullet_Hit_Kind(buf[offset])
	impact.hit = impact.kind != .Miss
	shooter, _ := endian.get_u32(buf[offset + 1:offset + 5], .Little)
	weapon, _ := endian.get_u32(buf[offset + 5:offset + 9], .Little)
	object, _ := endian.get_u32(buf[offset + 9:offset + 13], .Little)
	impact.shooter_uid = transmute(i32)shooter
	impact.weapon_id = transmute(i32)weapon
	impact.object_index = transmute(i32)object
	if impact.weapon_id < 0 || int(impact.weapon_id) >= len(WEAPONS_LIST) || WEAPONS_LIST[impact.weapon_id] == nil ||
	   impact.shooter_uid < 0 || (impact.kind == .World ? impact.object_index < 0 : impact.object_index != -1) {
		return {}, false
	}
	for vector in ([3]Vec3{impact.origin, impact.position, impact.normal}) {
		for value in vector { if !(value >= -1e8 && value <= 1e8) { return {}, false } }
	}

	return impact, true
}

packet_deserialize_header :: proc(buf: []byte) -> (header: Packet_Header, ok: bool) {
	if len(buf) < PACKET_HEADER_SIZE {
		return {}, false
	}

	header.magic, _ = endian.get_u32(buf[0:4], .Little)
	if header.magic != PACKET_MAGIC {
		return {}, false
	}

	header.packet_type = Packet_Type(buf[4])
	header.payload_len, _ = endian.get_u16(buf[5:7], .Little)

	return header, true
}

packet_match_state_from_game :: proc(game: ^Game) -> Packet_Match_State {
	state := Packet_Match_State{
		phase               = game.match.phase,
		map_index           = game.current_map_index,
		// During WARMUP the match clock is not running, so time_remaining
		// carries the warmup left (phase_remaining) for the client's
		// countdown; the client keeps its match clock as it was.
		time_remaining      = game.match.phase == .WARMUP ? game.match.phase_remaining : game.match.time_remaining,
		team1_score         = game.match.team_scores[1],
		team2_score         = game.match.team_scores[2],
		active_object_index = game.match.objective.active_object_index,
		active_zone         = game.match.objective.active_zone,
		owner_team          = game.match.objective.owner_team,
		contested           = game.match.objective.contested,
		rotation_remaining  = game.match.objective.rotation_remaining,
	}

	// Authoritative roster: every player the server still tracks. Clients use
	// this list to drop ghosts when someone disconnects.
	state.player_count = min(i32(len(game.players)), MAX_PLAYERS_PER_MATCH)
	for i in 0 ..< state.player_count {
		state.player_ids[i] = u32(game.players[i].uid)
	}
	return state
}

packet_apply_match_state :: proc(game: ^Game, state: ^Packet_Match_State) {
	game.match.phase = state.phase
	game.current_map_index = state.map_index
	if state.phase == .WARMUP { game.match.phase_remaining = state.time_remaining }
	else { game.match.time_remaining = state.time_remaining }
	game.match.team_scores[1] = state.team1_score
	game.match.team_scores[2] = state.team2_score
	game.match.objective.active_object_index = state.active_object_index
	game.match.objective.active_zone = state.active_zone
	game.match.objective.owner_team = state.owner_team
	game.match.objective.contested = state.contested
	game.match.objective.rotation_remaining = state.rotation_remaining
}

packet_serialize_match_state :: proc(buf: []byte, state: ^Packet_Match_State) -> int {
	count := clamp(state.player_count, 0, MAX_PLAYERS_PER_MATCH)
	payload_size := 42 + int(count) * 4
	if len(buf) < PACKET_HEADER_SIZE + payload_size {
		return 0
	}

	endian.put_u32(buf[0:4], .Little, PACKET_MAGIC)
	buf[4] = u8(Packet_Type.MATCH_STATE)
	endian.put_u16(buf[5:7], .Little, u16(payload_size))
	offset := PACKET_HEADER_SIZE
	buf[offset] = u8(state.phase); offset += 1
	endian.put_i32(buf[offset:offset + 4], .Little, state.map_index); offset += 4
	endian.put_f32(buf[offset:offset + 4], .Little, state.time_remaining); offset += 4
	endian.put_u32(buf[offset:offset + 4], .Little, state.team1_score); offset += 4
	endian.put_u32(buf[offset:offset + 4], .Little, state.team2_score); offset += 4
	endian.put_i32(buf[offset:offset + 4], .Little, state.active_object_index); offset += 4
	endian.put_i32(buf[offset:offset + 4], .Little, state.active_zone); offset += 4
	endian.put_i32(buf[offset:offset + 4], .Little, state.owner_team); offset += 4
	buf[offset] = state.contested ? 1 : 0; offset += 1
	endian.put_f32(buf[offset:offset + 4], .Little, state.rotation_remaining); offset += 4
	endian.put_f32(buf[offset:offset + 4], .Little, state.send_rate); offset += 4
	endian.put_i32(buf[offset:offset + 4], .Little, count); offset += 4
	for i in 0 ..< count {
		endian.put_u32(buf[offset:offset + 4], .Little, state.player_ids[i])
		offset += 4
	}
	return offset
}

packet_deserialize_match_state :: proc(buf: []byte) -> (state: Packet_Match_State, ok: bool) {
	header, header_ok := packet_deserialize_header(buf)
	if !header_ok || header.packet_type != .MATCH_STATE || header.payload_len < 42 || len(buf) < PACKET_HEADER_SIZE + 42 {
		return {}, false
	}

	offset := PACKET_HEADER_SIZE
	state.phase = Match_Phase(buf[offset]); offset += 1
	state.map_index, _ = endian.get_i32(buf[offset:offset + 4], .Little); offset += 4
	state.time_remaining, _ = endian.get_f32(buf[offset:offset + 4], .Little); offset += 4
	state.team1_score, _ = endian.get_u32(buf[offset:offset + 4], .Little); offset += 4
	state.team2_score, _ = endian.get_u32(buf[offset:offset + 4], .Little); offset += 4
	state.active_object_index, _ = endian.get_i32(buf[offset:offset + 4], .Little); offset += 4
	state.active_zone, _ = endian.get_i32(buf[offset:offset + 4], .Little); offset += 4
	state.owner_team, _ = endian.get_i32(buf[offset:offset + 4], .Little); offset += 4
	state.contested = buf[offset] != 0; offset += 1
	state.rotation_remaining, _ = endian.get_f32(buf[offset:offset + 4], .Little); offset += 4
	state.send_rate, _ = endian.get_f32(buf[offset:offset + 4], .Little); offset += 4

	count, _ := endian.get_i32(buf[offset:offset + 4], .Little)
	offset += 4
	if count < 0 || count > MAX_PLAYERS_PER_MATCH {
		return {}, false
	}
	if int(header.payload_len) != 42 + int(count) * 4 || len(buf) != PACKET_HEADER_SIZE + 42 + int(count) * 4 {
		return {}, false
	}
	state.player_count = count
	for i in 0 ..< count {
		state.player_ids[i], _ = endian.get_u32(buf[offset:offset + 4], .Little)
		offset += 4
	}
	return state, true
}

// Networking hooks — the C port declares these as SHIMs; keep the same contracts.
player_send_event :: proc() {
	// SHIM
}

game_broadcast :: proc() {
	// SHIM
}

packet_serialize_kill_feed :: proc(buf: []byte, event: ^Kill_Event) -> int {
	if event == nil || len(buf) < PACKET_HEADER_SIZE + PACKET_KILL_FEED_PAYLOAD_SIZE { return 0 }
	endian.put_u32(buf[0:4], .Little, PACKET_MAGIC)
	buf[4] = u8(Packet_Type.KILL_FEED)
	endian.put_u16(buf[5:7], .Little, u16(PACKET_KILL_FEED_PAYLOAD_SIZE))
	offset := PACKET_HEADER_SIZE
	endian.put_u32(buf[offset:offset + 4], .Little, transmute(u32)event.victim_uid)
	endian.put_u32(buf[offset + 4:offset + 8], .Little, transmute(u32)event.killer_uid)
	endian.put_u32(buf[offset + 8:offset + 12], .Little, transmute(u32)event.weapon_id)
	buf[offset + 12] = event.headshot ? 1 : 0
	return PACKET_HEADER_SIZE + PACKET_KILL_FEED_PAYLOAD_SIZE
}

packet_deserialize_kill_feed :: proc(buf: []byte) -> (event: Kill_Event, ok: bool) {
	header, header_ok := packet_deserialize_header(buf)
	if !header_ok || header.packet_type != .KILL_FEED || header.payload_len != u16(PACKET_KILL_FEED_PAYLOAD_SIZE) ||
	   len(buf) != PACKET_HEADER_SIZE + PACKET_KILL_FEED_PAYLOAD_SIZE {
		return {}, false
	}
	offset := PACKET_HEADER_SIZE
	victim, _ := endian.get_u32(buf[offset:offset + 4], .Little)
	killer, _ := endian.get_u32(buf[offset + 4:offset + 8], .Little)
	weapon, _ := endian.get_u32(buf[offset + 8:offset + 12], .Little)
	event.victim_uid, event.killer_uid, event.weapon_id = transmute(i32)victim, transmute(i32)killer, transmute(i32)weapon
	event.headshot = buf[offset + 12] & 1 != 0
	if event.victim_uid < 0 || event.killer_uid < -1 || buf[offset + 12] > 1 ||
	   (event.weapon_id != -1 && (event.weapon_id < 0 || int(event.weapon_id) >= len(WEAPONS_LIST) || WEAPONS_LIST[event.weapon_id] == nil)) {
		return {}, false
	}
	return event, true
}

// CHAT (Krodin's native protocol; Krunker's equivalents are "ct" and "ch").
// Client -> server: [team u8][length u8][text]. team 1 asks for team-only chat.
// Server -> client: [sender i32][team u8][length u8][text]. sender is the
// player uid, or NET_CHAT_SYSTEM for the server's own lines; team 1 marks a
// team-only message. Text is printable ASCII, 1..NET_CHAT_MAX_LENGTH bytes
// (Krunker's #chatInput maxlength). Older peers skip the packet type.
NET_CHAT_MAX_LENGTH :: 70
NET_CHAT_SYSTEM :: i32(-1)
NET_CHAT_REQUEST_MAX_SIZE :: PACKET_HEADER_SIZE + 2 + NET_CHAT_MAX_LENGTH
NET_CHAT_MAX_SIZE :: PACKET_HEADER_SIZE + 6 + NET_CHAT_MAX_LENGTH

net_chat_text_valid :: proc(text: string) -> bool {
	if len(text) == 0 || len(text) > NET_CHAT_MAX_LENGTH { return false }
	blank := true
	for i in 0..<len(text) {
		c := text[i]
		if c < 32 || c >= 127 { return false }
		if c != ' ' { blank = false }
	}
	return !blank
}

packet_serialize_chat_request :: proc(buf: []byte, text: string, team: bool) -> int {
	if !net_chat_text_valid(text) || len(buf) < PACKET_HEADER_SIZE + 2 + len(text) { return 0 }
	endian.put_u32(buf[0:4], .Little, PACKET_MAGIC)
	buf[4] = u8(Packet_Type.CHAT)
	endian.put_u16(buf[5:7], .Little, u16(2 + len(text)))
	buf[PACKET_HEADER_SIZE] = team ? 1 : 0
	buf[PACKET_HEADER_SIZE + 1] = u8(len(text))
	copy(buf[PACKET_HEADER_SIZE + 2:], text)
	return PACKET_HEADER_SIZE + 2 + len(text)
}

// The text points into `buf`. Invalid text (control characters, blank, too
// long or a length that disagrees with the payload) fails.
packet_deserialize_chat_request :: proc(buf: []byte) -> (text: string, team: bool, ok: bool) {
	header, header_ok := packet_deserialize_header(buf)
	if !header_ok || header.packet_type != .CHAT || header.payload_len < 2 || len(buf) != PACKET_HEADER_SIZE + int(header.payload_len) { return }
	length := int(buf[PACKET_HEADER_SIZE + 1])
	if buf[PACKET_HEADER_SIZE] > 1 || int(header.payload_len) != 2 + length { return }
	text = string(buf[PACKET_HEADER_SIZE + 2:])
	if !net_chat_text_valid(text) { return "", false, false }
	return text, buf[PACKET_HEADER_SIZE] == 1, true
}

packet_serialize_chat :: proc(buf: []byte, sender: i32, team: bool, text: string) -> int {
	if !net_chat_text_valid(text) || len(buf) < PACKET_HEADER_SIZE + 6 + len(text) { return 0 }
	endian.put_u32(buf[0:4], .Little, PACKET_MAGIC)
	buf[4] = u8(Packet_Type.CHAT)
	endian.put_u16(buf[5:7], .Little, u16(6 + len(text)))
	endian.put_u32(buf[PACKET_HEADER_SIZE:PACKET_HEADER_SIZE + 4], .Little, transmute(u32)sender)
	buf[PACKET_HEADER_SIZE + 4] = team ? 1 : 0
	buf[PACKET_HEADER_SIZE + 5] = u8(len(text))
	copy(buf[PACKET_HEADER_SIZE + 6:], text)
	return PACKET_HEADER_SIZE + 6 + len(text)
}

packet_deserialize_chat :: proc(buf: []byte) -> (sender: i32, team: bool, text: string, ok: bool) {
	header, header_ok := packet_deserialize_header(buf)
	if !header_ok || header.packet_type != .CHAT || header.payload_len < 6 || len(buf) != PACKET_HEADER_SIZE + int(header.payload_len) { return }
	length := int(buf[PACKET_HEADER_SIZE + 5])
	if buf[PACKET_HEADER_SIZE + 4] > 1 || int(header.payload_len) != 6 + length { return }
	raw, _ := endian.get_u32(buf[PACKET_HEADER_SIZE:PACKET_HEADER_SIZE + 4], .Little)
	text = string(buf[PACKET_HEADER_SIZE + 6:])
	if !net_chat_text_valid(text) { return 0, false, "", false }
	return transmute(i32)raw, buf[PACKET_HEADER_SIZE + 4] == 1, text, true
}
