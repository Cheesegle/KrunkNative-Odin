package main

import "core:math"
import "core:strings"
import "core:testing"
import shared "../shared"
import kproto "../krunker"

when ODIN_TEST {
	@(private = "file")
	cam_near :: proc(a, b: f32, tolerance: f32 = 1e-3) -> bool { return abs(a - b) <= tolerance }

	@(private = "file")
	cam_distance :: proc(a, b: shared.Vec3) -> f32 {
		d := a - b
		return math.sqrt(d.x*d.x + d.y*d.y + d.z*d.z)
	}

	// Native/offline client with you (uid 1, eye at the origin's camera) and a
	// killer (uid 2) 100 units ahead (-z) on lower ground.
	@(private = "file")
	Cam_Fixture :: struct {
		client: ^Client,
		mode: shared.Game_Mode,
		me, killer, other: ^shared.Player,
	}

	@(private = "file")
	cam_fixture :: proc() -> ^Cam_Fixture {
		f := new(Cam_Fixture)
		f.client = new(Client)
		client := f.client
		client.game.mode = &f.mode
		client.game.config = shared.DEFAULT_GAME_CONFIG
		client.game.weapons = shared.g_weapons()
		client.game.is_local = true
		f.me, f.killer, f.other = new(shared.Player), new(shared.Player), new(shared.Player)
		f.me^ = {uid = 1, is_you = true, active = true, health = 100, game = &client.game, position = {0, 0, 0}, direction = {0.1, 0.3}}
		f.killer^ = {uid = 2, active = true, health = 100, max_health = 100, game = &client.game, position = {0, -8, -100}, interpolate = true}
		f.other^ = {uid = 3, active = true, health = 100, max_health = 100, game = &client.game, position = {40, 0, -40}, interpolate = true}
		for p in ([]^shared.Player{f.me, f.killer, f.other}) { shared.player_update_height(p) }
		append(&client.game.players, f.me, f.killer, f.other)
		client.me = f.me
		// Alive camera: at the eye, as client_tick places it.
		client.camera.position = f.me.position + shared.Vec3{0, f.me.height - shared.GAME_CONSTANTS.camera_height, 0}
		client.camera.rotation = {f.me.direction.x, f.me.direction.y, 0}
		client.camera.zoom = 1.6
		return f
	}

	@(private = "file")
	cam_fixture_free :: proc(f: ^Cam_Fixture) {
		delete(f.client.game.players)
		delete(f.client.game.kill_events)
		free(f.me); free(f.killer); free(f.other)
		free(f.client)
		free(f)
	}

	// One frame's kill-cam update followed by the killfeed drain, as client_tick.
	@(private = "file")
	cam_frame :: proc(client: ^Client, delta: f32) {
		client_kill_cam_update(client, delta)
		clear(&client.game.kill_events)
	}

	@(test)
	kill_cam_look_at_matches_krunker :: proc(t: ^testing.T) {
		eye := shared.Vec3{0, 10, 0}
		point := shared.Vec3{0, 6, -100}
		target := kill_cam_look_at(eye, point)
		// Ys(eye.z, eye.x, p.z, p.x) = atan2(0, 100) = 0: facing -z, the killer.
		testing.expect(t, cam_near(target.yaw, 0))
		// fN: asin(4 / |d|), negative because the eye is above the point.
		testing.expect(t, cam_near(target.pitch, -math.asin(4 / cam_distance(eye, point))))
		// The stop point is 24 units from the killer, on the line back to the eye.
		testing.expect(t, cam_near(cam_distance(target.position, point), KILL_CAM_STANDOFF))
		testing.expect(t, cam_near(cam_distance(eye, target.position) + KILL_CAM_STANDOFF, cam_distance(eye, point), 1e-2))
		// A killer to the +x side: yaw -pi/2 (camera forward is -sin(yaw), -cos(yaw)).
		side := kill_cam_look_at({0, 0, 0}, {50, 0, 0})
		testing.expect(t, cam_near(side.yaw, -math.PI/2) && cam_near(side.position.x, 26) && cam_near(side.pitch, 0))
		// Degenerate: camera already at the point.
		same := kill_cam_look_at(point, point)
		testing.expect(t, !math.is_nan(same.pitch) && !math.is_nan(same.position.x))
	}

	@(test)
	kill_cam_step_eases_like_controls_update :: proc(t: ^testing.T) {
		position := shared.Vec3{0, 10, 0}
		rotation := shared.Vec3{0, 1, 0}
		target := kill_cam_look_at(position, {0, 6, -100})
		start := cam_distance(position, target.position)
		kill_cam_step(&position, &rotation, target, 16)
		// Krunker: pos moves by distance * ms * Dre; angles by diff * ms * PD.
		testing.expect(t, cam_near(start - cam_distance(position, target.position), start * 16 * KILL_CAM_MOVE_RATE, 1e-2))
		testing.expect(t, cam_near(rotation.y, 1 + kill_cam_angle_diff(1, target.yaw) * 16 * KILL_CAM_ROTATE_RATE))
		// Shortest way round: from 3 rad toward -3 rad turns up through pi.
		testing.expect(t, kill_cam_angle_diff(3, -3) > 0)
		for _ in 0 ..< 600 { kill_cam_step(&position, &rotation, target, 1000.0 / 60) } // 10 s
		testing.expect(t, cam_distance(position, target.position) < 0.01)
		testing.expect(t, cam_near(rotation.y, target.yaw) && cam_near(rotation.x, target.pitch))
		// A 2 s hitch does not overshoot.
		far := shared.Vec3{100, 50, 100}
		rotation = {}
		kill_cam_step(&far, &rotation, target, 2000)
		testing.expect(t, cam_distance(far, target.position) < 1e-3)
	}

	@(test)
	kill_cam_native_kill_aims_at_two_thirds_of_the_killer :: proc(t: ^testing.T) {
		f := cam_fixture(); defer cam_fixture_free(f)
		client := f.client
		eye := client.camera.position
		testing.expect(t, shared.player_apply_damage(f.me, f.killer, 500, 0, false))
		client_kill_cam_update(client, 1.0 / 60)
		cam := &client.kill_cam
		if !testing.expect(t, cam.active && cam.killer_uid == 2, "a kill by another player starts the kill cam") { return }
		point := f.killer.position + shared.Vec3{0, f.killer.height / 1.5, 0}
		want := kill_cam_look_at(eye, point)
		testing.expect(t, cam_near(cam.target.yaw, want.yaw) && cam_near(cam.target.pitch, want.pitch) && cam_distance(cam.target.position, want.position) < 1e-3,
			"camLookAt(Dr.x, Dr.y + Dr.height / 1.5, Dr.z) from the death eye")
		testing.expect(t, !f.killer.interpolate, "the killer stops interpolating")
		testing.expect(t, f.other.interpolate, "nobody else is touched")
		// One frame already moved the camera toward the killer and unzoomed.
		testing.expect(t, cam_distance(client.camera.position, cam.target.position) < cam_distance(eye, cam.target.position))
		testing.expect(t, client.camera.zoom == 1)
		// The killfeed still drains the same event afterwards.
		client_tick_kill_feed(client, 0)
		testing.expect_value(t, client.kill_feed.count, 1)
		// The killer's frozen pose is what the camera keeps looking at.
		for _ in 0 ..< 600 { cam_frame(client, 1.0 / 60) }
		forward := shared.Vec3{-math.sin(client.camera.rotation.y) * math.cos(client.camera.rotation.x), math.sin(client.camera.rotation.x), -math.cos(client.camera.rotation.y) * math.cos(client.camera.rotation.x)}
		to_point := point - client.camera.position
		testing.expect(t, cam_near(cam_distance({}, to_point), KILL_CAM_STANDOFF, 0.05))
		dot := (forward.x*to_point.x + forward.y*to_point.y + forward.z*to_point.z) / cam_distance({}, to_point)
		testing.expectf(t, dot > 0.999, "the camera ends 24 units away, facing the killer (cos %v)", dot)
		// The audio listener stays where you died.
		position, yaw, pitch := client_audio_listener_pose(client)
		testing.expect(t, cam_distance(position, eye) < 1e-4 && yaw == f.me.direction.y && pitch == f.me.direction.x)
	}

	@(test)
	kill_cam_ignores_suicide_falls_others_and_kcams_off :: proc(t: ^testing.T) {
		f := cam_fixture(); defer cam_fixture_free(f)
		client := f.client
		shared.player_kill(f.me, f.me, nil, false) // Suicide.
		cam_frame(client, 0.016)
		testing.expect(t, !client.kill_cam.active, "suicide: no kill cam")
		f.me.active = true
		shared.player_kill(f.me, nil, nil, false) // Fall / environment.
		cam_frame(client, 0.016)
		testing.expect(t, !client.kill_cam.active, "no killer: no kill cam")
		f.me.active = true
		shared.player_kill(f.other, f.killer, nil, false) // Someone else died.
		cam_frame(client, 0.016)
		testing.expect(t, !client.kill_cam.active, "another victim: no kill cam")
		client_kill_cam_on_kill(client, 1, 99) // Killer not in the world.
		testing.expect(t, !client.kill_cam.active, "unknown killer: no kill cam")
		clear(&client.game.kill_events)
		client.game.config.kill_cams = false
		camera := client.camera
		shared.player_kill(f.me, f.killer, nil, false)
		cam_frame(client, 0.016)
		testing.expect(t, !client.kill_cam.active && f.killer.interpolate, "Kill Cams off: nothing happens")
		testing.expect(t, client.camera == camera, "the camera stays where you died")
	}

	@(test)
	kill_cam_ends_on_respawn_and_survives_the_killer_leaving :: proc(t: ^testing.T) {
		f := cam_fixture(); defer cam_fixture_free(f)
		client := f.client
		shared.player_kill(f.me, f.killer, nil, false)
		cam_frame(client, 0.016)
		testing.expect(t, client_kill_cam_killer(client) == f.killer)
		// The killer dies mid-cam: the model goes, the camera keeps panning.
		shared.player_kill(f.killer, f.other, nil, false)
		cam_frame(client, 0.016)
		before := client.camera.position
		cam_frame(client, 0.016)
		testing.expect(t, client.kill_cam.active && client.camera.position != before, "the target is a fixed point")
		f.client.game.players[1] = f.other
		pop(&f.client.game.players) // The killer disconnects.
		testing.expect(t, client_kill_cam_killer(client) == nil)
		cam_frame(client, 0.016)
		testing.expect(t, client.kill_cam.active, "still panning after the killer leaves")
		append(&f.client.game.players, f.killer)
		// The native kill event can precede the snapshot that marks you dead.
		f.me.active = true
		cam_frame(client, 0.016)
		testing.expect(t, !client.kill_cam.active, "respawn ends the kill cam")
		testing.expect(t, !client_kill_cam_viewing(client) && !client_kill_cam_freezes(client, 2))
		position, yaw, _ := client_audio_listener_pose(client)
		testing.expect(t, position == client.camera.position && yaw == f.me.direction.y, "the listener follows you again")

		f.me.active = true
		client.kill_cam = {}
		shared.player_kill(f.me, f.killer, nil, false)
		f.me.active = true // Still alive in this frame's snapshot.
		cam_frame(client, 0.5)
		testing.expect(t, client.kill_cam.active, "a kill event ahead of the death snapshot is kept")
		cam_frame(client, 0.6)
		testing.expect(t, !client.kill_cam.active, "...but not when you never die")
	}

	@(test)
	kill_cam_live_kill_player_packet :: proc(t: ^testing.T) {
		f := cam_fixture(); defer cam_fixture_free(f)
		client := f.client
		client.krunker.connected = true
		world := &client.krunker_world
		world^ = {local_sid = 1}
		defer kproto.krunker_world_reset(world)
		// INIT config: kCams parsed into the lobby config, default on.
		init := []kproto.Krunker_Msgpack_Value{"init", i64(0), i64(0), i64(0), nil, nil, nil, []kproto.Krunker_Msgpack_Map_Entry{{key = "kCams", value = false}}}
		kproto.krunker_world_apply_game_config(world, init)
		testing.expect(t, !world.game_config.kill_cams)
		kproto.krunker_world_apply_game_config(world, init[:7])
		testing.expect(t, world.game_config.kill_cams, "Krunker's default is on")
		append(&world.players,
			kproto.Krunker_World_Player{sid = 1, name = strings.clone("Me"), active = true},
			kproto.Krunker_World_Player{sid = 2, name = strings.clone("Killer"), active = true},
		)
		// KILL_PLAYER with the hide flag set: no feed line, still a kill cam.
		f.me.active = false
		packet := []kproto.Krunker_Msgpack_Value{"3", i64(1), i64(4), i64(2), kproto.Krunker_Msgpack_Nil{}, kproto.Krunker_Msgpack_Nil{}, true}
		testing.expect(t, kproto.krunker_world_apply_packet(world, packet))
		testing.expect(t, len(world.kills) == 0 && world.local_killer_sid == 2)
		client_kill_cam_update(client, 0.016)
		testing.expect(t, client.kill_cam.active && client.kill_cam.killer_uid == 2)
		// Processed once.
		client.kill_cam.active = false
		client_kill_cam_update(client, 0.016)
		testing.expect(t, !client.kill_cam.active)
		// No killer (fall) and Kill Cams off: nothing.
		world.players[0].life_ended, world.players[0].active = false, true
		testing.expect(t, kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"3", i64(1), i64(5), kproto.Krunker_Msgpack_Nil{}}))
		client_kill_cam_update(client, 0.016)
		testing.expect(t, !client.kill_cam.active && world.local_killer_sid == -1)
		world.game_config.kill_cams = false
		testing.expect(t, kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"3", i64(1), i64(6), i64(2)}))
		client_kill_cam_update(client, 0.016)
		testing.expect(t, !client.kill_cam.active, "kCams off")
		world.game_config.kill_cams = true

		// Freeze: the killer's buffered poses are not interpolated, others are.
		testing.expect(t, kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"3", i64(1), i64(7), i64(2)}))
		client_kill_cam_update(client, 0.016)
		testing.expect(t, client.kill_cam.active)
		other := kproto.Krunker_World_Player{sid = 3, active = true, send_rate = 10}
		killer := &world.players[1]
		for source in ([]^kproto.Krunker_World_Player{killer, &other}) {
			source.send_rate = 10
			source.poses[0] = {time = 0, position = {0, 0, 0}}
			source.poses[1] = {time = 1, position = {10, 0, 0}}
			source.pose_count = 2
		}
		append(&world.players, other)
		killer_before, other_before := f.killer.position, f.other.position
		krunker_client_interpolate_remotes(client, 0.6, 0.016)
		testing.expect(t, f.killer.position == killer_before, "the killer is frozen")
		testing.expect(t, f.other.position != other_before, "the rest of the world plays out what it received")
		// Respawn (START revives you): interpolation resumes.
		f.me.active = true
		client_kill_cam_update(client, 0.016)
		testing.expect(t, !client.kill_cam.active)
		krunker_client_interpolate_remotes(client, 0.6, 0.016)
		testing.expect(t, f.killer.position != killer_before)
	}

	@(test)
	kill_cam_forces_the_killers_nametag :: proc(t: ^testing.T) {
		f := cam_fixture(); defer cam_fixture_free(f)
		client := f.client
		f.other.nameplate_alpha = 1
		shared.player_kill(f.me, f.killer, nil, false)
		player_healthbars_update_visibility(client, 1)
		testing.expect(t, f.killer.nameplate_alpha == 0 && f.other.nameplate_alpha == 0, "dead without a kill cam: no plates")
		cam_frame(client, 0.016)
		player_healthbars_update_visibility(client, 1.1)
		testing.expect(t, f.killer.can_be_seen && f.killer.nameplate_alpha == 1, "Jf1b8al = true: the killer's plate is on")
		testing.expect(t, f.other.nameplate_alpha == 0)
		f.me.active = true
		cam_frame(client, 0.016)
		testing.expect(t, client_kill_cam_killer(client) == nil)
	}
}
