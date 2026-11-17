package shared

import "core:encoding/endian"
import "core:math"

// Native snapshots (protocol 12): one SNAPSHOT packet per client per server
// snapshot, numbered by server tick and delta-encoded against the newest
// snapshot that client acknowledged (SNAPSHOT_ACK). Krodin's own format;
// Krunker's equivalent is UPDATE_PLAYERS (`k`), which carries the server time
// (`M - this.startTime`) and the send rate (`this.sendFrequency`, set from the
// mode's `sendR` or the game's `snf`) and skips players beyond the mode's
// `viewDis` (krunkbox game.min.js `this.updateState=function`).
//
// SNAPSHOT payload (little endian; varint = LEB128, zvarint = zigzag varint):
//   u32  tick              server tick of this snapshot
//   u32  server_time_ms    tick * 1000 / tick_rate
//   u8   baseline_back     0: full snapshot; else the baseline is tick - back
//   u8   flags             SNAPSHOT_FLAG_*
//   varint you_id          the recipient's player id (0 before it joins)
//   [match]                if SNAPSHOT_FLAG_MATCH: Snapshot_Match, see below
//   [lobby]                if SNAPSHOT_FLAG_LOBBY: varint length + a LOBBY_STATE packet
//   varint entity_count
//   entity_count x:  varint id, varint field mask, then each masked field:
//                    the recipient's own float fields: 4 raw f32 bytes;
//                    every other field: zvarint of (value - baseline value)
//   [events]               if SNAPSHOT_FLAG_EVENTS: varint impacts, 49-byte
//                          BULLET_IMPACT payloads, varint kills, 13-byte KILL_FEED payloads
//
// An entity that is not in the baseline is encoded against all-zero fields;
// one missing from the list has left (or was never sent). Match and lobby are
// sent only when they differ from the baseline, so a client that sees them
// absent takes the baseline's copy.
//
// Precision: the recipient's own player travels unquantised (raw f32 bits),
// so reconciliation replays from exactly the server's state. Other players
// are quantised (SNAPSHOT_SCALES): positions to 1/128 unit, angles to whole
// milliradians (the grid input commands already use, so a native player's
// angles are lossless), crouch/aim to 1/255 and health to 1/16.

SNAPSHOT_RING :: 64 // snapshots both ends keep as possible baselines
SNAPSHOT_MAX_BACK :: SNAPSHOT_RING - 1 // older baselines fall back to a full snapshot
SNAPSHOT_MAX_ENTITIES :: MAX_PLAYERS_PER_MATCH
SNAPSHOT_LOBBY_MAX :: PACKET_HEADER_SIZE + 80 + MAX_PLAYERS_PER_MATCH * 12
SNAPSHOT_MAX_PACKET :: PACKET_HEADER_SIZE + 65535
SNAPSHOT_HEADER_SIZE :: 10
SNAPSHOT_ACK_PAYLOAD_SIZE :: 5
SNAPSHOT_ACK_PACKET_SIZE :: PACKET_HEADER_SIZE + SNAPSHOT_ACK_PAYLOAD_SIZE

SNAPSHOT_FLAG_MATCH :: 1
SNAPSHOT_FLAG_LOBBY :: 2
SNAPSHOT_FLAG_EVENTS :: 4

// SNAPSHOT_ACK flags: the client could not decode a delta (lost baseline) and
// asks for a full snapshot.
SNAPSHOT_ACK_RESET :: 1

// Entity fields, most frequently changing first so the mask stays short.
Snapshot_Field :: enum u8 {
	POS_X, POS_Y, POS_Z, YAW, PITCH, FLAGS, CROUCH, AIM,
	HEALTH, SHOT_SEQ, PROJECTILE_SHOT_SEQ, WEAPON, AMMO,
	// Only the recipient's own player: reconciliation needs them, nobody
	// else's view does, and they change on almost every tick.
	VEL_X, VEL_Y, VEL_Z, ACK_SEQ, SLIDE_TIMER, JUMP_TIMER, CAN_SLIDE_TIMER, CYL_X, CYL_Z, SPREAD,
	// Rarely changing: a delta leaves them out of almost every snapshot.
	TEAM, CLASS, SECONDARY, MAX_HEALTH, SCORE, KILLS, DEATHS,
}
SNAPSHOT_FIELD_COUNT :: len(Snapshot_Field)

