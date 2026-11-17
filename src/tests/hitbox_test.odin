package main

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import shared "../shared"

// Native hit tests follow Krunker's server (krunkbox game.min.js):
//   - hitscan and projectiles: `function n1e(` over the complexHitboxes as B8
//     OBBs (+1 halfSize while the target moves), head / torso (arms only when
//     the torso misses) / active legs, nearest wins; damage x hsMlt (1.5) for
//     headshot, x lsMlt (0.5) for legshot;
//   - melee: `this.melee=function(` tests one AABB scale + hitBoxPad wide on
//     each side, adjustedHeight + hitBoxPad tall; fists (`h.canThrow||(ve=35)`).

// The boxes the native server used before this change (two upright boxes,
// body 2 x scale wide), for the "it used to hit" side of each case.
@(private="file")
legacy_shot_hit :: proc(target: ^shared.Player, origin, segment: shared.Vec3) -> bool {
	body_height := max(0.1, target.height * 0.72)
	_, _, body := shared.ray_box_hit(origin, segment, target.position, {target.scale * 2, body_height, target.scale * 2})
	_, _, head := shared.ray_box_hit(origin, segment, target.position + {0, body_height, 0}, {target.scale * 1.6, max(0.1, target.height - body_height), target.scale * 1.6})
	return body || head
}

@(private="file")
Hit_Fixture :: struct {
	map_inst: shared.Map,
	game:     shared.Game,
	shooter, target: ^shared.Player,
	hitscan_slot, melee_slot: int,
}

@(private="file")
fixture_init :: proc(f: ^Hit_Fixture) -> bool {
	f.map_inst = shared.Map{death_y = -100}
	maps := []^shared.Map{&f.map_inst}
	shared.game_configure(&f.game, nil, maps, nil, nil, nil)
	shared.game_init(&f.game, 0, 0, true)
	f.shooter = shared.player_init(&f.game)
	shared.game_players_add(&f.game, f.shooter)
	shared.player_spawn(f.shooter)
	f.target = shared.player_init(&f.game)
	shared.game_players_add(&f.game, f.target)
	shared.player_spawn(f.target)
	f.hitscan_slot, f.melee_slot = -1, -1
	for i in 0 ..< int(f.shooter.loadout_size) {
		weapon := f.game.weapons[f.shooter.loadout[i]]
		if weapon.melee { f.melee_slot = i } else if !weapon.projectile && len(weapon.custom_spread) == 0 && f.hitscan_slot < 0 { f.hitscan_slot = i }
	}
	return f.hitscan_slot >= 0 && f.melee_slot >= 0
}

// Shooter at the origin, eye 9.5 up, facing +x; the target 10 ahead facing
// back at it (yaw pi/2), its feet placed so the unspread ray crosses its
// local point `aim` (relative to its feet) shifted `side` along z.
@(private="file")
fixture_place :: proc(f: ^Hit_Fixture, aim: shared.Vec3, side: f32, velocity := shared.Vec3{}, crouch: f32 = 0) {
	shooter, target := f.shooter, f.target
	shooter.position, shooter.direction = {0, 0, 0}, {0, -math.PI / 2.0}
	shooter.spread, shooter.recoil_anim_y, shooter.swap_timer = 0, 0, 0
	shooter.crouch_val = 0
	shared.player_update_height(shooter)
	eye := shooter.position.y + shooter.height - shared.GAME_CONSTANTS.camera_height
	target.direction = {0, math.PI / 2}
	target.crouch_val = crouch
	shared.player_update_height(target)
	target.position = {10 - aim.x, eye - aim.y, -side - aim.z}
	target.velocity = velocity
	target.step_val, target.step_chase = 0, 0
	target.health = f32(target.max_health)
	target.active = true
}

// A target-relative point of one of its tested boxes (the pose's own frame).
@(private="file")
box_point :: proc(f: ^Hit_Fixture, part: shared.Krunker_Hurtbox_Part, local: shared.Vec3, crouch: f32 = 0) -> shared.Vec3 {
	f.target.position, f.target.direction, f.target.crouch_val = {}, {0, math.PI / 2}, crouch
	f.target.step_val, f.target.step_chase, f.target.velocity = 0, 0, {}
	shared.player_update_height(f.target)
	boxes: [shared.KRUNKER_HURTBOX_MAX]shared.Krunker_Hurtbox
	count := shared.krunker_player_hurtboxes(shared.krunker_target_pose(f.target), &boxes)
	for box in boxes[:count] {
		if box.part == part && box.active { return (box.transform * shared.Vec4{local.x, local.y, local.z, 1}).xyz }
	}
	return {}
}

