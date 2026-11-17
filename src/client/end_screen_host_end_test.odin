package main

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import menuui "../menu"
import kproto "../krunker"

when ODIN_TEST {
	// A TDM match in progress: the local player (sid 7, team 1), a teammate
	// and one enemy, with the browser's UPDATE_LEADERS board.
	@(private = "file")
	host_end_live_match :: proc(client: ^Client) {
		client.krunker.connected = true
		world := &client.krunker_world
		world.received_at = 100
		testing_init := []kproto.Krunker_Msgpack_Value{"init", i64(0), i64(1)}
		kproto.krunker_world_apply_packet(world, testing_init)
		world.local_sid = 7
		for sid, i in ([3]i32{7, 8, 9}) {
			player := kproto.krunker_world_upsert_player(world, sid)
			player.team = i == 1 ? 2 : 1
		}
		kproto.krunker_world_upsert_player(world, 8).name = strings.clone("Eight")
		client.in_game, client.krunker.spawned = true, true
	}

	// The server's endGame(endIndex, winner, skip) sends END as
	// (skip ? 2 : 0, didWin, endData, winner, endIndex, reward, bpData, extra).
	@(private = "file")
	host_end_packet :: proc(world: ^kproto.Krunker_World_State, skip: bool, did_win, winner: kproto.Krunker_Msgpack_Value, end_index: i64) -> bool {
		// TDM endStats: sid, name, score, kills, deaths, assists, reward.
		ed := []kproto.Krunker_Msgpack_Value{
			i64(8), []kproto.Krunker_Msgpack_Value{"acc8", "Eight"}, i64(500), i64(9), i64(2), i64(1), i64(0),
			i64(7), "Seven", i64(310), i64(4), i64(6), i64(3), i64(0),
			i64(9), "Nine", i64(120), i64(1), i64(5), i64(0), i64(0),
		}
		data := []kproto.Krunker_Msgpack_Map_Entry{
			{key = "tms", value = []kproto.Krunker_Msgpack_Value{[]kproto.Krunker_Msgpack_Value{i64(1), i64(430)}, []kproto.Krunker_Msgpack_Value{i64(2), i64(500)}}},
			{key = "ed", value = ed},
		}
		packet := []kproto.Krunker_Msgpack_Value{"end", i64(skip ? 2 : 0), did_win, data, winner, end_index, i64(0), kproto.Krunker_Msgpack_Nil{}, []kproto.Krunker_Msgpack_Map_Entry{}}
		return kproto.krunker_world_apply_packet(world, packet)
	}

	@(private = "file")
	host_end_expect_final_table :: proc(t: ^testing.T, screen: ^End_Screen, label: string) {
		board := &screen.board
		testing.expectf(t, board.column_count == 5 && board.columns[0] == "Score" && board.columns[4] == "Reward", "%s: TDM end columns", label)
		testing.expectf(t, len(board.rows) == 3 && board.rows[0].name == "Eight" && board.rows[0].team == 2 && board.rows[1].name == "Seven" && board.rows[1].is_you && board.rows[1].team == 1, "%s: endSort order, names and teams", label)
		testing.expectf(t, board.rows[0].cells[0] == "500" && board.rows[1].cells[2] == "6" && board.rows[2].cells[4] == "NONE", "%s: the final stats", label)
		testing.expectf(t, screen.teams && board.team_scores[1] == 430 && board.team_scores[2] == 500 && board.rank_label == "#", "%s: final team totals", label)
	}

	// endGame(4, winner, true): END with skip set, then the next INIT at once
	// (endTimer 1 ms). The browser shows nothing; Krodin keeps the results up.
	@(test)
	end_screen_host_end_survives_immediate_restart :: proc(t: ^testing.T) {
		client: Client
		world := &client.krunker_world
		defer kproto.krunker_world_reset(world)
		host_end_live_match(&client)
		testing.expect(t, !client_end_screen_update(&client, 100, false), "no end screen while playing")
		// endIndex 4 without a given winner: winner -1, didWin false.
		world.received_at = 120
		testing.expect(t, host_end_packet(world, true, false, i64(-1), 4), "END with skip and endIndex 4 applies")
		testing.expect(t, world.final_results.revision == 1 && world.final_results.game_state == 2 && world.final_results.end_index == 4)
		world.received_at = 120.002
		testing.expect(t, kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"init", i64(0), i64(1)}), "the next INIT follows at once")
		testing.expect(t, !client_match_ended(&client) && len(world.end_entries) == 0 && len(world.players) == 0, "INIT cleared the live end state")
		// The network thread may apply END and INIT before the next frame.
		client.in_game, client.krunker.spawned = false, false
		testing.expect(t, client_end_screen_update(&client, 120.01, false), "the final scoreboard opens after the restart")
		screen := client_end_screen(&client)
		host_end_expect_final_table(t, &screen, "host end")
		testing.expectf(t, screen.result == .DEFEAT && screen.winner_team == 0 && !screen.abandoned && screen.timer == "", "the browser title for didWin false is def: got %v", screen.result)
		testing.expect(t, client_end_screen_update(&client, 140, false), "it stays for Krunker's normal end window")
		testing.expect(t, !client_end_screen_update(&client, 120+END_SCREEN_HOLD, false) && !client.end_screen_active, "then Krunker's flow continues")
	}

	@(test)
	end_screen_host_end_dismiss_and_rejoin :: proc(t: ^testing.T) {
		client: Client
		world := &client.krunker_world
		defer kproto.krunker_world_reset(world)
		host_end_live_match(&client)
		world.received_at = 50
		testing.expect(t, host_end_packet(world, true, true, "2", 4), "a given team winner")
		// krunker_client_sync_world leaves the game when the match ends.
		client.in_game, client.krunker.spawned = false, false
		testing.expect(t, client_end_screen_update(&client, 50, false))
		screen := client_end_screen(&client)
		testing.expect(t, screen.result == .VICTORY && screen.winner_team == 2)
		world.received_at = 50.01
		kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"init", i64(0), i64(1)})
		testing.expect(t, client_end_screen_update(&client, 51, false))
		testing.expect(t, !client_end_screen_update(&client, 52, true) && !client_end_screen_update(&client, 53, false), "dismissing reveals the menu")
		testing.expect(t, client.end_screen_active, "a dismissed screen does not come back during the window")
		client.end_screen_active, client.end_screen_dismissed = false, false
		client.spawn_pending = true
		testing.expect(t, !client_end_screen_update(&client, 54, false), "joining the next game closes the held results")
	}

	// endIndex 3 (abandoned): the browser never shows the result title, and the
	// end UI waits for the normal end timer and INIT.
	@(test)
	end_screen_host_abandon_keeps_normal_flow :: proc(t: ^testing.T) {
		client: Client
		world := &client.krunker_world
		defer kproto.krunker_world_reset(world)
		host_end_live_match(&client)
		world.received_at = 10
		testing.expect(t, kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"gsc", i64(4)}))
		testing.expect(t, host_end_packet(world, false, false, kproto.Krunker_Msgpack_Nil{}, 3))
		testing.expect(t, kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"t", "0:24", i64(1)}))
		testing.expect(t, client_end_screen_update(&client, 10, false))
		screen := client_end_screen(&client)
		host_end_expect_final_table(t, &screen, "abandoned")
		testing.expect(t, screen.abandoned && screen.timer == "MATCH ABANDONED")
		// The normal 25 s end timer runs out before INIT: no hold afterwards.
		world.received_at = 35
		kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"init", i64(0), i64(1)})
		client.in_game, client.krunker.spawned = false, false
		testing.expect(t, !client_end_screen_update(&client, 35, false), "the next game takes over after a normal end")
	}

	// Packets an early end can send that used to be dropped whole.
	@(test)
	end_screen_host_end_packets_apply :: proc(t: ^testing.T) {
		world: kproto.Krunker_World_State
		defer kproto.krunker_world_reset(&world)
		kproto.krunker_world_init_match(&world, []kproto.Krunker_Msgpack_Value{"init"})
		// A comp endTimer "inf" broadcasts its kind as endIndex || 2.
		testing.expect(t, kproto.krunker_world_apply_packet(&world, []kproto.Krunker_Msgpack_Value{"t", "inf", i64(4)}) && world.timer_kind == 4 && world.timer_text == "inf")
		testing.expect(t, kproto.krunker_world_apply_packet(&world, []kproto.Krunker_Msgpack_Value{"end", i64(0), false, []kproto.Krunker_Msgpack_Map_Entry{}, i64(3), i64(4)}), "a winner outside the two drawn teams")
		testing.expect(t, world.end_received && world.winner_team == 3 && world.end_index == 4 && world.match.phase == .ENDED)
	}

	@(test)
	end_screen_host_end_renders_after_restart :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		W :: 1280
		H :: 720
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(W, H, "Host end", nil, nil)
		if !testing.expect(t, window != nil) { return }
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.ClearColor(0.16, 0.18, 0.20, 1)
		framebuffer, color_texture: u32
		gl.GenFramebuffers(1, &framebuffer)
		gl.GenTextures(1, &color_texture)
		defer gl.DeleteFramebuffers(1, &framebuffer)
		defer gl.DeleteTextures(1, &color_texture)
		gl.BindFramebuffer(gl.FRAMEBUFFER, framebuffer)
		gl.BindTexture(gl.TEXTURE_2D, color_texture)
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGB8, W, H, 0, gl.RGB, gl.UNSIGNED_BYTE, nil)
		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, color_texture, 0)
		gl.BindTexture(gl.TEXTURE_2D, 0)
		g_active_texture = 0
		client := Client{ui = ui_init(), bindings = menuui.default_bindings()}
		defer { overlay_fini(); ui_fini(client.ui); resource_cache_fini() }
		world := &client.krunker_world
		defer kproto.krunker_world_reset(world)
		host_end_live_match(&client)
		world.received_at = 200
		testing.expect(t, host_end_packet(world, true, false, i64(-1), 4))
		world.received_at = 200.01
		kproto.krunker_world_apply_packet(world, []kproto.Krunker_Msgpack_Value{"init", i64(0), i64(1)})
		client.in_game, client.krunker.spawned = false, false
		client.viewport_width, client.viewport_height = W, H
		gl.Viewport(0, 0, W, H)
		testing.expect(t, client_end_screen_update(&client, 200.02, false))
		pixels := make([]u8, W*H*3)
		blank := make([]u8, W*H*3)
		defer { delete(pixels); delete(blank) }
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		ui_flush()
		gl.Clear(gl.COLOR_BUFFER_BIT)
		ui_flush()
		gl.ReadPixels(0, 0, W, H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(blank))
		ui_flush()
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		ui_update(client.ui, W, H)
		end_screen_render(&client, 200.02+END_SCREEN_PANEL_DELAY+0.1)
		ui_flush()
		gl.ReadPixels(0, 0, W, H, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
		w, h := client.ui.width/client.ui.scale, client.ui.height/client.ui.scale
		testing.expect(t, match_hud_region_delta(&client, blank, pixels, w*0.5-300, h*0.3, w*0.5+300, h*0.6) > 1000, "the final standings are drawn after the restart")
		os.make_directory("bin/end-screen")
		testing.expect(t, stbi.write_png("bin/end-screen/host-end-final-scoreboard.png", W, H, 3, &pixels[(H-1)*W*3], -W*3) != 0)
		testing.expect(t, gl.GetError() == gl.NO_ERROR)
	}
}
