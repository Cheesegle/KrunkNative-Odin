package main

import "core:fmt"
import "core:math"
import "core:math/rand"
import glfw "vendor:glfw"
import shared "../shared"
import kproto "../krunker"
import menuui "../menu"

// The spectator build: -define:KRODIN_SPECTATOR=true, bin\krodin_spectator.exe
// (`build.bat spectator`). It joins live Krunker lobbies the way the browser
// does when its Spectate switch is on, and never plays. Other builds compile
// this file but never activate it.
//
// Krunker parity (krunkbox game.min.js; see the PR for search strings):
//   - ENTER_GAME `en` with its spectate flag, en[6] = 1 (`parseInt(i0),Dc?1:0,`).
//   - START's third argument marks the socket as spectating (u3e, window.spectating).
//   - No INPUT (q) is ever sent; the browser sends q only for an active player.
//   - fpSp names the followed player (`aa.send(Da.fpSp, a ? a.sid : null)`).
//   - Left click previous, right click next, F free cam, R first/third
//     person, M names, 1-9 pick from the player list, wheel changes the
//     follow distance (10-160, step 3) or the free-cam speed, Q/E down/up.
//   - First person: camera at y + height - 1.5 - 3 * crouch with crouch eased
//     at .0085/ms and ADS at .009/ms; the followed body is hidden and a fake
//     crosshair drawn.
// Krodin-only: the view filter (spectator_smooth.odin), the followed
// player's viewmodel, follow-the-killer, the spectator HUD card and player
// list layout, and the free-cam sprint (Shift).

KRODIN_SPECTATOR :: #config(KRODIN_SPECTATOR, false)

Spectator_Mode :: enum { FIRST_PERSON, CHASE, FREE }

// Whether this frame belongs to the spectator (constant false in other builds).
client_spectating :: proc(client: ^Client) -> bool {
	return KRODIN_SPECTATOR && client.spectator.active && client.krunker_world.spectating
}

SPECTATOR_FOLLOW_MIN :: f32(10)  // spect.minD
SPECTATOR_FOLLOW_MAX :: f32(160) // spect.maxD
SPECTATOR_FOLLOW_STEP :: f32(3)  // wheel step
SPECTATOR_FOLLOW_DEFAULT :: f32(28) // Krodin; Krunker starts at its minimum, 10.
SPECTATOR_FREE_SPEED :: f32(60)  // units per second at speed 1
SPECTATOR_CROUCH_RATE :: f32(0.0085) // per millisecond, browser eo.crouch
SPECTATOR_AIM_RATE :: f32(0.009)     // per millisecond, browser eo.aim
SPECTATOR_EYE_DROP :: f32(1.5)       // browser `Do`
SPECTATOR_LIST_MAX :: 9
// Seconds before switching away from a dead target (Krodin's follow killer).
SPECTATOR_RETARGET_DELAY :: f64(1.2)

Spectator :: struct {
	active: bool,
	mode: Spectator_Mode,
	target_sid: i32,
	smoother: Spectator_Smoother,
	last_fed: f64, // Newest pose time pushed into the smoother.
	view: Spectator_View,
	crouch, aim: f32, // Eased like the browser's eo.crouch / eo.aim.
	// The followed player's first-person viewmodel (Krodin-only): a player
	// that never joins game.players, posed from the filtered view each frame.
	proxy: ^shared.Player,
	proxy_sid, proxy_class, proxy_secondary: i32,
	proxy_loadout_revision: u64,
	proxy_in_scene: bool,
	proxy_last_position: shared.Vec3,
	follow_distance: f32,
	orbit: shared.Vec2, // Chase/free camera pitch, yaw.
	free_position: shared.Vec3,
	free_speed: f32,
	hide_names: bool,
	scroll: f32,
	previous: Spectator_Input,
	target_lost_at: f64,
	pending_killer: i32,
	// Hits by the followed player (DO_DAMAGE routed to this socket by fpSp).
	hit_revision: u64,  // The last world.hit_revision looked at.
	hits_shown: int,
	switched_at: f64,   // When the followed player last changed.
	clock: f64,         // The newest spectator_update time.
	rejoin: bool,
	next_enter_at: f64,
	switches: int,
}

