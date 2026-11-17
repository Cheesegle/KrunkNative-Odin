package main

import "core:fmt"
import "core:math/rand"
import "core:time"

import shared "../shared"

// Krunker spawn selection (shared/spawn.odin, a port of krunkbox game.min.js
// `this.getSpawnPoint=function(M,z,B,X){`).

@(private = "file")
spawn_fail :: proc(format: string, args: ..any) -> bool {
	fmt.eprint("Spawn selection: ")
	fmt.eprintfln(format, ..args)
	return false
}

@(private = "file")
Spawn_Fixture :: struct {
	game:     ^shared.Game,
	map_inst: ^shared.Map,
}

@(private = "file")
spawn_fixture :: proc(spawns: []shared.Spawn, objects: []shared.Object = nil, teams := false) -> Spawn_Fixture {
	map_inst := new(shared.Map)
	map_inst.death_y = -1000
	for spawn in spawns {
		s := new(shared.Spawn)
		s^ = spawn
		append(&map_inst.spawns, s)
	}
	for object in objects {
		o := new(shared.Object)
		o^ = object
		append(&map_inst.objects, o)
	}
	shared.map_index_collision_objects(map_inst)

	game := new(shared.Game)
	game.config = shared.DEFAULT_GAME_CONFIG
	game.weapons = shared.g_weapons()
	game.classes = shared.CLASSES_LIST[:]
	game.map_inst = map_inst
	game.mode = shared.mode_init(0)
	game.mode.config.teams = teams
	game.is_local = true
	game.ready = true
	game.match.phase = .LIVE
	// A running clock: at 0 a 0:0 tie now ends the match as a draw (Krunker's
	// endGame), and nobody respawns into an ended match.
	game.match.time_remaining = 600
	game.match.objective.active_object_index = -1
	return {game, map_inst}
}

@(private = "file")
spawn_fixture_destroy :: proc(fixture: Spawn_Fixture) {
	shared.game_destroy(fixture.game)
	free(fixture.game)
	shared.map_destroy(fixture.map_inst) // Frees the map itself too.
}

@(private = "file")
spawn_add_player :: proc(game: ^shared.Game, team: i32, position: shared.Vec3) -> ^shared.Player {
	player := shared.player_init(game)
	player.team = team
	player.active = true
	player.position = position
	shared.player_update_height(player)
	shared.game_players_add(game, player)
	return player
}

@(private = "file")
wall :: proc(position, scale: shared.Vec3) -> shared.Object {
	return {active = true, collision_type = .BOX, position = position, scale = scale}
}

@(private = "file")
pick_x :: proc(fixture: Spawn_Fixture, team: i32, spawner: ^shared.Player, force_comp := false) -> f32 {
	pick := shared.game_get_spawn_point(fixture.game, team, spawner, false, force_comp)
	return pick.position.x
}

