package main

import "core:math"
import shared "../shared"

// Krunker's kill cam.
//
// The browser's KILL_PLAYER handler (krunkbox game.min.js `function I3e`,
// Krunker-Reverse game.deob.js line ~222034) does, when the victim is you and
// the killer is another player in the world:
//
//   $.config.kCams && (wt.camLookAt(Dr.x, Dr.y + Dr.height/1.5, Dr.z),
//       Dr.interpolate = !1, Dr.Jf1b8al = !0,
//       Dr.objInstances && (Dr.objInstances.visible = !0))
//
// camLookAt sets one fixed controls target from the camera's position at that
// moment: the pitch and yaw toward the point two thirds up the killer, and a
// stop point 24 units short of it on the line back to the camera. Every frame
// controls.update (`wt.update(qn * deltaMlt)`) eases toward it:
//
//   yaw   += angleDiff(yaw,   target.yD) * ms * 0.0022   (PD)
//   pitch += angleDiff(pitch, target.xD) * ms * 0.0022
//   pos   moves toward target.xyz by distance * ms * 0.0012   (Dre)
//
// The frame loop only places the camera at the player while you are alive, so
// the pan runs until the server's START (respawn), whose `wt.reset` clears the
// target. `Dr.interpolate = false` freezes the killer where they stood; the
// rest of the world stops as well because the server sends UPDATE_PLAYERS only
// to active or spectating players. `Jf1b8al` forces the killer's nametag on.
// Howler's listener is only moved while alive or spectating, so sound stays
// where you died.
KILL_CAM_ROTATE_RATE :: f32(0.0022) // PD, per millisecond
KILL_CAM_MOVE_RATE   :: f32(0.0012) // Dre, per millisecond
KILL_CAM_STANDOFF    :: f32(24)     // camLookAt stops 24 units short of the point
KILL_CAM_HEIGHT_DIV  :: f32(1.5)    // Dr.y + Dr.height / 1.5
// A native kill event can arrive a frame before the snapshot that marks you
// dead; a cam whose victim is still alive after this long is dropped.
KILL_CAM_DEATH_GRACE :: f32(1)

Kill_Cam_Target :: struct {
	pitch, yaw: f32,
	position: shared.Vec3,
}

Kill_Cam :: struct {
	active: bool,
	killer_uid: i32,
	target: Kill_Cam_Target,
	// Krunker's controls.object: the eye the target was computed from. A
	// third-person camera keeps its world offset from it.
	pivot, offset: shared.Vec3,
	rotation: shared.Vec3, // (pitch, yaw, roll) of controls.object
	// Audio listener pose at death (Howler keeps the last alive pose).
	listener_position: shared.Vec3,
	listener_yaw, listener_pitch: f32,
	seen_dead: bool,
	age: f32,
	// Last consumed krunker_world.local_death_revision.
	live_revision: u64,
}

// fN: pitch from `from` toward `to`, negative when looking down.
kill_cam_pitch_to :: proc(from, to: shared.Vec3) -> f32 {
	d := to - from
	distance := math.sqrt(d.x*d.x + d.y*d.y + d.z*d.z)
	if distance <= 0 { return 0 }
	pitch := math.asin(clamp(abs(d.y)/distance, 0, 1))
	return from.y > to.y ? -pitch : pitch
}

// Ys(from.z, from.x, to.z, to.x): the camera yaw that faces `to`.
kill_cam_yaw_to :: proc(from, to: shared.Vec3) -> f32 {
	return math.atan2(from.x - to.x, from.z - to.z)
}

// fp: shortest signed angle from a to b.
kill_cam_angle_diff :: proc(a, b: f32) -> f32 {
	return math.atan2(math.sin(b - a), math.cos(a - b))
}

// controls.camLookAt(x, y, z) from the camera pivot `eye`.
kill_cam_look_at :: proc(eye, point: shared.Vec3) -> Kill_Cam_Target {
	pitch := kill_cam_pitch_to(eye, point)
	yaw := kill_cam_yaw_to(eye, point)
	return {
		pitch = pitch, yaw = yaw,
		position = {
			point.x + KILL_CAM_STANDOFF*math.sin(yaw)*math.cos(pitch),
			point.y - KILL_CAM_STANDOFF*math.sin(pitch),
			point.z + KILL_CAM_STANDOFF*math.cos(yaw)*math.cos(pitch),
		},
	}
}