// Sends Krunker's fpSp; tests record it instead of using a socket.
spectator_send_control: proc(^Krunker_WS_State, string) -> bool = krunker_ws_send

Spectator_Input :: struct {
	next, previous_target, free, toggle_first, names: bool,
	pick: i32, // 1-9, 0 for none.
	look: shared.Vec2, // Already scaled to radians (yaw, pitch deltas).
	scroll: f32,
	forward, back, left, right, up, down, sprint: bool,
}

spectator_reset :: proc(client: ^Client) {
	spectator_proxy_release(client)
	strength := client.spectator.smoother.strength
	client.spectator = {target_sid = -1, follow_distance = SPECTATOR_FOLLOW_DEFAULT, free_speed = 1, pending_killer = -1}
	client.spectator.smoother.strength = strength
}

// The followed player's live record and client player (nil when gone).
spectator_target :: proc(client: ^Client) -> (^kproto.Krunker_World_Player, ^shared.Player) {
	sid := client.spectator.target_sid
	if sid < 0 { return nil, nil }
	for &source in client.krunker_world.players {
		if source.sid != sid { continue }
		return &source, client_find_player(client, sid)
	}
	return nil, nil
}

// Players that can be followed, in Krunker's player-list order (join order),
// grouped by team for the numbered list.
spectator_candidates :: proc(client: ^Client, out: ^[dynamic; 64]i32) {
	clear(out)
	world := &client.krunker_world
	for team in 0 ..< 3 {
		for source in world.players {
			if source.sid == world.local_sid || !source.active || !source.has_position || source.life_ended { continue }
			if team < 2 ? source.team != i32(team+1) : source.team == 1 || source.team == 2 { continue }
			if len(out) < 64 { append(out, source.sid) }
		}
	}
}

spectator_select :: proc(client: ^Client, sid: i32) {
	spec := &client.spectator
	if sid == spec.target_sid { return }
	spec.target_sid = sid
	spec.switches += 1
	spectator_smoother_reset(&spec.smoother)
	spec.last_fed = 0
	spec.target_lost_at = 0
	spec.pending_killer = -1
	spec.switched_at = spec.clock
	// Start the filter with the poses already buffered for this player, so a
	// switch shows them at once.
	spectator_feed(client)
	source, _ := spectator_target(client)
	if source != nil && source.pose_count > 0 {
		newest := source.poses[source.pose_count-1]
		spec.crouch, spec.aim = newest.crouch, newest.aim
		spec.orbit = {source.direction.x, source.direction.y}
	}
	// Tell the server whom we follow, as the browser does on every switch.
	if client.krunker.connected && client.krunker_world.spectating {
		client.krunker.spectate_target = sid
		spectator_send_control(&client.krunker, "fpSp")
	}
}

// Whether sid is a living player the spectator can follow.
spectator_followable :: proc(client: ^Client, sid: i32) -> bool {
	list: [dynamic; 64]i32
	spectator_candidates(client, &list)
	for candidate in list { if candidate == sid { return true } }
	return false
}

// A random living player other than `except` (never the local spectator),
// -1 when there is none.
spectator_random_other :: proc(client: ^Client, except: i32) -> i32 {
	list: [dynamic; 64]i32
	spectator_candidates(client, &list)
	others: [dynamic; 64]i32
	for sid in list { if sid != except { append(&others, sid) } }
	if len(others) == 0 { return -1 }
	return others[rand.int_max(len(others))]
}

