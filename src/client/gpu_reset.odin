package main

import "core:fmt"
import "core:sync"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"

// GPU reset detection (Krodin's own diagnostics; Krunker has no equivalent).
//
// The game's context is created with GLFW_CONTEXT_ROBUSTNESS =
// GLFW_LOSE_CONTEXT_ON_RESET when the driver offers it, falling back to a
// plain context when that creation fails. The main loop then asks
// glGetGraphicsResetStatus about once a second and right after a hang. A
// reset is logged (logs/gpu-reset.log, and hang.log if a hang preceded it),
// and the player gets a message box instead of a frozen or black window:
// after a reset every GL object is gone, so the game closes cleanly.
// `--no-gl-robustness` creates the plain context directly.

GPU_RESET_LOG_PATH :: "logs/gpu-reset.log"
DIAGNOSTICS_CHECK_INTERVAL :: 1.0 // Seconds between GPU reset checks.

// From --no-gl-robustness; the benchmark uses the same setting as the game.
g_gl_robustness_wanted := true

Window_Create_Proc :: #type proc(width, height: i32, title: cstring, robust: bool) -> glfw.WindowHandle

// The real creator: the robustness hint, then glfw.CreateWindow with the
// other hints already set by the caller.
glfw_create_window_hinted :: proc(width, height: i32, title: cstring, robust: bool) -> glfw.WindowHandle {
	glfw.WindowHint(glfw.CONTEXT_ROBUSTNESS, robust ? glfw.LOSE_CONTEXT_ON_RESET : glfw.NO_ROBUSTNESS)
	return glfw.CreateWindow(width, height, title, nil, nil)
}

// Creates the window asking for reset notification when `want_robust`, and
// retries without it if that fails. `robust_requested` says whether the
// returned window was created with the request (the driver may still ignore
// it; gl_context_loses_on_reset says what it granted).
client_create_window :: proc(width, height: i32, title: cstring, want_robust: bool, create: Window_Create_Proc = glfw_create_window_hinted) -> (window: glfw.WindowHandle, robust_requested: bool) {
	if want_robust {
		window = create(width, height, title, true)
		if window != nil { return window, true }
		description, code := glfw.GetError()
		fmt.eprintf("[GL] Creating a context with GPU reset notification failed (GLFW error 0x%X: %s); retrying without it\n", code, description)
	}
	return create(width, height, title, false), false
}

// The message the player sees, and the report's headline.
gpu_reset_message :: proc(buffer: []u8, status: u32) -> string {
	line_buffer: [160]u8
	return fmt.bprintf(buffer, "The graphics driver reset the GPU.\n%s\n\nKrodin cannot keep drawing after a reset and will close now. Your settings are saved.\nPlease send the logs folder (logs\\gpu-reset.log) with your report.",
		gpu_reset_line(line_buffer[:], status))
}

// Records a reset: writes `report_path`, appends to hang.log if a hang came
// first, and returns the player message (in `message_buffer`).
gpu_reset_handle :: proc(status: u32, report_path: string, message_buffer: []u8) -> string {
	line_buffer: [160]u8
	line := gpu_reset_line(line_buffer[:], status)
	fmt.eprintln("[GPU]", line)
	info := Crash_Info{title = "GPU reset report", detail = line, live = true}
	crash_log_write(report_path, info)
	if crash_hang_was_reported() {
		append_buffer: [256]u8
		crash_log_append(crash_hang_log_path(), fmt.bprintf(append_buffer[:], "\n*** %s ***\n", line))
	}
	return gpu_reset_message(message_buffer, status)
}

// About once a second from the main loop, and right after a hang: refreshes
// the monitor list after display changes and polls for a GPU reset.
client_diagnostics_check :: proc(client: ^Client) {
	if g_diag.monitors_stale { diagnostics_capture_monitors(client.window) }
	after_hang := sync.atomic_exchange(&g_diag.gl_reset_check_requested, false)
	if !g_diag.gl_reset_detection {
		if after_hang { crash_log_append(crash_hang_log_path(), "GPU reset check after the hang: not possible (the GL context has no reset notification).\n") }
		return
	}
	status: u32
	when KRODIN_VULKAN { status = gpu_device_lost() ? GPU_RESET_DEVICE_LOST : 0 } else { status = u32(gl.GetGraphicsResetStatus()) }
	reset := gpu_reset_poll(status)
	if after_hang && reset == 0 {
		crash_log_append(crash_hang_log_path(), g_diag.gl_reset_status == 0 ? "GPU reset check after the hang: none detected.\n" : "GPU reset check after the hang: a reset was reported earlier (see above).\n")
	}
	if reset == 0 { return }
	message_buffer: [1024]u8
	message := gpu_reset_handle(reset, GPU_RESET_LOG_PATH, message_buffer[:])
	gpu_reset_show_message(message)
	glfw.SetWindowShouldClose(client.window, true)
}
