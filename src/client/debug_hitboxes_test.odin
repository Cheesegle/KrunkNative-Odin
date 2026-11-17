package main

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import mu "vendor:microui"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import shared "../shared"
import kproto "../krunker"

when ODIN_TEST {
	HITBOX_SHOT_W :: 640
	HITBOX_SHOT_H :: 360

	@(test)
	debug_render_toggles_default_off :: proc(t: ^testing.T) {
		client: Client
		dr := &client.debug_render
		testing.expect(t, !dr.player_hitboxes && !dr.map_collision && !dr.shot_rays && !dr.xray, "every Rendering toggle starts off")
		testing.expect(t, !debug_render_enabled(dr), "nothing is drawn with every toggle off")
		// Off means no work: no lines, no GL objects, no recorded shots.
		append(&client.game.impacts, shared.Bullet_Impact{origin = {0, 9.5, 0}, position = {0, 9.5, -40}, hit = true, kind = .World})
		defer delete(client.game.impacts)
		debug_render_record_impacts(&client, 0)
		debug_render_after_world(&client)
		debug_render_after_viewmodel(&client)
		testing.expect(t, len(dr.lines) == 0 && dr.program == 0 && dr.shot_count == 0, "disabled toggles must not build lines, create GL objects or record shots")
	}

	// Position of a text command drawn by the debug window this frame.
	debug_test_text_pos :: proc(dbg: ^Debug_UI, label: string) -> (pos: [2]f32, found: bool) {
		command: ^mu.Command
		for variant in mu.next_command_iterator(&dbg.ctx, &command) {
			if text, ok := variant.(^mu.Command_Text); ok && text.str == label {
				return {f32(text.pos.x) + 4, f32(text.pos.y) + 4}, true
			}
		}
		return
	}

	debug_test_click :: proc(client: ^Client, dbg: ^Debug_UI, at: [2]f32) {
		perf_test_frame(client, dbg, {pointer = at})
		perf_test_frame(client, dbg, {pointer = at})
		perf_test_frame(client, dbg, {pointer = at, buttons = {.LEFT}})
		perf_test_frame(client, dbg, {pointer = at})
	}

	@(test)
	debug_ui_rendering_section_toggles :: proc(t: ^testing.T) {
		client, dbg := perf_test_debug_ui()
		defer { free(dbg); free(client) }
		// 1080p: below the Player section the expanded Rendering section would
		// scroll past a 720p screen's bottom.
		debug_ui_layout(dbg, 1920, 1080)
		perf_test_frame(client, dbg, {})
		perf_test_frame(client, dbg, {}) // The window fits its content height after a frame.
		header, has_header := debug_test_text_pos(dbg, "Rendering")
		_, shown_collapsed := debug_test_text_pos(dbg, "Player hitboxes")
		testing.expect(t, has_header && !shown_collapsed, "the Rendering section starts collapsed")
		debug_test_click(client, dbg, header)
		toggles := [?]string{"Player hitboxes", "Map collision (150u)", "Shot rays", "X-ray (through walls)"}
		for label in toggles {
			at, found := debug_test_text_pos(dbg, label)
			if !testing.expectf(t, found, "%s checkbox is listed (header at %v)", label, header) { return }
			debug_test_click(client, dbg, at)
		}
		dr := &client.debug_render
		testing.expect(t, dr.player_hitboxes && dr.map_collision && dr.shot_rays && dr.xray, "each checkbox flips its toggle")
		_, labelled := debug_test_text_pos(dbg, "Native server hurtboxes")
		testing.expect(t, labelled, "the hitbox model in use is labelled")
	}

	@(test)
	debug_hitboxes_draw_the_tested_boxes :: proc(t: ^testing.T) {
		player := shared.Player{active = true, scale = shared.GAME_CONSTANTS.player_scale, position = {3.5, 1.25, -20}}
		for crouch in ([3]f32{0, 0.5, 1}) {
			player.crouch_val = crouch
			shared.player_update_height(&player)
			for moving in ([2]bool{false, true}) {
				player.velocity = moving ? shared.Vec3{0.02, 0, 0} : {}
				// Shots: the hurtboxes player_shoot tests, in the pose and size
				// it tests them (solid), the other size and leg set dim.
				lines, want: [dynamic]Debug_Line_Vertex
				defer { delete(lines); delete(want) }
				debug_lines_player(&lines, &player, .KRODIN, .SHOT, moving)
				debug_lines_krunker_pose(&want, shared.krunker_target_pose(&player), moving)
				testing.expectf(t, len(lines) == len(want) && len(lines) > 0, "crouch %v: native shot boxes draw the server's hurtboxes (%d vs %d vertices)", crouch, len(lines), len(want))
				same := len(lines) == len(want)
				for v, i in lines { if same && v != want[i] { same = false } }
				testing.expectf(t, same, "crouch %v moving %v: drawn lines match the tested pose", crouch, moving)
				// Every box the shot test uses is drawn solid.
				boxes: [shared.KRUNKER_HURTBOX_MAX]shared.Krunker_Hurtbox
				count := shared.krunker_player_hurtboxes(shared.krunker_target_pose(&player), &boxes)
				colors := DEBUG_KRUNKER_COLORS
				for box in boxes[:count] {
					corner := (box.transform * shared.Vec4{-0.5, -0.5, -0.5, 1}).xyz
					found := false
					for v in lines { if v.color == colors[box.part] && linalg.length(v.position - corner) < 1e-4 { found = true; break } }
					testing.expectf(t, found, "crouch %v moving %v: tested %v box is drawn solid", crouch, moving, box.part)
				}
			}
			player.velocity = {}
			// Melee: Krunker's one padded box (players.melee).
			lines: [dynamic]Debug_Line_Vertex
			defer delete(lines)
			debug_lines_player(&lines, &player, .KRODIN, .MELEE, false)
			if !testing.expect(t, len(lines) == 24, "native melee draws one box of 12 edges") { return }
			box := shared.krunker_melee_box(shared.krunker_shot_target(&player))
			want_min := shared.Vec3{box.origin.x - box.scale.x * 0.5, box.origin.y, box.origin.z - box.scale.z * 0.5}
			want_max := shared.Vec3{box.origin.x + box.scale.x * 0.5, box.origin.y + box.scale.y, box.origin.z + box.scale.z * 0.5}
			got_min, got_max := lines[0].position, lines[0].position
			for vertex in lines {
				got_min = linalg.min(got_min, vertex.position)
				got_max = linalg.max(got_max, vertex.position)
			}
			testing.expectf(t, linalg.length(got_min - want_min) < 1e-4 && linalg.length(got_max - want_max) < 1e-4,
				"crouch %v melee: drawn %v..%v, hit-tested %v..%v", crouch, got_min, got_max, want_min, want_max)
		}
	}

	hurtbox_center :: proc(box: shared.Krunker_Hurtbox) -> shared.Vec3 {
		return (box.transform * shared.Vec4{0, 0, 0, 1}).xyz
	}

	hurtbox_size :: proc(box: shared.Krunker_Hurtbox) -> shared.Vec3 {
		m := box.transform
		return {linalg.length(m[0].xyz), linalg.length(m[1].xyz), linalg.length(m[2].xyz)}
	}

	near3 :: proc(a, b: shared.Vec3, tolerance: f32 = 1e-3) -> bool { return linalg.length(a - b) <= tolerance }

	@(test)
	krunker_hurtboxes_follow_krunker_rig :: proc(t: ^testing.T) {
		weapon := shared.WEAPON_AK47
		boxes: [shared.KRUNKER_HURTBOX_MAX]shared.Krunker_Hurtbox
		pose := shared.Krunker_Hurtbox_Pose{position = {0, 0, 0}, weapon = &weapon}
		count := shared.krunker_player_hurtboxes(pose, &boxes)
		testing.expect(t, count == 10, "standing: head, torso, 3 boxes per arm, 2 legs")
		testing.expect(t, boxes[0].part == .HEAD && near3(hurtbox_center(boxes[0]), {0, 10, 0}) && near3(hurtbox_size(boxes[0]), {2, 2, 2}),
			"head: a 2-unit cube from 9 to 11")
		testing.expect(t, boxes[1].part == .TORSO && near3(hurtbox_center(boxes[1]), {0, 6.6, 0}) && near3(hurtbox_size(boxes[1]), {2.6, 4.8, 1.3}),
			"torso: chestWidth x 4.8 x chestScale from legHeight to 9")
		legs := 0
		for box in boxes[:count] {
			if box.part == .LEG {
				legs += 1
				c := hurtbox_center(box)
				testing.expect(t, abs(abs(c.x) - 0.65) < 1e-3 && abs(c.y - 2.1) < 1e-3 && near3(hurtbox_size(box), {1.3, 4.2, 1.3}), "standing legs hang from the hips")
			}
			if box.part == .ARM {
				c := hurtbox_center(box)
				testing.expectf(t, c.z < 0 && c.y > 6 && c.y < 10, "arms reach forward (-z) at chest height, got %v", c)
			}
		}
		testing.expect(t, legs == 2)

		pose.crouch = 1
		count = shared.krunker_player_hurtboxes(pose, &boxes)
		testing.expect(t, count == 14, "crouched: bent legs are 3 boxes each")
		testing.expect(t, near3(hurtbox_center(boxes[0]), {0, 7, 0}), "crouching drops the head by crouchDst")

		pose.crouch, pose.moving = 0, true
		shared.krunker_player_hurtboxes(pose, &boxes)
		testing.expect(t, near3(hurtbox_size(boxes[0]), {4, 4, 4}), "moving targets get 1 unit of padding per side")

		pose.moving, pose.pitch = false, -0.6
		shared.krunker_player_hurtboxes(pose, &boxes)
		head := hurtbox_center(boxes[0])
		testing.expect(t, head.z < -1 && head.y < 10, "looking down tilts the upper body (yD * 0.5) forward")

		pose.pitch, pose.yaw, pose.position = 0, math.PI / 2, {5, 2, 7}
		shared.krunker_player_hurtboxes(pose, &boxes)
		testing.expect(t, near3(hurtbox_center(boxes[0]), {5, 12, 7}), "the rig follows the position")
	}

	// Krunker's world-space complexHitboxes for fixed pose inputs, computed
	// independently from game.js (cH, a1e, r1e and the head/torso builders) in
	// three.js conventions: Object3D order T * R(XYZ) * S, OBB = geometry box,
	// halfSize + 1 while moving, then matrixWorld. Every box is checked: its
	// centre (getGeometryCenterWorldPosition), size and x/y axes. Box order:
	// head, torso, standing legs (right, left), crouched legs (right upper,
	// connector, lower, then left), with the inactive set flagged.
	@(test)
	krunker_hurtboxes_reproduce_krunker_world_boxes :: proc(t: ^testing.T) {
		Expected_Box :: struct { center, size, x_axis, y_axis: shared.Vec3 }
		Case :: struct { name: string, pose: shared.Krunker_Hurtbox_Pose, boxes: [10]Expected_Box }
		cases := [?]Case{
			{"standing", {}, {
				{{0.00000, 10.00000, 0.00000}, {2.00000, 2.00000, 2.00000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{0.00000, 6.60000, 0.00000}, {2.60000, 4.80000, 1.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{0.65000, 2.10000, 0.00000}, {1.30000, 4.20000, 1.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{-0.65000, 2.10000, 0.00000}, {1.30000, 4.20000, 1.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{1.12738, 1.59376, -0.92915}, {1.30000, 2.10000, 1.30000}, {0.86603, 0.28232, 0.41267}, {-0.45465, 0.10118, 0.88491}},
				{{1.60476, 1.48752, -1.85830}, {1.30000, 0.88613, 0.95120}, {0.86603, 0.28232, 0.41267}, {-0.47449, 0.72430, 0.50025}},
				{{1.85646, 0.48085, -1.69781}, {1.30000, 2.10000, 1.30000}, {0.86603, 0.28232, 0.41267}, {-0.23971, 0.95874, -0.15285}},
				{{-1.01537, 1.56257, -0.97474}, {1.30000, 2.10000, 1.30000}, {0.92388, -0.21608, -0.31584}, {0.34797, 0.13088, 0.92832}},
				{{-1.38074, 1.42514, -1.94948}, {1.30000, 0.88613, 0.95120}, {0.92388, -0.21608, -0.31584}, {0.36316, 0.75530, 0.54557}},
				{{-1.57339, 0.40202, -1.81303}, {1.30000, 2.10000, 1.30000}, {0.92388, -0.21608, -0.31584}, {0.18347, 0.97440, -0.12995}},
			}},
			{"crouched", {crouch = 1}, {
				{{0.00000, 7.00000, 0.00000}, {2.00000, 2.00000, 2.00000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{0.00000, 3.60000, 0.00000}, {2.60000, 4.80000, 1.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{0.65000, 2.10000, 0.00000}, {1.30000, 4.20000, 1.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{-0.65000, 2.10000, 0.00000}, {1.30000, 4.20000, 1.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{1.12738, 1.59376, -0.92915}, {1.30000, 2.10000, 1.30000}, {0.86603, 0.28232, 0.41267}, {-0.45465, 0.10118, 0.88491}},
				{{1.60476, 1.48752, -1.85830}, {1.30000, 0.88613, 0.95120}, {0.86603, 0.28232, 0.41267}, {-0.47449, 0.72430, 0.50025}},
				{{1.85646, 0.48085, -1.69781}, {1.30000, 2.10000, 1.30000}, {0.86603, 0.28232, 0.41267}, {-0.23971, 0.95874, -0.15285}},
				{{-1.01537, 1.56257, -0.97474}, {1.30000, 2.10000, 1.30000}, {0.92388, -0.21608, -0.31584}, {0.34797, 0.13088, 0.92832}},
				{{-1.38074, 1.42514, -1.94948}, {1.30000, 0.88613, 0.95120}, {0.92388, -0.21608, -0.31584}, {0.36316, 0.75530, 0.54557}},
				{{-1.57339, 0.40202, -1.81303}, {1.30000, 2.10000, 1.30000}, {0.92388, -0.21608, -0.31584}, {0.18347, 0.97440, -0.12995}},
			}},
			{"pitch_up", {pitch = 1.5}, {
				{{0.00000, 8.44380, 3.95350}, {2.00000, 2.00000, 2.00000}, {1.00000, 0.00000, 0.00000}, {0.00000, 0.73169, 0.68164}},
				{{0.00000, 5.95605, 1.63593}, {2.60000, 4.80000, 1.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 0.73169, 0.68164}},
				{{0.65000, 2.10000, 0.00000}, {1.30000, 4.20000, 1.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{-0.65000, 2.10000, 0.00000}, {1.30000, 4.20000, 1.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{1.12738, 1.59376, -0.92915}, {1.30000, 2.10000, 1.30000}, {0.86603, 0.28232, 0.41267}, {-0.45465, 0.10118, 0.88491}},
				{{1.60476, 1.48752, -1.85830}, {1.30000, 0.88613, 0.95120}, {0.86603, 0.28232, 0.41267}, {-0.47449, 0.72430, 0.50025}},
				{{1.85646, 0.48085, -1.69781}, {1.30000, 2.10000, 1.30000}, {0.86603, 0.28232, 0.41267}, {-0.23971, 0.95874, -0.15285}},
				{{-1.01537, 1.56257, -0.97474}, {1.30000, 2.10000, 1.30000}, {0.92388, -0.21608, -0.31584}, {0.34797, 0.13088, 0.92832}},
				{{-1.38074, 1.42514, -1.94948}, {1.30000, 0.88613, 0.95120}, {0.92388, -0.21608, -0.31584}, {0.36316, 0.75530, 0.54557}},
				{{-1.57339, 0.40202, -1.81303}, {1.30000, 2.10000, 1.30000}, {0.92388, -0.21608, -0.31584}, {0.18347, 0.97440, -0.12995}},
			}},
			{"pitch_down", {pitch = -1.5}, {
				{{0.00000, 8.44380, -3.95350}, {2.00000, 2.00000, 2.00000}, {1.00000, 0.00000, 0.00000}, {0.00000, 0.73169, -0.68164}},
				{{0.00000, 5.95605, -1.63593}, {2.60000, 4.80000, 1.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 0.73169, -0.68164}},
				{{0.65000, 2.10000, 0.00000}, {1.30000, 4.20000, 1.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{-0.65000, 2.10000, 0.00000}, {1.30000, 4.20000, 1.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{1.12738, 1.59376, -0.92915}, {1.30000, 2.10000, 1.30000}, {0.86603, 0.28232, 0.41267}, {-0.45465, 0.10118, 0.88491}},
				{{1.60476, 1.48752, -1.85830}, {1.30000, 0.88613, 0.95120}, {0.86603, 0.28232, 0.41267}, {-0.47449, 0.72430, 0.50025}},
				{{1.85646, 0.48085, -1.69781}, {1.30000, 2.10000, 1.30000}, {0.86603, 0.28232, 0.41267}, {-0.23971, 0.95874, -0.15285}},
				{{-1.01537, 1.56257, -0.97474}, {1.30000, 2.10000, 1.30000}, {0.92388, -0.21608, -0.31584}, {0.34797, 0.13088, 0.92832}},
				{{-1.38074, 1.42514, -1.94948}, {1.30000, 0.88613, 0.95120}, {0.92388, -0.21608, -0.31584}, {0.36316, 0.75530, 0.54557}},
				{{-1.57339, 0.40202, -1.81303}, {1.30000, 2.10000, 1.30000}, {0.92388, -0.21608, -0.31584}, {0.18347, 0.97440, -0.12995}},
			}},
			{"moving", {moving = true}, {
				{{0.00000, 10.00000, 0.00000}, {4.00000, 4.00000, 4.00000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{0.00000, 6.60000, 0.00000}, {4.60000, 6.80000, 3.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{0.65000, 2.10000, 0.00000}, {3.30000, 6.20000, 3.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{-0.65000, 2.10000, 0.00000}, {3.30000, 6.20000, 3.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{1.12738, 1.59376, -0.92915}, {3.30000, 4.10000, 3.30000}, {0.86603, 0.28232, 0.41267}, {-0.45465, 0.10118, 0.88491}},
				{{1.60476, 1.48752, -1.85830}, {3.30000, 2.88613, 2.95120}, {0.86603, 0.28232, 0.41267}, {-0.47449, 0.72430, 0.50025}},
				{{1.85646, 0.48085, -1.69781}, {3.30000, 4.10000, 3.30000}, {0.86603, 0.28232, 0.41267}, {-0.23971, 0.95874, -0.15285}},
				{{-1.01537, 1.56257, -0.97474}, {3.30000, 4.10000, 3.30000}, {0.92388, -0.21608, -0.31584}, {0.34797, 0.13088, 0.92832}},
				{{-1.38074, 1.42514, -1.94948}, {3.30000, 2.88613, 2.95120}, {0.92388, -0.21608, -0.31584}, {0.36316, 0.75530, 0.54557}},
				{{-1.57339, 0.40202, -1.81303}, {3.30000, 4.10000, 3.30000}, {0.92388, -0.21608, -0.31584}, {0.18347, 0.97440, -0.12995}},
			}},
			{"big_head", {head_mlt = 2}, {
				{{0.00000, 11.00000, 0.00000}, {4.00000, 4.00000, 4.00000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{0.00000, 6.60000, 0.00000}, {2.60000, 4.80000, 1.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{0.65000, 2.10000, 0.00000}, {1.30000, 4.20000, 1.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{-0.65000, 2.10000, 0.00000}, {1.30000, 4.20000, 1.30000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{1.12738, 1.59376, -0.92915}, {1.30000, 2.10000, 1.30000}, {0.86603, 0.28232, 0.41267}, {-0.45465, 0.10118, 0.88491}},
				{{1.60476, 1.48752, -1.85830}, {1.30000, 0.88613, 0.95120}, {0.86603, 0.28232, 0.41267}, {-0.47449, 0.72430, 0.50025}},
				{{1.85646, 0.48085, -1.69781}, {1.30000, 2.10000, 1.30000}, {0.86603, 0.28232, 0.41267}, {-0.23971, 0.95874, -0.15285}},
				{{-1.01537, 1.56257, -0.97474}, {1.30000, 2.10000, 1.30000}, {0.92388, -0.21608, -0.31584}, {0.34797, 0.13088, 0.92832}},
				{{-1.38074, 1.42514, -1.94948}, {1.30000, 0.88613, 0.95120}, {0.92388, -0.21608, -0.31584}, {0.36316, 0.75530, 0.54557}},
				{{-1.57339, 0.40202, -1.81303}, {1.30000, 2.10000, 1.30000}, {0.92388, -0.21608, -0.31584}, {0.18347, 0.97440, -0.12995}},
			}},
			{"hurtbox_scale", {hurtbox_scale = 1.5}, {
				{{0.00000, 10.00000, 0.00000}, {3.00000, 3.00000, 3.00000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{0.00000, 6.60000, 0.00000}, {3.90000, 7.20000, 1.95000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{0.65000, 2.10000, 0.00000}, {1.95000, 6.30000, 1.95000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{-0.65000, 2.10000, 0.00000}, {1.95000, 6.30000, 1.95000}, {1.00000, 0.00000, 0.00000}, {0.00000, 1.00000, 0.00000}},
				{{1.12738, 1.59376, -0.92915}, {1.95000, 3.15000, 1.95000}, {0.86603, 0.28232, 0.41267}, {-0.45465, 0.10118, 0.88491}},
				{{1.60476, 1.48752, -1.85830}, {1.95000, 1.32920, 1.42679}, {0.86603, 0.28232, 0.41267}, {-0.47449, 0.72430, 0.50025}},
				{{1.85646, 0.48085, -1.69781}, {1.95000, 3.15000, 1.95000}, {0.86603, 0.28232, 0.41267}, {-0.23971, 0.95874, -0.15285}},
				{{-1.01537, 1.56257, -0.97474}, {1.95000, 3.15000, 1.95000}, {0.92388, -0.21608, -0.31584}, {0.34797, 0.13088, 0.92832}},
				{{-1.38074, 1.42514, -1.94948}, {1.95000, 1.32920, 1.42679}, {0.92388, -0.21608, -0.31584}, {0.36316, 0.75530, 0.54557}},
				{{-1.57339, 0.40202, -1.81303}, {1.95000, 3.15000, 1.95000}, {0.92388, -0.21608, -0.31584}, {0.18347, 0.97440, -0.12995}},
			}},
			{"stride_yaw", {position = {5, 2, -7}, yaw = math.PI / 2, step_val = 1}, {
				{{5.00000, 12.37866, -7.00000}, {2.00000, 2.00000, 2.00000}, {0.12589, 0.00000, -0.99204}, {0.00000, 1.00000, 0.00000}},
				{{5.00000, 8.97866, -7.00000}, {2.60000, 4.80000, 1.30000}, {0.12589, 0.00000, -0.99204}, {0.00000, 1.00000, 0.00000}},
				{{6.20252, 4.80840, -7.50262}, {1.30000, 4.20000, 1.30000}, {0.12589, 0.00000, -0.99204}, {-0.53366, 0.84298, -0.06772}},
				{{3.79748, 4.80840, -6.49738}, {1.30000, 4.20000, 1.30000}, {0.12589, 0.00000, -0.99204}, {0.53366, 0.84298, 0.06772}},
				{{4.42159, 3.48928, -8.20982}, {1.30000, 2.10000, 1.30000}, {0.30346, 0.45998, -0.83446}, {0.62879, 0.56132, 0.53809}},
				{{3.76136, 2.89989, -8.77481}, {1.30000, 0.88613, 0.95120}, {0.30346, 0.45998, -0.83446}, {-0.02791, 0.87968, 0.47476}},
				{{4.46448, 2.13761, -8.93930}, {1.30000, 2.10000, 1.30000}, {0.30346, 0.45998, -0.83446}, {-0.66964, 0.72598, 0.15666}},
				{{3.98369, 4.48716, -6.10545}, {1.30000, 2.10000, 1.30000}, {-0.26314, -0.01225, -0.96468}, {0.88999, -0.38905, -0.23783}},
				{{3.04920, 4.89567, -5.85573}, {1.30000, 0.88613, 0.95120}, {-0.26314, -0.01225, -0.96468}, {0.90503, 0.34322, -0.25123}},
				{{2.59306, 3.95979, -5.71943}, {1.30000, 2.10000, 1.30000}, {-0.26314, -0.01225, -0.96468}, {0.43442, 0.89131, -0.12981}},
			}},
			{"crouch_stride", {step_val = 1, crouch = 1}, {
				{{0.00000, 7.37866, 0.00000}, {2.00000, 2.00000, 2.00000}, {0.99204, 0.00000, 0.12589}, {0.00000, 1.00000, 0.00000}},
				{{0.00000, 3.97866, 0.00000}, {2.60000, 4.80000, 1.30000}, {0.99204, 0.00000, 0.12589}, {0.00000, 1.00000, 0.00000}},
				{{0.57076, 2.56278, 0.66555}, {1.30000, 4.20000, 1.30000}, {0.99204, 0.00000, 0.12589}, {0.03527, 0.95994, -0.27797}},
				{{-0.57076, 2.56278, -0.66555}, {1.30000, 4.20000, 1.30000}, {0.99204, 0.00000, 0.12589}, {-0.03527, 0.95994, 0.27797}},
				{{1.22695, 1.71634, -0.71338}, {1.30000, 2.10000, 1.30000}, {0.81923, 0.38664, 0.42353}, {-0.55440, 0.34507, 0.75734}},
				{{1.80906, 1.35401, -1.50859}, {1.30000, 0.88613, 0.95120}, {0.81923, 0.38664, 0.42353}, {-0.50562, 0.83545, 0.21533}},
				{{2.00386, 0.43263, -1.04425}, {1.30000, 2.10000, 1.30000}, {0.81923, 0.38664, 0.42353}, {-0.18552, 0.87751, -0.44223}},
				{{-0.88466, 2.21985, -1.09427}, {1.30000, 2.10000, 1.30000}, {0.96232, -0.11893, -0.24454}, {0.22841, -0.13447, 0.96423}},
				{{-1.12448, 2.36105, -2.10672}, {1.30000, 0.88613, 0.95120}, {0.96232, -0.11893, -0.24454}, {0.26770, 0.57218, 0.77521}},
				{{-1.29599, 1.34068, -2.28542}, {1.30000, 2.10000, 1.30000}, {0.96232, -0.11893, -0.24454}, {0.16334, 0.97178, 0.17019}},
			}},
		}
		close :: proc(a, b: shared.Vec3) -> bool { return linalg.length(a - b) < 2e-4 }
		for c in cases {
			pose := c.pose
			pose.inactive_legs = true
			boxes: [shared.KRUNKER_HURTBOX_MAX]shared.Krunker_Hurtbox
			count := shared.krunker_player_hurtboxes(pose, &boxes)
			if !testing.expectf(t, count == 10, "%s: head, torso and both leg sets, got %d", c.name, count) { continue }
			for want, i in c.boxes {
				box := boxes[i]
				m := box.transform
				size := shared.Vec3{linalg.length(m[0].xyz), linalg.length(m[1].xyz), linalg.length(m[2].xyz)}
				center := shared.krunker_hurtbox_center(box)
				testing.expectf(t, close(center, want.center) && close(size, want.size) && close(linalg.normalize(m[0].xyz), want.x_axis) && close(linalg.normalize(m[1].xyz), want.y_axis),
					"%s box %d: centre %v size %v x %v y %v, want %v", c.name, i, center, size, linalg.normalize(m[0].xyz), linalg.normalize(m[1].xyz), want)
				part := i == 0 ? shared.Krunker_Hurtbox_Part.HEAD : i == 1 ? .TORSO : .LEG
				crouched_set := i >= 4
				testing.expectf(t, box.part == part && box.active == (i < 2 || crouched_set == (c.pose.crouch != 0)), "%s box %d: part %v active %v", c.name, i, box.part, box.active)
			}
			pose.inactive_legs = false
			testing.expect(t, shared.krunker_player_hurtboxes(pose, &boxes) == (c.pose.crouch != 0 ? 8 : 4), "the hit test only gets the active leg set")
		}
	}

	// cH lifts the arm holder by recoilAnimY * (recoilYM || 0.3) * animMult.
	@(test)
	krunker_hurtbox_arms_follow_recoil :: proc(t: ^testing.T) {
		weapon := shared.WEAPON_AK47
		pose := shared.Krunker_Hurtbox_Pose{weapon = &weapon}
		rest, kicked: [shared.KRUNKER_HURTBOX_MAX]shared.Krunker_Hurtbox
		count := shared.krunker_player_hurtboxes(pose, &rest)
		pose.recoil_anim_y = 0.5
		shared.krunker_player_hurtboxes(pose, &kicked)
		mlt := weapon.recoil_y_mlt != 0 ? weapon.recoil_y_mlt : 0.3
		lift := 0.5 * mlt * shared.GAME_CONSTANTS.anim_mlt
		for i in 0 ..< count {
			delta := shared.krunker_hurtbox_center(kicked[i]) - shared.krunker_hurtbox_center(rest[i])
			want := rest[i].part == .ARM ? shared.Vec3{0, lift, 0} : shared.Vec3{}
			testing.expectf(t, linalg.length(delta - want) < 1e-4, "box %d (%v) moved %v, want %v", i, rest[i].part, delta, want)
		}
	}

	debug_test_project :: proc(view_projection: shared.Mat4, point: shared.Vec3) -> (pixel: [2]int, ok: bool) {
		screen, visible := player_healthbar_project(view_projection, point, HITBOX_SHOT_W, HITBOX_SHOT_H)
		return {int(math.round(screen.x)), int(math.round(screen.y))}, visible
	}

	// Whether a pixel within `radius` of the screen point (top-left origin) matches.
	debug_test_pixel_near :: proc(pixels: []u8, at: [2]int, radius: int, match: proc(r, g, b: u8) -> bool) -> bool {
		for dy in -radius ..= radius {
			for dx in -radius ..= radius {
				x, y := at.x + dx, at.y + dy
				if x < 0 || y < 0 || x >= HITBOX_SHOT_W || y >= HITBOX_SHOT_H { continue }
				i := ((HITBOX_SHOT_H - 1 - y) * HITBOX_SHOT_W + x) * 3
				if match(pixels[i], pixels[i + 1], pixels[i + 2]) { return true }
			}
		}
		return false
	}

	debug_test_lit_pixels :: proc(pixels: []u8) -> (lit: int) {
		for i := 0; i < len(pixels); i += 3 { if pixels[i] > 60 || pixels[i + 1] > 60 || pixels[i + 2] > 60 { lit += 1 } }
		return
	}

	debug_test_read :: proc(pixels: []u8) {
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		ui_flush()
		gl.ReadPixels(0, 0, HITBOX_SHOT_W, HITBOX_SHOT_H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
	}

	debug_test_save :: proc(pixels: []u8, path: cstring) {
		os.make_directory("bin/debug_hitboxes")
		stbi.write_png(path, HITBOX_SHOT_W, HITBOX_SHOT_H, 3, &pixels[(HITBOX_SHOT_H - 1) * HITBOX_SHOT_W * 3], -HITBOX_SHOT_W * 3)
	}

	is_green :: proc(r, g, b: u8) -> bool { return g > 200 && r < 120 && b < 160 }
	is_yellow :: proc(r, g, b: u8) -> bool { return r > 200 && g > 180 && b < 100 }

	// A remote player 30 units in front of the camera: the wireframes land on
	// the screen where the hit-tested boxes project, the depth-tested pass is
	// hidden behind nearer depth while x-ray is not, and screenshots of both
	// hitbox models are written to bin/debug_hitboxes/.
	@(test)
	debug_hitboxes_render_at_projected_boxes :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init()), "GLFW initialization failed") do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(HITBOX_SHOT_W, HITBOX_SHOT_H, "Debug hitboxes", nil, nil)
		if !testing.expect(t, window != nil, "hidden OpenGL window failed") do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.Viewport(0, 0, HITBOX_SHOT_W, HITBOX_SHOT_H)

		client := Client{window = window, scene = scene_init(), fps_scene = scene_init(), viewport_width = HITBOX_SHOT_W, viewport_height = HITBOX_SHOT_H}
		g_client = &client
		defer { g_client = nil }
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		crate := shared.Object{active = true, collision_type = .BOX, position = {-13, 0, -32}, scale = {5, 9, 5}}
		zone := shared.Object{active = true, collision_type = .CYLINDER, no_shoot = true, position = {13, 0, -32}, scale = {7, 12, 7}}
		far_box := shared.Object{active = true, collision_type = .BOX, position = {0, 0, -400}, scale = {10, 10, 10}}
		map_inst := shared.Map{death_y = -1000}
		append(&map_inst.objects, &crate, &zone, &far_box)
		maps := []^shared.Map{&map_inst}
		shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, 0, true)
		defer {
			debug_render_fini(&client.debug_render)
			client_clear_players(&client)
			shared.game_destroy(&client.game)
			scene_fini(client.fps_scene)
			scene_fini(client.scene)
			resource_cache_fini()
		}

		me := shared.player_init(&client.game)
		shared.game_players_add(&client.game, me)
		shared.player_spawn(me, 0)
		me.uid, me.active, me.is_you, me.position = 1, true, true, {0, 0, 0}
		client.me = me
		remote := shared.player_init(&client.game)
		shared.game_players_add(&client.game, remote)
		shared.player_spawn(remote, 0)
		remote.uid, remote.active, remote.swap_timer = 2, true, 0
		remote.position, remote.last_position, remote.direction = {0, 0, -30}, {0, 0, -30}, {0, math.PI} // Facing the camera.

		camera := camera_init(math.PI / 2)
		camera.position = {0, 6, 0}
		camera_update_projection_matrix(&camera, f32(HITBOX_SHOT_W) / f32(HITBOX_SHOT_H))
		camera_update_world_inverse_matrix(&camera)
		client.camera = camera
		view_projection := camera.projection_matrix * camera.world_inverse_matrix
		dr := &client.debug_render
		pixels := make([]u8, HITBOX_SHOT_W * HITBOX_SHOT_H * 3)
		defer delete(pixels)

		// 1. Lines alone on black: edges at the projected hit-tested boxes.
		dr.player_hitboxes = true
		debug_render_build(&client, 0)
		player_lines: [dynamic]Debug_Line_Vertex
		defer delete(player_lines)
		debug_lines_player(&player_lines, remote, .KRODIN, .SHOT, false)
		testing.expect(t, len(dr.lines) == len(player_lines), "only the remote player is drawn (first-person you is not)")
		gl.ClearColor(0, 0, 0, 1)
		ui_flush()
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		testing.expect(t, debug_render_lines(dr, view_projection, true) == len(player_lines))
		testing.expect(t, gl.GetError() == gl.NO_ERROR, "wireframes must draw without OpenGL errors")
		debug_test_read(pixels)
		// The torso and head boxes the native shot test uses (standing still: unpadded).
		tested: [shared.KRUNKER_HURTBOX_MAX]shared.Krunker_Hurtbox
		shared.krunker_player_hurtboxes(shared.krunker_target_pose(remote), &tested)
		head, torso := tested[0], tested[1]
		at :: proc(box: shared.Krunker_Hurtbox, local: shared.Vec3) -> shared.Vec3 { return (box.transform * shared.Vec4{local.x, local.y, local.z, 1}).xyz }
		body_left_mid, ok1 := debug_test_project(view_projection, at(torso, {-0.5, 0, 0.5}))
		// Inside the head's face, above the arms and off its centre marker.
		body_center, ok2 := debug_test_project(view_projection, at(head, {0.3, 0.35, 0.5}))
		head_top_mid, ok3 := debug_test_project(view_projection, at(head, {0, 0.5, 0.5}))
		testing.expect(t, ok1 && ok2 && ok3, "the target is in front of the camera")
		testing.expectf(t, debug_test_pixel_near(pixels, body_left_mid, 1, is_green), "body edge must be drawn at its projected position %v", body_left_mid)
		testing.expectf(t, debug_test_pixel_near(pixels, head_top_mid, 1, is_yellow), "head edge must be drawn at its projected position %v", head_top_mid)
		black :: proc(r, g, b: u8) -> bool { return r < 20 && g < 20 && b < 20 }
		testing.expect(t, debug_test_pixel_near(pixels, body_center, 0, black), "boxes are wireframes, not filled")
		shifted := body_left_mid + {12, 0}
		testing.expect(t, !debug_test_pixel_near(pixels, shifted, 1, is_green), "no body edge where the box is not")

		// 2. Depth-tested lines hide behind nearer depth; x-ray shows through.
		gl.ClearDepth(0)
		ui_flush()
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		debug_render_lines(dr, view_projection, true)
		debug_test_read(pixels)
		testing.expect(t, debug_test_lit_pixels(pixels) == 0, "depth-tested wireframes must be hidden behind nearer geometry")
		debug_render_lines(dr, view_projection, false)
		debug_test_read(pixels)
		testing.expect(t, debug_test_lit_pixels(pixels) > 100, "x-ray wireframes must show through geometry")
		testing.expect(t, gl.IsEnabled(gl.DEPTH_TEST) && gl.GetError() == gl.NO_ERROR, "line drawing must restore depth testing")
		gl.ClearDepth(1)

		// 3. Screenshots over the real player model, with map collision (only
		// the two nearby objects) and a recorded shot ray.
		dr.map_collision, dr.shot_rays = true, true
		append(&client.game.impacts, shared.Bullet_Impact{origin = {9, 9.5, -8}, position = {0.4, 9.2, -27.5}, hit = true, kind = .Player, shooter_uid = 1})
		debug_render_record_impacts(&client, 0)
		clear(&client.game.impacts)
		testing.expect(t, dr.shot_count == 1, "the local player's shot is recorded")
		player_generate_meshes(remote, false)
		scene_add_player_mesh(client.scene, cast(^Player_Mesh)remote.mesh, int(remote.loadout_size))
		player_update_meshes(remote, false)
		debug_render_build(&client, 0)
		testing.expect(t, len(dr.lines) == len(player_lines) + 24 + (16*2 + 4)*2 + 2 + 6, "players, the two nearby map objects and the shot ray")
		shots := [2]cstring{"bin/debug_hitboxes/krodin_hitboxes.png", "bin/debug_hitboxes/krunker_hurtboxes.png"}
		for model, i in ([2]Debug_Hitbox_Model{.KRODIN, .KRUNKER}) {
			if model == .KRUNKER {
				clear(&dr.lines)
				debug_lines_player(&dr.lines, remote, .KRUNKER, .SHOT, false)
				debug_lines_map(&dr.lines, &client.game, camera.position, DEBUG_MAP_RANGE)
			}
			gl.ClearColor(0.55, 0.62, 0.7, 1)
			ui_flush()
			gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
			scene_render(client.scene, &camera, HITBOX_SHOT_W, HITBOX_SHOT_H)
			scene_err := gl.GetError()
			testing.expectf(t, scene_err == gl.NO_ERROR, "the world pass after a wireframe pass must draw without OpenGL errors (0x%x)", scene_err)
			debug_render_lines(dr, view_projection, true)
			err := gl.GetError()
			testing.expectf(t, err == gl.NO_ERROR, "wireframes over the scene must draw without OpenGL errors (0x%x)", err)
			debug_test_read(pixels)
			debug_test_save(pixels, shots[i])
		}
	}

	// The live drawing, posed the way the shot test is: two k snapshots per
	// pose, the remote drawn between them, Krunker's boxes solid at the size
	// the server tests, the other size dim, centre markers, and the rendered
	// model's part bounds (magenta). The strafing case reproduces the close
	// range video: a strafing target's server boxes are the +1 padded ones,
	// twice the head the model shows. Previews: bin/debug_hitboxes/pose_*.png.
	@(test)
	debug_krunker_hurtbox_poses_render :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init()), "GLFW initialization failed") do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(HITBOX_SHOT_W, HITBOX_SHOT_H, "Krunker hurtbox poses", nil, nil)
		if !testing.expect(t, window != nil, "hidden OpenGL window failed") do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.Viewport(0, 0, HITBOX_SHOT_W, HITBOX_SHOT_H)

		client := Client{window = window, scene = scene_init(), fps_scene = scene_init(), viewport_width = HITBOX_SHOT_W, viewport_height = HITBOX_SHOT_H}
		g_client = &client
		defer { g_client = nil }
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		map_inst := shared.Map{death_y = -1000}
		maps := []^shared.Map{&map_inst}
		shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, 0, false)
		defer {
			debug_render_fini(&client.debug_render)
			client_clear_players(&client)
			shared.game_destroy(&client.game)
			kproto.krunker_world_reset(&client.krunker_world)
			scene_fini(client.fps_scene)
			scene_fini(client.scene)
			resource_cache_fini()
		}
		me := shared.player_init(&client.game)
		shared.game_players_add(&client.game, me)
		shared.player_spawn(me, 0)
		me.uid, me.active, me.is_you, me.position = 1, true, true, {0, 0, 0}
		client.me = me
		remote := shared.player_init(&client.game)
		shared.game_players_add(&client.game, remote)
		shared.player_spawn(remote, 0)
		remote.uid, remote.active, remote.swap_timer = 2, true, 0
		player_generate_meshes(remote, false)
		scene_add_player_mesh(client.scene, cast(^Player_Mesh)remote.mesh, int(remote.loadout_size))

		camera := camera_init(math.PI / 2)
		camera.position = {0, 6, 0}
		camera_update_projection_matrix(&camera, f32(HITBOX_SHOT_W) / f32(HITBOX_SHOT_H))
		camera_update_world_inverse_matrix(&camera)
		view_projection := camera.projection_matrix * camera.world_inverse_matrix
		pixels := make([]u8, HITBOX_SHOT_W * HITBOX_SHOT_H * 3)
		defer delete(pixels)
		lines := &client.debug_render.lines

		Pose_Case :: struct {
			name:      string,
			crouch:    f64,
			pitch_deg: f64,
			head_mlt:  f32,
			strafe:    bool, // Moves 2 units sideways between the snapshots.
			padding:   Debug_Hurtbox_Padding,
			file:      cstring,
		}
		cases := [?]Pose_Case{
			{"standing", 0, 0, 1, false, .AUTO, "bin/debug_hitboxes/pose_standing.png"},
			{"crouched", 1, 0, 1, false, .AUTO, "bin/debug_hitboxes/pose_crouched.png"},
			{"pitch up", 0, 86, 1, false, .AUTO, "bin/debug_hitboxes/pose_pitch_up.png"},
			{"pitch down", 0, -86, 1, false, .AUTO, "bin/debug_hitboxes/pose_pitch_down.png"},
			{"big head", 0, 0, 2, false, .AUTO, "bin/debug_hitboxes/pose_big_head.png"},
			{"strafing", 0, 0, 1, true, .AUTO, "bin/debug_hitboxes/pose_strafing_padded.png"},
			{"strafing unpadded", 0, 0, 1, true, .UNPADDED, "bin/debug_hitboxes/pose_strafing_unpadded.png"},
		}
		padded_head_left, unpadded_head_left: f32
		for c in cases {
			kproto.krunker_world_reset(&client.krunker_world)
			client.krunker_world.local_sid = 1
			// Facing the camera (yaw 180 degrees) 14 units away.
			record := []kproto.Krunker_Msgpack_Value{i64(2), f64(-1), i64(0), i64(-14), i64(180), f64(c.pitch_deg), f64(0), true, f64(c.crouch), i64(0), i64(1), kproto.Krunker_Msgpack_Nil{}, i64(20)}
			packet := []kproto.Krunker_Msgpack_Value{"k", record, i64(10), i64(1000)}
			client.krunker_world.received_at = 1
			kproto.krunker_world_apply_packet(&client.krunker_world, packet)
			record[1], packet[3], client.krunker_world.received_at = f64(c.strafe ? 1 : -1), i64(1100), 1.1
			kproto.krunker_world_apply_packet(&client.krunker_world, packet)
			client.krunker_world.players[0].head_mlt = c.head_mlt
			krunker_client_interpolate_remotes(&client, 1.15, 0)
			// Fixed stride phase (the jump from the spawn point is not a step).
			remote.step_val, remote.step_chase = 0, 0
			remote.crouch_val = f32(c.crouch)
			shared.player_update_height(remote)
			player_update_meshes(remote, false)

			gl.ClearColor(0.55, 0.62, 0.7, 1)
			ui_flush()
			gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
			scene_render(client.scene, &camera, HITBOX_SHOT_W, HITBOX_SHOT_H)

			pose, server_moving := debug_krunker_hurtbox_pose(&client, remote)
			testing.expectf(t, server_moving == c.strafe, "%s: the server pads a target that moved between snapshots", c.name)
			testing.expectf(t, pose.head_mlt == c.head_mlt && pose.crouch == f32(c.crouch), "%s: headMlt and the newest snapshot's cV feed the boxes", c.name)
			padded := c.padding == .AUTO ? server_moving : c.padding == .PADDED
			clear(lines)
			debug_lines_model_bounds(lines, remote)
			debug_lines_krunker_pose(lines, pose, padded)
			debug_render_lines(&client.debug_render, view_projection, false)
			err := gl.GetError()
			testing.expectf(t, err == gl.NO_ERROR, "%s: pose preview must draw without OpenGL errors (0x%x)", c.name, err)
			debug_test_read(pixels)
			debug_test_save(pixels, c.file)

			pose.moving = padded
			boxes: [shared.KRUNKER_HURTBOX_MAX]shared.Krunker_Hurtbox
			shared.krunker_player_hurtboxes(pose, &boxes)
			head := boxes[0]
			centre, visible := debug_test_project(view_projection, shared.krunker_hurtbox_center(head))
			testing.expectf(t, visible && debug_test_pixel_near(pixels, centre, 1, is_yellow), "%s: the head's centre marker is drawn at %v", c.name, centre)
			// The head's left edge at its vertical middle, on screen.
			left_world := (head.transform * shared.Vec4{-0.5, 0, -0.5, 1}).xyz
			left, _ := debug_test_project(view_projection, left_world)
			testing.expectf(t, debug_test_pixel_near(pixels, left, 2, is_yellow), "%s: the solid head box edge is drawn at %v", c.name, left)
			if c.name == "strafing" { padded_head_left = f32(left.x) }
			if c.name == "strafing unpadded" { unpadded_head_left = f32(left.x) }
			if c.name == "big head" {
				testing.expectf(t, abs(shared.krunker_hurtbox_center(head).y - 11) < 1e-3, "headMlt 2 grows the head upward from the neck, centre %v", shared.krunker_hurtbox_center(head))
			}
		}
		// Padded: the head is 4 units wide instead of 2 around the same centre,
		// so its side edge sits about one unit (~13 px here) further out.
		testing.expectf(t, abs(unpadded_head_left - padded_head_left) > 10, "the padded head reaches further out (padded %v, unpadded %v)", padded_head_left, unpadded_head_left)
	}

	// A live remote seen side-on, mid-stride. Its stride phase now comes from
	// the server's stepVal (k record value 6), so the drawn complexHitboxes
	// (Krunker's server boxes) and the model's legs follow the server's swing
	// instead of a locally re-derived phase. Writes before/after previews to
	// bin/debug_hitboxes/krunker_remote_stride_*.png.
	@(test)
	krunker_remote_stride_render_follows_server_step :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init()), "GLFW initialization failed") do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(HITBOX_SHOT_W, HITBOX_SHOT_H, "Remote stride", nil, nil)
		if !testing.expect(t, window != nil, "hidden OpenGL window failed") do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.Viewport(0, 0, HITBOX_SHOT_W, HITBOX_SHOT_H)

		client := Client{window = window, scene = scene_init(), fps_scene = scene_init(), viewport_width = HITBOX_SHOT_W, viewport_height = HITBOX_SHOT_H}
		g_client = &client
		defer { g_client = nil }
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		map_inst := shared.Map{death_y = -1000}
		maps := []^shared.Map{&map_inst}
		shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, 0, false)
		defer {
			debug_render_fini(&client.debug_render)
			client_clear_players(&client)
			shared.game_destroy(&client.game)
			kproto.krunker_world_reset(&client.krunker_world)
			scene_fini(client.fps_scene)
			scene_fini(client.scene)
			resource_cache_fini()
		}
		me := shared.player_init(&client.game)
		shared.game_players_add(&client.game, me)
		shared.player_spawn(me, 0)
		me.uid, me.active, me.is_you, me.position = 1, true, true, {0, 0, 0}
		client.me = me
		client.krunker_world.local_sid = 1
		remote := shared.player_init(&client.game)
		shared.game_players_add(&client.game, remote)
		shared.player_spawn(remote, 0)
		remote.uid, remote.active, remote.swap_timer = 2, true, 0
		player_generate_meshes(remote, false)
		scene_add_player_mesh(client.scene, cast(^Player_Mesh)remote.mesh, int(remote.loadout_size))

		camera := camera_init(math.PI / 2)
		camera.position = {0, 6, 0}
		camera_update_projection_matrix(&camera, f32(HITBOX_SHOT_W) / f32(HITBOX_SHOT_H))
		camera_update_world_inverse_matrix(&camera)
		client.camera = camera
		view_projection := camera.projection_matrix * camera.world_inverse_matrix
		pixels := make([]u8, HITBOX_SHOT_W * HITBOX_SHOT_H * 3)
		defer delete(pixels)
		is_red :: proc(r, g, b: u8) -> bool { return r > 200 && g < 120 && b < 120 }

		// Two k packets 0.1 s apart, side-on (yaw 90 degrees), with the
		// server's stepVal; the remote is drawn half way between them.
		leg_corner: [2][2]int
		names := [2]cstring{"bin/debug_hitboxes/krunker_remote_stride_step0.png", "bin/debug_hitboxes/krunker_remote_stride_server_step.png"}
		for step, i in ([2]f64{0, 1.2}) {
			kproto.krunker_world_reset(&client.krunker_world)
			client.krunker_world.local_sid = 1
			record := []kproto.Krunker_Msgpack_Value{i64(2), i64(0), i64(0), i64(-24), i64(90), i64(0), f64(step), true, i64(0), i64(0), i64(1), kproto.Krunker_Msgpack_Nil{}, i64(20)}
			packet := []kproto.Krunker_Msgpack_Value{"k", record, i64(10), i64(1000)}
			client.krunker_world.received_at = 1
			kproto.krunker_world_apply_packet(&client.krunker_world, packet)
			packet[3], client.krunker_world.received_at = i64(1100), 1.1
			kproto.krunker_world_apply_packet(&client.krunker_world, packet)
			krunker_client_interpolate_remotes(&client, 1.15, 0)
			testing.expectf(t, abs(remote.step_val-f32(step)) < 1e-5, "the remote takes the server's stepVal %v, got %v", step, remote.step_val)
			remote.step_chase = remote.step_val
			player_update_meshes(remote, false)

			boxes: [shared.KRUNKER_HURTBOX_MAX]shared.Krunker_Hurtbox
			count := shared.krunker_player_hurtboxes(shared.krunker_hurtbox_pose(remote, false), &boxes)
			// The lowest corner of the first leg box: the foot, which the swing moves.
			lowest := shared.Vec3{0, 1e9, 0}
			for box in boxes[:count] {
				if box.part != .LEG { continue }
				for corner in 0 ..< 8 {
					local := shared.Vec4{corner & 1 == 0 ? -0.5 : 0.5, corner & 2 == 0 ? -0.5 : 0.5, corner & 4 == 0 ? -0.5 : 0.5, 1}
					world := box.transform * local
					if world.y < lowest.y { lowest = world.xyz }
				}
				break
			}
			pixel, visible := debug_test_project(view_projection, lowest)
			testing.expect(t, visible, "the stride is in view")
			leg_corner[i] = pixel

			clear(&client.debug_render.lines)
			debug_lines_player(&client.debug_render.lines, remote, .KRUNKER, .SHOT, false)
			gl.ClearColor(0.55, 0.62, 0.7, 1)
			ui_flush()
			gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
			scene_render(client.scene, &camera, HITBOX_SHOT_W, HITBOX_SHOT_H)
			debug_render_lines(&client.debug_render, view_projection, false)
			err := gl.GetError()
			testing.expectf(t, err == gl.NO_ERROR, "stride preview must draw without OpenGL errors (0x%x)", err)
			debug_test_read(pixels)
			testing.expectf(t, debug_test_pixel_near(pixels, pixel, 2, is_red), "the leg hurtbox is drawn at its projected foot %v", pixel)
			debug_test_save(pixels, names[i])
		}
		moved := leg_corner[1] - leg_corner[0]
		testing.expectf(t, abs(moved.x) + abs(moved.y) >= 6, "the server's stride swings the drawn leg box (moved %v px)", moved)
	}
}