// Krunker's spectMode(dir): the next/previous followable player, wrapping.
spectator_cycle :: proc(client: ^Client, dir: int) {
	list: [dynamic; 64]i32
	spectator_candidates(client, &list)
	if len(list) == 0 { return }
	index := -1
	for sid, i in list { if sid == client.spectator.target_sid { index = i } }
	if index < 0 { index = dir > 0 ? 0 : len(list)-1 }
	else { index = (index + dir + len(list)) % len(list) }
	spectator_select(client, list[index])
	if client.spectator.mode == .FREE { client.spectator.mode = .FIRST_PERSON }
}

spectator_set_free :: proc(client: ^Client) {
	spec := &client.spectator
	spec.mode = .FREE
	spec.free_position = client.camera.position
	spec.orbit = {client.camera.rotation.x, client.camera.rotation.y}
	if client.krunker.connected && client.krunker_world.spectating {
		client.krunker.spectate_target = -1
		spectator_send_control(&client.krunker, "fpSp")
		spec.switched_at = spec.clock
	}
}

// Pushes the target's k poses that arrived since the last call.
spectator_feed :: proc(client: ^Client) {
	spec := &client.spectator
	source, _ := spectator_target(client)
	if source == nil { return }
	for pose in source.poses[:source.pose_count] {
		if pose.time <= spec.last_fed { continue }
		rate := source.send_rate > 0 ? source.send_rate : 10
		spectator_smoother_push(&spec.smoother, pose.time, pose.server_time, pose.has_server_time, rate, pose.position, pose.direction.x, pose.direction.y, pose.crouch, pose.aim, pose.on_ground)
		spec.last_fed = pose.time
	}
}

// Reads the spectator's keys. `read` is client_binding_down's shape (GLFW
// key codes, mouse buttons as -(button+1)) so tests can hold keys.
spectator_read_input :: proc(client: ^Client, look: shared.Vec2, read: proc(glfw.WindowHandle, i32) -> bool = client_binding_down) -> Spectator_Input {
	input: Spectator_Input
	if client.window == nil && read == client_binding_down { return input }
	if client.chat.open || !client.mouse_state.locked { return input }
	w := client.window
	input.previous_target = read(w, -(glfw.MOUSE_BUTTON_LEFT+1))
	input.next = read(w, -(glfw.MOUSE_BUTTON_RIGHT+1))
	input.free = read(w, glfw.KEY_F)
	input.toggle_first = read(w, glfw.KEY_R)
	input.names = read(w, glfw.KEY_M)
	for n in 1 ..= 9 { if read(w, glfw.KEY_0 + i32(n)) { input.pick = i32(n) } }
	input.look = look
	input.scroll = client.spectator.scroll
	client.spectator.scroll = 0
	input.forward = client_action_down(client, .FORWARD, read, scroll = false)
	input.back = client_action_down(client, .BACKWARD, read, scroll = false)
	input.left = client_action_down(client, .LEFT, read, scroll = false)
	input.right = client_action_down(client, .RIGHT, read, scroll = false)
	// Up: Krunker's E, or Space. Down: Krunker's Q, or the rebindable
	// "Spectator: free cam down" (default Left/Right Ctrl, Krodin-only). A
	// spectator sends no gameplay input, so neither ever crouches or jumps.
	input.up = read(w, glfw.KEY_E) || read(w, glfw.KEY_SPACE)
	input.down = read(w, glfw.KEY_Q) || client_action_down(client, .SPECTATOR_DOWN, read, scroll = false)
	input.sprint = read(w, glfw.KEY_LEFT_SHIFT) || read(w, glfw.KEY_RIGHT_SHIFT)
	return input
}

