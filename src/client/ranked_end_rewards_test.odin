package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import menuui "../menu"
import kproto "../krunker"

when ODIN_TEST {
	// TDM endStats: sid, name, score, kills, deaths, assists, reward.
	@(private = "file")
	ranked_end_test_world :: proc(client: ^Client, ranked: bool) -> bool {
		client.krunker.connected = true
		world := &client.krunker_world
		world.local_sid, world.is_ranked = 7, ranked
		for sid, i in ([2]i32{7, 8}) { kproto.krunker_world_upsert_player(world, sid).team = i32(i)+1 }
		ed := []kproto.Krunker_Msgpack_Value{
			i64(8), []kproto.Krunker_Msgpack_Value{"acc8", "Eight"}, i64(500), i64(9), i64(2), i64(1), i64(30),
			i64(7), "Seven", i64(310), i64(4), i64(6), i64(3), i64(12),
		}
		return end_screen_test_packet(world, 1, false, 2, 0, ed)
	}

	@(test)
	ranked_end_table_has_no_reward_column :: proc(t: ^testing.T) {
		{
			client: Client
			defer kproto.krunker_world_reset(&client.krunker_world)
			if !testing.expect(t, ranked_end_test_world(&client, true)) do return
			board := client_end_screen(&client).board
			testing.expect(t, board.column_count == 4 && board.columns[0] == "Score" && board.columns[3] == "Assists", "ranked drops only the Reward column")
			for c in 0..<board.column_count { testing.expect(t, board.columns[c] != "Reward") }
			testing.expect(t, len(board.rows) == 2 && board.rows[0].cells[0] == "500" && board.rows[0].cells[3] == "1" && board.rows[1].cells[3] == "3", "the other cells stay in their columns")
			for row in board.rows { for c in 0..<board.column_count { testing.expect(t, row.cells[c] != "+30 KR" && row.cells[c] != "+12 KR", "no KR in ranked") } }

			// The kept results outlive INIT, which may start an unranked lobby.
			kproto.krunker_world_init_match(&client.krunker_world, []kproto.Krunker_Msgpack_Value{"init"})
			client.krunker_world.is_ranked = false
			kept := end_screen_from_final(&client, &client.krunker_world.final_results).board
			testing.expect(t, client.krunker_world.final_results.ranked && kept.column_count == 4 && kept.columns[3] == "Assists", "the ranked match's results stay without rewards")
		}
		{
			client: Client
			defer kproto.krunker_world_reset(&client.krunker_world)
			if !testing.expect(t, ranked_end_test_world(&client, false)) do return
			board := client_end_screen(&client).board
			testing.expect(t, board.column_count == 5 && board.columns[4] == "Reward" && board.rows[0].cells[4] == "+30 KR", "unranked and comp tables keep Krunker's Reward column")
		}
	}

	// Writes bin/end-screen/ranked.png and unranked.png (the standings after
	// the five second delay).
	@(test)
	ranked_end_table_renders_without_rewards :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		W, H :: 1280, 720
		if !testing.expect(t, bool(glfw.Init())) { return }
		defer glfw.Terminate()
		test_gpu := test_gpu_open(W, H, "Ranked end screen")
		if !testing.expect(t, test_gpu.ok, "no GPU device for the test") do return
		defer test_gpu_close(&test_gpu, t)
		g_test_gpu = &test_gpu
		window := test_gpu.window
		gpu_set_clear_color({0.16, 0.18, 0.20})
		g_active_texture = 0
		gpu_set_target(test_gpu_current_target(), W, H)
		ui := ui_init()
		defer { overlay_fini(); ui_fini(ui); resource_cache_fini() }
		os.make_directory("bin/end-screen")
		pixels := make([]u8, W*H*3)
		defer delete(pixels)
		flipped := make([]u8, W*H*3)
		defer delete(flipped)
		for ranked in ([2]bool{true, false}) {
			client := Client{ui = ui, bindings = menuui.default_bindings()}
			client.viewport_width, client.viewport_height = W, H
			if !testing.expect(t, ranked_end_test_world(&client, ranked)) do return
			testing.expect(t, client_end_screen_update(&client, 10, false), "the END packet shows the end screen")
			gpu_clear(color = true, depth = true)
			ui_update(ui, W, H)
			end_screen_render(&client, 10+END_SCREEN_PANEL_DELAY+0.1)
			test_read_rgb(0, 0, W, H, raw_data(pixels))
			for row in 0 ..< H { copy(flipped[row*W*3:][:W*3], pixels[(H-1-row)*W*3:][:W*3]) }
			testing.expect(t, stbi.write_png(fmt.ctprintf("bin/end-screen/%s.png", ranked ? "ranked" : "unranked"), W, H, 3, raw_data(flipped), W*3) != 0)
			kproto.krunker_world_reset(&client.krunker_world)
		}
		testing.expect(t, test_gpu_no_error())
	}
}
