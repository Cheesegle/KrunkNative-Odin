package main

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import kproto "../krunker"
import menuui "../menu"

// Tester diagnostics: cheap, always-on breadcrumbs plus optional GL debug output.
//
// - phase_mark records what the main loop is doing in a small ring. Crash and
//   hang reports (logs/crash.log, logs/hang.log) print the last few entries.
// - `--gl-debug` creates a debug context and logs every distinct
//   KHR_debug message to logs/gl-debug.log, once each, with a repeat count.
// - Without it, gl_check polls glGetError once per frame (per phase after the
//   first error) and logs the first error of each site to logs/gl-errors.log.
// Nothing here allocates per frame; the cost without errors is a ring write
// per phase and one glGetError call per frame.

KRODIN_VERSION :: #load("../../VERSION", string)

DIAGNOSTICS_LOG_DIR :: "logs"
GL_DEBUG_LOG_PATH :: "logs/gl-debug.log"
GL_ERROR_LOG_PATH :: "logs/gl-errors.log"
CRASH_LOG_PATH :: "logs/crash.log"
CRASH_DUMP_PATH :: "logs/crash.dmp"
HANG_LOG_PATH :: "logs/hang.log"
HANG_DUMP_PATH :: "logs/hang.dmp"

// Phases are small integers rather than strings, so the hang watchdog thread
// can read the ring without ever seeing a torn (pointer, length) pair.
Phase :: enum u8 {
	NONE,
	STARTUP,
	MAP_LOAD,
	BATCH_BUILD,
	BATCH_SELF_TEST,
	TICK,
	RENDER_WORLD,
	RENDER_SCENE,
	RENDER_VIEWMODEL,
	PREVIEW_GRAPHICS,
	HUD,
	MENU_VIEW,
	MONITOR_CACHE_REFRESH,
	MENU_BUILD,
	SETTINGS_TAB_MAIN,
	SETTINGS_TAB_INPUT,
	SETTINGS_TAB_VIDEO,
	SETTINGS_TAB_VISUALS,
	SETTINGS_TAB_GAMEPLAY,
	SETTINGS_TAB_AUDIO,
	SETTINGS_TAB_HUD,
	SETTINGS_SEARCH,
	MENU_RENDER,
	MENU_ACTION,
	APPLY_SETTINGS,
	APPLY_DISPLAY,
	DEBUG_WINDOW,
	SWAP_BUFFERS,
	POLL_EVENTS,
	GAME_FRAME_WAIT,
	IDLE_WAIT,
	SHUTDOWN,
}

PHASE_NAMES := [Phase]string{
	.NONE                  = "none",
	.STARTUP               = "startup",
	.MAP_LOAD              = "load map",
	.BATCH_BUILD           = "build map batches",
	.BATCH_SELF_TEST       = "batching self-test",
	.TICK                  = "tick",
	.RENDER_WORLD          = "render world",
	.RENDER_SCENE          = "render scene",
	.RENDER_VIEWMODEL      = "render view model",
	.PREVIEW_GRAPHICS      = "preview visuals/quality",
	.HUD                   = "hud",
	.MENU_VIEW             = "menu: build view",
	.MONITOR_CACHE_REFRESH = "menu: refresh monitor modes",
	.MENU_BUILD            = "menu: layout",
	.SETTINGS_TAB_MAIN     = "settings: build Main tab",
	.SETTINGS_TAB_INPUT    = "settings: build Key binds tab",
	.SETTINGS_TAB_VIDEO    = "settings: build Video tab",
	.SETTINGS_TAB_VISUALS  = "settings: build Visuals tab",
	.SETTINGS_TAB_GAMEPLAY = "settings: build Gameplay tab",
	.SETTINGS_TAB_AUDIO    = "settings: build Audio tab",
	.SETTINGS_TAB_HUD      = "settings: build HUD tab",
	.SETTINGS_SEARCH       = "settings: build search results",
	.MENU_RENDER           = "menu: draw",
	.MENU_ACTION           = "menu: apply action",
	.APPLY_SETTINGS        = "settings: save",
	.APPLY_DISPLAY         = "apply display mode",
	.DEBUG_WINDOW          = "debug window",
	.SWAP_BUFFERS          = "swap buffers",
	.POLL_EVENTS           = "poll events",
	.GAME_FRAME_WAIT       = "game FPS limit wait",
	.IDLE_WAIT             = "idle frame wait",
	.SHUTDOWN              = "shutdown",
}

PHASE_RING_SIZE :: 32

Phase_Entry :: struct {
	frame: u32,
	phase: Phase,
}

