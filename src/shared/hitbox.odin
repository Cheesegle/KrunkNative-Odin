package shared

import "core:math"
import "core:math/linalg"

// Player hitbox geometry. Krodin's native/offline hit tests and the developer
// hitbox visualizer both read it from here, so what is drawn is what is hit.
// Native hits follow Krunker: hitscan and projectiles test the complexHitboxes
// (below), melee one axis-aligned box padded by the lobby's Hitbox Padding.

// An axis-aligned box in ray_box_hit's convention: `origin` is the centre of
// the bottom face, `scale` the full size.
Box :: struct {
	origin: Vec3,
	scale:  Vec3,
}

// What the native hit tests are for: hitscan shots test Krunker's hurtboxes
// (krunker_player_shot_test), melee swings one padded box (krunker_melee_box).
// The developer hitbox visualizer picks its drawing by this.
Hitbox_Kind :: enum u8 {
	SHOT,  // player_shoot, projectiles
	MELEE, // player_melee (non-throw swing)
}

// Unit-cube transform of a Box: maps [-0.5, 0.5]^3 onto it.
box_transform :: proc(box: Box) -> Mat4 {
	return linalg.matrix4_translate_f32(box.origin + Vec3{0, box.scale.y * 0.5, 0}) * linalg.matrix4_scale_f32(box.scale)
}

// The shot filter both native hitscan loops (player_shoot, player_melee) apply
// to map objects: only these stop a bullet.
map_object_blocks_shots :: proc(object: ^Object) -> bool {
	if object == nil { return false }
	return !(!object.active || object.no_shoot || object.collision_type == .NONE || object.score_zone || object.objective || object.team_zone || object.bomb_site || object.flag || object.trigger || object.premium || object.verified || object.teleporter || object.checkpoint || object.pickup)
}

// ---------------------------------------------------------------------------
// Krunker's live hitboxes ("complexHitboxes", game.js updateComplexHitboxes,
// the per-shot pose update and the server ray test). On official servers, and
// on Krodin's native server and offline game, every hitscan and projectile hit
// is decided by these oriented boxes:
//
//   root     at (x, y + |sin(sV) * stepAnim * 6|, z), yaw xD - 2 sin(sV) stepAnim
//   upper    at legHeight - crouchDst * cV above the root, pitched yD * 0.5
//     head   headScale^3 cube centred playerHeight - headScale/2 - legHeight up
//     torso  chestWidth x (playerHeight - headScale - legHeight) x chestScale
//     arms   3 boxes per arm (upper, elbow connector, forearm), IK to the
//            weapon's hold points, pitched another yD * 0.5 ("torsoshot")
//   legs     standing: legScale x legHeight x legScale per leg, swung by the
//            stride; crouched (cV = round(crouchVal)): 3 bent boxes per leg
//
// Every box grows by 1 unit on each side (before hurtboxScale) while the target
// is moving. The server rewinds the pose to the shooter's view (fetchState).

// Head, torso, 3 boxes per arm, then 2 standing + 6 crouched leg boxes (one
// set is inactive: Krunker toggles them through userData.active).
KRUNKER_HURTBOX_MAX :: 16

Krunker_Hurtbox_Part :: enum u8 { HEAD, TORSO, ARM, LEG }

// `transform` maps the unit cube [-0.5, 0.5]^3 onto the oriented box.
Krunker_Hurtbox :: struct {
	part:      Krunker_Hurtbox_Part,
	transform: Mat4,
	// False only for the other leg set, emitted on request for drawing.
	active:    bool,
}

// A box's world centre: its geometry is centred on the mesh origin, so this is
// three.js getGeometryCenterWorldPosition (bounding-box centre x matrixWorld).
krunker_hurtbox_center :: proc(box: Krunker_Hurtbox) -> Vec3 {
	return (box.transform * Vec4{0, 0, 0, 1}).xyz
}