@(private="file")
fixture_shoot :: proc(f: ^Hit_Fixture) -> (damage: f32, unused: bool, impact: shared.Bullet_Impact) {
	shooter := f.shooter
	shooter.loadout_index = i32(f.hitscan_slot)
	shooter.weapon = f.game.weapons[shooter.loadout[f.hitscan_slot]]
	saved := shooter.weapon.inaccuracy
	shooter.weapon.inaccuracy = 0
	defer shooter.weapon.inaccuracy = saved
	shooter.ammo[f.hitscan_slot] = max(shooter.ammo[f.hitscan_slot], 1)
	shooter.reloads[f.hitscan_slot] = 0
	clear(&f.game.impacts)
	health := f.target.health
	shared.player_shoot(shooter)
	if len(f.game.impacts) > 0 { impact = f.game.impacts[0] }
	return health - f.target.health, false, impact
}

@(private="file")
fail :: proc(ok: ^bool, format: string, args: ..any) {
	fmt.printf(format, ..args)
	fmt.println()
	ok^ = false
}

test_native_hurtbox_shots :: proc() -> bool {
	f: Hit_Fixture
	if !fixture_init(&f) { fmt.println("Hurtbox shot test: default loadout lacks a hitscan or melee weapon"); return false }
	defer shared.game_destroy(&f.game)
	ok := true
	weapon := f.game.weapons[f.shooter.loadout[f.hitscan_slot]]
	base := weapon.damage
	hs := weapon.headshot_mlt != 0 ? weapon.headshot_mlt : 1.5
	ls := weapon.legshot_mlt != 0 ? weapon.legshot_mlt : 0.5

	torso := box_point(&f, .TORSO, {0, 0, 0})
	head := box_point(&f, .HEAD, {0, 0, 0})
	head_top := box_point(&f, .HEAD, {0, 0.5, 0})
	leg := box_point(&f, .LEG, {0, 0, 0})
	origin := shared.Vec3{0, 9.5, 0}
	segment := shared.Vec3{weapon.range, 0, 0}

	// 1. Standing target, torso centre: a torsoshot for the weapon's damage
	// (less its tiny drop over 10 units, the same for every case below).
	fixture_place(&f, torso, 0)
	if _, hit_type := shared.krunker_player_shot_test(f.target, origin, segment); hit_type != .TORSOSHOT { fail(&ok, "torso centre: hit type %v", hit_type) }
	body, _, imp := fixture_shoot(&f)
	if abs(body - base) > base * 0.01 || imp.kind != .Player {
		fail(&ok, "torso centre: damage %v (want %v) kind %v", body, base, imp.kind)
	}
	// 2. 1.5 units beside the torso centre: the old 4.9-wide box hit, Krunker's misses.
	fixture_place(&f, torso, 1.5)
	if !legacy_shot_hit(f.target, origin, segment) { fail(&ok, "the old box should have hit 1.5 beside the torso") }
	if d, _, imp := fixture_shoot(&f); d != 0 || imp.kind == .Player {
		fail(&ok, "1.5 beside the torso centre must miss a standing target (damage %v, kind %v)", d, imp.kind)
	}
	// 3. Through the head: a headshot for damage x hsMlt.
	fixture_place(&f, head, 0)
	if _, hit_type := shared.krunker_player_shot_test(f.target, origin, segment); hit_type != .HEADSHOT { fail(&ok, "head: hit type %v", hit_type) }
	if d, _, _ := fixture_shoot(&f); abs(d - body * hs) > base * 0.01 {
		fail(&ok, "head: damage %v (want %v)", d, body * hs)
	}
	// 4. Just above the 2-unit head: a miss.
	fixture_place(&f, head_top + {0, 0.05, 0}, 0)
	if d, _, imp := fixture_shoot(&f); d != 0 || imp.kind == .Player {
		fail(&ok, "just above the head must miss (damage %v, kind %v)", d, imp.kind)
	}
	// 5. A leg: a legshot for damage x lsMlt.
	fixture_place(&f, leg, 0)
	if _, hit_type := shared.krunker_player_shot_test(f.target, origin, segment); hit_type != .LEGSHOT { fail(&ok, "leg: hit type %v", hit_type) }
	if d, _, _ := fixture_shoot(&f); abs(d - body * ls) > base * 0.01 {
		fail(&ok, "leg: damage %v (want %v)", d, body * ls)
	}
	// 6. Moving padding: 0.2 outside a leg misses a standing target and hits
	// the same target while its velocity is non-zero (+1 per side).
	side := (shared.GAME_CONSTANTS.leg_scale * 0.5 + 0.2) * math.sign(leg.z)
	fixture_place(&f, leg, side)
	if d, _, _ := fixture_shoot(&f); d != 0 { fail(&ok, "0.2 outside the leg must miss a standing target (damage %v)", d) }
	fixture_place(&f, leg, side, {0.01, 0, 0})
	if d, _, _ := fixture_shoot(&f); abs(d - body * ls) > base * 0.01 { fail(&ok, "the moving target's +1 padding must catch 0.2 outside the leg (damage %v)", d) }

	// 7. Crouched: the crouched leg boxes are tested, the standing ones are not.
	crouched_leg := box_point(&f, .LEG, {0, 0, 0}, 1)
	fixture_place(&f, crouched_leg, 0, {}, 1)
	if d, _, _ := fixture_shoot(&f); abs(d - body * ls) > base * 0.01 {
		fail(&ok, "crouched leg: damage %v (want %v)", d, body * ls)
	}
	{
		boxes: [shared.KRUNKER_HURTBOX_MAX]shared.Krunker_Hurtbox
		count := shared.krunker_player_hurtboxes(shared.krunker_target_pose(f.target), &boxes)
		legs := 0
		for box in boxes[:count] { if box.part == .LEG { legs += 1 } }
		if legs != 6 { fail(&ok, "a crouched target tests the 6 crouched leg boxes, got %d", legs) }
		// The other set (userData.active false) is never tested: a ray through
		// an inactive standing leg box alone misses, the same box active hits.
		pose := shared.krunker_target_pose(f.target)
		pose.inactive_legs = true
		count = shared.krunker_player_hurtboxes(pose, &boxes)
		inactive := 0
		for box in boxes[:count] {
			if box.part != .LEG || box.active { continue }
			inactive += 1
			centre := shared.krunker_hurtbox_center(box)
			from := centre - {10, 0, 0}
			one := []shared.Krunker_Hurtbox{box}
			if _, hit := shared.krunker_hurtboxes_ray(one, from, {20, 0, 0}); hit != .NONE { fail(&ok, "an inactive leg box was hit") }
			one[0].active = true
			if _, hit := shared.krunker_hurtboxes_ray(one, from, {20, 0, 0}); hit != .LEGSHOT { fail(&ok, "the same leg box active must be a legshot (%v)", hit) }
		}
		if inactive != 2 { fail(&ok, "a crouched pose has the 2 standing leg boxes inactive, got %d", inactive) }
	}

	// 8. Melee: Krunker's padded box, no complexHitboxes; fists do 35.
	melee :: proc(f: ^Hit_Fixture, side: f32, can_throw: bool) -> f32 {
		fixture_place(f, {0, 4, 0}, side)
		f.shooter.loadout_index = i32(f.melee_slot)
		f.shooter.weapon = f.game.weapons[f.shooter.loadout[f.melee_slot]]
		f.shooter.can_throw = can_throw
		f.shooter.aim_val = 0
		health := f.target.health
		shared.player_melee(f.shooter)
		return health - f.target.health
	}
	half := f.target.scale + f.game.config.hitbox_pad
	knife := f.game.weapons[f.shooter.loadout[f.melee_slot]].damage
	if d := melee(&f, half * 0.95, true); abs(d - knife) > 1e-3 { fail(&ok, "melee inside the padded box: damage %v (want %v)", d, knife) }
	if d := melee(&f, half * 1.05, true); d != 0 { fail(&ok, "melee outside the padded box must miss (damage %v)", d) }
	if d := melee(&f, 0, false); abs(d - 35) > 1e-3 { fail(&ok, "fists (knife thrown) do 35 (got %v)", d) }

	// 9. Neither shot path keeps another copy of the player boxes.
	source, read_ok := shared.read_file(fmt.tprintf("%ssrc/shared/player.odin", project_root()))
	if !read_ok { fmt.println("Hurtbox shot test: cannot read src/shared/player.odin"); return false }
	defer delete(source)
	text := string(source)
	if strings.count(text, "krunker_shot_target_test(player_shot_target(player, target, !presentation_only), shot_origin, shot_dir)") != 1 ||
		strings.count(text, "krunker_melee_box(player_shot_target(player, target, true))") != 1 ||
		strings.contains(text, "player_hitboxes") || strings.contains(text, "target.height * 0.72") || strings.count(text, "!map_object_blocks_shots(object)") != 2 {
		fail(&ok, "player_shoot/player_melee must test player_shot_target with the hurtboxes / krunker_melee_box and map_object_blocks_shots")
	}
	if ok { fmt.println("Native shots hit Krunker's hurtboxes (torso/side miss/head/above-head/leg/moving pad/crouched legs), melee its padded box OK") }
	return ok
}