Diagnostics :: struct {
	frame:      u32, // Main-loop frame counter; the hang watchdog watches it.
	phase_head: u32,
	phases:     [PHASE_RING_SIZE]Phase_Entry,
	// Copied once at startup so the crash handler never calls into GL.
	gl_vendor, gl_renderer, gl_version: [128]u8,
	gl_vendor_len, gl_renderer_len, gl_version_len: int,
	gl_debug_context: bool, // The context reports CONTEXT_FLAG_DEBUG_BIT.
	gl_debug_output: bool,  // The KHR_debug callback is installed.
	gl_debug_log: ^os.File,
	gl_error_log: ^os.File,
	gl_debug_lines: int,
	// Message counts by type, for tests and the shutdown summary.
	gl_errors, gl_warnings, gl_other: int,
	gl_seen: [512]GL_Message_Seen,
	gl_seen_count: int,
	// The most recent distinct GL message, quoted in crash reports.
	gl_last_message: [512]u8,
	gl_last_message_len: int,
	// glGetError polling: first error of each call site.
	gl_error_sites: [64]string,
	gl_error_site_count: int,
	gl_check_errors: int,
	gl_check_detailed: bool, // Per-phase checks, on after the first error.
	// Recent history for reports, written by the main thread only. Fixed-size
	// rings: one store per frame, nothing allocated.
	frame_ms_head: u32,
	frame_ms:      [FRAME_TIME_RING_SIZE]f32,
	event_head:    u32,
	events:        [EVENT_RING_SIZE]Diag_Event,
	// Edge detection for events polled once per frame.
	watch_settings_open, watch_cursor_disabled: bool,
	// GPU reset detection (robust context, polled about once a second).
	gl_robust_requested: bool, // The window was created asking for reset notification.
	gl_reset_detection:  bool, // The context reports GL_LOSE_CONTEXT_ON_RESET.
	gl_reset_status:     u32,  // First non-zero glGetGraphicsResetStatus, else 0.
	gl_reset_checks:     u32,
	gl_reset_last_check: time.Tick,
	// Set by the hang watchdog when the main loop resumes: check for a reset now.
	gl_reset_check_requested: bool,
	// Captured at startup (and when monitors change) so reports never gather
	// it on the crash path.
	system_text:    [4096]u8,
	system_len:     int,
	monitor_text:   [1024]u8,
	monitor_len:    int,
	monitors_stale: bool,
	power_plan:     [128]u8,
	power_plan_len: int,
}

FRAME_TIME_RING_SIZE :: 128 // The report prints the newest REPORT_FRAME_TIMES.
REPORT_FRAME_TIMES :: 120
EVENT_RING_SIZE :: 64       // The report prints the newest REPORT_EVENTS.
REPORT_EVENTS :: 50

Diag_Event_Kind :: enum u8 {
	NONE,
	FOCUS_GAINED,
	FOCUS_LOST,
	MINIMISED,
	RESTORED,
	WM_DISPLAYCHANGE,     // a, b = new desktop width, height
	DISPLAY_MODE_APPLIED, // a = Display_Mode, b = width << 16 | height
	MONITOR_CONNECTED,
	MONITOR_DISCONNECTED,
	SETTINGS_OPENED,
	SETTINGS_CLOSED,
	CURSOR_CAPTURED,
	CURSOR_RELEASED,
	SOFTWARE_CURSOR_ON,
	SOFTWARE_CURSOR_OFF,
	MAP_LOAD_STARTED,
	MAP_LOADED,           // a = milliseconds
	MAP_UNLOADED,
	JOIN_STARTED,
	LEFT_GAME,
	GPU_RESET,            // a = glGetGraphicsResetStatus
}

DIAG_EVENT_NAMES := [Diag_Event_Kind]string{
	.NONE                 = "none",
	.FOCUS_GAINED         = "focus gained",
	.FOCUS_LOST           = "focus lost",
	.MINIMISED            = "minimised",
	.RESTORED             = "restored",
	.WM_DISPLAYCHANGE     = "WM_DISPLAYCHANGE",
	.DISPLAY_MODE_APPLIED = "display mode applied",
	.MONITOR_CONNECTED    = "monitor connected",
	.MONITOR_DISCONNECTED = "monitor disconnected",
	.SETTINGS_OPENED      = "settings menu opened",
	.SETTINGS_CLOSED      = "settings menu closed",
	.CURSOR_CAPTURED      = "cursor captured (game)",
	.CURSOR_RELEASED      = "cursor released (menu)",
	.SOFTWARE_CURSOR_ON   = "software cursor on",
	.SOFTWARE_CURSOR_OFF  = "software cursor off",
	.MAP_LOAD_STARTED     = "map load started",
	.MAP_LOADED           = "map loaded",
	.MAP_UNLOADED         = "map unloaded",
	.JOIN_STARTED         = "join started",
	.LEFT_GAME            = "left the game",
	.GPU_RESET            = "GPU reset detected",
}

Diag_Event :: struct {
	tick: time.Tick,
	kind: Diag_Event_Kind,
	a, b: i32,
}

GL_Message_Seen :: struct {
	key:   u64,
	count: u32,
}

// Cap on lines written to gl-debug.log, so a driver that reports something
// every draw call cannot fill the disk.
GL_DEBUG_MAX_LINES :: 4000

g_diag: Diagnostics

phase_mark :: #force_inline proc "contextless" (phase: Phase) {
	head := g_diag.phase_head
	g_diag.phases[head % PHASE_RING_SIZE] = {g_diag.frame, phase}
	sync.atomic_store_explicit(&g_diag.phase_head, head + 1, .Release)
}

phase_frame_begin :: #force_inline proc "contextless" () {
	sync.atomic_store_explicit(&g_diag.frame, g_diag.frame + 1, .Release)
}

// The previous frame's duration (start to start). One store per frame.
diag_frame_time :: #force_inline proc "contextless" (ms: f32) {
	head := g_diag.frame_ms_head
	g_diag.frame_ms[head % FRAME_TIME_RING_SIZE] = ms
	sync.atomic_store_explicit(&g_diag.frame_ms_head, head + 1, .Release)
}

// A platform or game event for the report's history. Main thread only; the
// events it records happen a few times a minute at most.
diag_event :: proc "contextless" (kind: Diag_Event_Kind, a: i32 = 0, b: i32 = 0) {
	head := g_diag.event_head
	g_diag.events[head % EVENT_RING_SIZE] = {time.tick_now(), kind, a, b}
	sync.atomic_store_explicit(&g_diag.event_head, head + 1, .Release)
}