// Once START marks this socket as spectating: take over the camera.
spectator_begin :: proc(client: ^Client) {
	spec := &client.spectator
	spec.active = true
	// Nobody followed yet (the zeroed Client would read as sid 0), so the
	// first frame picks a player at once.
	spec.target_sid, spec.pending_killer, spec.target_lost_at = -1, -1, 0
	client.spawn_pending = false
	client.in_game = true
	if spec.follow_distance == 0 { spec.follow_distance, spec.free_speed = SPECTATOR_FOLLOW_DEFAULT, 1 }
	krunker_ws_set_status(client, "Spectating. Left/right click switches player, F free cam, R first/third person.")
	kproto.network_log("spectate", fmt.tprintf("server accepted spectate; players=%d", len(client.krunker_world.players)))
	if client.window != nil && client.menu.page == .HOME && cursor_focus_may_capture(&client.cursor_focus) {
		glfw.SetInputMode(client.window, glfw.CURSOR, glfw.CURSOR_DISABLED)
		client.mouse_state.locked = true
		x, y := glfw.GetCursorPos(client.window)
		client.mouse_state.last_pos = {f32(x), f32(y)}
	}
}

// One spectator frame: runs after the remote players were interpolated.
spectator_update :: proc(client: ^Client, input: Spectator_Input, now: f64, delta: f32) {
	spec := &client.spectator
	world := &client.krunker_world
	if !world.spectating || !client.krunker.connected {
		if spec.active {
			// A new match (INIT) ends spectating; enter again as a spectator.
			spectator_reset(client)
			spec.rejoin = client.krunker.connected
			kproto.network_log("spectate", "spectating ended; re-entering as a spectator when the lobby is ready")
		}
		if spec.rejoin && client.krunker.connected && world.ready && client.krunker.render_map_ready && !client.spawn_pending && now >= spec.next_enter_at {
			spec.next_enter_at = now + 3
			client_enter_game(client)
		}
		return
	}
	spec.rejoin = false
	if !spec.active { spectator_begin(client) }
	spec.clock = now
	spec.smoother.strength = client.spectator_settings.smoothing
	pressed :: proc(now, before: bool) -> bool { return now && !before }

	// Keys (Krunker's spectate binds).
	if pressed(input.next, spec.previous.next) { spectator_cycle(client, 1) }
	if pressed(input.previous_target, spec.previous.previous_target) { spectator_cycle(client, -1) }
	if pressed(input.free, spec.previous.free) {
		if spec.mode == .FREE {
			spec.mode = .FIRST_PERSON
			if spec.target_sid < 0 { spectator_cycle(client, 1) }
			else if client.krunker.connected {
				// Back on the same player: name them to the server again.
				client.krunker.spectate_target = spec.target_sid
				spectator_send_control(&client.krunker, "fpSp")
				spec.switched_at = spec.clock
			}
		}
		else { spectator_set_free(client) }
	}
	if pressed(input.toggle_first, spec.previous.toggle_first) && spec.mode != .FREE {
		spec.mode = spec.mode == .FIRST_PERSON ? .CHASE : .FIRST_PERSON
		if spec.mode == .CHASE { spec.orbit = {spec.view.pitch, spec.view.yaw} }
	}
	if pressed(input.names, spec.previous.names) { spec.hide_names = !spec.hide_names }
	if input.pick > 0 && input.pick != spec.previous.pick {
		list: [dynamic; 64]i32
		spectator_candidates(client, &list)
		if int(input.pick) <= len(list) {
			spectator_select(client, list[input.pick-1])
			if spec.mode == .FREE { spec.mode = .FIRST_PERSON }
		}
	}
	if input.scroll != 0 {
		if spec.mode == .FREE {
			spec.free_speed = clamp(spec.free_speed * (input.scroll > 0 ? 1.15 : 1/1.15), 0.2, 8)
		} else {
			spec.follow_distance = clamp(spec.follow_distance - SPECTATOR_FOLLOW_STEP*math.sign(input.scroll), SPECTATOR_FOLLOW_MIN, SPECTATOR_FOLLOW_MAX)
		}
	}
	spec.previous = input

	// On death (Krodin-only): about a second after the followed player dies,
	// watch a random living player, their killer, or stay on them.
	for kill in world.kills {
		if kill.victim_sid == spec.target_sid && kill.killer_sid >= 0 && kill.killer_sid != kill.victim_sid { spec.pending_killer = kill.killer_sid }
	}
	source, target := spectator_target(client)
	alive := source != nil && source.active && !source.life_ended && target != nil && target.active
	if spec.mode != .FREE {
		if !alive {
			if spec.target_lost_at == 0 { spec.target_lost_at = now }
			on_death := menuui.Spectator_On_Death(menuui.spectator_settings_validate(client.spectator_settings).on_death)
			// Stay only while they are still in the lobby; a player who left
			// is replaced like any other.
			stay := on_death == .STAY && source != nil && spec.target_sid >= 0
			if !stay && (spec.target_sid < 0 || now - spec.target_lost_at >= SPECTATOR_RETARGET_DELAY) {
				if spec.target_sid < 0 {
					spectator_cycle(client, 1)
				} else {
					next: i32 = -1
					if on_death == .KILLER && spec.pending_killer >= 0 && spectator_followable(client, spec.pending_killer) { next = spec.pending_killer }
					if next < 0 { next = spectator_random_other(client, spec.target_sid) }
					// Nobody else alive: keep the view until someone spawns.
					if next >= 0 { spectator_select(client, next) }
				}
				source, target = spectator_target(client)
				alive = source != nil && source.active && !source.life_ended && target != nil && target.active
			}
		} else { spec.target_lost_at = 0 }
	}

	spectator_hits(client, now)

	spectator_feed(client)
	rate := source != nil && source.send_rate > 0 ? source.send_rate : 10
	spec.view = spectator_smoother_sample(&spec.smoother, now, rate)
	if spec.view.valid {
		// Browser: eo.crouch/eo.aim ease toward the target's values per ms.
		ms := delta * 1000
		spec.crouch += (spec.view.crouch - spec.crouch) * min(1, SPECTATOR_CROUCH_RATE*ms)
		spec.aim += (spec.view.aim - spec.aim) * min(1, SPECTATOR_AIM_RATE*ms)
	}

	switch spec.mode {
	case .FREE:
		spectator_free_camera(client, input, delta)
	case .FIRST_PERSON, .CHASE:
		if !spec.view.valid || target == nil {
			spectator_free_camera(client, {look = input.look}, delta)
			break
		}
		height := shared.GAME_CONSTANTS.player_height - spec.crouch*shared.GAME_CONSTANTS.crouch_distance
		eye := spec.view.position + shared.Vec3{0, height - shared.GAME_CONSTANTS.camera_height, 0}
		if spec.mode == .FIRST_PERSON {
			client.camera.position = eye
			client.camera.rotation = {spec.view.pitch, spec.view.yaw, 0}
			weapon_zoom: f32 = target.weapon != nil ? target.weapon.zoom : 1
			client.camera.zoom = viewmodel_zoom(weapon_zoom, spec.aim, client_viewmodel_values(client))
		} else {
			spec.orbit.y -= input.look.x
			spec.orbit.x = clamp(spec.orbit.x - input.look.y, -1.45, 1.45)
			client.camera.rotation = {spec.orbit.x, spec.orbit.y, 0}
			back := shared.Vec3{math.sin(spec.orbit.y)*math.cos(spec.orbit.x), -math.sin(spec.orbit.x), math.cos(spec.orbit.y)*math.cos(spec.orbit.x)}
			distance := spec.follow_distance
			// Pull in ahead of walls so the target stays in view.
			if client.game.map_inst != nil {
				for step := 0; step < 12 && distance > SPECTATOR_FOLLOW_MIN*0.5 && !shared.map_can_see(client.game.map_inst, eye, eye + back*distance); step += 1 { distance *= 0.8 }
			}
			client.camera.position = eye + back*distance
			client.camera.zoom = 1
		}
		spec.free_position = client.camera.position
	}
	spectator_update_meshes(client, target, delta)
	client.freecam_enabled = false
}

