package shared

import "core:math"
import "core:math/rand"

// Krunker spawn selection ("spawn control"), ported from krunkbox game.min.js:
//   this.getSpawnPoint=function(M,z,B,X){ ... }   (M team, z spawner,
//   B force first spawn, X force comp spawns)
//   this.getPointSpread=function(M,z,B,X,Z){ ... }
//   this.canSee=function(M,z,B,X,Z,$,se,pe,oe){ ... }
//   function mp(e,a){return e.dst-a.dst}
// Krunker-Reverse game.deob.js has the same code (this["getSpawnPoint"]).
//
// 1. Visibility: every spawn's dst = number of living enemies (not the
//    spawner, not on team M; everyone in FFA) whose canSee to
//    (spawn.x, spawn.y + 11, spawn.z) is clear. canSee returns the
//    obstruction, so a falsy result means the enemy CAN see the spawn.
//    map.spawns is stably sorted by dst IN PLACE; the order carries over to
//    the next call (Krodin keeps it in Game.spawn_order).
// 2. Distance: only spawns tied for the lowest dst are scored again, as the
//    sum of distances to every enemy (+ enemy flags in flag modes, + zones the
//    enemy captured in dom). A spawn qualifies if its team is the spawner's
//    (possibly flipped) team or it has no team. Stable ascending sort then
//    reverse: the farthest wins and, among equal scores, the LAST one in the
//    current spawn order wins.
// 3. Fallback: map.spawns[0] (the current order's first spawn).
// 4. Spread: during a comp wait timer getPointSpread(radius 10), else
//    getPointSpread(spread + 7) when the spawn has a spread.

// Krunker's ip (playerHeight): visibility is tested at spawn.y + 11.
SPAWN_SIGHT_HEIGHT :: f64(PLAYER_HEIGHT)

Spawn_Rank :: struct {
	spawn: ^Spawn,
	dst:   f64,
}

Spawn_Pick :: struct {
	position:  Vec3,
	direction: i32,
	spawn:     ^Spawn, // The map spawn the pick came from; nil without spawns.
}

// Krunker's spawn yaw: xDire = -((dir||0)+1)*PI/2.
spawn_yaw :: proc(direction: i32) -> f32 {
	return -math.PI / 2.0 * (1.0 + f32(direction))
}

// Krunker flips spawn teams 1 and 2 every round (flippedSpawns).
spawn_effective_team :: proc(game: ^Game, team: i32) -> i32 {
	if team != 0 && game.flipped_spawns {
		if team == 1 { return 2 }
		if team == 2 { return 1 }
	}
	return team
}

// The persistent spawn order (Krunker sorts map.spawns in place). Rebuilt in
// map order whenever the game's map changes, like Krunker reloading the map.
game_spawn_order :: proc(game: ^Game) -> []Spawn_Rank {
	map_inst := game.map_inst
	if map_inst == nil {
		clear(&game.spawn_order)
		game.spawn_order_map = nil
		return nil
	}
	if game.spawn_order_map != map_inst || len(game.spawn_order) != len(map_inst.spawns) {
		clear(&game.spawn_order)
		for spawn in map_inst.spawns {
			append(&game.spawn_order, Spawn_Rank{spawn = spawn})
		}
		game.spawn_order_map = map_inst
	}
	return game.spawn_order[:]
}

// JavaScript Array.prototype.sort with mp: a stable ascending sort on dst.
@(private = "file")
spawn_rank_stable_sort :: proc(ranks: []Spawn_Rank) {
	for i in 1 ..< len(ranks) {
		item := ranks[i]
		j := i
		for j > 0 && ranks[j - 1].dst > item.dst {
			ranks[j] = ranks[j - 1]
			j -= 1
		}
		ranks[j] = item
	}
}

// JS Math.min / Math.max propagate NaN; n0 relies on that for rays that run
// exactly along a slab face (0 * Infinity).
@(private = "file")
js_min :: #force_inline proc(a, b: f64) -> f64 {
	if a != a || b != b { return math.nan_f64() }
	return a < b ? a : b
}