// FLAGS word: movement flags (bits 0-7 as in GAME_STATE), on_wall << 8,
// wall_jump_count << 16, then these.
SNAPSHOT_ENTITY_ACTIVE :: u32(1) << 24
// Beyond the recipient's view distance: pose fields are frozen at the
// baseline's and the client hides the player until it comes back.
SNAPSHOT_ENTITY_CULLED :: u32(1) << 25

// Quantisation steps per unit for other players' float fields (0: integer
// field, or own-only and always 0 for others).
SNAPSHOT_SCALES := [Snapshot_Field]f32 {
	.POS_X = 128, .POS_Y = 128, .POS_Z = 128,
	.YAW = 1000, .PITCH = 1000,
	.CROUCH = 255, .AIM = 255, .HEALTH = 16,
	.FLAGS = 0, .SHOT_SEQ = 0, .PROJECTILE_SHOT_SEQ = 0, .WEAPON = 0, .AMMO = 0,
	.VEL_X = 0, .VEL_Y = 0, .VEL_Z = 0, .ACK_SEQ = 0, .SLIDE_TIMER = 0, .JUMP_TIMER = 0, .CAN_SLIDE_TIMER = 0, .CYL_X = 0, .CYL_Z = 0, .SPREAD = 0,
	.TEAM = 0, .CLASS = 0, .SECONDARY = 0, .MAX_HEALTH = 0, .SCORE = 0, .KILLS = 0, .DEATHS = 0,
}

// Float fields: raw f32 bits for the recipient's own player.
SNAPSHOT_FLOAT_FIELDS :: bit_set[Snapshot_Field]{
	.POS_X, .POS_Y, .POS_Z, .YAW, .PITCH, .CROUCH, .AIM, .HEALTH,
	.VEL_X, .VEL_Y, .VEL_Z, .SLIDE_TIMER, .JUMP_TIMER, .CAN_SLIDE_TIMER, .CYL_X, .CYL_Z, .SPREAD,
}
SNAPSHOT_OWN_ONLY_FIELDS :: bit_set[Snapshot_Field]{.VEL_X, .VEL_Y, .VEL_Z, .ACK_SEQ, .SLIDE_TIMER, .JUMP_TIMER, .CAN_SLIDE_TIMER, .CYL_X, .CYL_Z, .SPREAD}
// Kept current for players beyond view distance (the scoreboard needs them).
SNAPSHOT_INFO_FIELDS :: bit_set[Snapshot_Field]{.TEAM, .CLASS, .SECONDARY, .MAX_HEALTH, .SCORE, .KILLS, .DEATHS}

Snapshot_Entity :: struct {
	id:    u32,
	words: [Snapshot_Field]u32,
}

// The match part of a snapshot. Clocks are in tenths of a second, so the
// section only changes ten times a second instead of every tick.
Snapshot_Match :: struct {
	phase:               u8,
	map_index:           i32,
	time_ds:             u32,
	team1_score:         u32,
	team2_score:         u32,
	active_object_index: i32,
	active_zone:         i32,
	owner_team:          i32,
	contested:           bool,
	rotation_ds:         u32,
	send_rate:           f32,
	tick_rate:           u32,
}

Snapshot_Frame :: struct {
	tick:           u32,
	server_time_ms: u32,
	you_id:         u32,
	valid:          bool,
	match:          Snapshot_Match,
	lobby:          [SNAPSHOT_LOBBY_MAX]u8,
	lobby_len:      int,
	count:          int,
	entities:       [SNAPSHOT_MAX_ENTITIES]Snapshot_Entity,
}

// The last SNAPSHOT_RING snapshots, by tick. Allocate it on the heap (about
// 300 KB).
Snapshot_Ring :: struct {
	frames: [SNAPSHOT_RING]Snapshot_Frame,
}

snapshot_ring_find :: proc(ring: ^Snapshot_Ring, tick: u32) -> ^Snapshot_Frame {
	if ring == nil { return nil }
	frame := &ring.frames[tick % SNAPSHOT_RING]
	return frame.valid && frame.tick == tick ? frame : nil
}

snapshot_ring_store :: proc(ring: ^Snapshot_Ring, frame: ^Snapshot_Frame) {
	if ring == nil { return }
	slot := &ring.frames[frame.tick % SNAPSHOT_RING]
	slot^ = frame^
	slot.valid = true
}