// Once per frame: turns state changes that have no callback into events.
diagnostics_watch :: #force_inline proc "contextless" (settings_open, cursor_disabled: bool) {
	if settings_open != g_diag.watch_settings_open {
		g_diag.watch_settings_open = settings_open
		diag_event(settings_open ? .SETTINGS_OPENED : .SETTINGS_CLOSED)
	}
	if cursor_disabled != g_diag.watch_cursor_disabled {
		g_diag.watch_cursor_disabled = cursor_disabled
		diag_event(cursor_disabled ? .CURSOR_CAPTURED : .CURSOR_RELEASED)
	}
}

phase_current :: proc "contextless" () -> Phase {
	head := sync.atomic_load_explicit(&g_diag.phase_head, .Acquire)
	if head == 0 { return .NONE }
	return g_diag.phases[(head - 1) % PHASE_RING_SIZE].phase
}

settings_tab_phase :: proc "contextless" (tab: int) -> Phase {
	phases := [?]Phase{.SETTINGS_TAB_MAIN, .SETTINGS_TAB_INPUT, .SETTINGS_TAB_VIDEO, .SETTINGS_TAB_VISUALS, .SETTINGS_TAB_GAMEPLAY, .SETTINGS_TAB_AUDIO, .SETTINGS_TAB_HUD}
	return tab >= 0 && tab < len(phases) ? phases[tab] : .MENU_BUILD
}

diagnostics_make_log_dir :: proc() {
	if !os.exists(DIAGNOSTICS_LOG_DIR) { os.make_directory(DIAGNOSTICS_LOG_DIR) }
}

// Records the GL strings for crash reports. Call once after the context exists.
diagnostics_capture_gl_info :: proc() {
	copy_gl_string :: proc(name: u32, dst: ^[128]u8, length: ^int) {
		value := cstring(gl.GetString(name))
		length^ = value == nil ? 0 : copy(dst[:], string(value))
	}
	copy_gl_string(gl.VENDOR, &g_diag.gl_vendor, &g_diag.gl_vendor_len)
	copy_gl_string(gl.RENDERER, &g_diag.gl_renderer, &g_diag.gl_renderer_len)
	copy_gl_string(gl.VERSION, &g_diag.gl_version, &g_diag.gl_version_len)
	flags: i32
	gl.GetIntegerv(gl.CONTEXT_FLAGS, &flags)
	g_diag.gl_debug_context = flags & gl.CONTEXT_FLAG_DEBUG_BIT != 0
	g_diag.gl_reset_detection = gl_context_loses_on_reset()
	g_diag.gl_reset_status = 0
	g_diag.gl_reset_last_check = time.tick_now()
}

GL_RESET_NOTIFICATION_STRATEGY :: 0x8256
GL_LOSE_CONTEXT_ON_RESET :: 0x8252
GL_GUILTY_CONTEXT_RESET :: 0x8253
GL_INNOCENT_CONTEXT_RESET :: 0x8254
GL_UNKNOWN_CONTEXT_RESET :: 0x8255

// The current context reports resets (it was created with
// GLFW_LOSE_CONTEXT_ON_RESET and the driver honoured it).
gl_context_loses_on_reset :: proc() -> bool {
	strategy: i32
	gl.GetIntegerv(GL_RESET_NOTIFICATION_STRATEGY, &strategy)
	return strategy == GL_LOSE_CONTEXT_ON_RESET
}

gpu_reset_status_name :: proc "contextless" (status: u32) -> string {
	switch status {
	case 0: return "none"
	case GL_GUILTY_CONTEXT_RESET: return "guilty"
	case GL_INNOCENT_CONTEXT_RESET: return "innocent"
	case GL_UNKNOWN_CONTEXT_RESET: return "unknown"
	}
	return "unknown"
}

// "GPU reset detected: guilty" etc.: the line reports put first.
gpu_reset_line :: proc(buffer: []u8, status: u32) -> string {
	switch status {
	case 0: return ""
	case GL_GUILTY_CONTEXT_RESET: return fmt.bprintf(buffer, "GPU reset detected: guilty (Krodin's own GL commands caused the reset)")
	case GL_INNOCENT_CONTEXT_RESET: return fmt.bprintf(buffer, "GPU reset detected: innocent (another program or the driver caused the reset)")
	}
	return fmt.bprintf(buffer, "GPU reset detected: unknown (the driver could not say what caused the reset; status 0x%X)", status)
}

// Polls glGetGraphicsResetStatus. Cheap, but not free on every driver, so the
// main loop calls it about once a second and right after a hang. Returns the
// status when a reset is first seen, else 0.
gpu_reset_poll :: proc(status: u32) -> u32 {
	g_diag.gl_reset_checks += 1
	g_diag.gl_reset_last_check = time.tick_now()
	if status == 0 || g_diag.gl_reset_status != 0 { return 0 }
	g_diag.gl_reset_status = status
	diag_event(.GPU_RESET, i32(status))
	return status
}

diagnostics_gl_renderer :: proc() -> string {
	return string(g_diag.gl_renderer[:g_diag.gl_renderer_len])
}

// --- KHR_debug ---------------------------------------------------------------

gl_debug_source_name :: proc(source: u32) -> string {
	switch source {
	case gl.DEBUG_SOURCE_API: return "API"
	case gl.DEBUG_SOURCE_WINDOW_SYSTEM: return "WINDOW_SYSTEM"
	case gl.DEBUG_SOURCE_SHADER_COMPILER: return "SHADER_COMPILER"
	case gl.DEBUG_SOURCE_THIRD_PARTY: return "THIRD_PARTY"
	case gl.DEBUG_SOURCE_APPLICATION: return "APPLICATION"
	}
	return "OTHER"
}

