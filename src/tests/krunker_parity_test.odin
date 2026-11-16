package main

import "core:fmt"
import shared "../shared"

// Small Krunker movement parity checks: class wallJD, crouchVal rounding,
// border height (Yb) and the collision of addMesh props past KNIGHT.
test_krunker_movement_parity :: proc() -> bool {
	return test_wall_jump_decel() && test_crouch_val_rounding() && test_border_height() && test_mesh_prop_prefab_collision()
}

parity_empty_map :: proc() -> shared.Map {
	return shared.Map{death_y = -10000, config = shared.Map_Config{speed = {1, 1, 1}, air_accel = 1, ladder_accel = 1, slide_time = 1, slide_accel = 1, jump_cooldown = 1}}
}

// Krunker: `var Ze = p.mode.wallJD ?? (this.config.wallJD || 0)`, and every
// class gets the class-editor default (`varN: "wallJD"`, `def: 0.3`) when its
// export omits the field. Gravity while falling, crouched and on a wall is
// scaled by it.
test_wall_jump_decel :: proc() -> bool {
	for class in shared.CLASSES_LIST {
		if class.wall_jump_decel != 0.3 {
			fmt.printf("wallJD default missing for %s: %f\n", class.name, class.wall_jump_decel)
			return false
		}
	}
	map_inst := parity_empty_map()
	defer delete(map_inst.objects)
	game := shared.Game{}
	player := physics_game_init(&game, &map_inst, true)
	defer shared.game_destroy(&game)

	classes := shared.CLASSES_LIST
	runner := 9 // Runner: wallJ true
	falling_step :: proc(player: ^shared.Player, crouch: bool) -> f32 {
		player.position = {0, 50, 0}
		player.last_position = player.position
		player.on_ground = false
		player.on_wall = 1
		player.crouch_val = crouch ? 1 : 0
		player.velocity = {0, -0.01, 0}
		input := shared.Input{delta = PHYSICS_DT, move_dir = -1, crouch = crouch}
		shared.player_proc_input(player, &input, true, false)
		return -0.01 - player.velocity.y
	}
	gravity_step := PHYSICS_DT * shared.GAME_CONSTANTS.gravity
	for decel in ([?]f32{0.3, 0.05, 0.2, 0}) {
		classes[runner].wall_jump_decel = decel
		game.classes = classes[:]
		shared.player_spawn(player, i32(runner))
		if player.wall_jump_decel != decel || !player.wall_jump {
			fmt.printf("wallJD not copied at spawn: %f != %f\n", player.wall_jump_decel, decel)
			return false
		}
		if dv := falling_step(player, true); abs(dv - gravity_step * decel) > 1e-7 {
			fmt.printf("Crouched wall gravity with wallJD %f: dv %f, expected %f\n", decel, dv, gravity_step * decel)
			return false
		}
		if dv := falling_step(player, false); abs(dv - gravity_step) > 1e-7 {
			fmt.printf("Standing wall gravity must ignore wallJD: dv %f\n", dv)
			return false
		}
	}
	// A mode's wallJD overrides the class value.
	classes[runner].wall_jump_decel = 0.3
	shared.player_spawn(player, i32(runner))
	game.mode.config.wall_jump_decel, game.mode.config.has_wall_jump_decel = 0.05, true
	defer game.mode.config.has_wall_jump_decel = false
	if dv := falling_step(player, true); abs(dv - gravity_step * 0.05) > 1e-7 {
		fmt.printf("Mode wallJD override ignored: dv %f\n", dv)
		return false
	}
	game.classes = shared.CLASSES_LIST[:]
	fmt.println("Wall jump decel (wallJD) OK")
	return true
}

// Krunker: `this.crouchVal &&= this.crouchVal.round(3)` after the crouch update.
test_crouch_val_rounding :: proc() -> bool {
	map_inst := parity_empty_map()
	defer delete(map_inst.objects)
	game := shared.Game{}
	player := physics_game_init(&game, &map_inst, true)
	defer shared.game_destroy(&game)
	player.position = {0, 50, 0}
	player.on_ground = false
	dt := f32(1.0 / 144.0) // 7 * dt = 0.048611...
	expected := [?]f32{0.049, 0.098, 0.147}
	for want in expected {
		input := shared.Input{delta = dt, move_dir = -1, crouch = true}
		shared.player_proc_input(player, &input, true, false)
		if abs(player.crouch_val - want) > 1e-6 {
			fmt.printf("crouchVal not rounded to 3 decimals: %f, expected %f\n", player.crouch_val, want)
			return false
		}
		if abs(player.height - (shared.GAME_CONSTANTS.player_height - want * shared.GAME_CONSTANTS.crouch_distance)) > 1e-5 {
			fmt.printf("Height must use the rounded crouchVal: %f\n", player.height)
			return false
		}
	}
	input := shared.Input{delta = dt, move_dir = -1}
	shared.player_proc_input(player, &input, true, false)
	if abs(player.crouch_val - 0.098) > 1e-6 {
		fmt.printf("Uncrouch not rounded: %f\n", player.crouch_val)
		return false
	}
	fmt.println("crouchVal rounding OK")
	return true
}