spectator_free_camera :: proc(client: ^Client, input: Spectator_Input, delta: f32) {
	spec := &client.spectator
	spec.orbit.y -= input.look.x
	spec.orbit.x = clamp(spec.orbit.x - input.look.y, -math.PI*0.5, math.PI*0.5)
	yaw := spec.orbit.y
	move: shared.Vec3
	if input.forward != input.back {
		s: f32 = input.forward ? -1 : 1
		move += {math.sin(yaw)*s, 0, math.cos(yaw)*s}
	}
	if input.left != input.right {
		s: f32 = input.left ? -1 : 1
		move += {math.cos(yaw)*s, 0, -math.sin(yaw)*s}
	}
	if input.up != input.down { move.y = input.up ? 1 : -1 }
	if length := math.sqrt(move.x*move.x + move.y*move.y + move.z*move.z); length > 0 {
		speed := SPECTATOR_FREE_SPEED * spec.free_speed * (input.sprint ? 2.5 : 1)
		spec.free_position += move / length * speed * delta
	}
	client.camera.position = spec.free_position
	client.camera.rotation = {spec.orbit.x, spec.orbit.y, 0}
	client.camera.zoom = 1
}

spectator_proxy_release :: proc(client: ^Client) {
	spec := &client.spectator
	if spec.proxy == nil { return }
	if spec.proxy.mesh != nil {
		if spec.proxy_in_scene && client.fps_scene != nil { scene_remove_player_mesh(client.fps_scene, cast(^Player_Mesh)spec.proxy.mesh, int(spec.proxy.loadout_size)) }
		player_meshes_fini(spec.proxy)
	}
	shared.player_destroy(spec.proxy)
	spec.proxy, spec.proxy_in_scene = nil, false
}