@(private = "file")
js_max :: #force_inline proc(a, b: f64) -> f64 {
	if a != a || b != b { return math.nan_f64() }
	return a > b ? a : b
}

// Krunker's n0: slab test with an inverse direction. Returns the entry
// fraction, or 0 for a miss (n0 returns false; NaN is falsy too). The entry
// can be negative when the origin is inside the box; Krunker keeps that.
krunker_ray_box :: proc(origin, inv_dir, box_min, box_max: [3]f64) -> f64 {
	f := (box_min.x - origin.x) * inv_dir.x
	p := (box_max.x - origin.x) * inv_dir.x
	m := (box_min.y - origin.y) * inv_dir.y
	g := (box_max.y - origin.y) * inv_dir.y
	u := (box_min.z - origin.z) * inv_dir.z
	y := (box_max.z - origin.z) * inv_dir.z
	entry := js_max(js_max(js_min(f, p), js_min(m, g)), js_min(u, y))
	exit := js_min(js_min(js_max(f, p), js_max(m, g)), js_max(u, y))
	if exit < 0 || entry > exit || entry != entry { return 0 }
	return entry
}

@(private = "file")
js_inverse :: #force_inline proc(v: f64) -> f64 {
	if v == 0 { return math.copy_sign(math.inf_f64(1), v) }
	return 1.0 / v
}

// One object canSee tests, with its box precomputed (Krodin's objects are
// bottom-centred with full sizes; Krunker's are centred with half sizes).
Sight_Blocker :: struct {
	box_min, box_max: [3]f64,
	ramp:             ^Object, // Non-nil for ramps: the top depends on the viewer.
}

// Objects canSee tests: Krunker skips noShoot (and noCol, which sets noShoot),
// inactive, complexColl, transparent and triangle objects. Krodin's shot
// filter is the same set for the objects it models.
spawn_sight_blockers :: proc(map_inst: ^Map, allocator := context.temp_allocator) -> [dynamic]Sight_Blocker {
	blockers := make([dynamic]Sight_Blocker, 0, 64, allocator)
	if map_inst == nil { return blockers }
	count := map_inst.collision_indexed ? len(map_inst.collision_objects) : len(map_inst.objects)
	for i in 0 ..< count {
		object := map_inst.objects[map_inst.collision_indexed ? int(map_inst.collision_objects[i]) : i]
		if !map_object_blocks_shots(object) { continue }
		half_x := f64(object.scale.x) * 0.5
		half_z := f64(object.scale.z) * 0.5
		append(&blockers, Sight_Blocker{
			box_min = {f64(object.position.x) - half_x, f64(object.position.y), f64(object.position.z) - half_z},
			// A ramp can reach 0.02 above its size (see spawn_sight_blocked).
			box_max = {f64(object.position.x) + half_x, f64(object.position.y) + f64(object.scale.y) + (object.ramp != nil ? 0.02 : 0), f64(object.position.z) + half_z},
			ramp    = object.ramp != nil ? object : nil,
		})
	}
	return blockers
}