// One controls.update(ms) toward the target. `rotation` is (pitch, yaw, roll).
// The factors are clamped to 1 so a long hitch cannot overshoot.
kill_cam_step :: proc(position, rotation: ^shared.Vec3, target: Kill_Cam_Target, ms: f32) {
	turn := min(max(ms, 0)*KILL_CAM_ROTATE_RATE, 1)
	rotation.y += kill_cam_angle_diff(rotation.y, target.yaw)*turn
	rotation.x += kill_cam_angle_diff(rotation.x, target.pitch)*turn
	d := target.position - position^
	distance := math.sqrt(d.x*d.x + d.y*d.y + d.z*d.z)
	if distance <= 0 { return }
	travel := distance*min(max(ms, 0)*KILL_CAM_MOVE_RATE, 1)
	yaw := kill_cam_yaw_to(position^, target.position)
	pitch := kill_cam_pitch_to(position^, target.position)
	position.x -= travel*math.sin(yaw)*math.cos(pitch)
	position.y += travel*math.sin(pitch)
	position.z -= travel*math.cos(yaw)*math.cos(pitch)
}

client_kill_cams_enabled :: proc(client: ^Client) -> bool {
	// Live: the lobby's INIT config; before one arrives, Krunker's default (on).
	if client.krunker.connected { return !client.krunker_world.has_game_config || client.krunker_world.game_config.kill_cams }
	return client.game.config.kill_cams
}

// The cam is showing: started and you have not respawned.
client_kill_cam_viewing :: proc(client: ^Client) -> bool {
	return client.kill_cam.active && client.me != nil && !client.me.active
}

// The killer while the cam is showing, if still in the world.
client_kill_cam_killer :: proc(client: ^Client) -> ^shared.Player {
	if !client_kill_cam_viewing(client) { return nil }
	return client_find_player(client, client.kill_cam.killer_uid)
}

// Krunker's Dr.interpolate = false: the killer's displayed pose is frozen.
client_kill_cam_freezes :: proc(client: ^Client, uid: i32) -> bool {
	return client_kill_cam_viewing(client) && uid == client.kill_cam.killer_uid
}

client_kill_cam_stop :: proc(client: ^Client) {
	revision := client.kill_cam.live_revision
	client.kill_cam = {live_revision = revision}
}

// A kill of `victim_uid` by `killer_uid`. Nothing happens unless the lobby has
// Kill Cams on, you are the victim and the killer is another player that this
// client knows about (no suicide, fall or environment death).
client_kill_cam_on_kill :: proc(client: ^Client, victim_uid, killer_uid: i32) {
	me := client.me
	if !client_kill_cams_enabled(client) || me == nil || victim_uid != me.uid || killer_uid < 0 || killer_uid == victim_uid { return }
	killer := client_find_player(client, killer_uid)
	if killer == nil || killer == me { return }
	revision := client.kill_cam.live_revision
	cam := Kill_Cam{active = true, killer_uid = killer_uid, live_revision = revision}
	if player_uses_third_person_camera(me) { cam.offset = me.game.map_inst.config.cam_offset }
	cam.pivot = client.camera.position - cam.offset
	point := killer.position + shared.Vec3{0, killer.height/KILL_CAM_HEIGHT_DIV, 0}
	cam.target = kill_cam_look_at(cam.pivot, point)
	// The view direction, without the camera-only recoil kick.
	cam.rotation = {me.direction.x, me.direction.y, 0}
	cam.listener_position = cam.pivot
	cam.listener_yaw, cam.listener_pitch = me.direction.y, me.direction.x
	killer.interpolate = false
	client.kill_cam = cam
}

// Runs once per frame after the alive camera, before the audio listener and
// the killfeed drain (which clears the native kill events read here).
client_kill_cam_update :: proc(client: ^Client, delta: f32) {
	if client.krunker.connected {
		world := &client.krunker_world
		if world.local_death_revision != client.kill_cam.live_revision {
			client.kill_cam.live_revision = world.local_death_revision
			client_kill_cam_on_kill(client, world.local_sid, world.local_killer_sid)
		}
	} else {
		for event in client.game.kill_events { client_kill_cam_on_kill(client, event.victim_uid, event.killer_uid) }
	}
	cam := &client.kill_cam
	if !cam.active { return }
	me := client.me
	cam.age += delta
	// START ends it in Krunker (wt.reset); END retargets the camera.
	if me == nil || client.end_screen_active || me.active && (cam.seen_dead || cam.age > KILL_CAM_DEATH_GRACE) {
		client_kill_cam_stop(client)
		return
	}
	if me.active { return }
	cam.seen_dead = true
	if client.freecam_enabled { return }
	delta_mlt := client.game.config.delta_mlt > 0 ? client.game.config.delta_mlt : 1
	kill_cam_step(&cam.pivot, &cam.rotation, cam.target, delta*1000*delta_mlt)
	client.camera.position = cam.pivot + cam.offset
	client.camera.rotation = cam.rotation
	// players.kill: toggleAim(you, 0).
	client.camera.zoom = 1
}