test_spawn_selection :: proc() -> bool {
	// A spawn an enemy can see loses to one no enemy can see, even when the
	// hidden one is closer. The wall hides x=50 from an eye at the origin.
	{
		f := spawn_fixture({{position = {50, 0, 0}}, {position = {-200, 0, 0}}}, {wall({25, 0, 0}, {4, 60, 60})})
		defer spawn_fixture_destroy(f)
		me := spawn_add_player(f.game, 0, {1000, 0, 1000})
		me.active = false
		spawn_add_player(f.game, 0, {0, 0, 0})
		if x := pick_x(f, 0, me); x != 50 { return spawn_fail("hidden spawn must beat a visible one, got x=%v", x) }
		// canSee itself: blocked through the wall, clear the other way.
		blockers := shared.spawn_sight_blockers(f.map_inst)
		enemy := f.game.players[1]
		if !shared.spawn_sight_blocked(enemy, {50, 11, 0}, blockers[:]) || shared.spawn_sight_blocked(enemy, {-200, 11, 0}, blockers[:]) {
			return spawn_fail("canSee port disagrees with the wall")
		}
	}

	// canSee ramps: a ramp blocks up to the height the viewer's spot along it
	// reaches (progress 0: flat, nothing blocked; progress 1: full height).
	{
		low := shared.Ramp{start = {20, 0}, end = {30, 0}}
		high := shared.Ramp{start = {-100, 0}, end = {-90, 0}}
		f := spawn_fixture({{position = {50, 0, 0}}}, {wall({25, 0, 0}, {10, 60, 60})})
		defer spawn_fixture_destroy(f) // map_destroy frees the ramp.
		f.map_inst.objects[0].ramp = new_clone(low)
		viewer := spawn_add_player(f.game, 0, {0, 0, 0})
		blockers := shared.spawn_sight_blockers(f.map_inst)
		if shared.spawn_sight_blocked(viewer, {50, 11, 0}, blockers[:]) { return spawn_fail("a flat ramp must not block") }
		free(f.map_inst.objects[0].ramp)
		f.map_inst.objects[0].ramp = new_clone(high)
		if !shared.spawn_sight_blocked(viewer, {50, 11, 0}, blockers[:]) { return spawn_fail("a full-height ramp must block") }
	}

	// Among equally seen spawns, the one farthest from the enemies wins.
	{
		f := spawn_fixture({{position = {150, 0, 0}}, {position = {50, 0, 0}}, {position = {-80, 0, 0}}})
		defer spawn_fixture_destroy(f)
		me := spawn_add_player(f.game, 0, {0, 0, 0})
		me.active = false
		spawn_add_player(f.game, 0, {0, 0, 0})
		if x := pick_x(f, 0, me); x != 150 { return spawn_fail("farthest spawn must win, got x=%v", x) }
	}

	// FFA counts every other player; team mode ignores teammates, and a team's
	// own positions push enemy spawns away from it (spawn control).
	{
		spawns := []shared.Spawn{{position = {-100, 0, 0}}, {position = {100, 0, 0}}}
		// Only p2: x=100 is farther. p2 + p3 (p3 next to x=100): x=-100 wins.
		f := spawn_fixture(spawns)
		me := spawn_add_player(f.game, 0, {0, 0, 0})
		me.active = false
		spawn_add_player(f.game, 0, {-150, 0, 300})
		spawn_add_player(f.game, 0, {100, 0, 10})
		ffa := pick_x(f, 0, me)
		spawn_fixture_destroy(f)
		if ffa != -100 { return spawn_fail("FFA must count every other player, got x=%v", ffa) }

		f = spawn_fixture(spawns, teams = true)
		me = spawn_add_player(f.game, 1, {0, 0, 0})
		me.active = false
		spawn_add_player(f.game, 2, {-150, 0, 300})
		mate := spawn_add_player(f.game, 1, {100, 0, 10})
		team_pick := pick_x(f, 1, me)
		// The enemy's view: the team 1 player near x=100 pushes team 2 away.
		enemy_pick := pick_x(f, 2, f.game.players[1])
		_ = mate
		spawn_fixture_destroy(f)
		if team_pick != 100 { return spawn_fail("teammates must not affect your spawn, got x=%v", team_pick) }
		if enemy_pick != -100 { return spawn_fail("your team must push enemy spawns away, got x=%v", enemy_pick) }
	}

	// Team spawns: other-team and teamOnly spawns are refused, and flipped
	// spawns swap teams 1 and 2.
	{
		f := spawn_fixture({{position = {-50, 0, 0}, team = 1}, {position = {500, 0, 0}, team = 2, team_only = true}}, teams = true)
		defer spawn_fixture_destroy(f)
		me := spawn_add_player(f.game, 1, {0, 0, 0})
		me.active = false
		spawn_add_player(f.game, 2, {0, 0, 0})
		if x := pick_x(f, 1, me); x != -50 { return spawn_fail("team 1 must not take a team 2 teamOnly spawn, got x=%v", x) }
		if x := pick_x(f, 2, me); x != 500 { return spawn_fail("team 2 must take its teamOnly spawn, got x=%v", x) }
		f.game.flipped_spawns = true
		if x := pick_x(f, 1, me); x != 500 { return spawn_fail("flipped spawns must give team 1 the team 2 spawn, got x=%v", x) }
		if x := pick_x(f, 2, me); x != -50 { return spawn_fail("flipped spawns must give team 2 the team 1 spawn, got x=%v", x) }
	}

	// Fallback: nothing qualifies, so map.spawns[0] after the visibility sort
	// (the least seen spawn, map order among ties).
	{
		f := spawn_fixture({{position = {10, 0, 0}, team = 2}, {position = {50, 0, 0}, team = 2}, {position = {-50, 0, 0}, team = 2}}, {wall({25, 0, 0}, {4, 60, 60})}, teams = true)
		defer spawn_fixture_destroy(f)
		me := spawn_add_player(f.game, 1, {0, 0, 0})
		me.active = false
		spawn_add_player(f.game, 1, {0, 0, 0}) // A teammate: nobody counts.
		if x := pick_x(f, 1, me); x != 10 { return spawn_fail("fallback must be map order's first spawn, got x=%v", x) }
		spawn_add_player(f.game, 2, {0, 0, 0}) // An enemy sees all but x=50.
		if x := pick_x(f, 1, me); x != 50 { return spawn_fail("fallback must be the least seen spawn, got x=%v", x) }
	}

	// Ties: stable sort + reverse picks the LAST equal spawn in the current
	// order, every time.
	{
		f := spawn_fixture({{position = {-100, 0, 0}}, {position = {0, 0, 100}}, {position = {100, 0, 0}}, {position = {0, 0, 40}}})
		defer spawn_fixture_destroy(f)
		me := spawn_add_player(f.game, 0, {0, 0, 0})
		me.active = false
		spawn_add_player(f.game, 0, {0, 0, 0})
		for _ in 0 ..< 3 {
			pick := shared.game_get_spawn_point(f.game, 0, me)
			if pick.position != {100, 0, 0} { return spawn_fail("ties must go to the last equal spawn, got %v", pick.position) }
		}
		// No players at all: every spawn scores 0, so the last spawn wins.
		f.game.players[1].active = false
		if pick := shared.game_get_spawn_point(f.game, 0, me); pick.position != {0, 0, 40} { return spawn_fail("all-zero tie must pick the last spawn, got %v", pick.position) }
		// Force first spawn: the current order's first.
		if pick := shared.game_get_spawn_point(f.game, 0, me, true); pick.position != {-100, 0, 0} { return spawn_fail("force first must return spawns[0], got %v", pick.position) }
	}

	// Comp spawns: skipped normally, used (first in order, own team in team
	// modes) when forced, as in Krunker's warmupReset.
	{
		f := spawn_fixture({{position = {300, 0, 0}, comp = 1, team = 2}, {position = {-300, 0, 0}, comp = 1, team = 1}, {position = {20, 0, 0}, team = 1}}, teams = true)
		defer spawn_fixture_destroy(f)
		me := spawn_add_player(f.game, 1, {0, 0, 0})
		me.active = false
		spawn_add_player(f.game, 2, {0, 0, 0})
		if x := pick_x(f, 1, me); x != 20 { return spawn_fail("comp spawns must be skipped outside comp waits, got x=%v", x) }
		if x := pick_x(f, 1, me, true); x != -300 { return spawn_fail("forced comp must take team 1's comp spawn, got x=%v", x) }
		// Warmup end moves active players onto comp spawns.
		me.active = true
		me.position = {0, 0, 0}
		shared.game_warmup_reset(f.game)
		if me.position.x != -300 || f.game.players[1].position.x != 300 { return spawn_fail("warmup reset must use comp spawns, got %v / %v", me.position, f.game.players[1].position) }
	}

	// Spread: getPointSpread lands within spread - 3 of the spawn, rounded,
	// and a wall cuts the offset short.
	{
		f := spawn_fixture({{position = {0.4, 5, 0.3}, spread = 20, direction = 1}})
		defer spawn_fixture_destroy(f)
		me := spawn_add_player(f.game, 0, {0, 0, 0})
		me.active = false
		rand.reset(1234)
		for _ in 0 ..< 32 {
			pick := shared.game_get_spawn_point(f.game, 0, me)
			r2 := pick.position.x * pick.position.x + pick.position.z * pick.position.z
			if r2 > 18 * 18 || pick.position.y != 5 || pick.position.x != f32(i32(pick.position.x)) || pick.direction != 1 {
				return spawn_fail("spread pick out of range: %v", pick.position)
			}
		}
		// A comp wait uses radius 10: no offset, just rounding.
		f.game.spawn_comp_wait = true
		f.map_inst.spawns[0].comp = 1
		if pick := shared.game_get_spawn_point(f.game, 0, me); pick.position != {0, 5, 0} { return spawn_fail("comp wait spread must only round, got %v", pick.position) }
	}

	// The running sim: auto respawn goes through the new selection.
	{
		f := spawn_fixture({{position = {50, 0, 0}}, {position = {-200, 0, 0}}}, {wall({25, 0, 0}, {4, 60, 60}), wall({0, -10, 0}, {2000, 10, 2000})})
		defer spawn_fixture_destroy(f)
		me := spawn_add_player(f.game, 0, {0, 0, 0})
		spawn_add_player(f.game, 0, {0, 0, 0})
		shared.player_kill(me, nil, nil, true)
		if me.active || me.respawn_timer <= 0 { return spawn_fail("kill must start the respawn timer") }
		for _ in 0 ..< 400 {
			shared.game_tick(f.game, 0, 1.0 / 64.0)
			if me.active { break }
		}
		if !me.active || me.position.x != 50 || me.position.z != 0 { return spawn_fail("auto respawn must use the hidden spawn, got active=%v %v", me.active, me.position) }
		if me.direction.y != shared.spawn_yaw(0) { return spawn_fail("spawn yaw must be -PI/2, got %v", me.direction.y) }
	}

	// Map loader: Krunker spawn keys [x, y, z, team, dir, comp, teamOnly, spread].
	{
		path := fmt.tprintf("%ssrc/tests/fixtures/maps/sandstorm.json", project_root())
		map_inst, ok := shared.map_load_from_file(path)
		if !ok { return spawn_fail("sandstorm fixture failed to load") }
		defer { shared.map_destroy(map_inst) }
		if len(map_inst.spawns) == 0 { return spawn_fail("sandstorm fixture has no spawns") }
	}

	fmt.println("Spawn selection tests OK")
	return true
}