// Port of Krunker's canSee(viewer, x, y, z): a ray from the viewer's eye
// (y + height - cameraHeight) along (target - feet); blocked when an object's
// entry fraction is in (0, 1). Ramps block only up to the height the viewer's
// position along the ramp reaches. Returns true when the view is BLOCKED,
// matching canSee's truthy result. Krodin maps have no terrain mesh.
// Boxes outside the segment's bounds are skipped first: they cannot give an
// entry in (0, 1), nor contain the eye (Krunker's negative-entry case).
spawn_sight_blocked :: proc(viewer: ^Player, target: [3]f64, blockers: []Sight_Blocker) -> bool {
	feet := [3]f64{f64(viewer.position.x), f64(viewer.position.y), f64(viewer.position.z)}
	eye := feet
	eye.y += f64(viewer.height) - f64(GAME_CONSTANTS.camera_height)
	dir := target - feet
	end := eye + dir
	seg_min := [3]f64{min(eye.x, end.x), min(eye.y, end.y), min(eye.z, end.z)}
	seg_max := [3]f64{max(eye.x, end.x), max(eye.y, end.y), max(eye.z, end.z)}
	inv := [3]f64{js_inverse(dir.x), js_inverse(dir.y), js_inverse(dir.z)}
	for blocker in blockers {
		box_min, box_max := blocker.box_min, blocker.box_max
		if box_max.x < seg_min.x || box_min.x > seg_max.x || box_max.z < seg_min.z || box_min.z > seg_max.z || box_max.y < seg_min.y || box_min.y > seg_max.y {
			continue
		}
		if object := blocker.ramp; object != nil {
			ramp_direction := math.PI * 0.5 * f32(object.direction)
			point := Vec2{viewer.position.x + viewer.scale * math.cos(ramp_direction), viewer.position.z + viewer.scale * math.sin(ramp_direction)}
			progress := f64(clamp(progress_on_line(object.ramp.start, object.ramp.end, point), 0.0, 1.0))
			// ot = (height + .01) * progress with Krunker's half height.
			box_max.y = box_min.y + (f64(object.scale.y) + 0.02) * progress
		}
		t := krunker_ray_box(eye, inv, box_min, box_max)
		if t != 0 && t < 1 { return true }
	}
	return false
}

@(private = "file")
js_round :: #force_inline proc(v: f64) -> f64 {
	return math.floor(v + 0.5)
}

// Port of getPointSpread(x, z, y, radius, dir): a random direction, shortened
// to the first active object along it (from y + 1, rising 1 unit), then moved
// radius - 10 units and rounded. Comp waits use radius 10, i.e. no offset.
spawn_point_spread :: proc(map_inst: ^Map, x, z, y, radius: f64, direction: i32) -> Spawn_Pick {
	angle := rand.float64_range(-math.PI, math.PI)
	sin_a := math.sin(angle + math.PI)
	cos_a := math.cos(angle + math.PI)
	inv := [3]f64{js_inverse(radius * sin_a), 1, js_inverse(radius * cos_a)}
	origin := [3]f64{x, y + 1, z}
	fraction := 1.0
	if map_inst != nil {
		count := map_inst.collision_indexed ? len(map_inst.collision_objects) : len(map_inst.objects)
		for i in 0 ..< count {
			object := map_inst.objects[map_inst.collision_indexed ? int(map_inst.collision_objects[i]) : i]
			if !object.active || object.collision_type == .NONE { continue }
			half_x := f64(object.scale.x) * 0.5
			half_z := f64(object.scale.z) * 0.5
			box_min := [3]f64{f64(object.position.x) - half_x, f64(object.position.y), f64(object.position.z) - half_z}
			box_max := [3]f64{f64(object.position.x) + half_x, f64(object.position.y) + f64(object.scale.y), f64(object.position.z) + half_z}
			t := krunker_ray_box(origin, inv, box_min, box_max)
			if t != 0 && t <= fraction { fraction = t }
		}
	}
	reach := radius - 10
	return Spawn_Pick{
		position  = {f32(js_round(x + reach * fraction * sin_a)), f32(y), f32(js_round(z + reach * fraction * cos_a))},
		direction = direction,
	}
}

@(private = "file")
spawn_distance :: #force_inline proc(spawn: ^Spawn, p: Vec3) -> f64 {
	dx := f64(spawn.position.x) - f64(p.x)
	dy := f64(spawn.position.y) - f64(p.y)
	dz := f64(spawn.position.z) - f64(p.z)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
}