snapshot_ring_clear :: proc(ring: ^Snapshot_Ring) {
	if ring == nil { return }
	for &frame in ring.frames { frame.valid = false }
}

// Wrap-safe "a is after b" for ticks.
snapshot_tick_after :: proc(a, b: u32) -> bool {
	return i32(a - b) > 0
}

snapshot_server_time_ms :: proc(tick: u64, tick_rate: int) -> u32 {
	return u32(tick * 1000 / u64(max(1, tick_rate)))
}

snapshot_quantize :: proc(value, scale: f32) -> u32 {
	if value != value { return 0 }
	q := math.round(f64(value) * f64(scale))
	return transmute(u32)i32(clamp(q, -2147483647, 2147483647))
}

snapshot_dequantize :: proc(word: u32, scale: f32) -> f32 {
	return f32(f64(transmute(i32)word) / f64(scale))
}

@(private = "file")
entity_float :: proc(entity: ^Snapshot_Entity, field: Snapshot_Field, value: f32, own: bool) {
	if own {
		entity.words[field] = transmute(u32)value
	} else if field not_in SNAPSHOT_OWN_ONLY_FIELDS {
		entity.words[field] = snapshot_quantize(value, SNAPSHOT_SCALES[field])
	}
}

@(private = "file")
entity_get_float :: proc(entity: ^Snapshot_Entity, field: Snapshot_Field, own: bool) -> f32 {
	if own { return transmute(f32)entity.words[field] }
	if field in SNAPSHOT_OWN_ONLY_FIELDS { return 0 }
	return snapshot_dequantize(entity.words[field], SNAPSHOT_SCALES[field])
}

// One player as entity words: `own` is the recipient's player (unquantised).
snapshot_entity_from_state :: proc(state: ^Packet_Player_State, own: bool) -> (e: Snapshot_Entity) {
	e.id = state.player_id
	entity_float(&e, .POS_X, state.position.x, own)
	entity_float(&e, .POS_Y, state.position.y, own)
	entity_float(&e, .POS_Z, state.position.z, own)
	entity_float(&e, .YAW, own ? state.y_dir : normalize_angle(state.y_dir), own)
	entity_float(&e, .PITCH, state.x_dir, own)
	movement: u32
	movement |= state.on_ground ? 1 : 0
	movement |= state.on_ladder ? 2 : 0
	movement |= state.on_ramp ? 4 : 0
	movement |= state.on_terrain ? 8 : 0
	movement |= state.terrain_slipping ? 16 : 0
	movement |= state.did_jump ? 32 : 0
	movement |= state.did_wall_jump ? 64 : 0
	movement |= state.can_slide ? 128 : 0
	movement |= u32(state.on_wall) << 8
	movement |= u32(state.wall_jump_count) << 16
	movement |= state.active ? SNAPSHOT_ENTITY_ACTIVE : 0
	movement |= state.culled ? SNAPSHOT_ENTITY_CULLED : 0
	e.words[.FLAGS] = movement
	entity_float(&e, .CROUCH, state.crouch_val, own)
	entity_float(&e, .AIM, state.aim_val, own)
	entity_float(&e, .HEALTH, state.health, own)
	e.words[.SHOT_SEQ] = state.shot_seq
	e.words[.PROJECTILE_SHOT_SEQ] = state.projectile_shot_seq
	e.words[.WEAPON] = u32(state.weapon_id)
	e.words[.AMMO] = state.active_ammo
	entity_float(&e, .VEL_X, state.velocity.x, own)
	entity_float(&e, .VEL_Y, state.velocity.y, own)
	entity_float(&e, .VEL_Z, state.velocity.z, own)
	if own { e.words[.ACK_SEQ] = transmute(u32)state.ack_seq }
	entity_float(&e, .SLIDE_TIMER, state.slide_timer, own)
	entity_float(&e, .JUMP_TIMER, state.jump_timer, own)
	entity_float(&e, .CAN_SLIDE_TIMER, state.can_slide_timer, own)
	entity_float(&e, .CYL_X, state.cylinder_velocity.x, own)
	entity_float(&e, .CYL_Z, state.cylinder_velocity.y, own)
	entity_float(&e, .SPREAD, state.spread_plus, own)
	e.words[.TEAM] = transmute(u32)state.team
	e.words[.CLASS] = transmute(u32)state.class_id
	e.words[.SECONDARY] = transmute(u32)state.secondary_id
	e.words[.MAX_HEALTH] = transmute(u32)state.max_health
	e.words[.SCORE] = state.score
	e.words[.KILLS] = state.kills
	e.words[.DEATHS] = state.deaths
	return
}

