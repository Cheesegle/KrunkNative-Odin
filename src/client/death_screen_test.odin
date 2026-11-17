package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import shared "../shared"
import kproto "../krunker"

when ODIN_TEST {
	// Offline practice with you (uid 1, Hunter) and a killer (uid 2, Rocketeer)
	// in front of you. The pointer is locked, as during play.
	@(private = "file")
	Death_Fixture :: struct {
		client: ^Client,
		mode: shared.Game_Mode,
		me, killer: ^shared.Player,
		me_loadout, killer_loadout: [2]i32,
	}

	@(private = "file")
	death_fixture :: proc() -> ^Death_Fixture {
		f := new(Death_Fixture)
		f.client = new(Client)
		client := f.client
		client.game.mode = &f.mode
		client.game.config = shared.DEFAULT_GAME_CONFIG
		client.game.weapons = shared.g_weapons()
		client.game.classes = shared.CLASSES_LIST[:]
		client.game.is_local, client.game.ready = true, true
		client.game.match.phase = .LIVE
		client.local_practice, client.in_game = true, true
		client.mouse_state.locked = true
		f.me_loadout, f.killer_loadout = {0, 2}, {1, 2}
		f.me, f.killer = new(shared.Player), new(shared.Player)
		f.me^ = {uid = 1, is_you = true, active = true, health = 100, max_health = 100, team = 1, class_index = 1, game = &client.game, direction = {0.1, 0.3}, loadout = f.me_loadout[:]}
		f.killer^ = {uid = 2, active = true, health = 64, max_health = 100, team = 2, class_index = 0, game = &client.game, position = {0, 0, -60}, interpolate = true, loadout = f.killer_loadout[:]}
		for p in ([]^shared.Player{f.me, f.killer}) { shared.player_update_height(p) }
		append(&client.game.players, f.me, f.killer)
		client.me = f.me
		client.camera.position = {0, f.me.height - shared.GAME_CONSTANTS.camera_height, 0}
		client.camera.rotation = {f.me.direction.x, f.me.direction.y, 0}
		return f
	}

	@(private = "file")
	death_fixture_free :: proc(f: ^Death_Fixture) {
		delete(f.client.game.players)
		delete(f.client.game.kill_events)
		free(f.me); free(f.killer)
		free(f.client)
		free(f)
	}

	// client_tick's order: kill cam, death screen, then the killfeed drain.
	@(private = "file")
	death_frame :: proc(client: ^Client, now: f64) {
		client_kill_cam_update(client, 1.0 / 60)
		client_death_screen_update(client, now)
		clear(&client.game.kill_events)
	}

	@(private = "file")
	death_near :: proc(a, b: f32, tolerance: f32 = 1e-3) -> bool { return abs(a - b) <= tolerance }

	@(test)
	death_screen_timeline_follows_the_life :: proc(t: ^testing.T) {
		f := death_fixture(); defer death_fixture_free(f)
		client := f.client
		client.game.config.kill_cams = false
		death_frame(client, 9)
		ds := &client.death_screen
		testing.expect(t, !ds.active && ds.has_ended && ds.ended_at == 9 && ds.ended_after == 0, "the first life fades in; no death card")
		testing.expect(t, ds.was_active && ds.spawned_at == 9)
		f.me.kills, f.me.score = 2, 200 // during this life

		testing.expect(t, shared.player_apply_damage(f.me, f.killer, 500, 1, true))
		death_frame(client, 10)
		testing.expect(t, ds.active && ds.died_at == 10 && ds.filled, "the death starts the screen and the same frame's kill fills it")
		testing.expect(t, ds.has_killer && ds.killer_uid == 2 && kill_feed_name_text(&ds.killer.name) == "Player 2" && kill_feed_name_text(&ds.you.name) == "You")
		testing.expect(t, ds.killer.weapon_id == 1 && ds.headshot && ds.you.weapon_id == 0, "the killing weapon and your equipped weapon")
		testing.expect(t, ds.killer.class_index == 0 && ds.you.class_index == 1)
		testing.expect(t, ds.killer.kills == 1 && ds.you.kills == 0, "killedBy counts")
		testing.expect(t, death_near(ds.killer_health, 64) && ds.killer_max_health == 100, "the killer's health left")
		testing.expect(t, ds.stat_count == 3 && ds.stats[0].label == "Time Survived" && death_text_string(&ds.stats[0].value) == "1s")
		testing.expect(t, death_text_string(&ds.stats[1].value) == "2" && death_text_string(&ds.stats[2].value) == "200")

		// The lobby tick no longer releases the pointer for a death.
		testing.expect(t, client_death_screen_begin(client, 10.1) && client.mouse_state.locked, "Krunker keeps the pointer through deathDelay")
		testing.expect(t, client_death_screen_hides_hud(client))

		// Card timing.
		death_frame(client, 10 + DEATH_SCREEN_DELAY - 0.05)
		testing.expect(t, !ds.popped, "no card before the delay")
		death_frame(client, 10 + DEATH_SCREEN_DELAY)
		testing.expect(t, ds.popped, "the card pops in at the delay")

		// Krodin's death camera: rolls and sinks without a kill cam.
		death_frame(client, 10 + DEATH_SCREEN_TILT_TIME + 0.1)
		testing.expect(t, death_near(client.camera.rotation.z, DEATH_SCREEN_TILT_ROLL), "rolled")
		testing.expect(t, death_near(client.camera.position.y, f.me.height - shared.GAME_CONSTANTS.camera_height - DEATH_SCREEN_TILT_DROP), "sunk")

		// The offline authority respawns after respawn_delay; the client asks
		// only as a fallback, once.
		testing.expect(t, !client_death_screen_allows_respawn(client, 12.9))
		testing.expect(t, !client_death_screen_allows_respawn(client, 10 + 3 + DEATH_SCREEN_AUTO_MARGIN - 0.01))
		testing.expect(t, client_death_screen_allows_respawn(client, 10 + 3 + DEATH_SCREEN_AUTO_MARGIN))
		testing.expect(t, !client_death_screen_allows_respawn(client, 14.5), "asked once per death")
		remaining, total := client_death_screen_respawn(client, 11.5)
		testing.expect(t, death_near(remaining, 1.5) && death_near(total, 3))

		// The respawn: the card leaves, input is free and the roll is undone.
		f.me.active = true
		death_frame(client, 13)
		testing.expect(t, !ds.active && ds.has_ended && ds.ended_at == 13 && death_near(ds.ended_after, 3))
		testing.expect(t, !client_death_screen_hides_hud(client) && client_death_screen_allows_respawn(client, 13) && client.mouse_state.locked, "nothing holds input after the respawn")
		testing.expect(t, client.camera.rotation.z == 0)
	}

	@(test)
	death_screen_waits_without_auto_respawn :: proc(t: ^testing.T) {
		f := death_fixture(); defer death_fixture_free(f)
		client := f.client
		client.game.config.auto_respawn = 0
		client.game.config.respawn_delay = 1
		death_frame(client, 1)
		shared.player_kill(f.me, nil, nil, false)
		death_frame(client, 2)
		ds := &client.death_screen
		testing.expect(t, ds.active && !ds.has_killer, "a fall is a death without a killer: You / Died")
		testing.expect(t, !client_death_screen_allows_respawn(client, 2 + DEATH_SCREEN_RESPAWN - 0.01), "Krunker's deathDelay is the floor")
		testing.expect(t, client_death_screen_allows_respawn(client, 2 + DEATH_SCREEN_RESPAWN))
		// The match ending closes it for the end screen.
		client.game.match.phase = .ENDED
		death_frame(client, 5)
		testing.expect(t, !ds.active && !ds.has_ended)
		testing.expect(t, !client_death_screen_begin(client, 5), "no death screen once the match is over")
	}

	@(test)
	death_screen_kill_cam_plays_first :: proc(t: ^testing.T) {
		f := death_fixture(); defer death_fixture_free(f)
		client := f.client
		death_frame(client, 1)
		shared.player_kill(f.me, f.killer, nil, false)
		death_frame(client, 2)
		testing.expect(t, client.kill_cam.active && client.death_screen.active)
		testing.expect(t, !client.death_screen.tilting && client.camera.rotation.z == 0, "the kill cam owns the camera")
		death_frame(client, 2 + DEATH_SCREEN_DELAY)
		testing.expect(t, client.kill_cam.active && client.death_screen.popped, "the card joins the running kill cam")
	}

	@(test)
	death_screen_counts_rivals :: proc(t: ^testing.T) {
		f := death_fixture(); defer death_fixture_free(f)
		client := f.client
		death_frame(client, 1)
		for _ in 0..<2 {
			shared.game_push_kill_event(&client.game, {victim_uid = 2, killer_uid = 1, weapon_id = 0})
			death_frame(client, 1.5)
		}
		shared.game_push_kill_event(&client.game, {victim_uid = 3, killer_uid = 2, weapon_id = 0}) // not about you
		shared.player_kill(f.me, f.killer, nil, false)
		death_frame(client, 2)
		ds := &client.death_screen
		testing.expect(t, ds.you.kills == 2 && ds.killer.kills == 1, "you killed them twice, they killed you once")
		testing.expect(t, ds.killer.weapon_id == 1, "without a weapon in the kill, the killer's equipped weapon")
	}

	@(test)
	death_screen_reads_live_kill_player :: proc(t: ^testing.T) {
		f := death_fixture(); defer death_fixture_free(f)
		client := f.client
		client.local_practice, client.game.is_local = false, false
		client.krunker.connected = true
		world := &client.krunker_world
		world^ = {local_sid = 1}
		defer kproto.krunker_world_reset(world)
		append(&world.players,
			kproto.Krunker_World_Player{sid = 1, name = strings.clone("Me"), team = 1, active = true},
			kproto.Krunker_World_Player{sid = 2, name = strings.clone("Sidney"), team = 2, active = true},
		)
		death_frame(client, 1)
		// [3, victim, deaths, killer, [wId, killer class xp, [stat, KDR], [ms, shots, accuracy, kills, score]], info]
		info := []kproto.Krunker_Msgpack_Value{i64(2), i64(10000), []kproto.Krunker_Msgpack_Value{f64(1.5), i64(3)},
			[]kproto.Krunker_Msgpack_Value{i64(65000), i64(20), "45%", i64(3), kproto.Krunker_Msgpack_Nil{}}}
		kill := []kproto.Krunker_Msgpack_Map_Entry{{key = "hs", value = true}}
		testing.expect(t, kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"3", i64(1), i64(4), i64(2), info, kill}))
		death := &world.local_death
		testing.expect(t, death.weapon_id == 2 && death.stat_index == 3 && death.has_stats && death.stats[2].is_text && !death.stats[4].known)
		// The shared player turns inactive in krunker_client_sync_world.
		f.me.active = false
		testing.expect(t, client_death_screen_begin(client, 1.2) && client.mouse_state.locked)
		testing.expect(t, client_death_screen_begin(client, 1.3) && client.death_screen.died_at == 1.2, "one death, one start")
		death_frame(client, 1.2)
		ds := &client.death_screen
		testing.expect(t, ds.active && ds.filled && ds.has_killer && kill_feed_name_text(&ds.killer.name) == "Sidney" && kill_feed_name_text(&ds.you.name) == "Me")
		testing.expect(t, ds.killer.weapon_id == 2 && ds.headshot, "deathInfo[0] and the info's hs")
		testing.expect(t, ds.killer.level == 4, "lvl max(1, floor(0.03*sqrt(10000)) + 1)")
		testing.expect(t, death_text_string(&ds.killer_stat) == "1.50 KDR")
		testing.expect(t, ds.stat_count == 5 && death_text_string(&ds.stats[0].value) == "1m 5s" && death_text_string(&ds.stats[1].value) == "20")
		testing.expect(t, death_text_string(&ds.stats[2].value) == "45%" && death_text_string(&ds.stats[4].value) == "Unknown")
		testing.expect(t, ds.killer.kills == 1)

		// Respawn waits for deathDelay and is asked for once.
		world.respawn_available_at = 1.2 + DEATH_SCREEN_RESPAWN
		testing.expect(t, !client_death_screen_allows_respawn(client, 3.9))
		testing.expect(t, client_death_screen_allows_respawn(client, 4.0) && !client_death_screen_allows_respawn(client, 4.1))
		// Entry refused (fe clears spawn_pending): the menu takes over.
		client.spawn_pending = false
		death_frame(client, 4.4)
		testing.expect(t, !client.mouse_state.locked, "a refused entry releases the pointer for the menu's reason")

		// A round switch ends the life without KILL_PLAYER: no death screen.
		client.death_screen = {live_revision = world.local_death_revision, record_revision = world.local_death_revision}
		client.mouse_state.locked = true
		testing.expect(t, !client_death_screen_begin(client, 6), "no KILL_PLAYER, no death screen")
		// A fresh world (reconnect) resets the revision without a phantom death.
		world.local_death_revision = 0
		testing.expect(t, !client_death_screen_begin(client, 7))
	}

	@(test)
	death_screen_formats_like_krunker :: proc(t: ^testing.T) {
		testing.expect(t, death_screen_duration(0) == "0s" && death_screen_duration(59999) == "59s" && death_screen_duration(61000) == "1m 1s")
		testing.expect(t, death_screen_duration(3723000) == "1h 2m 3s")
		testing.expect(t, death_screen_level(0) == 1 && death_screen_level(2500) == 2 && death_screen_level(1e6) == 31)
		testing.expect(t, death_screen_number(3) == "3" && death_screen_number(0.5) == "0.50")
		testing.expect(t, death_near(death_ease_back(0), 0) && death_near(death_ease_back(1), 1) && death_ease_back(0.6) > 1, "the pop overshoots")
	}

	// Hidden-window frames of the death screen at key moments, at 1280x720 and
	// 1920x1080. Writes bin/death-screen/<size>-<moment>.png.
	@(test)
	death_screen_renders_key_moments :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		test_gpu := test_gpu_open(320, 180, "Death screen")
		if !testing.expect(t, test_gpu.ok, "no GPU device for the test") do return
		defer test_gpu_close(&test_gpu, t)
		g_test_gpu = &test_gpu
		window := test_gpu.window
		os.make_directory("bin/death-screen")

		f := death_fixture(); defer death_fixture_free(f)
		client := f.client
		client.ui = ui_init()
		defer { overlay_fini(); ui_fini(client.ui); resource_cache_fini() }
		client.game.config.kill_cams = false
		death_frame(client, 1)
		f.me.kills, f.me.score = 3, 350
		shared.game_push_kill_event(&client.game, {victim_uid = 2, killer_uid = 1, weapon_id = 0})
		testing.expect(t, shared.player_apply_damage(f.me, f.killer, 500, 1, true))
		death_frame(client, 10)
		ds := &client.death_screen
		killed := ds^
		no_killer := killed
		no_killer.has_killer = false

		Moment :: struct { name: string, now: f64, state: ^Death_Screen }
		respawned := killed
		respawned.active, respawned.has_ended, respawned.ended_at, respawned.ended_after = false, true, 20, 3
		moments := [?]Moment{
			{"0-death-flash", 10.08, &killed},
			{"1-before-card", 10 + DEATH_SCREEN_DELAY - 0.1, &killed},
			{"2-card-pop", 10 + DEATH_SCREEN_DELAY + 0.12, &killed},
			{"3-card-settled", 10 + DEATH_SCREEN_DELAY + 0.8, &killed},
			{"4-you-died", 10 + DEATH_SCREEN_DELAY + 0.8, &no_killer},
			{"5-respawn-exit", 20.12, &respawned},
			{"6-spawn-in", 20.32, &respawned},
		}
		sizes := [2][2]i32{{1280, 720}, {1920, 1080}}
		for size in sizes {
			W, H := size[0], size[1]
			framebuffer := test_gpu_target(W, H)
			test_gpu_use_target(framebuffer, W, H)
			g_active_texture = 0
			client.viewport_width, client.viewport_height = W, H
			gpu_set_target(test_gpu_current_target(), W, H)
			frames := make([][]u8, len(moments))
			for moment, i in moments {
				client.death_screen = moment.state^
				// A stand-in world: sky over ground, so overlays read clearly.
				gpu_set_clear_color({0.38, 0.55, 0.72})
				gpu_clear(color = true, depth = false)
				ui_update(client.ui, f32(W), f32(H))
				ui_fill_rect(client.ui, {0.35, 0.42, 0.28, 1}, 0, f32(H) * 0.55, f32(W), f32(H) * 0.45)
				death_screen_render(client, moment.now)
				frames[i] = make([]u8, int(W*H*3))
				test_read_rgb(0, 0, W, H, raw_data(frames[i]))
				path := fmt.ctprintf("bin/death-screen/%dx%d-%s.png", W, H, moment.name)
				testing.expect(t, stbi.write_png(path, W, H, 3, &frames[i][(H-1)*W*3], -W*3) != 0)
			}
			// Pixel checks in the card's band (bottom quarter, above the bar).
			band :: proc(a, b: []u8, W, H: i32, y0, y1: f32) -> int {
				changes := 0
				for y in int(f32(H)*y0)..<int(f32(H)*y1) {
					for x in int(W/4)..<int(W*3/4) {
						o := ((int(H)-1-y)*int(W)+x)*3
						if abs(int(a[o]) - int(b[o])) > 24 || abs(int(a[o+1]) - int(b[o+1])) > 24 { changes += 1 }
					}
				}
				return changes
			}
			px :: proc(frame: []u8, W, H: i32, x, y: int) -> [3]u8 {
				o := ((int(H)-1-y)*int(W)+x)*3
				return {frame[o], frame[o+1], frame[o+2]}
			}
			area := int(W*H)
			testing.expectf(t, band(frames[1], frames[3], W, H, 0.6, 0.9) > area/200, "%dx%d: the card appears after the delay", W, H)
			testing.expectf(t, band(frames[2], frames[3], W, H, 0.6, 0.9) > area/400, "%dx%d: mid-pop differs from the settled card", W, H)
			testing.expectf(t, band(frames[3], frames[4], W, H, 0.6, 0.9) > area/400, "%dx%d: You / Died replaces the VS card", W, H)
			// Letterbox: black top rows while dead, gone once the next life fades in.
			testing.expect(t, px(frames[3], W, H, int(W/2), 2) == {0, 0, 0})
			sky := px(frames[6], W, H, int(W/2), 2)
			testing.expectf(t, sky[2] > 60, "%dx%d: the bars are gone by the spawn-in (got %v)", W, H, sky)
			// The death flash tints the edges red.
			edge := px(frames[0], W, H, 4, int(H/2))
			testing.expectf(t, int(edge[0]) > int(edge[2]), "%dx%d: red flash at the edge (got %v)", W, H, edge)
			for frame in frames { delete(frame) }
			delete(frames)
			test_gpu_target_destroy(&framebuffer)
		}
		testing.expect(t, test_gpu_no_error())
	}
}