// Port of Krunker's getSpawnPoint(team, spawner, forceFirst, forceComp).
// The comp wait timer state (Krunker waitTimers[0].comp) is Game.spawn_comp_wait.
game_get_spawn_point :: proc(game: ^Game, team: i32, spawner: ^Player, force_first := false, force_comp := false) -> Spawn_Pick {
	order := game_spawn_order(game)
	if len(order) == 0 { return {} }
	comp_wait := game.spawn_comp_wait
	spawn_team := spawn_effective_team(game, team)
	pick_of :: proc(spawn: ^Spawn) -> Spawn_Pick {
		return {position = spawn.position, direction = spawn.direction, spawn = spawn}
	}
	if force_first { return pick_of(order[0].spawn) }

	// Step 1: count the enemies with a clear view of each spawn.
	blockers := spawn_sight_blockers(game.map_inst)
	for &rank in order {
		rank.dst = 0
		spawn := rank.spawn
		target := [3]f64{f64(spawn.position.x), f64(spawn.position.y) + SPAWN_SIGHT_HEIGHT, f64(spawn.position.z)}
		for other in game.players {
			if other == nil || !other.active || other == spawner || team != 0 && other.team == team { continue }
			if !spawn_sight_blocked(other, target, blockers[:]) { rank.dst += 1 }
		}
	}
	spawn_rank_stable_sort(order)
	lowest := order[0].dst
	teams := game.mode != nil && game.mode.config.teams

	// Step 2: score the least-seen spawns by distance to the enemy.
	candidates := make([dynamic]Spawn_Rank, 0, len(order), context.temp_allocator)
	for &rank in order {
		spawn := rank.spawn
		is_comp := spawn.comp != 0
		if !(!is_comp || comp_wait || force_comp) || spawn.team_only && spawn.team != spawn_team { continue }
		if comp_wait || force_comp {
			if is_comp && (!teams || spawn.team == spawn_team) {
				append(&candidates, rank)
				break
			}
			continue
		}
		if rank.dst != lowest { continue }
		rank.dst = 0
		for other in game.players {
			if other == nil || !other.active || other == spawner || team != 0 && other.team == team { continue }
			rank.dst += spawn_distance(spawn, other.position)
		}
		// Krunker mode.flags / mode.oneflag add the distance to every
		// non-neutral flag not owned by `team`, and mode.dom the distance to
		// every zone captured by another team. Krodin has no CTF flag manager
		// or domination zones yet, so those terms are not added.
		if spawn_team != 0 && spawn.team == spawn_team || spawn.team == 0 {
			append(&candidates, rank)
		}
	}
	spawn_rank_stable_sort(candidates[:])
	// E.reverse(); E[0]: the last of the highest scores.
	chosen := len(candidates) > 0 ? candidates[len(candidates) - 1].spawn : order[0].spawn

	if comp_wait {
		pick := spawn_point_spread(game.map_inst, f64(chosen.position.x), f64(chosen.position.z), f64(chosen.position.y), 10, chosen.direction)
		pick.spawn = chosen
		return pick
	}
	if chosen.spread != 0 {
		pick := spawn_point_spread(game.map_inst, f64(chosen.position.x), f64(chosen.position.z), f64(chosen.position.y), f64(chosen.spread) + 7, chosen.direction)
		pick.spawn = chosen
		return pick
	}
	return pick_of(chosen)
}

// Krunker warmupReset: when warmup ends every active player is moved to a
// comp spawn (getSpawnPoint(team, player, false, true)) and resetPosition'd.
game_warmup_reset :: proc(game: ^Game) {
	for player in game.players {
		if player == nil || !player.active { continue }
		pick := game_get_spawn_point(game, player.team, player, false, true)
		if pick.spawn == nil { continue }
		player_reset_position(player, pick.position, spawn_yaw(pick.direction))
	}
}

// Krunker player.resetPosition(x, y, z, xDire): y + .01, zero velocity,
// clear ladder/wall/jump state and stand up.
player_reset_position :: proc(player: ^Player, position: Vec3, yaw: f32) {
	player.position = {position.x, position.y + 0.01, position.z}
	player.direction.y = yaw
	player.velocity = {}
	player.on_ladder = false
	player.did_jump = false
	player.did_wall_jump = false
	player.crouch_val = 0
	player_update_height(player)
}