// Timing: 8 respawns against 7 live players on the biggest stock map.
test_spawn_selection_timing :: proc() -> bool {
	path := fmt.tprintf("%sassets/maps/piazza.json", project_root())
	map_inst, ok := shared.map_load_from_file(path)
	if !ok { return spawn_fail("piazza failed to load") }
	shared.map_index_collision_objects(map_inst)
	game := new(shared.Game)
	game.config = shared.DEFAULT_GAME_CONFIG
	game.weapons = shared.g_weapons()
	game.classes = shared.CLASSES_LIST[:]
	game.map_inst = map_inst
	game.mode = shared.mode_init(0)
	game.mode.config.teams = false
	game.is_local = true
	game.ready = true
	game.match.phase = .LIVE
	defer {
		shared.game_destroy(game)
		free(game)
		shared.map_destroy(map_inst)
	}
	if len(map_inst.spawns) == 0 { return spawn_fail("piazza has no spawns") }
	players: [8]^shared.Player
	for i in 0 ..< 8 {
		players[i] = spawn_add_player(game, 0, map_inst.spawns[(i * 7) % len(map_inst.spawns)].position)
	}
	blockers := shared.spawn_sight_blockers(map_inst)
	start := time.tick_now()
	for p in players {
		p.active = false
		pick := shared.game_get_spawn_point(game, 0, p)
		p.position = pick.position
		p.active = true
	}
	elapsed := time.duration_milliseconds(time.tick_since(start))
	fmt.printfln("Spawn selection timing: 8 respawns, %d spawns, %d sight blockers (%d objects): %.3f ms total, %.3f ms each", len(map_inst.spawns), len(blockers), len(map_inst.objects), elapsed, elapsed / 8)
	return true
}