snapshot_entity_to_state :: proc(e: ^Snapshot_Entity, own: bool) -> (state: Packet_Player_State) {
	state.player_id = e.id
	state.is_you = own
	state.position = {entity_get_float(e, .POS_X, own), entity_get_float(e, .POS_Y, own), entity_get_float(e, .POS_Z, own)}
	state.y_dir = entity_get_float(e, .YAW, own)
	state.x_dir = entity_get_float(e, .PITCH, own)
	movement := e.words[.FLAGS]
	state.on_ground = movement & 1 != 0
	state.on_ladder = movement & 2 != 0
	state.on_ramp = movement & 4 != 0
	state.on_terrain = movement & 8 != 0
	state.terrain_slipping = movement & 16 != 0
	state.did_jump = movement & 32 != 0
	state.did_wall_jump = movement & 64 != 0
	state.can_slide = movement & 128 != 0
	state.on_wall = u8(movement >> 8)
	state.wall_jump_count = u8(movement >> 16)
	state.culled = movement & SNAPSHOT_ENTITY_CULLED != 0
	state.active = movement & SNAPSHOT_ENTITY_ACTIVE != 0 && !state.culled
	state.crouch_val = entity_get_float(e, .CROUCH, own)
	state.aim_val = entity_get_float(e, .AIM, own)
	state.health = entity_get_float(e, .HEALTH, own)
	state.shot_seq = e.words[.SHOT_SEQ]
	state.projectile_shot_seq = e.words[.PROJECTILE_SHOT_SEQ]
	state.weapon_id = u8(e.words[.WEAPON])
	state.active_ammo = e.words[.AMMO]
	state.velocity = {entity_get_float(e, .VEL_X, own), entity_get_float(e, .VEL_Y, own), entity_get_float(e, .VEL_Z, own)}
	state.ack_seq = own ? transmute(i32)e.words[.ACK_SEQ] : -1
	state.slide_timer = entity_get_float(e, .SLIDE_TIMER, own)
	state.jump_timer = entity_get_float(e, .JUMP_TIMER, own)
	state.can_slide_timer = entity_get_float(e, .CAN_SLIDE_TIMER, own)
	state.cylinder_velocity = {entity_get_float(e, .CYL_X, own), entity_get_float(e, .CYL_Z, own)}
	state.spread_plus = entity_get_float(e, .SPREAD, own)
	state.team = transmute(i32)e.words[.TEAM]
	state.class_id = transmute(i32)e.words[.CLASS]
	state.secondary_id = transmute(i32)e.words[.SECONDARY]
	state.max_health = transmute(i32)e.words[.MAX_HEALTH]
	state.score = e.words[.SCORE]
	state.kills = e.words[.KILLS]
	state.deaths = e.words[.DEATHS]
	return
}

// A player beyond the recipient's view distance: the baseline's pose (or
// zeros) with only the scoreboard fields kept current, marked culled.
snapshot_entity_culled :: proc(current: ^Snapshot_Entity, baseline: ^Snapshot_Entity) -> (e: Snapshot_Entity) {
	if baseline != nil { e = baseline^ }
	e.id = current.id
	for field in SNAPSHOT_INFO_FIELDS { e.words[field] = current.words[field] }
	e.words[.FLAGS] = (e.words[.FLAGS] &~ SNAPSHOT_ENTITY_ACTIVE) | SNAPSHOT_ENTITY_CULLED
	return
}

snapshot_match_from_state :: proc(state: ^Packet_Match_State, tick_rate: int) -> Snapshot_Match {
	deciseconds :: proc(seconds: f32) -> u32 {
		if !(seconds > 0) { return 0 }
		return u32(min(math.ceil(f64(seconds) * 10), 4e9))
	}
	return {
		phase = u8(state.phase), map_index = state.map_index, time_ds = deciseconds(state.time_remaining),
		team1_score = state.team1_score, team2_score = state.team2_score,
		active_object_index = state.active_object_index, active_zone = state.active_zone, owner_team = state.owner_team,
		contested = state.contested, rotation_ds = deciseconds(state.rotation_remaining),
		send_rate = state.send_rate, tick_rate = u32(max(0, tick_rate)),
	}
}