@(private = "file")
spectator_mesh_shown :: proc(player: ^shared.Player, shown: bool) {
	if player == nil || player.mesh == nil { return }
	mesh := cast(^Player_Mesh)player.mesh
	if mesh.anchor != nil { mesh.anchor.scale = shown ? {1, 1, 1} : {0, 0, 0} }
}

// Hides the followed body in first person (browser objInstances.visible =
// false) and poses the Krodin-only first-person viewmodel at frame rate.
spectator_update_meshes :: proc(client: ^Client, target: ^shared.Player, delta: f32) {
	spec := &client.spectator
	for player in client.game.players {
		if player != nil && player != client.me && player.active { spectator_mesh_shown(player, !(spec.mode == .FIRST_PERSON && player == target)) }
	}
	want := spec.mode == .FIRST_PERSON && target != nil && target.weapon != nil && spec.view.valid && client.fps_scene != nil
	source, _ := spectator_target(client)
	if want && spec.proxy != nil && (spec.proxy_sid != target.uid || spec.proxy_class != target.class_index || spec.proxy_secondary != target.secondary_id || source != nil && source.loadout_revision != spec.proxy_loadout_revision) {
		spectator_proxy_release(client)
	}
	if !want {
		if spec.proxy != nil { spectator_mesh_shown(spec.proxy, false) }
		return
	}
	if spec.proxy == nil {
		proxy := shared.player_init(&client.game)
		if proxy == nil { return }
		proxy.uid, proxy.team, proxy.is_you = target.uid, target.team, true
		shared.player_spawn(proxy, target.class_index, target.secondary_id)
		shared.player_swap_weapon(proxy, clamp(target.loadout_index, 0, max(proxy.loadout_size-1, 0)), true, true, false)
		proxy.swap_timer = 0
		proxy.active = true
		proxy.position = spec.view.position
		player_generate_meshes(proxy, true)
		if proxy.mesh != nil {
			scene_add_player_mesh(client.fps_scene, cast(^Player_Mesh)proxy.mesh, int(proxy.loadout_size))
			spec.proxy_in_scene = true
		}
		spec.proxy = proxy
		spec.proxy_sid, spec.proxy_class, spec.proxy_secondary = target.uid, target.class_index, target.secondary_id
		if source != nil { spec.proxy_loadout_revision = source.loadout_revision }
		spec.proxy_last_position = spec.view.position
	}
	proxy := spec.proxy
	// Weapon state (swaps, reloads, recoil, melee) is animated on the
	// followed player every frame; copy it. Pose and step come from the
	// filtered view, so the viewmodel moves at render rate.
	// A remote player's swap timer never runs (no input is simulated for
	// them), so the proxy animates its own swap from the k weapon slot.
	if proxy.loadout_index != target.loadout_index && target.loadout_index >= 0 && target.loadout_index < proxy.loadout_size {
		shared.player_swap_weapon(proxy, target.loadout_index, true, false, false)
	}
	proxy.swap_timer = max(0, proxy.swap_timer - delta)
	proxy.recoil_anim, proxy.recoil_anim_y = target.recoil_anim, target.recoil_anim_y
	proxy.view_kick, proxy.view_kick_phase = target.view_kick, target.view_kick_phase
	proxy.melee_pose, proxy.melee_phase = target.melee_pose, target.melee_phase
	proxy.position = spec.view.position
	proxy.velocity = spec.view.velocity
	proxy.direction = {spec.view.pitch, spec.view.yaw}
	proxy.crouch_val, proxy.aim_val, proxy.on_ground = spec.crouch, spec.aim, spec.view.on_ground
	shared.player_update_height(proxy)
	// The walk cycle advances with the filtered horizontal distance, as the
	// local player's does, instead of the server's 10 Hz stepVal.
	d := spec.view.position - spec.proxy_last_position
	distance := math.sqrt(d.x*d.x + d.z*d.z)
	if distance < 16 && spec.view.on_ground { shared.player_step(proxy, distance) }
	spec.proxy_last_position = spec.view.position
	proxy.step_chase += (proxy.step_val - proxy.step_chase) * min(1, delta*20)
	proxy.idle_anim += shared.GAME_CONSTANTS.idle_anim_speed * delta
	shared.player_update_visual_animations(proxy, delta)
	player_update_meshes(proxy, false)
	spectator_mesh_shown(proxy, !client.spectator_settings.hide_viewmodel)
}