Krunker_Hurtbox_Pose :: struct {
	position:      Vec3,
	yaw, pitch:    f32, // Krunker xD and yD (Krodin direction.y and direction.x).
	crouch:        f32, // Krunker's cV: 0 or 1.
	step_val:      f32, // sV
	step_chase:    f32,
	moving:        bool, // Target velocity non-zero: every box grows by 1.
	head_mlt:      f32, // Head-size multiplier (1 unless a mode grows heads).
	hurtbox_scale: f32, // Server hurtboxScale setting (1 by default).
	weapon:        ^Weapon, // Arm IK targets; nil leaves the arms out.
	// cH lifts the arm holder by recoilAnimY * (weapon recoilYM || 0.3) * animMult.
	recoil_anim_y: f32,
	// Also emit the inactive leg set (crouched legs while standing and the
	// reverse) with active = false, for drawing only.
	inactive_legs: bool,
}

krunker_hurtbox_pose :: proc(player: ^Player, moving: bool) -> Krunker_Hurtbox_Pose {
	return {
		position = player.position,
		yaw = player.direction.y, pitch = player.direction.x,
		// The server keeps Math.round(crouchVal) in its pose history.
		crouch = math.round(clamp(player.crouch_val, 0, 1)),
		step_val = player.step_val, step_chase = player.step_chase,
		moving = moving, head_mlt = 1, hurtbox_scale = 1,
		weapon = player.weapon,
		recoil_anim_y = player.recoil_anim_y,
	}
}

@(private="file")
euler_xyz :: proc(x, y, z: f32) -> Mat4 {
	return linalg.matrix4_rotate_f32(x, {1, 0, 0}) * linalg.matrix4_rotate_f32(y, {0, 1, 0}) * linalg.matrix4_rotate_f32(z, {0, 0, 1})
}

@(private="file")
node :: proc(position: Vec3, rotation: Mat4 = 1) -> Mat4 {
	return linalg.matrix4_translate_f32(position) * rotation
}

@(private="file")
hurtbox_append :: proc(out: ^[KRUNKER_HURTBOX_MAX]Krunker_Hurtbox, count: ^int, part: Krunker_Hurtbox_Part, parent: Mat4, size: Vec3, scale: f32, moving: bool, active := true) {
	if count^ >= KRUNKER_HURTBOX_MAX { return }
	// three.js OBB.fromBox3 + halfSize + 1, then applyMatrix4(matrixWorld),
	// which includes the mesh's own scale.
	full := size + (moving ? Vec3{2, 2, 2} : Vec3{})
	out[count^] = {part, parent * linalg.matrix4_scale_f32(full * scale), active}
	count^ += 1
}

