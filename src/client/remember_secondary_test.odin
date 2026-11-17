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
import menuui "../menu"
import clay "../third_party/clay"

when ODIN_TEST {
	// Two classes with a secondary slot and one without, from the built-in configs.
	@(private = "file")
	remember_test_classes :: proc() -> (a, b, none: i32) {
		a, b, none = -1, -1, -1
		for class, i in shared.CLASSES_LIST {
			if class.secondary {
				if a < 0 { a = i32(i) } else if b < 0 { b = i32(i) }
			} else if none < 0 { none = i32(i) }
		}
		return
	}

	// The live fixture plus cached "no portrait" entries, so menu_view (used by
	// class selection) loads no textures without a GL context.
	@(private = "file")
	remember_test_fixture :: proc(client: ^Client, map_inst: ^shared.Map) {
		krunker_presentation_fixture(client, map_inst)
		if menu_portraits == nil { menu_portraits = make(map[i32]u32) }
		for class in client.game.classes { menu_portraits[class.icon_index] = 0 }
	}

	@(private = "file")
	remember_test_cleanup :: proc(client: ^Client) {
		delete(client.selection_status)
		krunker_presentation_cleanup(client)
		delete(menu_portraits); menu_portraits = nil
		// menu_view caches class portraits; free them with this test's allocator.
		resource_cache_fini()
	}

	@(test)
	remember_secondary_setting_persists_and_resets :: proc(t: ^testing.T) {
		defaults := client_settings_default_values()
		testing.expect(t, !client_settings_defaults().remember_secondary && !defaults.remember_secondary, "Remember last secondary is off by default (Krodin's own setting)")

		// The draft toggles it; Cancel discards and Save applies.
		client := settings_reset_test_client()
		defer { delete(menu_portraits); menu_portraits = nil; resource_cache_fini() }
		state := &client.menu
		state.page = .SETTINGS
		menuui.prepare_settings(state, menu_view(&client))
		menuui.activate(state, {action = {kind = .REMEMBER_SECONDARY}})
		testing.expect(t, state.settings_draft.remember_secondary && !client.remember_secondary, "the toggle changes only the draft")
		menu_apply_action(&client, menuui.activate(state, {action = {kind = .SETTINGS_CANCEL}}))
		testing.expect(t, !client.remember_secondary, "Cancel discards the toggle")
		state.page = .SETTINGS
		menuui.prepare_settings(state, menu_view(&client))
		testing.expect(t, !state.settings_draft.remember_secondary, "reopening Settings after Cancel shows Off")
		menuui.activate(state, {action = {kind = .REMEMBER_SECONDARY}})
		menu_apply_action(&client, menuui.activate(state, {action = {kind = .SETTINGS_SAVE}}))
		testing.expect(t, client.remember_secondary && client.settings_dirty, "Save applies the toggle and schedules persistence")

		// client-settings.json keeps the toggle and the per-class picks.
		client.secondary_picks[1], client.secondary_picks[3] = 15, 10
		path := "bin/remember-secondary-test.json"
		defer os.remove(path)
		testing.expect(t, client_settings_save(client_settings_snapshot(&client), path))
		loaded := client_settings_load(path)
		testing.expect(t, loaded.remember_secondary && loaded.secondary_picks[1] == 15 && loaded.secondary_picks[3] == 10 && loaded.secondary_picks[0] == 0, "the setting and picks survive a restart")

		// Older files without the keys load the defaults; bad picks are cleared.
		testing.expect(t, os.write_entire_file(path, transmute([]u8)string(`{"version":1,"sensitivity":2}`)) == nil)
		loaded = client_settings_load(path)
		testing.expect(t, loaded.sensitivity == 2 && !loaded.remember_secondary && loaded.secondary_picks == {}, "an older file defaults to Off with no picks")
		testing.expect(t, os.write_entire_file(path, transmute([]u8)string(`{"version":1,"remember_secondary":true,"secondary_picks":[-4,15]}`)) == nil)
		loaded = client_settings_load(path)
		testing.expect(t, loaded.remember_secondary && loaded.secondary_picks[0] == 0 && loaded.secondary_picks[1] == 15, "negative picks are cleared and a short list keeps the rest unset")

		// Reset: the Gameplay tab and Reset all restore Off, and keep the picks.
		state.page = .SETTINGS
		menuui.prepare_settings(state, menu_view(&client))
		testing.expect(t, state.settings_draft.remember_secondary, "the draft starts from the saved On")
		menuui.settings_reset_tab(&state.settings_draft, defaults, .HUD)
		testing.expect(t, state.settings_draft.remember_secondary, "other tabs leave it alone")
		menuui.settings_reset_tab(&state.settings_draft, defaults, .GAMEPLAY)
		testing.expect(t, !state.settings_draft.remember_secondary, "Reset Gameplay restores Off")
		menuui.activate(state, {action = {kind = .REMEMBER_SECONDARY}})
		menuui.activate(state, {action = {kind = .SETTINGS_RESET_OPEN}})
		menuui.activate(state, {action = {kind = .SETTINGS_RESET}})
		menu_apply_action(&client, menuui.activate(state, {action = {kind = .SETTINGS_SAVE}}))
		testing.expect(t, !client.remember_secondary && client.secondary_picks[1] == 15, "Reset all restores Off; the remembered picks are not settings")

		// Krunker has no such key: import keeps it and export does not mention it.
		client.menu.settings_draft.remember_secondary = true
		_, error := menuui.krunker_settings_import(&client.menu.settings_draft, `{"fov":100}`)
		testing.expect(t, len(error) == 0 && client.menu.settings_draft.remember_secondary, "a Krunker import keeps Krodin's own setting")
		text := menuui.krunker_settings_export(client.menu.settings_draft)
		defer delete(text)
		testing.expect(t, !strings.contains(text, "emember") && !strings.contains(text, "secondaryInd"), "Krunker's settings export has no such key")
	}

	@(test)
	remember_secondary_reuses_each_class_pick :: proc(t: ^testing.T) {
		a, b, none := remember_test_classes()
		if !testing.expect(t, a >= 0 && b >= 0 && none >= 0, "the configs have two classes with a secondary and one without") do return
		client: Client
		map_inst: shared.Map
		remember_test_fixture(&client, &map_inst)
		defer remember_test_cleanup(&client)
		client.local_practice, client.selected_class, client.selected_secondary = true, none, 2
		client.remember_secondary = true

		// First pick of each class: no stored pick, so the prompt opens and records.
		client.menu.page = .HOME
		menu_apply_action(&client, {kind = .SELECT_CLASS, index = a})
		testing.expect(t, client.menu.page == .LOADOUT && client.secondary_picks[a] == 2, "a class without a stored pick still prompts, and keeps the shown secondary as its pick")
		menu_apply_action(&client, {kind = .SELECT_SECONDARY, index = 15})
		testing.expect(t, client.secondary_picks[a] == 15 && client.settings_dirty, "choosing a secondary stores it for that class")
		client.menu.page = .CLASSES
		client.menu.return_focus = 4321
		menu_apply_action(&client, {kind = .SELECT_CLASS, index = b})
		testing.expect(t, client.menu.page == .LOADOUT, "the other class prompts the first time")
		menu_apply_action(&client, {kind = .SELECT_SECONDARY, index = 10})
		testing.expect(t, client.secondary_picks[b] == 10 && client.secondary_picks[a] == 15, "picks are kept per class")

		// Back to the first class from the class picker: no prompt, its own pick.
		client.menu.page = .CLASSES
		menu_apply_action(&client, {kind = .SELECT_CLASS, index = a})
		testing.expect(t, client.menu.page == .HOME && client.menu.focus == 4321 && client.selected_class == a, "a remembered pick skips the loadout and closes the picker")
		testing.expect(t, client_secondary_choice(&client) == 15 && menu_view(&client).selected_secondary == 15, "the class's own pick is reused, not the last one chosen")
		// Local Practice spawns with it.
		shared.player_spawn(client.me, client.selected_class, client_secondary_choice(&client))
		testing.expect(t, client.me.loadout[1] == 15, "Local Practice spawns with the remembered secondary")
		// From the competitive lobby's class strip the page stays on the lobby.
		client.menu.page, client.menu.focus = .HOME, 777
		menu_apply_action(&client, {kind = .SELECT_CLASS, index = b})
		testing.expect(t, client.menu.page == .HOME && client.menu.focus == 777 && client_secondary_choice(&client) == 10, "the lobby class strip also skips the prompt")

		// A class with no secondary slot has nothing to ask.
		menu_apply_action(&client, {kind = .SELECT_CLASS, index = none})
		testing.expect(t, client.menu.page == .HOME && client.secondary_picks[none] == 0 && client_secondary_request(&client, none) == -1, "a class without a secondary skips the prompt and stores nothing")

		// Choosing the class you already have opens the loadout to change it.
		menu_apply_action(&client, {kind = .SELECT_CLASS, index = b})
		menu_apply_action(&client, {kind = .SELECT_CLASS, index = b})
		testing.expect(t, client.menu.page == .LOADOUT && client.menu.loadout_parent == .HOME, "choosing your current class again opens its loadout")
		menu_apply_action(&client, {kind = .SELECT_SECONDARY, index = 21})
		testing.expect(t, client.secondary_picks[b] == 21 && client_secondary_choice(&client) == 21 && client.secondary_picks[a] == 15, "changing it there updates only that class")

		// Native server: the spawn request carries client_secondary_choice.
		buf: [64]u8
		size := shared.packet_serialize_connect(buf[:], client.selected_class, client_secondary_choice(&client))
		class_id, secondary_id, _, ok := shared.packet_deserialize_loadout(buf[:size])
		testing.expect(t, ok && class_id == b && secondary_id == 21, "the native spawn request carries the remembered secondary")

		// Live Krunker: the class request and entry carry the class's own pick.
		client.local_practice = false
		client.krunker.connected, client.krunker.q_index = true, 1
		client.menu.page = .CLASSES
		menu_apply_action(&client, {kind = .SELECT_CLASS, index = a}, class_selection_test_send)
		testing.expect(t, client.menu.page == .HOME && client.krunker.class_index == a && client.krunker.secondary_index == 15, "the live class request sends the remembered secondary")
		counter: u8
		encoded := krunker_ws_message("class", &counter, 0, 0, client.krunker.class_index, client.krunker.secondary_index)
		defer delete(encoded)
		messages, _, error_text := kproto.krunker_msgpack_decode_packet(encoded[:])
		if testing.expect(t, len(error_text) == 0 && len(messages) == 1) {
			entries := messages[0].([]kproto.Krunker_Msgpack_Value)[2].([]kproto.Krunker_Msgpack_Map_Entry)
			testing.expect(t, kproto.krunker_world_i32(entries[1].value) == 15, "Krunker's class packet carries it")
		}
		testing.expect(t, client_secondary_request(&client, b) == 21, "the entry and server-forced class paths use each class's pick")
		// A failed live send keeps the old class and does not skip anywhere.
		client.krunker.q_index = 0
		client.menu.page = .CLASSES
		menu_apply_action(&client, {kind = .SELECT_CLASS, index = b}, class_selection_test_send)
		testing.expect(t, client.menu.page == .CLASSES && client.selected_class == a && client.krunker.secondary_index == 15, "a failed request keeps the picker open and the old loadout")
	}

	@(test)
	remember_secondary_invalid_pick_prompts :: proc(t: ^testing.T) {
		a, b, _ := remember_test_classes()
		client: Client
		map_inst: shared.Map
		remember_test_fixture(&client, &map_inst)
		defer remember_test_cleanup(&client)
		client.local_practice, client.selected_class, client.selected_secondary = true, b, 16
		client.remember_secondary = true
		for stored in ([]i32{1, 999, -3}) { // A primary, an unknown id, a corrupted value.
			client.selected_class = b
			client.secondary_picks[a] = stored
			testing.expect(t, client_remembered_secondary(&client, a) == -1, "an invalid stored pick is not reused")
			client.menu.page = .HOME
			menu_apply_action(&client, {kind = .SELECT_CLASS, index = a})
			testing.expect(t, client.menu.page == .LOADOUT, "an invalid stored pick falls back to the loadout prompt")
			testing.expect(t, client.secondary_picks[a] == 16 && client_secondary_choice(&client) == 16, "the prompt opens on a valid secondary, which replaces the bad pick")
		}
		// Secondaries disabled by the lobby: nothing to choose, nothing sent.
		client.secondary_picks[b] = 15
		client.game.config.no_secondaries = true
		client.menu.page = .HOME
		menu_apply_action(&client, {kind = .SELECT_CLASS, index = b})
		testing.expect(t, client.menu.page == .HOME && client_secondary_request(&client, b) == -1, "a lobby without secondaries skips the prompt and sends none")
	}

	@(test)
	remember_secondary_off_still_prompts :: proc(t: ^testing.T) {
		a, b, _ := remember_test_classes()
		client: Client
		map_inst: shared.Map
		remember_test_fixture(&client, &map_inst)
		defer remember_test_cleanup(&client)
		client.local_practice, client.selected_class, client.selected_secondary = true, b, 2
		client.secondary_picks[a], client.secondary_picks[b] = 15, 10
		for _ in 0..<2 {
			client.menu.page = .CLASSES
			menu_apply_action(&client, {kind = .SELECT_CLASS, index = a})
			testing.expect(t, client.menu.page == .LOADOUT, "with the setting off every class choice opens the loadout")
			testing.expect(t, client_secondary_choice(&client) == 2 && client_secondary_request(&client, b) == 2, "with it off the current secondary is used, not stored picks")
			client.menu.page = .CLASSES
			menu_apply_action(&client, {kind = .SELECT_CLASS, index = b})
			testing.expect(t, client.menu.page == .LOADOUT, "every class prompts")
		}
		menu_apply_action(&client, {kind = .SELECT_SECONDARY, index = 11})
		testing.expect(t, client.secondary_picks[b] == 11 && client_secondary_choice(&client) == 11, "picks are still recorded while off, ready for when it is turned on")
	}

	// Writes bin/remember-secondary/<scene>_<w>x<h>.png: the Gameplay setting
	// (found through search), the class picker hint and the standard lobby.
	@(test)
	remember_secondary_menu_renders :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init()), "GLFW initialization failed") do return
		defer glfw.Terminate()
		glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		window := glfw.CreateWindow(1280, 720, "Remember secondary", nil, nil)
		if !testing.expect(t, window != nil, "hidden OpenGL window failed") do return
		defer glfw.DestroyWindow(window)
		glfw.MakeContextCurrent(window)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		ui := ui_init()
		defer { ui_fini(ui); resource_cache_fini() }
		state: menuui.State
		if !testing.expect(t, menuui.init(&state, menu_measure_text, ui), "menu initialization failed") do return
		defer menuui.fini(&state)
		classes: [len(shared.CLASSES_LIST)]menuui.Class
		for class, i in shared.CLASSES_LIST {
			path := shared.concat(shared.assets_path(), fmt.tprintf("textures/classes/icon_%d.png", class.icon_index))
			classes[i] = {id = i32(i), name = class.name, weapon = "Primary", available = true, portrait = rawptr(uintptr(load_texture(path)))}
			delete(path)
		}
		view := menuui.View{classes = classes[:], online = true, ready = true, presentation = .STANDARD, selected_class = 0, confirmed_class = 0, confirmed_team = 1,
			secondary_name = "Sawed Off", selected_secondary = 15, remember_secondary = true, lobby_name = "Local practice", match_status = "Match in progress",
			resolution = "1920 x 1080", sensitivity = 1, bindings = menuui.default_bindings(), audio_volumes = {0.8, 1, 0.8, 0.6, 0.3},
			visuals = menuui.DEFAULT_VISUAL_SETTINGS, resolution_options = []string{"1280 x 720", "1920 x 1080"}}
		os.make_directory("bin/remember-secondary")
		scenes := [?]string{"settings_search", "settings_gameplay", "class_picker", "standard_lobby"}
		for size in ([?][2]i32{{1280, 720}, {1920, 1080}}) {
			glfw.SetWindowSize(window, size[0], size[1])
			glfw.PollEvents()
			gl.Viewport(0, 0, size[0], size[1])
			ui_update(ui, f32(size[0]), f32(size[1]))
			pixels := make([]u8, int(size[0]*size[1]*3))
			defer delete(pixels)
			for scene, index in scenes {
				state.settings_active, state.search_length, state.focus = false, 0, 0
				switch index {
				case 0:
					state.page, state.settings_tab = .SETTINGS, .MAIN
					state.search_length = copy(state.search_buffer[:], "remember")
				case 1:
					state.page, state.settings_tab = .SETTINGS, .GAMEPLAY
					state.focus = clay.ID("RememberSecondary").id
				case 2: state.page = .CLASSES
				case 3: state.page = .HOME
				}
				commands := menuui.build(&state, view, {}, ui.width, ui.height, 1.0/60.0)
				if index == 1 {
					// Scroll the Gameplay tab to its Loadout section.
					for control in state.controls[:state.control_count] { if control.id.id == state.focus { menuui.focus_visible(control, .SETTINGS) } }
					menuui.build(&state, view, {}, ui.width, ui.height, 1.0/60.0)
				}
				commands = menuui.build(&state, view, {}, ui.width, ui.height, 1.0/60.0)
				testing.expectf(t, state.errors == 0, "menu layout reported an error (%s)", scene)
				want: string
				switch index {
				case 0, 1:
					testing.expect(t, state.settings_draft.remember_secondary, "the draft shows the saved On")
					toggle := clay.GetElementData(clay.ID("RememberSecondary"))
					panel := clay.GetElementData(clay.ID("SettingsPanel")).boundingBox
					box := toggle.boundingBox
					testing.expectf(t, toggle.found && box.y >= panel.y-1 && box.y+box.height <= panel.y+panel.height+1, "the Remember last secondary toggle is visible (%s at %v): %v in %v", scene, size, box, panel)
					want = "Remember last secondary"
				case 2: want = menuui.REMEMBER_SECONDARY_HINT
				case 3: want = "Secondary: Sawed Off (remembered)"
				}
				found := false
				for command in commands.internalArray[:commands.length] {
					if command.commandType != .Text { continue }
					text := command.renderData.text.stringContents
					line := string(text.chars[:text.length])
					if line == want || len(line) >= 12 && strings.contains(want, strings.trim_space(line)) {
						found = true
						box := command.boundingBox
						testing.expectf(t, box.x >= 0 && box.y >= 0 && box.x+box.width <= f32(size[0])+1 && box.y+box.height <= f32(size[1])+1, "%q must be on screen at %v", line, size)
					}
				}
				testing.expectf(t, found, "%q must be drawn (%s at %v)", want, scene, size)
				gl.ClearColor(0.17, 0.17, 0.17, 1)
				gl.Clear(gl.COLOR_BUFFER_BIT)
				menu_render_commands(ui, commands)
				gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
				gl.ReadPixels(0, 0, size[0], size[1], gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
				testing.expect(t, stbi.write_png(fmt.ctprintf("bin/remember-secondary/%s_%dx%d.png", scene, size[0], size[1]), size[0], size[1], 3, &pixels[(size[1]-1)*size[0]*3], -size[0]*3) != 0, "preview PNG written")
			}
		}
	}
}