// Krunker's border volumes reach `Yb = 500` above their top (`borderH: Yb`).
test_border_height :: proc() -> bool {
	if shared.GAME_CONSTANTS.border_height != 500 {
		fmt.printf("Border height %f, Krunker Yb is 500\n", shared.GAME_CONSTANTS.border_height)
		return false
	}
	map_inst := parity_empty_map()
	border := shared.Object{active = true, collision_type = .BOX, is_border = true, position = {0, 0, 0}, scale = {20, 10, 20}}
	append(&map_inst.objects, &border)
	defer delete(map_inst.objects)
	game := shared.Game{}
	player := physics_game_init(&game, &map_inst, true)
	defer shared.game_destroy(&game)

	// 400 units above the top: inside Krunker's border, so a wall.
	player.position = {-20, 410, 0}
	player.last_position = player.position
	player.on_ground = false
	player.velocity = {0.08, 0, 0}
	for _ in 0 ..< 32 {
		input := shared.Input{delta = PHYSICS_DT, move_dir = -1}
		shared.player_proc_input(player, &input, true, false)
		player.velocity.x = 0.08
	}
	if player.position.x > -10 - player.scale + 0.001 {
		fmt.printf("Border at +400 did not block: x %f\n", player.position.x)
		return false
	}
	// Above Yb a falling player lands on the border's ceiling.
	player.position = {0, 515, 0}
	player.last_position = player.position
	player.velocity = {}
	for _ in 0 ..< 128 {
		input := shared.Input{delta = PHYSICS_DT, move_dir = -1}
		shared.player_proc_input(player, &input, true, false)
	}
	if !player.on_ground || abs(player.position.y - 510) > 0.001 {
		fmt.printf("Border ceiling: y %f grounded %v, expected 510\n", player.position.y, player.on_ground)
		return false
	}
	fmt.println("Border height (Yb = 500) OK")
	return true
}

// Prefab ids past KNIGHT that reach Krunker's addMesh are solid unless l/col.
test_mesh_prop_prefab_collision :: proc() -> bool {
	path := fmt.tprintf("%ssrc/tests/fixtures/maps/prop_prefabs.json", project_root())
	map_inst, loaded := shared.map_load_from_file(path)
	if !loaded {
		fmt.eprintln("Prop prefab test: could not load fixture")
		return false
	}
	defer shared.map_destroy(map_inst)
	Expect :: struct { id: i32, no_col: bool, solid: bool }
	// Order matches the fixture's objects.
	expected := [?]Expect{
		{60, false, true},  // GIFT
		{81, false, true},  // DUMPSTER
		{85, false, true},  // AC_UNIT
		{90, false, true},  // WEAPONBOX
		{97, false, true},  // SCRAPCRATE
		{81, true, false},  // DUMPSTER with l: 1
		{97, true, false},  // SCRAPCRATE with col: true
		{91, false, false}, // MYSTERY_BOX: own add path, starts inactive
		{92, false, false}, // PERK_MACHINE: own add path
		{94, false, false}, // KRUM_MACHINE: own add path
		{63, false, false}, // LIGHT_BAR: own add path
		{99, false, false}, // COLLISION_MESH: editor tool, never exported
	}
	if len(map_inst.objects) != len(expected) {
		fmt.printf("Prop prefab fixture has %d objects\n", len(map_inst.objects))
		return false
	}
	for want, i in expected {
		object := map_inst.objects[i]
		solid := object.collision_type == .BOX
		if i32(object.prefab) != want.id || solid != want.solid {
			fmt.printf("Prefab %d (noCol %v): solid %v, expected %v\n", i32(object.prefab), want.no_col, solid, want.solid)
			return false
		}
		if want.solid && !test_map_collision_drop(object, map_inst.config, true) {
			return false
		}
	}
	fmt.println("Mesh prop prefabs past KNIGHT collide like Krunker's addMesh OK")
	return true
}