// Fills `out` with Krunker's hit-test boxes for one pose; returns the count.
krunker_player_hurtboxes :: proc(pose: Krunker_Hurtbox_Pose, out: ^[KRUNKER_HURTBOX_MAX]Krunker_Hurtbox) -> (count: int) {
	g := GAME_CONSTANTS
	step := g.step_anim
	cv := pose.crouch
	head_mlt := pose.head_mlt != 0 ? pose.head_mlt : 1
	hurt := pose.hurtbox_scale != 0 ? pose.hurtbox_scale : 1
	anim_mlt := g.anim_mlt                            // Y
	arm_anim := g.anim_mlt * 0.7                      // G
	d := math.sin(pose.step_val) * step
	bounce := abs(d * 6)
	sway := -d * 2
	v := math.cos(pose.step_val * 2) / 2 * step
	v -= v * (cv * g.crouch_anim_mlt)
	d -= d * (cv * g.crouch_anim_mlt)
	c := -math.cos(pose.step_chase * 2) / 2 * step

	root := node(pose.position + Vec3{0, bounce, 0}, linalg.matrix4_rotate_f32(pose.yaw + sway, {0, 1, 0}))
	upper := root * node({0, g.leg_height - g.crouch_distance * cv, 0}, linalg.matrix4_rotate_f32(g.crouch_lean * cv + pose.pitch * 0.5, {1, 0, 0}))

	head_offset := g.head_scale * (head_mlt - 1) / 2
	head := upper * node({0, g.player_height - g.head_scale * 0.5 - g.leg_height + head_offset, 0})
	hurtbox_append(out, &count, .HEAD, head, {g.head_scale, g.head_scale, g.head_scale}, hurt * head_mlt, pose.moving)

	torso_height := g.player_height - g.head_scale - g.leg_height
	torso := upper * node({0, torso_height * 0.5, 0})
	hurtbox_append(out, &count, .TORSO, torso, {g.chest_width, torso_height, g.chest_scale}, hurt, pose.moving)

	if weapon := pose.weapon; weapon != nil {
		recoil_y_mlt := weapon.recoil_y_mlt != 0 ? weapon.recoil_y_mlt : 0.3
		arm_lift := pose.recoil_anim_y * recoil_y_mlt * anim_mlt
		arm_hold := upper * node({0, arm_lift + g.player_height - g.camera_height - g.leg_height, 0}, linalg.matrix4_rotate_f32(pose.pitch * 0.5, {1, 0, 0}))
		n_mlt := 1 - cv * 0.8
		h := -math.sin(pose.step_chase) * step
		arms_position := Vec3{
			weapon.offset.x + (-weapon.crouch_rotation * cv * anim_mlt + d * 0.5 * n_mlt * anim_mlt) * arm_anim,
			weapon.offset.y + (v * 0.85 - weapon.crouch_drop * cv * anim_mlt) * arm_anim,
			weapon.offset.z,
		}
		arms_rotation_x := -c * 1.5 + weapon.rotation_offset * anim_mlt + weapon.rotation_offset_aim * (1 - anim_mlt) + c * -0.9 * arm_anim
		arms_rotation_y := (-h * 0.16 * anim_mlt * n_mlt) * arm_anim
		arms := arm_hold * node(arms_position, euler_xyz(arms_rotation_x, arms_rotation_y, 0))
		shoulder_x := -g.chest_width + g.arm_scale / 2 - g.arm_inset
		for is_left in ([2]bool{true, false}) {
			krunker_arm_hurtboxes(out, &count, arms, weapon, is_left, is_left ? shoulder_x : -shoulder_x, g.arm_offset, hurt, pose.moving)
		}
	}

	legs := root
	// Both sets are posed every frame; only the one matching cV is tested.
	if cv == 0 || pose.inactive_legs {
		active := cv == 0
		for i in 0 ..< 2 {
			side: f32 = i == 0 ? 1 : -1
			swing := d * (i == 1 ? 1 : -1) * 9
			holder := legs * node({g.leg_scale * 0.5 * side, g.leg_height, 0}, linalg.matrix4_rotate_f32(swing, {1, 0, 0}))
			hurtbox_append(out, &count, .LEG, holder * node({0, -g.leg_height * 0.5, 0}), {g.leg_scale, g.leg_height, g.leg_scale}, hurt, pose.moving, active)
		}
	}
	if cv != 0 || pose.inactive_legs {
		active := cv != 0
		s := g.leg_scale
		o := g.leg_height / 2
		l := s / 2
		x0, x1: f32 = 0.5, 2
		p := math.sqrt(l * l + l * l - l * 2 * l * math.cos(x0 - x1))
		f := math.sqrt(l * l - p / 2 * (p / 2)) * 2
		for i in 2 ..< 4 {
			is_left := i == 3
			side: f32 = is_left ? -1 : 1
			swing := d * (i == 3 ? 1 : -1) * 9 - 0.6
			holder := legs * node({g.leg_scale * 0.5 * side, g.leg_height - g.crouch_distance + 0.5, 0}, euler_xyz(swing, is_left ? math.PI / 8 : -math.PI / 6, 0))
			hurtbox_append(out, &count, .LEG, holder * node({0, -o / 2 * math.cos(x1), -o / 2 * math.sin(x1)}, linalg.matrix4_rotate_f32(x1, {1, 0, 0})), {s, o, s}, hurt, pose.moving, active)
			hurtbox_append(out, &count, .LEG, holder * node({0, -o * math.cos(x1), -o * math.sin(x1)}, linalg.matrix4_rotate_f32((x1 + x0) / 2, {1, 0, 0})), {s, p, f}, hurt, pose.moving, active)
			hurtbox_append(out, &count, .LEG, holder * node({0, -o * math.cos(x1) - o / 2 * math.cos(x0), -o * math.sin(x1) - o / 2 * math.sin(x0)}, linalg.matrix4_rotate_f32(x0, {1, 0, 0})), {s, o, s}, hurt, pose.moving, active)
		}
	}
	return
}