gl_debug_type_name :: proc(type: u32) -> string {
	switch type {
	case gl.DEBUG_TYPE_ERROR: return "ERROR"
	case gl.DEBUG_TYPE_DEPRECATED_BEHAVIOR: return "DEPRECATED"
	case gl.DEBUG_TYPE_UNDEFINED_BEHAVIOR: return "UNDEFINED_BEHAVIOR"
	case gl.DEBUG_TYPE_PORTABILITY: return "PORTABILITY"
	case gl.DEBUG_TYPE_PERFORMANCE: return "PERFORMANCE"
	case gl.DEBUG_TYPE_MARKER: return "MARKER"
	case gl.DEBUG_TYPE_PUSH_GROUP: return "PUSH_GROUP"
	case gl.DEBUG_TYPE_POP_GROUP: return "POP_GROUP"
	}
	return "OTHER"
}

gl_debug_severity_name :: proc(severity: u32) -> string {
	switch severity {
	case gl.DEBUG_SEVERITY_HIGH: return "HIGH"
	case gl.DEBUG_SEVERITY_MEDIUM: return "MEDIUM"
	case gl.DEBUG_SEVERITY_LOW: return "LOW"
	}
	return "NOTIFICATION"
}

// Counts and logs one debug message. Identical messages (same source, type,
// id, severity and text) are written once; the shutdown summary gives counts.
// Repeats are also noted at 10, 100, 1000... so per-frame spam is visible
// even if the process never shuts down cleanly. Returns true when the message
// was new.
gl_debug_record :: proc(source, type, id, severity: u32, message: string) -> bool {
	switch {
	case type == gl.DEBUG_TYPE_ERROR: g_diag.gl_errors += 1
	case type == gl.DEBUG_TYPE_UNDEFINED_BEHAVIOR || type == gl.DEBUG_TYPE_PORTABILITY || type == gl.DEBUG_TYPE_DEPRECATED_BEHAVIOR ||
	     type == gl.DEBUG_TYPE_PERFORMANCE && severity != gl.DEBUG_SEVERITY_NOTIFICATION:
		g_diag.gl_warnings += 1
	case: g_diag.gl_other += 1
	}
	header := [4]u32{source, type, id, severity}
	key := hash.fnv64a(transmute([]u8)message, hash.fnv64a(([^]u8)(&header[0])[:size_of(header)]))
	seen: ^GL_Message_Seen
	for &entry in g_diag.gl_seen[:g_diag.gl_seen_count] {
		if entry.key == key { seen = &entry; break }
	}
	is_new := seen == nil
	count: u32 = 1
	if seen != nil {
		seen.count += 1
		count = seen.count
	} else if g_diag.gl_seen_count < len(g_diag.gl_seen) {
		g_diag.gl_seen[g_diag.gl_seen_count] = {key, 1}
		g_diag.gl_seen_count += 1
	}
	if is_new && severity != gl.DEBUG_SEVERITY_NOTIFICATION {
		g_diag.gl_last_message_len = copy(g_diag.gl_last_message[:], message)
	}
	repeat_milestone := !is_new && (count == 10 || count == 100 || count == 1000 || count == 10000 || count == 100000)
	// Notifications (NVIDIA reports where every buffer lives) are only counted.
	loggable := severity != gl.DEBUG_SEVERITY_NOTIFICATION
	if loggable && (is_new || repeat_milestone) && g_diag.gl_debug_log != nil && g_diag.gl_debug_lines < GL_DEBUG_MAX_LINES {
		buffer: [2048]u8
		line: string
		if is_new {
			line = fmt.bprintf(buffer[:], "[frame %d, %s] %s %s %s id=%d: %s\n", g_diag.frame, PHASE_NAMES[phase_current()],
				gl_debug_severity_name(severity), gl_debug_type_name(type), gl_debug_source_name(source), id, strings.trim_space(message))
		} else {
			line = fmt.bprintf(buffer[:], "[frame %d, %s] repeated %d times: %s %s id=%d\n", g_diag.frame, PHASE_NAMES[phase_current()],
				count, gl_debug_type_name(type), gl_debug_source_name(source), id)
		}
		os.write_string(g_diag.gl_debug_log, line)
		g_diag.gl_debug_lines += 1
		if g_diag.gl_debug_lines == GL_DEBUG_MAX_LINES {
			os.write_string(g_diag.gl_debug_log, "Log limit reached; further messages are only counted.\n")
		}
	}
	return is_new
}

gl_debug_callback :: proc "c" (source, type, id, severity: u32, length: i32, message: cstring, user: rawptr) {
	context = runtime.default_context()
	text := length >= 0 ? string(([^]u8)(message)[:length]) : string(message)
	gl_debug_record(source, type, id, severity, text)
}

// Installs the KHR_debug logger (OpenGL 4.3+ core). Synchronous output makes
// the callback run inside the offending GL call, so the logged phase is the
// one that issued it. Returns false when the context has no debug output.
gl_debug_install :: proc(log_path := GL_DEBUG_LOG_PATH) -> bool {
	if gl.DebugMessageCallback == nil { return false }
	if len(log_path) > 0 {
		diagnostics_make_log_dir()
		file, err := os.open(log_path, {.Write, .Create, .Trunc})
		if err == nil {
			g_diag.gl_debug_log = file
			fmt.fprintf(file, "Krodin GL debug log\nGL_VENDOR: %s\nGL_RENDERER: %s\nGL_VERSION: %s\nDebug context: %v\n\n",
				string(g_diag.gl_vendor[:g_diag.gl_vendor_len]), diagnostics_gl_renderer(), string(g_diag.gl_version[:g_diag.gl_version_len]), g_diag.gl_debug_context)
		}
	}
	gl.Enable(gl.DEBUG_OUTPUT)
	gl.Enable(gl.DEBUG_OUTPUT_SYNCHRONOUS)
	gl.DebugMessageControl(gl.DONT_CARE, gl.DONT_CARE, gl.DONT_CARE, 0, nil, true)
	gl.DebugMessageCallback(gl_debug_callback, nil)
	g_diag.gl_debug_output = true
	return true
}