// The match state a snapshot describes; the roster is not part of it (the
// caller fills player_ids from the lobby).
snapshot_match_to_state :: proc(m: ^Snapshot_Match) -> Packet_Match_State {
	return {
		phase = Match_Phase(min(m.phase, u8(max(Match_Phase)))), map_index = m.map_index, time_remaining = f32(m.time_ds) / 10,
		team1_score = m.team1_score, team2_score = m.team2_score,
		active_object_index = m.active_object_index, active_zone = m.active_zone, owner_team = m.owner_team,
		contested = m.contested, rotation_remaining = f32(m.rotation_ds) / 10, send_rate = m.send_rate,
	}
}

// ---------------------------------------------------------------- writer --

@(private = "file")
Writer :: struct {
	buf: []byte,
	at:  int,
	ok:  bool,
}

@(private = "file")
put_u8 :: proc(w: ^Writer, v: u8) {
	if w.at + 1 > len(w.buf) { w.ok = false; return }
	w.buf[w.at] = v
	w.at += 1
}

@(private = "file")
put_u32 :: proc(w: ^Writer, v: u32) {
	if w.at + 4 > len(w.buf) { w.ok = false; return }
	endian.put_u32(w.buf[w.at:w.at + 4], .Little, v)
	w.at += 4
}

@(private = "file")
put_varint :: proc(w: ^Writer, v: u32) {
	v := v
	for {
		b := u8(v & 0x7f)
		v >>= 7
		if v == 0 { put_u8(w, b); return }
		put_u8(w, b | 0x80)
	}
}

@(private = "file")
put_zvarint :: proc(w: ^Writer, v: i32) {
	put_varint(w, u32((v << 1) ~ (v >> 31)))
}

@(private = "file")
put_bytes :: proc(w: ^Writer, data: []byte) {
	if w.at + len(data) > len(w.buf) { w.ok = false; return }
	copy(w.buf[w.at:], data)
	w.at += len(data)
}

@(private = "file")
Reader :: struct {
	buf: []byte,
	at:  int,
	ok:  bool,
}

@(private = "file")
get_u8 :: proc(r: ^Reader) -> u8 {
	if r.at + 1 > len(r.buf) { r.ok = false; return 0 }
	r.at += 1
	return r.buf[r.at - 1]
}

@(private = "file")
get_u32 :: proc(r: ^Reader) -> u32 {
	if r.at + 4 > len(r.buf) { r.ok = false; return 0 }
	v, _ := endian.get_u32(r.buf[r.at:r.at + 4], .Little)
	r.at += 4
	return v
}

@(private = "file")
get_varint :: proc(r: ^Reader) -> u32 {
	v: u32
	for shift := u32(0); shift < 35; shift += 7 {
		b := get_u8(r)
		if !r.ok { return 0 }
		if shift == 28 && b > 0x0f { r.ok = false; return 0 }
		v |= u32(b & 0x7f) << shift
		if b & 0x80 == 0 { return v }
	}
	r.ok = false
	return 0
}

@(private = "file")
get_zvarint :: proc(r: ^Reader) -> i32 {
	u := get_varint(r)
	return i32(u >> 1) ~ -i32(u & 1)
}

@(private = "file")
get_bytes :: proc(r: ^Reader, n: int) -> []byte {
	if n < 0 || r.at + n > len(r.buf) { r.ok = false; return nil }
	r.at += n
	return r.buf[r.at - n:r.at]
}

@(private = "file")
put_match :: proc(w: ^Writer, m: ^Snapshot_Match) {
	put_u8(w, m.phase)
	put_zvarint(w, m.map_index)
	put_varint(w, m.time_ds)
	put_varint(w, m.team1_score)
	put_varint(w, m.team2_score)
	put_zvarint(w, m.active_object_index)
	put_zvarint(w, m.active_zone)
	put_zvarint(w, m.owner_team)
	put_u8(w, m.contested ? 1 : 0)
	put_varint(w, m.rotation_ds)
	put_u32(w, transmute(u32)m.send_rate)
	put_varint(w, m.tick_rate)
}