// One arm (game.js Uge): a two-bone IK chain from the shoulder to the weapon's
// hold point, as upper arm, elbow connector and forearm boxes.
@(private="file")
krunker_arm_hurtboxes :: proc(out: ^[KRUNKER_HURTBOX_MAX]Krunker_Hurtbox, count: ^int, arms: Mat4, weapon: ^Weapon, is_left: bool, r, n: f32, hurt: f32, moving: bool) {
	g := GAME_CONSTANTS
	hold := is_left ? weapon.left_hold : weapon.right_hold
	akimbo_flip: f32 = is_left && weapon.akimbo ? -1 : 1
	target := Vec3{(weapon.offset.x - hold.x) * akimbo_flip, weapon.offset.y + hold.y, weapon.offset.z - hold.z}
	reach := linalg.length(Vec3{r, n, 0} - target)
	reach = min(g.upper_arm_length + g.lower_arm_length - 0.01, reach)
	// hN(d, uArm, lArm) = [-r - PI/2, n, PI - r - n]
	ua, la := g.upper_arm_length, g.lower_arm_length
	elbow := math.acos((ua * ua + la * la - reach * reach) / (ua * 2 * la))
	shoulder := math.acos((la * la + reach * reach - ua * ua) / (la * 2 * reach))
	p0 := -elbow - math.PI / 2
	f := g.arm_scale
	v := f32(math.PI / 2)
	m := f / 2
	gap := math.sqrt(m * m + m * m - m * 2 * m * math.cos(math.PI + p0 + math.PI / 2))
	ys :: proc(e, a, t, r: f32) -> f32 { return math.atan2(a - r, e - t) }
	rot_x := -shoulder - ys(0, n, weapon.offset.z - hold.z, weapon.offset.y + hold.y)
	rot_y := ys(-r, 0, (is_left && weapon.akimbo ? 1 : -1) * (weapon.offset.x - hold.x), weapon.offset.z - hold.z) - math.PI / 2
	// Euler order YXZ.
	holder := arms * node({r - weapon.offset.x, n - weapon.offset.y, -weapon.offset.z}, linalg.matrix4_rotate_f32(rot_y, {0, 1, 0}) * linalg.matrix4_rotate_f32(rot_x, {1, 0, 0}))
	connector_depth := math.sqrt(m * m - gap / 2 * (gap / 2)) * 2
	half_lower := la / 2
	hurtbox_append(out, count, .ARM, holder * node({0, -ua / 2 * math.cos(v), -ua / 2 * math.sin(v)}, linalg.matrix4_rotate_f32(v, {1, 0, 0})), {f, ua, f}, hurt, moving)
	hurtbox_append(out, count, .ARM, holder * node({0, -ua * math.cos(v), -ua * math.sin(v)}, linalg.matrix4_rotate_f32((v + p0) / 2, {1, 0, 0})), {f, gap, connector_depth}, hurt, moving)
	hurtbox_append(out, count, .ARM, holder * node({0, -ua * math.cos(v) - half_lower * math.cos(p0), -ua * math.sin(v) - half_lower * math.sin(p0)}, linalg.matrix4_rotate_f32(p0, {1, 0, 0})), {f, la, f}, hurt, moving)
}

// ---------------------------------------------------------------------------
// Krunker's per-player shot test (krunkbox game.min.js `function n1e(`), used
// by the native/authoritative hitscan and projectiles:
//
//   - the ray is the shot direction from the shooter's eye, unbounded forward
//     (three.js Ray), tested against B8 OBBs: fromBox3(geometry bounds), then
//     halfSize + 1 when the target's velocity is non-zero, then
//     applyMatrix4(matrixWorld);
//   - head, then torso; only when the torso misses, the arms in the order
//     left upper, right upper, left connector, left forearm, right connector,
//     right forearm, stopping at the first hit; then the active leg set,
//     stopping at the first hit;
//   - the nearest of those hits wins (ties keep the earlier one), and its
//     hitType decides the damage: headshot, torsoshot (torso and arms) or
//     legshot.
//
// The caller first runs Krunker's cheap prefilter (krunker_hurtbox_prefilter).