gl_debug_shutdown :: proc() {
	if g_diag.gl_debug_output && gl.DebugMessageCallback != nil {
		gl.DebugMessageCallback(nil, nil)
		gl.Disable(gl.DEBUG_OUTPUT)
	}
	g_diag.gl_debug_output = false
	if g_diag.gl_debug_log != nil {
		fmt.fprintf(g_diag.gl_debug_log, "\nSummary after %d frames: %d errors, %d warnings, %d other messages, %d distinct.\n",
			g_diag.frame, g_diag.gl_errors, g_diag.gl_warnings, g_diag.gl_other, g_diag.gl_seen_count)
		os.close(g_diag.gl_debug_log)
		g_diag.gl_debug_log = nil
	}
	if g_diag.gl_error_log != nil {
		os.close(g_diag.gl_error_log)
		g_diag.gl_error_log = nil
	}
}

gl_debug_reset_counts :: proc() {
	g_diag.gl_errors, g_diag.gl_warnings, g_diag.gl_other = 0, 0, 0
	g_diag.gl_seen_count = 0
	g_diag.gl_error_site_count, g_diag.gl_check_errors, g_diag.gl_check_detailed = 0, 0, false
	g_diag.gl_last_message_len = 0
}

// --- glGetError polling ------------------------------------------------------

gl_error_name :: proc(error: u32) -> string {
	switch error {
	case gl.INVALID_ENUM: return "GL_INVALID_ENUM"
	case gl.INVALID_VALUE: return "GL_INVALID_VALUE"
	case gl.INVALID_OPERATION: return "GL_INVALID_OPERATION"
	case gl.STACK_OVERFLOW: return "GL_STACK_OVERFLOW"
	case gl.STACK_UNDERFLOW: return "GL_STACK_UNDERFLOW"
	case gl.OUT_OF_MEMORY: return "GL_OUT_OF_MEMORY"
	case gl.INVALID_FRAMEBUFFER_OPERATION: return "GL_INVALID_FRAMEBUFFER_OPERATION"
	case 0x0507: return "GL_CONTEXT_LOST"
	}
	return "unknown GL error"
}

// Polls glGetError when the debug callback is off. The main loop checks once
// per frame; per-phase checks (`per_phase`) start only after the first error,
// to name the phase that raised it. glGetError does not wait for the GPU, but
// threaded drivers may sync with their worker thread, so it stays rare. The
// first error of each site is logged with its phase; later ones are counted.
gl_check :: proc(site: string, per_phase := false) -> bool {
	if g_diag.gl_debug_output || per_phase && !g_diag.gl_check_detailed { return true }
	clean := true
	for _ in 0 ..< 8 {
		error := gl.GetError()
		if error == gl.NO_ERROR { break }
		clean = false
		g_diag.gl_check_errors += 1
		g_diag.gl_check_detailed = true
		known := false
		for logged in g_diag.gl_error_sites[:g_diag.gl_error_site_count] {
			if logged == site { known = true; break }
		}
		if known || g_diag.gl_error_site_count >= len(g_diag.gl_error_sites) { continue }
		g_diag.gl_error_sites[g_diag.gl_error_site_count] = site
		g_diag.gl_error_site_count += 1
		buffer: [512]u8
		line := fmt.bprintf(buffer[:], "[frame %d, %s] %s (0x%04X) after %s\n", g_diag.frame, PHASE_NAMES[phase_current()], gl_error_name(error), error, site)
		g_diag.gl_last_message_len = copy(g_diag.gl_last_message[:], line)
		if g_diag.gl_error_log == nil {
			diagnostics_make_log_dir()
			file, err := os.open(GL_ERROR_LOG_PATH, {.Write, .Create, .Trunc})
			if err == nil {
				g_diag.gl_error_log = file
				fmt.fprintf(file, "GL_RENDERER: %s\nGL_VERSION: %s\n", diagnostics_gl_renderer(), string(g_diag.gl_version[:g_diag.gl_version_len]))
			}
		}
		if g_diag.gl_error_log != nil { os.write_string(g_diag.gl_error_log, line) }
		fmt.eprint("[GL] ", line)
	}
	return clean
}

// --- Crash and hang reports --------------------------------------------------
//
// Reports are plain text in sections (System, Settings, Recent history, ...).
// Everything slow to gather (adapters, CPU, Windows version) is captured once
// at startup; the report only formats what is already in memory, plus a few
// syscalls (free RAM, AC/battery). The finished text goes through the network
// log redaction line by line, so no access or guest token can reach it.

// Optional commit, set by build.bat and package-windows.ps1 so a report names
// the symbols (dist/symbols/<commit>/) that match its dump.
KRODIN_COMMIT :: #config(KRODIN_COMMIT, "")

Crash_Info :: struct {
	title:          string, // "crash report (unhandled exception)" or "hang report (...)".
	code:           u32,
	code_name:      string,
	address:        uintptr,
	module_path:    string,
	module_base:    uintptr,
	access:         string, // "read", "write" or "execute" for access violations.
	access_address: uintptr,
	detail:         string,
	stack:          []uintptr, // Return addresses, innermost first (optional).
	stack_modules:  []string,  // Module path per stack entry (optional).
	stack_bases:    []uintptr,
	// Event times are printed relative to this; zero means now.
	report_tick:    time.Tick,
	// Hangs: when the main loop last finished a frame.
	stall_tick:     time.Tick,
	// The reporting thread may refresh slow OS state (the power plan). The
	// crash filter passes false and uses what startup captured.
	live:           bool,
}