@(private = "file")
get_match :: proc(r: ^Reader) -> (m: Snapshot_Match) {
	m.phase = get_u8(r)
	m.map_index = get_zvarint(r)
	m.time_ds = get_varint(r)
	m.team1_score = get_varint(r)
	m.team2_score = get_varint(r)
	m.active_object_index = get_zvarint(r)
	m.active_zone = get_zvarint(r)
	m.owner_team = get_zvarint(r)
	contested := get_u8(r)
	m.contested = contested != 0
	m.rotation_ds = get_varint(r)
	m.send_rate = transmute(f32)get_u32(r)
	m.tick_rate = get_varint(r)
	if contested > 1 || m.phase > u8(max(Match_Phase)) || !(m.send_rate >= 0 && m.send_rate <= 1000) || m.tick_rate > 1000 { r.ok = false }
	return
}

@(private = "file")
find_entity :: proc(frame: ^Snapshot_Frame, id: u32) -> ^Snapshot_Entity {
	if frame == nil { return nil }
	for &e in frame.entities[:frame.count] { if e.id == id { return &e } }
	return nil
}

// The baseline to encode `frame` against: the acked snapshot when it is still
// usable, otherwise nil (a full snapshot).
snapshot_usable_baseline :: proc(frame: ^Snapshot_Frame, baseline: ^Snapshot_Frame) -> ^Snapshot_Frame {
	if baseline == nil || !baseline.valid || baseline.you_id != frame.you_id { return nil }
	back := frame.tick - baseline.tick
	if back == 0 || back > SNAPSHOT_MAX_BACK { return nil }
	return baseline
}

// Writes the SNAPSHOT packet for `frame`, delta-encoded against `baseline`
// (nil, or one snapshot_usable_baseline rejects: a full snapshot). Returns 0
// when buf is too small.
snapshot_encode :: proc(buf: []byte, frame: ^Snapshot_Frame, baseline: ^Snapshot_Frame, impacts: []Bullet_Impact = nil, kills: []Kill_Event = nil) -> int {
	base := snapshot_usable_baseline(frame, baseline)
	w := Writer{buf = buf, at = PACKET_HEADER_SIZE, ok = len(buf) >= PACKET_HEADER_SIZE}
	if !w.ok { return 0 }
	flags: u8
	if base == nil || base.match != frame.match { flags |= SNAPSHOT_FLAG_MATCH }
	if base == nil || base.lobby_len != frame.lobby_len || string(base.lobby[:base.lobby_len]) != string(frame.lobby[:frame.lobby_len]) { flags |= SNAPSHOT_FLAG_LOBBY }
	if len(impacts) > 0 || len(kills) > 0 { flags |= SNAPSHOT_FLAG_EVENTS }
	put_u32(&w, frame.tick)
	put_u32(&w, frame.server_time_ms)
	put_u8(&w, base == nil ? 0 : u8(frame.tick - base.tick))
	put_u8(&w, flags)
	put_varint(&w, frame.you_id)
	if flags & SNAPSHOT_FLAG_MATCH != 0 { put_match(&w, &frame.match) }
	if flags & SNAPSHOT_FLAG_LOBBY != 0 {
		put_varint(&w, u32(frame.lobby_len))
		put_bytes(&w, frame.lobby[:frame.lobby_len])
	}
	put_varint(&w, u32(frame.count))
	zero: Snapshot_Entity
	for &e in frame.entities[:frame.count] {
		own := e.id == frame.you_id
		old := find_entity(base, e.id)
		if old == nil { old = &zero }
		mask: u32
		for field in Snapshot_Field {
			if e.words[field] != old.words[field] { mask |= 1 << u32(field) }
		}
		put_varint(&w, e.id)
		put_varint(&w, mask)
		for field in Snapshot_Field {
			if mask & (1 << u32(field)) == 0 { continue }
			if own && field in SNAPSHOT_FLOAT_FIELDS {
				put_u32(&w, e.words[field])
			} else {
				put_zvarint(&w, transmute(i32)(e.words[field] - old.words[field]))
			}
		}
	}
	if flags & SNAPSHOT_FLAG_EVENTS != 0 {
		scratch: [PACKET_HEADER_SIZE + PACKET_BULLET_IMPACT_PAYLOAD_SIZE]byte
		put_varint(&w, u32(len(impacts)))
		for &impact in impacts {
			if packet_serialize_bullet_impact(scratch[:], &impact) == 0 { w.ok = false }
			put_bytes(&w, scratch[PACKET_HEADER_SIZE:])
		}
		put_varint(&w, u32(len(kills)))
		for &event in kills {
			kill_scratch: [PACKET_HEADER_SIZE + PACKET_KILL_FEED_PAYLOAD_SIZE]byte
			if packet_serialize_kill_feed(kill_scratch[:], &event) == 0 { w.ok = false }
			put_bytes(&w, kill_scratch[PACKET_HEADER_SIZE:])
		}
	}
	payload := w.at - PACKET_HEADER_SIZE
	if !w.ok || payload > 65535 { return 0 }
	endian.put_u32(buf[0:4], .Little, PACKET_MAGIC)
	buf[4] = u8(Packet_Type.SNAPSHOT)
	endian.put_u16(buf[5:7], .Little, u16(payload))
	return w.at
}