// Hitmarkers for the followed player's hits (Krodin's hitmarker, Krunker's
// sound). The server sends DO_DAMAGE(victim sid, damage, headshot) to each
// socket whose specStream is the attacker (changeHealth:
// `specStream==N.sid&&...send($e.DO_DAMAGE,h.sid,Y,J)`), and fpSp is what
// names our stream. So a DO_DAMAGE that names a player, while we follow
// someone, is that player's hit. Guards: none in free cam (fpSp null), none
// within SPECTATOR_HIT_GRACE of a switch (in flight for the previous
// stream), none naming the followed player himself (self damage), and only
// for victims in the lobby. The spectator variant has no kill flag; the
// victim's CHANGE_HEALTH arrives just before it, so health 0 (or a
// KILL_PLAYER by the followed player) marks a kill.
SPECTATOR_HIT_GRACE :: f64(0.3)

spectator_hits :: proc(client: ^Client, now: f64) {
	spec := &client.spectator
	world := &client.krunker_world
	if world.hit_revision == spec.hit_revision { return }
	spec.hit_revision = world.hit_revision
	if world.hit_revision == 0 || spec.mode == .FREE || spec.target_sid < 0 { return }
	if world.last_hit_at - spec.switched_at < SPECTATOR_HIT_GRACE { return }
	victim_sid := world.hit_victim_sid
	if victim_sid < 0 || victim_sid == spec.target_sid { return }
	victim: ^kproto.Krunker_World_Player
	for &p in world.players { if p.sid == victim_sid { victim = &p } }
	if victim == nil { return }
	lethal := victim.health <= 0 || victim.life_ended
	for kill in world.kills { if kill.victim_sid == victim_sid && kill.killer_sid == spec.target_sid { lethal = true } }
	hit_marker_show(&client.hit_marker, client_hitmarker_values(client), lethal, world.hit_headshot)
	spec.hits_shown += 1
	audio_play_effect(client.audio, world.hit_headshot ? "crit_0" : "hit_0", gain = 0.7, priority = 4)
}
