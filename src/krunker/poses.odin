package krunker

import shared "../shared"

Krunker_World_Pose :: struct {
	time: f64,
	position: shared.Vec3,
	direction: shared.Vec2,
	crouch, aim: f32,
	on_ground: bool,
	step: f32,
	// The k packet's server stamp (seconds since the match started; value 3,
	// `M - this.startTime` in ms on the wire), for the spectator view filter.
	server_time: f64,
	has_server_time: bool,
}

krunker_world_buffer_pose :: proc(player: ^Krunker_World_Player, received_at: f64) {
	pose := Krunker_World_Pose{time = received_at, position = player.position, direction = player.direction, crouch = player.crouch_val, aim = player.aim_val, on_ground = player.on_ground, step = player.step_val}
	if player.pose_count > 0 {
		previous := player.poses[player.pose_count-1]
		distance := pose.position - previous.position
		// A teleport or reappearance starts a new path; never sweep across the
		// map or replay an old path after a prolonged interruption.
		if received_at - previous.time > 0.5 || distance.x*distance.x + distance.y*distance.y + distance.z*distance.z > 256*256 {
			player.pose_count = 0
		} else if received_at <= previous.time {
			player.poses[player.pose_count-1] = pose
			return
		}
	}
	if player.pose_count == len(player.poses) {
		copy(player.poses[:], player.poses[1:])
		player.pose_count -= 1
	}
	player.poses[player.pose_count] = pose
	player.pose_count += 1
}