Snapshot_Decode_Result :: enum {
	OK,
	NO_BASELINE, // a delta against a snapshot this end no longer has: ask for a full one
	MALFORMED,
}

// Decodes a SNAPSHOT packet into `out` using the baselines in `ring`, and
// appends its events to impacts/kills (when given). The caller stores `out`
// in the ring afterwards (snapshot_ring_store) and acknowledges out.tick.
snapshot_decode :: proc(buf: []byte, ring: ^Snapshot_Ring, out: ^Snapshot_Frame, impacts: ^[dynamic]Bullet_Impact = nil, kills: ^[dynamic]Kill_Event = nil) -> Snapshot_Decode_Result {
	header, header_ok := packet_deserialize_header(buf)
	if !header_ok || header.packet_type != .SNAPSHOT || len(buf) != PACKET_HEADER_SIZE + int(header.payload_len) || int(header.payload_len) < SNAPSHOT_HEADER_SIZE {
		return .MALFORMED
	}
	r := Reader{buf = buf, at = PACKET_HEADER_SIZE, ok = true}
	out^ = {}
	out.tick = get_u32(&r)
	out.server_time_ms = get_u32(&r)
	back := get_u8(&r)
	flags := get_u8(&r)
	out.you_id = get_varint(&r)
	if !r.ok || flags & ~u8(SNAPSHOT_FLAG_MATCH | SNAPSHOT_FLAG_LOBBY | SNAPSHOT_FLAG_EVENTS) != 0 || u32(back) > SNAPSHOT_MAX_BACK { return .MALFORMED }
	base: ^Snapshot_Frame
	if back > 0 {
		base = snapshot_ring_find(ring, out.tick - u32(back))
		if base == nil || base.you_id != out.you_id { return .NO_BASELINE }
	} else if flags & (SNAPSHOT_FLAG_MATCH | SNAPSHOT_FLAG_LOBBY) != SNAPSHOT_FLAG_MATCH | SNAPSHOT_FLAG_LOBBY {
		return .MALFORMED // a full snapshot carries both sections
	}
	if flags & SNAPSHOT_FLAG_MATCH != 0 {
		out.match = get_match(&r)
	} else {
		out.match = base.match
	}
	if flags & SNAPSHOT_FLAG_LOBBY != 0 {
		length := int(get_varint(&r))
		if !r.ok || length > SNAPSHOT_LOBBY_MAX { return .MALFORMED }
		data := get_bytes(&r, length)
		if !r.ok { return .MALFORMED }
		if length > 0 {
			if _, lobby_ok := packet_deserialize_lobby(data); !lobby_ok { return .MALFORMED }
		}
		copy(out.lobby[:], data)
		out.lobby_len = length
	} else {
		out.lobby = base.lobby
		out.lobby_len = base.lobby_len
	}
	count := int(get_varint(&r))
	if !r.ok || count > SNAPSHOT_MAX_ENTITIES { return .MALFORMED }
	zero: Snapshot_Entity
	for i in 0 ..< count {
		e := &out.entities[i]
		e.id = get_varint(&r)
		mask := get_varint(&r)
		if !r.ok || mask >> SNAPSHOT_FIELD_COUNT != 0 || e.id == 0 { return .MALFORMED }
		for j in 0 ..< i { if out.entities[j].id == e.id { return .MALFORMED } }
		own := e.id == out.you_id
		old := find_entity(base, e.id)
		if old == nil { old = &zero }
		e.words = old.words
		for field in Snapshot_Field {
			if mask & (1 << u32(field)) == 0 { continue }
			if own && field in SNAPSHOT_FLOAT_FIELDS {
				e.words[field] = get_u32(&r)
			} else {
				e.words[field] = old.words[field] + transmute(u32)get_zvarint(&r)
			}
		}
		if !r.ok { return .MALFORMED }
	}
	out.count = count
	if flags & SNAPSHOT_FLAG_EVENTS != 0 {
		scratch: [PACKET_HEADER_SIZE + PACKET_BULLET_IMPACT_PAYLOAD_SIZE]byte
		endian.put_u32(scratch[0:4], .Little, PACKET_MAGIC)
		scratch[4] = u8(Packet_Type.BULLET_IMPACT)
		endian.put_u16(scratch[5:7], .Little, PACKET_BULLET_IMPACT_PAYLOAD_SIZE)
		n := int(get_varint(&r))
		if !r.ok || n > (len(buf) - r.at) / PACKET_BULLET_IMPACT_PAYLOAD_SIZE { return .MALFORMED }
		for _ in 0 ..< n {
			copy(scratch[PACKET_HEADER_SIZE:], get_bytes(&r, PACKET_BULLET_IMPACT_PAYLOAD_SIZE))
			impact, ok := packet_deserialize_bullet_impact(scratch[:])
			if !r.ok || !ok { return .MALFORMED }
			if impacts != nil { append(impacts, impact) }
		}
		kill_scratch: [PACKET_HEADER_SIZE + PACKET_KILL_FEED_PAYLOAD_SIZE]byte
		endian.put_u32(kill_scratch[0:4], .Little, PACKET_MAGIC)
		kill_scratch[4] = u8(Packet_Type.KILL_FEED)
		endian.put_u16(kill_scratch[5:7], .Little, PACKET_KILL_FEED_PAYLOAD_SIZE)
		k := int(get_varint(&r))
		if !r.ok || k > (len(buf) - r.at) / PACKET_KILL_FEED_PAYLOAD_SIZE { return .MALFORMED }
		for _ in 0 ..< k {
			copy(kill_scratch[PACKET_HEADER_SIZE:], get_bytes(&r, PACKET_KILL_FEED_PAYLOAD_SIZE))
			event, ok := packet_deserialize_kill_feed(kill_scratch[:])
			if !r.ok || !ok { return .MALFORMED }
			if kills != nil { append(kills, event) }
		}
	}
	if !r.ok || r.at != len(buf) { return .MALFORMED }
	out.valid = true
	return .OK
}