Krunker_Hit_Type :: enum u8 { NONE, HEADSHOT, TORSOSHOT, LEGSHOT }

krunker_hit_type :: proc(part: Krunker_Hurtbox_Part) -> Krunker_Hit_Type {
	switch part {
	case .HEAD:       return .HEADSHOT
	case .TORSO, .ARM: return .TORSOSHOT
	case .LEG:        return .LEGSHOT
	}
	return .NONE
}

// Ray (origin + direction * t, t >= 0) against an oriented box whose
// transform maps the unit cube onto it. The ray goes into box space (the
// transform's columns are the box axes times its full size; the hurtbox
// chains have no shear) and runs the slab test there. three.js Ray.intersectBox:
// the entry point, or the exit point when the origin is inside.
krunker_hurtbox_ray :: proc(box: Krunker_Hurtbox, origin, direction: Vec3) -> (t: f32, hit: bool) {
	m := box.transform
	center := Vec3{m[0, 3], m[1, 3], m[2, 3]}
	rel := origin - center
	t_near := f32(-math.F32_MAX)
	t_far := f32(math.F32_MAX)
	for axis in 0 ..< 3 {
		column := Vec3{m[0, axis], m[1, axis], m[2, axis]}
		length_sq := linalg.dot(column, column)
		if length_sq <= 0 { return 0, false }
		// Box-space coordinates: [-0.5, 0.5] on this axis.
		o := linalg.dot(rel, column) / length_sq
		d := linalg.dot(direction, column) / length_sq
		if abs(d) < 1e-12 {
			if o < -0.5 || o > 0.5 { return 0, false }
			continue
		}
		t1 := (-0.5 - o) / d
		t2 := (0.5 - o) / d
		if t1 > t2 { t1, t2 = t2, t1 }
		t_near = max(t_near, t1)
		t_far = min(t_far, t2)
		if t_near > t_far { return 0, false }
	}
	if t_far < 0 { return 0, false }
	return t_near >= 0 ? t_near : t_far, true
}

// Krunker's arm test order (n1e's L list) as indices into the arm boxes that
// krunker_player_hurtboxes emits: left upper/connector/forearm, then right.
@(private="file")
KRUNKER_ARM_ORDER := [6]int{0, 3, 1, 2, 4, 5}

// n1e over one target's boxes (krunker_player_hurtboxes output, active legs
// only). `t` is in units of `direction`.
krunker_hurtboxes_ray :: proc(boxes: []Krunker_Hurtbox, origin, direction: Vec3) -> (t: f32, hit_type: Krunker_Hit_Type) {
	best := f32(math.F32_MAX)
	consider :: proc(best: ^f32, hit_type: ^Krunker_Hit_Type, t: f32, part: Krunker_Hurtbox_Part) {
		if t < best^ { best^, hit_type^ = t, krunker_hit_type(part) }
	}
	first_arm, arm_count, first_leg := -1, 0, len(boxes)
	for box, i in boxes {
		if box.part == .ARM && first_arm < 0 { first_arm = i }
		if box.part == .ARM { arm_count += 1 }
		if box.part == .LEG && first_leg == len(boxes) { first_leg = i }
	}
	torso_hit := false
	for box in boxes {
		if box.part != .HEAD && box.part != .TORSO { continue }
		if bt, ok := krunker_hurtbox_ray(box, origin, direction); ok {
			consider(&best, &hit_type, bt, box.part)
			if box.part == .TORSO { torso_hit = true }
		}
	}
	if !torso_hit && arm_count == 6 {
		for k in KRUNKER_ARM_ORDER {
			box := boxes[first_arm + k]
			if bt, ok := krunker_hurtbox_ray(box, origin, direction); ok {
				consider(&best, &hit_type, bt, box.part)
				break
			}
		}
	}
	for box in boxes[first_leg:] {
		if box.part != .LEG || !box.active { continue }
		if bt, ok := krunker_hurtbox_ray(box, origin, direction); ok {
			consider(&best, &hit_type, bt, box.part)
			break
		}
	}
	if hit_type == .NONE { return 0, .NONE }
	return best, hit_type
}