// A bolt flies at the target: Krunker's projectile test is the same prefilter
// + n1e, so 1.5 beside the torso misses and the head is a headshot for
// projectile damage x hsMlt.
test_native_hurtbox_projectiles :: proc() -> bool {
	f: Hit_Fixture
	if !fixture_init(&f) { return false }
	defer shared.game_destroy(&f.game)
	weapon_id: i32 = -1
	for weapon, i in f.game.weapons {
		if weapon != nil && weapon.projectile && weapon.projectile_speed > 0 && weapon.physical_power == 0 && weapon.projectile_damage > 0 { weapon_id = i32(i); break }
	}
	if weapon_id < 0 { fmt.println("Projectile hurtbox test: no plain projectile weapon"); return false }
	weapon := f.game.weapons[weapon_id]
	fly :: proc(f: ^Hit_Fixture, weapon_id: i32) -> f32 {
		clear(&f.game.projectiles)
		append(&f.game.projectiles, shared.Projectile{owner_uid = f.shooter.uid, weapon_id = weapon_id, position = {0, 9.5, 0}, direction = {1, 0, 0}, remaining = 200})
		health := f.target.health
		for _ in 0 ..< 400 {
			if len(f.game.projectiles) == 0 { break }
			shared.game_tick_projectiles(&f.game, 1.0 / 64)
		}
		return health - f.target.health
	}
	ok := true
	torso := box_point(&f, .TORSO, {0, 0, 0})
	head := box_point(&f, .HEAD, {0, 0, 0})
	hs := weapon.headshot_mlt != 0 ? weapon.headshot_mlt : 1.5
	fixture_place(&f, torso, 0)
	if d := fly(&f, weapon_id); abs(d - weapon.projectile_damage) > 1e-3 { fmt.printf("projectile torso: damage %v (want %v)\n", d, weapon.projectile_damage); ok = false }
	fixture_place(&f, torso, 1.5)
	if d := fly(&f, weapon_id); d != 0 { fmt.printf("projectile 1.5 beside the torso must miss (damage %v)\n", d); ok = false }
	fixture_place(&f, head, 0)
	if d := fly(&f, weapon_id); abs(d - weapon.projectile_damage * hs) > 1e-3 { fmt.printf("projectile head: damage %v (want %v)\n", d, weapon.projectile_damage * hs); ok = false }
	if ok { fmt.printf("Projectiles (%s) hit Krunker's hurtboxes OK\n", weapon.name) }
	return ok
}