// SNAPSHOT_ACK (client -> server): [u32 tick][u8 flags]. The newest snapshot
// the client decoded; the server encodes the next ones against it.
packet_serialize_snapshot_ack :: proc(buf: []byte, tick: u32, flags: u8 = 0) -> int {
	if len(buf) < SNAPSHOT_ACK_PACKET_SIZE { return 0 }
	endian.put_u32(buf[0:4], .Little, PACKET_MAGIC)
	buf[4] = u8(Packet_Type.SNAPSHOT_ACK)
	endian.put_u16(buf[5:7], .Little, SNAPSHOT_ACK_PAYLOAD_SIZE)
	endian.put_u32(buf[7:11], .Little, tick)
	buf[11] = flags
	return SNAPSHOT_ACK_PACKET_SIZE
}

packet_deserialize_snapshot_ack :: proc(buf: []byte) -> (tick: u32, flags: u8, ok: bool) {
	header, header_ok := packet_deserialize_header(buf)
	if !header_ok || header.packet_type != .SNAPSHOT_ACK || header.payload_len != SNAPSHOT_ACK_PAYLOAD_SIZE || len(buf) != SNAPSHOT_ACK_PACKET_SIZE {
		return 0, 0, false
	}
	tick, _ = endian.get_u32(buf[7:11], .Little)
	flags = buf[11]
	return tick, flags, flags & ~u8(SNAPSHOT_ACK_RESET) == 0
}

// Krunker's PLAYER_ANIM falls back to 600 units, but UPDATE_PLAYERS only culls
// when the mode sets viewDis; the server's view_distance follows the latter.
// Squared 3D distance check, as Krunker's `$r(x,y,z,...)` distance.
snapshot_beyond_view :: proc(a, b: Vec3, view_distance: f32) -> bool {
	if view_distance <= 0 { return false }
	d := a - b
	return d.x * d.x + d.y * d.y + d.z * d.z >= view_distance * view_distance
}