// The pose Krunker's server tests a native target in: its current state, and
// the +1 padding only while its actual velocity is non-zero (n1e's `y`).
krunker_target_pose :: proc(target: ^Player) -> Krunker_Hurtbox_Pose {
	moving := target.velocity.x != 0 || target.velocity.y != 0 || target.velocity.z != 0
	pose := krunker_hurtbox_pose(target, moving)
	if target.game != nil && target.game.config.hurtbox_scale > 0 { pose.hurtbox_scale = target.game.config.hurtbox_scale }
	return pose
}

// Everything a shot tests about one target: its hurtbox pose plus the sizes
// of Krunker's prefilter and melee boxes (fetchState's x/y/z, xD/yD, sV,
// stepChase, cV, h/ah and weapon).
Krunker_Shot_Target :: struct {
	pose:       Krunker_Hurtbox_Pose,
	scale:      f32,
	height:     f32, // adjustedHeight
	hitbox_pad: f32, // the lobby's hitBoxPad
}

krunker_shot_target :: proc(target: ^Player) -> Krunker_Shot_Target {
	return {
		pose = krunker_target_pose(target),
		scale = target.scale,
		height = target.height,
		hitbox_pad = target.game != nil ? target.game.config.hitbox_pad : KRUNKER_HITBOX_PAD_DEFAULT,
	}
}

// Krunker's prefilter before n1e (hitscan and projectiles): the segment must
// reach an axis-aligned box scale + 5 out from the target on x/z and from its
// feet to adjustedHeight + 5 up. `segment` is the whole shot (t <= 1).
krunker_hurtbox_prefilter :: proc(target: Krunker_Shot_Target, origin, segment: Vec3) -> bool {
	width := (target.scale + 5) * 2
	_, _, hit := ray_box_hit(origin, segment, target.pose.position, {width, target.height + 5, width})
	return hit
}

// One target through Krunker's shot test: prefilter, pose, n1e.
krunker_shot_target_test :: proc(target: Krunker_Shot_Target, origin, segment: Vec3) -> (t: f32, hit_type: Krunker_Hit_Type) {
	if !krunker_hurtbox_prefilter(target, origin, segment) { return 0, .NONE }
	boxes: [KRUNKER_HURTBOX_MAX]Krunker_Hurtbox
	count := krunker_player_hurtboxes(target.pose, &boxes)
	return krunker_hurtboxes_ray(boxes[:count], origin, segment)
}

// The same, for a target as it is now (projectiles, tests).
krunker_player_shot_test :: proc(target: ^Player, origin, segment: Vec3) -> (t: f32, hit_type: Krunker_Hit_Type) {
	return krunker_shot_target_test(krunker_shot_target(target), origin, segment)
}

// ---------------------------------------------------------------------------
// Lag compensation on the native server (Krunker's storeState/fetchState).
// After every server tick each player's pose is stored with the tick's time;
// a command carries the tick its view showed (Input.view_tick/view_frac, set
// by the client's remote-player clock), and its shots and melee swings test
// every target as it was at that moment, blended between the two stored
// ticks around it. Like Krunker, history older than 500 ms is not used (the
// oldest kept pose is), the +1 moving padding follows the target's current
// velocity, and crouch, height and weapon come from the older of the two
// poses. Unstamped commands (and the offline game) test targets as they are.

LAG_HISTORY_MAX :: 64
LAG_HISTORY_WINDOW :: f32(0.5) // Krunker: `N-h.stateHistory[Y].time>=500` is dropped

Lag_Sample :: struct {
	time:          f32, // game.now after the tick (the snapshot time)
	position:      Vec3,
	direction:     Vec2,
	crouch_val:    f32,
	step_val:      f32,
	step_chase:    f32,
	recoil_anim_y: f32,
	height:        f32,
	weapon:        ^Weapon,
}

player_lag_record :: proc(player: ^Player, now: f32) {
	if !player.active {
		player.lag_count, player.lag_next = 0, 0
		return
	}
	player.lag_history[player.lag_next] = {
		time = now,
		position = player.position, direction = player.direction,
		crouch_val = player.crouch_val, step_val = player.step_val, step_chase = player.step_chase,
		recoil_anim_y = player.recoil_anim_y, height = player.height, weapon = player.weapon,
	}
	player.lag_next = (player.lag_next + 1) % LAG_HISTORY_MAX
	player.lag_count = min(player.lag_count + 1, LAG_HISTORY_MAX)
}