// Cost of one hitscan ray against 8 players: the old two-box test versus the
// prefilter + hurtboxes (pose build and OBB tests), with half the targets in
// the prefilter's way.
test_native_hurtbox_cost :: proc() -> bool {
	f: Hit_Fixture
	if !fixture_init(&f) { return false }
	defer shared.game_destroy(&f.game)
	targets: [8]shared.Player
	for &target, i in targets {
		target = f.target^
		target.position = {f32(10 + 6 * i), 0, f32(i % 2) * 40}
		target.velocity = {f32(i % 3) * 0.01, 0, 0}
	}
	origin := shared.Vec3{0, 9.5, 0}
	segment := shared.Vec3{200, 0, 0}
	ROUNDS :: 20000
	hits_old, hits_new := 0, 0
	start := time.tick_now()
	for r in 0 ..< ROUNDS {
		for &target in targets {
			if legacy_shot_hit(&target, origin, segment + {0, f32(r % 7) * 0.1, 0}) { hits_old += 1 }
		}
	}
	old_ns := f64(time.tick_since(start)) / ROUNDS
	start = time.tick_now()
	for r in 0 ..< ROUNDS {
		for &target in targets {
			if _, hit := shared.krunker_player_shot_test(&target, origin, segment + {0, f32(r % 7) * 0.1, 0}); hit != .NONE { hits_new += 1 }
		}
	}
	new_ns := f64(time.tick_since(start)) / ROUNDS
	fmt.printf("Hitscan vs 8 players: old boxes %.2f us, Krunker hurtboxes %.2f us per shot (%d / %d target hits over %d rounds) OK\n", old_ns / 1000, new_ns / 1000, hits_old, hits_new, ROUNDS)
	return true
}
