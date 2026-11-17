package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import stbi "vendor:stb/image"
import menuui "../menu"
import clay "../third_party/clay"

when ODIN_TEST {
	@(private = "file")
	import_exclude_inside :: proc(box, parent: clay.BoundingBox) -> bool {
		return box.width > 0 && box.height > 0 && box.x >= parent.x-1 && box.y >= parent.y-1 && box.x+box.width <= parent.x+parent.width+1 && box.y+box.height <= parent.y+parent.height+1
	}

	// Each label must be drawn (whole, or wrapped into lines that start with its
	// first line) and every line of it must lie inside `parent`. Only commands
	// at `min_z` or above are considered, so the popup ignores the page behind it.
	@(private = "file")
	import_exclude_texts_inside :: proc(t: ^testing.T, commands: clay.ClayArray(clay.RenderCommand), labels: []string, parent: clay.BoundingBox, size: [2]i32, min_z: i16 = 0) {
		for label in labels {
			drawn := 0
			for command in commands.internalArray[:commands.length] {
				if command.commandType != .Text || command.zIndex < min_z { continue }
				text := command.renderData.text.stringContents
				line := strings.trim_space(string(text.chars[:text.length]))
				if len(line) == 0 || !(line == label || len(line) >= 8 && strings.contains(label, line)) { continue }
				drawn += len(line)
				testing.expectf(t, import_exclude_inside(command.boundingBox, parent), "%q must fit at %v: %v outside %v", line, size, command.boundingBox, parent)
			}
			testing.expectf(t, drawn >= len(label) - 4, "%q must be drawn in full at %v", label, size)
		}
	}

	// The Import popup with Krodin's exclude toggles, rendered with the real
	// font. Writes bin/import-filter/import_popup_<w>x<h>.png and
	// bin/import-filter/import_message_<w>x<h>.png (the footer result message).
	@(test)
	import_exclude_popup_renders_and_fits :: proc(t: ^testing.T) {
		logger := context.logger
		context = runtime.default_context()
		context.logger = logger
		if !testing.expect(t, bool(glfw.Init()), "GLFW initialization failed") do return
		defer glfw.Terminate()
		test_gpu := test_gpu_open(1280, 720, "Import exclude")
		if !testing.expect(t, test_gpu.ok, "no GPU device for the test") do return
		defer test_gpu_close(&test_gpu, t)
		g_test_gpu = &test_gpu
		window := test_gpu.window
		ui := ui_init()
		defer { ui_fini(ui); resource_cache_fini() }
		state: menuui.State
		if !testing.expect(t, menuui.init(&state, menu_measure_text, ui), "menu initialization failed") do return
		defer menuui.fini(&state)
		view := menuui.View{online = true, ready = true, resolution = "1920 x 1080", sensitivity = 1, bindings = menuui.default_bindings(), audio_volumes = {0.8, 1, 0.8, 0.6, 0.3},
			visuals = menuui.DEFAULT_VISUAL_SETTINGS, resolution_options = []string{"1280 x 720", "1920 x 1080"}}
		os.make_directory("bin/import-filter")
		popup_labels := []string{"Import Settings", "Krodin extra: excluded settings keep their current values.", "Exclude sensitivity", "Exclude keybinds", "Exclude sound", "On", "Off", "Import"}
		longest := menuui.krunker_import_message({imported = 28, ignored = 13, skipped = 22}, {.SENSITIVITY, .KEYBINDS, .SOUND})
		for size in ([?][2]i32{{1280, 720}, {1920, 1080}}) {
			test_gpu_resize(size[0], size[1])
			glfw.PollEvents()
			gpu_set_target(test_gpu_current_target(), size[0], size[1])
			ui_update(ui, f32(size[0]), f32(size[1]))
			pixels := make([]u8, int(size[0]*size[1]*3))
			defer delete(pixels)
			for scene in 0..<2 {
				state.page, state.settings_tab = .SETTINGS, .MAIN
				state.settings_active = false
				state.settings_message_length = 0
				state.import_open = scene == 0
				state.import_exclude = {.KEYBINDS, .SOUND}
				state.import_length = copy(state.import_buffer[:], `{"fov":110,"sound":0.2,"controls":{"jumpKey":70}}`)
				state.focus = clay.ID("ImportExcludeToggle", u32(menuui.Krunker_Import_Group.SOUND)).id
				menuui.build(&state, view, {}, ui.width, ui.height, 1.0/60.0)
				if scene == 1 { menuui.settings_set_message(&state, longest, false) }
				commands := menuui.build(&state, view, {}, ui.width, ui.height, 1.0/60.0)
				testing.expect(t, state.errors == 0, "menu layout reported an error")
				overlay := clay.GetElementData(clay.ID("Overlay")).boundingBox
				if scene == 0 {
					popup := clay.GetElementData(clay.ID("ImportPopup")).boundingBox
					testing.expectf(t, import_exclude_inside(popup, overlay) && import_exclude_inside(popup, {0, 0, f32(size[0]), f32(size[1])}), "the Import popup must fit in Settings at %v: %v", size, popup)
					for group in menuui.Krunker_Import_Group {
						testing.expectf(t, import_exclude_inside(clay.GetElementData(clay.ID("ImportExcludeToggle", u32(group))).boundingBox, popup), "%v toggle must fit in the popup at %v", group, size)
						testing.expectf(t, import_exclude_inside(clay.GetElementData(clay.ID("ImportExcludeRow", u32(group))).boundingBox, popup), "%v row must fit in the popup at %v", group, size)
					}
					testing.expect(t, import_exclude_inside(clay.GetElementData(clay.ID("ImportConfirm")).boundingBox, popup), "Import must fit in the popup")
					testing.expect(t, state.control_count == 4, "the popup holds Import and the three toggles")
					import_exclude_texts_inside(t, commands, popup_labels, popup, size, min_z = 20)
				} else {
					import_exclude_texts_inside(t, commands, {longest}, clay.GetElementData(clay.ID("SettingsFooter")).boundingBox, size)
				}
				gpu_set_clear_color({0.17, 0.17, 0.17})
				gpu_clear(color = true, depth = false)
				menu_render_commands(ui, commands)
				test_read_rgb(0, 0, size[0], size[1], raw_data(pixels))
				name := scene == 0 ? "import_popup" : "import_message"
				testing.expect(t, stbi.write_png(fmt.ctprintf("bin/import-filter/%s_%dx%d.png", name, size[0], size[1]), size[0], size[1], 3, &pixels[(size[1]-1)*size[0]*3], -size[0]*3) != 0, "preview PNG written")
			}
		}
	}
}