// The k-th newest stored pose (0 = newest).
@(private="file")
lag_sample :: proc(player: ^Player, k: i32) -> ^Lag_Sample {
	return &player.lag_history[(player.lag_next - 1 - k + 2 * LAG_HISTORY_MAX) % LAG_HISTORY_MAX]
}

// `target` as it was at server time `time`. ok is false without history or
// when `time` is at or past the newest stored tick (the current state is then
// the newest the shooter can have seen).
player_lag_target :: proc(target: ^Player, time: f32) -> (result: Krunker_Shot_Target, ok: bool) {
	if target.lag_count == 0 { return }
	newest := lag_sample(target, 0)
	if time >= newest.time { return }
	// The newest pose at or before `time` and the one after it.
	older, newer: ^Lag_Sample = nil, newest
	for k in 0 ..< target.lag_count {
		sample := lag_sample(target, k)
		if newest.time - sample.time >= LAG_HISTORY_WINDOW { break }
		if sample.time <= time { older = sample; break }
		newer = sample
	}
	frac: f32 = 1
	if older == nil {
		older = newer // before the window: the oldest kept pose
	} else if newer.time > older.time {
		frac = clamp((time - older.time) / (newer.time - older.time), 0, 1)
	} else {
		frac = 0
	}
	result = krunker_shot_target(target)
	pose := &result.pose
	pose.position = older.position + (newer.position - older.position) * frac
	pose.pitch = older.direction.x + (newer.direction.x - older.direction.x) * frac
	pose.yaw = older.direction.y + normalize_angle(newer.direction.y - older.direction.y) * frac
	pose.step_val = older.step_val + (newer.step_val - older.step_val) * frac
	pose.step_chase = older.step_chase + (newer.step_chase - older.step_chase) * frac
	pose.recoil_anim_y = older.recoil_anim_y + (newer.recoil_anim_y - older.recoil_anim_y) * frac
	pose.crouch = math.round(clamp(older.crouch_val, 0, 1))
	pose.weapon = older.weapon
	result.height = older.height
	return result, true
}

// The target a shot from `shooter` tests: rewound to the shooter's view on
// the native server when the command was stamped, else as it is now.
player_shot_target :: proc(shooter, target: ^Player, rewind: bool) -> Krunker_Shot_Target {
	game := shooter.game
	if rewind && shooter.view_stamped && game != nil && game.server != nil && game.config.tick_rate > 0 {
		time := (f64(shooter.view_tick) + f64(shooter.view_frac)) / f64(game.config.tick_rate)
		if rewound, ok := player_lag_target(target, f32(time)); ok { return rewound }
	}
	return krunker_shot_target(target)
}

// Damage multiplier for a hit type (Krunker's shot and projectile damage):
// headshot x hsMlt (1.5 when unset), legshot x lsMlt (0.5 when unset),
// torsoshot x 1.
krunker_hit_damage_mlt :: proc(weapon: ^Weapon, hit_type: Krunker_Hit_Type) -> f32 {
	if weapon == nil { return 1 }
	#partial switch hit_type {
	case .HEADSHOT: return weapon.headshot_mlt != 0 ? weapon.headshot_mlt : 1.5
	case .LEGSHOT:  return weapon.legshot_mlt != 0 ? weapon.legshot_mlt : 0.5
	}
	return 1
}

// Krunker's melee swing test (players.melee): no complexHitboxes, one
// axis-aligned box scale + hitboxPadW out on x/z and adjustedHeight +
// hitboxPadH tall, both pads the lobby's Hitbox Padding (hitBoxPad).
krunker_melee_box :: proc(target: Krunker_Shot_Target) -> Box {
	width := (target.scale + target.hitbox_pad) * 2
	return {origin = target.pose.position, scale = {width, max(0.1, target.height + target.hitbox_pad), width}}
}

// Krunker's lobby default for Hitbox Padding (hitBoxPad: def .6, -2..2).
KRUNKER_HITBOX_PAD_DEFAULT :: 0.6