@(private = "file")
tick_seconds_before :: proc(now, then: time.Tick) -> f64 {
	if then._nsec == 0 { return 0 }
	return time.duration_seconds(time.tick_diff(then, now))
}

@(private = "file")
report_section :: proc(b: ^strings.Builder, title: string) {
	fmt.sbprintf(b, "\n== %s ==\n", title)
}

// The report, formatted into `buffer` without heap allocation.
crash_report_format :: proc(buffer: []u8, info: Crash_Info) -> string {
	now := info.report_tick
	if now._nsec == 0 { now = time.tick_now() }
	b := strings.builder_from_bytes(buffer)
	fmt.sbprintf(&b, "Krodin %s\n", info.title)
	fmt.sbprintf(&b, "Build: %s%s%s%s\n", strings.trim_space(KRODIN_VERSION), len(KRODIN_COMMIT) > 0 ? ", commit " : "", KRODIN_COMMIT, KRODIN_DEV ? " (dev)" : "")
	reset_buffer: [160]u8
	if g_diag.gl_reset_status != 0 {
		fmt.sbprintf(&b, "\n*** %s ***\n", gpu_reset_line(reset_buffer[:], g_diag.gl_reset_status))
	} else if g_diag.gl_reset_detection {
		fmt.sbprintf(&b, "GPU reset: none detected (%d checks, the last %.1f s before this report)\n", g_diag.gl_reset_checks, tick_seconds_before(now, g_diag.gl_reset_last_check))
	} else if g_diag.gl_vendor_len > 0 {
		fmt.sbprintf(&b, "GPU reset: cannot be detected (the GL context has no reset notification)\n")
	}

	report_section(&b, "What happened")
	if info.stall_tick._nsec != 0 {
		fmt.sbprintf(&b, "The main loop last finished a frame %.1f s before this report.\n", tick_seconds_before(now, info.stall_tick))
	}
	if info.code != 0 { fmt.sbprintf(&b, "Exception: 0x%08X %s\n", info.code, info.code_name) }
	if info.address != 0 {
		if len(info.module_path) > 0 {
			fmt.sbprintf(&b, "Address: 0x%X = %s+0x%X\n", info.address, info.module_path, info.address - info.module_base)
		} else {
			fmt.sbprintf(&b, "Address: 0x%X (no module)\n", info.address)
		}
	}
	if len(info.access) > 0 { fmt.sbprintf(&b, "Access violation: %s of address 0x%X\n", info.access, info.access_address) }
	if len(info.detail) > 0 { fmt.sbprintf(&b, "%s\n", info.detail) }
	if len(info.stack) > 0 {
		fmt.sbprintf(&b, "\nStack (innermost first; tools/symbolicate turns the .dmp into names):\n")
		for address, i in info.stack {
			if i < len(info.stack_modules) && len(info.stack_modules[i]) > 0 {
				fmt.sbprintf(&b, "  0x%X = %s+0x%X\n", address, info.stack_modules[i], address - info.stack_bases[i])
			} else {
				fmt.sbprintf(&b, "  0x%X\n", address)
			}
		}
	}

	report_section(&b, "System")
	if g_diag.system_len > 0 { strings.write_string(&b, string(g_diag.system_text[:g_diag.system_len])) }
	diagnostics_write_live_system(&b, info.live)
	fmt.sbprintf(&b, "OpenGL is on: %s (GL_VENDOR %s)\nGL_VERSION: %s\n", diagnostics_gl_renderer(), string(g_diag.gl_vendor[:g_diag.gl_vendor_len]), string(g_diag.gl_version[:g_diag.gl_version_len]))
	fmt.sbprintf(&b, "GL context: reset notification %s%s, debug context %s, GL debug output %s\n",
		g_diag.gl_reset_detection ? "on" : "off", g_diag.gl_robust_requested && !g_diag.gl_reset_detection ? " (requested, not granted)" : "",
		g_diag.gl_debug_context ? "yes" : "no", g_diag.gl_debug_output ? "on" : "off")
	if g_diag.monitor_len > 0 {
		strings.write_string(&b, "Monitors:\n")
		strings.write_string(&b, string(g_diag.monitor_text[:g_diag.monitor_len]))
	}

	report_section(&b, "Settings")
	diagnostics_write_settings(&b)

	report_section(&b, "Recent frames")
	diagnostics_write_frame_times(&b)

	report_section(&b, "Recent events")
	diagnostics_write_events(&b, now, info.stall_tick)

	report_section(&b, "Frame phases")
	fmt.sbprintf(&b, "Frame: %d\nLast phases (oldest first):\n", g_diag.frame)
	head := sync.atomic_load_explicit(&g_diag.phase_head, .Acquire)
	start := head > PHASE_RING_SIZE ? head - PHASE_RING_SIZE : 0
	for i in start ..< head {
		entry := g_diag.phases[i % PHASE_RING_SIZE]
		fmt.sbprintf(&b, "  frame %d: %s\n", entry.frame, PHASE_NAMES[entry.phase])
	}

	report_section(&b, "GL messages")
	if g_diag.gl_last_message_len > 0 {
		fmt.sbprintf(&b, "Last new GL message: %s\n", strings.trim_space(string(g_diag.gl_last_message[:g_diag.gl_last_message_len])))
	}
	fmt.sbprintf(&b, "GL messages so far: %d errors, %d warnings; glGetError reported %d\n", g_diag.gl_errors, g_diag.gl_warnings, g_diag.gl_check_errors)

	lines: [kproto.NETWORK_LOG_RECENT_LINES][]u8
	count := kproto.network_log_recent_lines(lines[:])
	report_section(&b, "Network log (newest lines, redacted)")
	if count == 0 { strings.write_string(&b, "(no network activity this session)\n") }
	for line in lines[:count] {
		strings.write_string(&b, "  ")
		strings.write_string(&b, string(line))
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

diagnostics_write_settings :: proc(b: ^strings.Builder) {
	client := g_client
	if client == nil {
		strings.write_string(b, "(not loaded yet)\n")
		return
	}
	mode_names := [Display_Mode]string{.Windowed = "Windowed", .Borderless = "Borderless", .Fullscreen = "Fullscreen (exclusive)"}
	mode := client.display_mode
	if mode < min(Display_Mode) || mode > max(Display_Mode) { mode = .Windowed }
	fmt.sbprintf(b, "Display mode: %s, monitor %d\n", mode_names[mode], client.monitor_index)
	resolution := DISPLAY_RESOLUTIONS[clamp(client.resolution_index, 0, len(DISPLAY_RESOLUTIONS) - 1)]
	fmt.sbprintf(b, "Windowed resolution: %dx%d\n", resolution.width, resolution.height)
	if client.fullscreen_resolution.width > 0 {
		fmt.sbprintf(b, "Fullscreen size: %dx%d\n", client.fullscreen_resolution.width, client.fullscreen_resolution.height)
	} else {
		strings.write_string(b, "Fullscreen size: the monitor's largest mode\n")
	}
	fmt.sbprintf(b, "Viewport: %dx%d\n", client.viewport_width, client.viewport_height)
	fmt.sbprintf(b, "V-Sync: %s\n", client.vsync ? "on" : "off")
	if client.game_fps_limit <= menuui.GAME_FPS_LIMIT_UNLIMITED {
		strings.write_string(b, "Game FPS limit: unlimited\n")
	} else {
		fmt.sbprintf(b, "Game FPS limit: %d\n", client.game_fps_limit)
	}
	switch client.menu_fps_limit {
	case menuui.MENU_FPS_LIMIT_MONITOR: strings.write_string(b, "Menu FPS limit: monitor refresh rate\n")
	case menuui.MENU_FPS_LIMIT_UNLIMITED: strings.write_string(b, "Menu FPS limit: unlimited\n")
	case: fmt.sbprintf(b, "Menu FPS limit: %d\n", client.menu_fps_limit)
	}
	q := client.quality_settings
	on_off :: proc(value: bool) -> string { return value ? "on" : "off" }
	fmt.sbprintf(b, "Shadows: %s (soft %s, high-res %s, dynamic %s, own body %s)\n", on_off(q.shadows), on_off(q.soft_shadows), on_off(q.high_res_shadows), on_off(q.dynamic_shadows), on_off(q.self_shadow))
	fmt.sbprintf(b, "Shadow quality: %s\n", menuui.SHADOW_QUALITY_LABELS[menuui.Shadow_Quality(clamp(q.shadow_quality, 0, 1))])
	fmt.sbprintf(b, "Lighting: %s\n", menuui.LIGHTING_LABELS[menuui.Lighting_Quality(clamp(q.lighting, 0, 3))])
	fmt.sbprintf(b, "Anisotropy: %d\n", q.anisotropy)
	v := client.visual_settings
	fmt.sbprintf(b, "Night mode: %s (strength %.2f)\n", on_off(v.night_mode), v.night_strength)
	spatial := menuui.Spatial_Audio_Mode(clamp(i32(client.audio_settings.spatial), 0, 2))
	fmt.sbprintf(b, "Spatial audio: %s\n", menuui.SPATIAL_AUDIO_LABELS[spatial])
	fmt.sbprintf(b, "Settings menu open: %s\n", g_diag.watch_settings_open ? "yes" : "no")
	fmt.sbprintf(b, "Map batching: %s\n", client.render_batching ? "on" : "off")
}

diagnostics_write_frame_times :: proc(b: ^strings.Builder) {
	head := sync.atomic_load_explicit(&g_diag.frame_ms_head, .Acquire)
	count := min(int(head), REPORT_FRAME_TIMES)
	if count == 0 {
		strings.write_string(b, "(no frames yet)\n")
		return
	}
	lowest, highest, total: f32 = max(f32), 0, 0
	slow := 0
	for i in 0 ..< count {
		ms := g_diag.frame_ms[(head - u32(count) + u32(i)) % FRAME_TIME_RING_SIZE]
		lowest, highest, total = min(lowest, ms), max(highest, ms), total + ms
		if ms > 50 { slow += 1 }
	}
	fmt.sbprintf(b, "Last %d frame times in ms (oldest first): min %.2f, avg %.2f, max %.2f, %d over 50 ms\n", count, lowest, total / f32(count), highest, slow)
	for i in 0 ..< count {
		ms := g_diag.frame_ms[(head - u32(count) + u32(i)) % FRAME_TIME_RING_SIZE]
		// Right-aligned by hand: fmt pads floats with zeros.
		number: [16]u8
		text := fmt.bprintf(number[:], "%.1f", ms)
		strings.write_string(b, i % 12 == 0 ? "  " : " ")
		for _ in len(text) ..< 6 { strings.write_byte(b, ' ') }
		strings.write_string(b, text)
		if i % 12 == 11 || i == count - 1 { strings.write_byte(b, '\n') }
	}
}

diagnostics_write_events :: proc(b: ^strings.Builder, now, stall: time.Tick) {
	head := sync.atomic_load_explicit(&g_diag.event_head, .Acquire)
	count := min(int(head), REPORT_EVENTS)
	strings.write_string(b, "Seconds before this report, oldest first:\n")
	stall_printed := stall._nsec == 0
	for i in 0 ..< count {
		event := g_diag.events[(head - u32(count) + u32(i)) % EVENT_RING_SIZE]
		if !stall_printed && time.tick_diff(stall, event.tick) > 0 {
			fmt.sbprintf(b, "  -%.2f s  -- main loop stopped (last finished frame) --\n", tick_seconds_before(now, stall))
			stall_printed = true
		}
		fmt.sbprintf(b, "  -%.2f s  %s", tick_seconds_before(now, event.tick), DIAG_EVENT_NAMES[event.kind] if event.kind <= max(Diag_Event_Kind) else "?")
		#partial switch event.kind {
		case .WM_DISPLAYCHANGE: fmt.sbprintf(b, " (%dx%d)", event.a, event.b)
		case .DISPLAY_MODE_APPLIED:
			names := [3]string{"windowed", "borderless", "fullscreen"}
			fmt.sbprintf(b, " (%s %dx%d)", names[clamp(event.a, 0, 2)], event.b >> 16, event.b & 0xFFFF)
		case .MAP_LOADED: fmt.sbprintf(b, " (%d ms)", event.a)
		case .GPU_RESET: fmt.sbprintf(b, " (%s)", gpu_reset_status_name(u32(event.a)))
		}
		strings.write_byte(b, '\n')
	}
	if !stall_printed {
		fmt.sbprintf(b, "  -%.2f s  -- main loop stopped (last finished frame) --\n", tick_seconds_before(now, stall))
	}
	if count == 0 && stall._nsec == 0 { strings.write_string(b, "  (none)\n") }
}

// Monitors as GLFW sees them. Main thread; at startup and after a display
// change (the once-a-second check refreshes it when monitors_stale is set).
diagnostics_capture_monitors :: proc(window: glfw.WindowHandle) {
	b := strings.builder_from_bytes(g_diag.monitor_text[:])
	primary := glfw.GetPrimaryMonitor()
	fullscreen_on := window != nil ? glfw.GetWindowMonitor(window) : nil
	for monitor, i in glfw.GetMonitors() {
		mode := glfw.GetVideoMode(monitor)
		scale_x, _ := glfw.GetMonitorContentScale(monitor)
		x, y := glfw.GetMonitorPos(monitor)
		width, height, refresh: i32
		if mode != nil { width, height, refresh = mode.width, mode.height, mode.refresh_rate }
		fmt.sbprintf(&b, "  %d: %s, %dx%d @ %d Hz, scale %.0f%%, at %d,%d%s%s\n", i, glfw.GetMonitorName(monitor), width, height, refresh,
			scale_x * 100, x, y, monitor == primary ? ", primary" : "", monitor == fullscreen_on ? ", Krodin fullscreen here" : "")
	}
	g_diag.monitor_len = len(strings.to_string(b))
	g_diag.monitors_stale = false
}

// --- Report writing and redaction ---------------------------------------------

REPORT_BUFFER_SIZE :: 64 * 1024
REPORT_ARENA_SIZE :: 64 * 1024
REPORT_REDACT_CHUNK :: 4096

// Each thread that writes reports has its own static buffers, so the crash
// path never needs the heap (it may be what broke) and a crash during a hang
// report does not overwrite the hang report's text.
Report_Writer :: enum { MAIN, WATCHDOG, CRASH }

Report_Buffers :: struct {
	text:     [REPORT_BUFFER_SIZE]u8,
	redacted: [REPORT_BUFFER_SIZE]u8,
	arena:    [REPORT_ARENA_SIZE]u8,
}

@(private = "file")
g_report_buffers: [Report_Writer]Report_Buffers

// Runs every line through the network log redaction (registered secrets,
// token-like fields, JWTs). Allocation comes from `arena_buffer`, reset per
// line; a line that cannot be redacted is dropped, never written raw.
report_redact :: proc(text: string, out: []u8, arena_buffer: []u8) -> string {
	arena: mem.Arena
	mem.arena_init(&arena, arena_buffer)
	context.allocator = mem.arena_allocator(&arena)
	b := strings.builder_from_bytes(out)
	rest := text
	for len(rest) > 0 {
		newline := strings.index_byte(rest, '\n')
		line := newline < 0 ? rest : rest[:newline]
		rest = newline < 0 ? "" : rest[newline + 1:]
		chunk_rest := line
		for {
			chunk := chunk_rest[:min(len(chunk_rest), REPORT_REDACT_CHUNK)]
			chunk_rest = chunk_rest[len(chunk):]
			safe := kproto.network_log_safe(chunk, REPORT_REDACT_CHUNK * 4)
			strings.write_string(&b, safe)
			free_all(context.allocator)
			if len(chunk_rest) == 0 { break }
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// Formats, redacts and writes a crash/hang report to `path` (truncating) and
// flushes it to disk.
crash_log_write :: proc(path: string, info: Crash_Info, writer := Report_Writer.MAIN) -> bool {
	buffers := &g_report_buffers[writer]
	report := crash_report_format(buffers.text[:], info)
	safe := report_redact(report, buffers.redacted[:], buffers.arena[:])
	return crash_file_write(path, transmute([]u8)safe)
}

// Appends redacted lines to an existing report (hang recovery, second dump,
// GPU reset found after a hang).
crash_log_append :: proc(path: string, text: string, writer := Report_Writer.MAIN) -> bool {
	buffers := &g_report_buffers[writer]
	safe := report_redact(text, buffers.redacted[:], buffers.arena[:])
	return crash_file_append(path, transmute([]u8)safe)
}
