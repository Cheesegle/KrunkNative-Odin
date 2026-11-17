package main

import "base:runtime"
import "core:fmt"
import "core:sync"
import win "core:sys/windows"
import "core:thread"
import "core:time"
import md "../minidump"

// Top-level crash handler and hang watchdog (Windows).
//
// An unhandled exception on any thread writes logs/crash.log (exception,
// faulting module+offset, stack return addresses, system, settings and recent
// history) and a small minidump, logs/crash.dmp, then lets Windows terminate
// the process as before. A watchdog thread writes logs/hang.log and
// logs/hang.dmp when the main loop has not finished a frame for
// HANG_SECONDS, a second dump (logs/hang-20s.dmp) if it is still stuck after
// HANG_SECOND_DUMP_SECONDS, and appends "recovered after N s" to hang.log
// when the loop resumes. tools/symbolicate turns a dump plus the build's
// archived PDB (dist/symbols/<commit>/) into named call stacks per thread.

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	GetModuleHandleExW :: proc(dwFlags: win.DWORD, lpModuleName: rawptr, phModule: ^win.HMODULE) -> win.BOOL ---
}

GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT :: 0x2
GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS :: 0x4
CONTEXT_AMD64_CONTROL :: 0x00100001

HANG_SECONDS :: 6
HANG_SECOND_DUMP_SECONDS :: 20

// What a dump contains: every thread's stack and registers, thread names and
// times, loaded and unloaded modules, handle metadata and the address-space
// layout (region types and protections, not their contents).
//
// PRIVACY: never add MiniDumpWithFullMemory, WithIndirectlyReferencedMemory,
// WithDataSegs, WithPrivateReadWriteMemory or WithCodeSegs. Heap and global
// memory can hold Krunker access tokens and guest tokens, and testers share
// these files. crash_dump_excludes_heap_memory checks a real dump.
CRASH_DUMP_TYPE :: win.MINIDUMP_TYPE(
	u32(win.MINIDUMP_TYPE.WithThreadInfo) |
	u32(win.MINIDUMP_TYPE.WithUnloadedModules) |
	u32(win.MINIDUMP_TYPE.WithHandleData) |
	u32(win.MINIDUMP_TYPE.WithFullMemoryInfo) |
	u32(win.MINIDUMP_TYPE.WithProcessThreadData))

CRASH_DUMP_FORBIDDEN_FLAGS :: u32(win.MINIDUMP_TYPE.WithFullMemory) | u32(win.MINIDUMP_TYPE.WithIndirectlyReferencedMemory) |
	u32(win.MINIDUMP_TYPE.WithDataSegs) | u32(win.MINIDUMP_TYPE.WithPrivateReadWriteMemory) | u32(win.MINIDUMP_TYPE.WithCodeSegs) |
	u32(win.MINIDUMP_TYPE.WithPrivateWriteCopyMemory) | u32(win.MINIDUMP_TYPE.ScanMemory)
#assert(u32(CRASH_DUMP_TYPE) & CRASH_DUMP_FORBIDDEN_FLAGS == 0)

// Tests shorten the timings and write somewhere else; the game uses the defaults.
Crash_Config :: struct {
	log_dir:             string,
	hang_seconds:        f64,
	second_dump_seconds: f64,
	poll_ms:             int,
}

DEFAULT_CRASH_CONFIG :: Crash_Config{log_dir = DIAGNOSTICS_LOG_DIR, hang_seconds = HANG_SECONDS, second_dump_seconds = HANG_SECOND_DUMP_SECONDS, poll_ms = 500}

g_crash_config := DEFAULT_CRASH_CONFIG

Crash_Paths :: struct {
	crash_log, crash_dump, hang_log, hang_dump, hang_dump_late: string,
	storage: [5][260]u8,
}

@(private = "file")
Aligned_Context :: struct #align (16) {
	ctx: win.CONTEXT,
}

@(private = "file")
Crash_State :: struct {
	installed:      bool,
	handling:       i32,
	previous_filter: win.LPTOP_LEVEL_EXCEPTION_FILTER,
	main_thread:    win.HANDLE,
	watchdog:       ^thread.Thread,
	watchdog_stop:  bool,
	watchdog_pause: bool,
	// The session had a hang report; a later GPU reset is appended to hang.log.
	hang_reported:  bool,
	paths:          Crash_Paths,
	module_paths:   [32][260]u8,
	stack:          [48]uintptr,
	stack_modules:  [48]string,
	stack_bases:    [48]uintptr,
	context_buffer: Aligned_Context,
	hang_module:    [260]u8,
}

@(private = "file")
g_crash: Crash_State

crash_paths :: proc() -> ^Crash_Paths {
	return &g_crash.paths
}

@(private = "file")
crash_paths_init :: proc(dir: string) {
	p := &g_crash.paths
	names := [5]string{"crash.log", "crash.dmp", "hang.log", "hang.dmp", "hang-20s.dmp"}
	out := [5]^string{&p.crash_log, &p.crash_dump, &p.hang_log, &p.hang_dump, &p.hang_dump_late}
	for name, i in names {
		out[i]^ = fmt.bprintf(p.storage[i][:], "%s/%s", dir, name)
	}
}

crash_exception_name :: proc(code: u32) -> string {
	switch code {
	case 0xC0000005: return "EXCEPTION_ACCESS_VIOLATION"
	case 0xC000001D: return "EXCEPTION_ILLEGAL_INSTRUCTION (Odin bounds check or assertion trap)"
	case 0x80000003: return "EXCEPTION_BREAKPOINT"
	case 0xC0000094: return "EXCEPTION_INT_DIVIDE_BY_ZERO"
	case 0xC00000FD: return "EXCEPTION_STACK_OVERFLOW"
	case 0xC0000409: return "STATUS_STACK_BUFFER_OVERRUN (fail fast)"
	case 0xC0000374: return "STATUS_HEAP_CORRUPTION"
	case 0xC0000006: return "EXCEPTION_IN_PAGE_ERROR"
	case 0xC000008E: return "EXCEPTION_FLT_DIVIDE_BY_ZERO"
	case 0xC0000017: return "STATUS_NO_MEMORY"
	case 0xE06D7363: return "C++ exception (likely from a driver or system DLL)"
	}
	return "unknown exception"
}

// Module (path, base) containing `address`, written into `path_buffer`.
crash_module_of :: proc(address: uintptr, path_buffer: ^[260]u8) -> (path: string, base: uintptr) {
	module: win.HMODULE
	if address == 0 || !bool(GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, rawptr(address), &module)) {
		return "", 0
	}
	wide: [260]u16
	length := win.GetModuleFileNameW(module, &wide[0], len(wide))
	if length == 0 { return "", uintptr(module) }
	bytes := win.WideCharToMultiByte(win.CP_UTF8, 0, cstring16(&wide[0]), i32(length), &path_buffer[0], len(path_buffer), nil, nil)
	return string(path_buffer[:max(bytes, 0)]), uintptr(module)
}

@(private = "file")
crash_wide_path :: proc(path: string, wide: ^[520]u16) -> bool {
	length := win.MultiByteToWideChar(win.CP_UTF8, 0, raw_data(path), i32(len(path)), &wide[0], len(wide) - 1)
	if length <= 0 { return false }
	wide[length] = 0
	// The report's folder ("logs" next to the game, or a test folder).
	slash := -1
	for i in 0 ..< int(length) {
		if wide[i] == '/' || wide[i] == '\\' { slash = i }
	}
	if slash > 0 {
		saved := wide[slash]
		wide[slash] = 0
		win.CreateDirectoryW(cstring16(&wide[0]), nil)
		wide[slash] = saved
	}
	return true
}

crash_file_write :: proc(path: string, data: []u8) -> bool {
	wide: [520]u16
	if !crash_wide_path(path, &wide) { return false }
	file := win.CreateFileW(cstring16(&wide[0]), win.GENERIC_WRITE, win.FILE_SHARE_READ, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if file == win.INVALID_HANDLE_VALUE { return false }
	defer win.CloseHandle(file)
	written: win.DWORD
	ok := bool(win.WriteFile(file, raw_data(data), win.DWORD(len(data)), &written, nil))
	win.FlushFileBuffers(file)
	return ok && int(written) == len(data)
}

crash_file_append :: proc(path: string, data: []u8) -> bool {
	wide: [520]u16
	if !crash_wide_path(path, &wide) { return false }
	FILE_APPEND_DATA :: 0x0004
	file := win.CreateFileW(cstring16(&wide[0]), FILE_APPEND_DATA, win.FILE_SHARE_READ, nil, win.OPEN_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if file == win.INVALID_HANDLE_VALUE { return false }
	defer win.CloseHandle(file)
	written: win.DWORD
	ok := bool(win.WriteFile(file, raw_data(data), win.DWORD(len(data)), &written, nil))
	win.FlushFileBuffers(file)
	return ok && int(written) == len(data)
}

// Writes a minidump of this process with CRASH_DUMP_TYPE (stacks and
// metadata, no heap), then scrubs it in place: ProcessThreadData also saves
// the process parameters and environment block, which minidump.scrub zeroes
// (only stacks, code bytes, TEB headers, the PEB and KUSER_SHARED_DATA keep
// their contents). The file is mapped, so no heap or buffer is needed. If it
// cannot be scrubbed it is rewritten without ProcessThreadData. `exception`
// is nil for hang dumps.
crash_write_dump :: proc(path: string, exception: ^win.EXCEPTION_POINTERS, thread_id: win.DWORD) -> bool {
	wide: [520]u16
	if !crash_wide_path(path, &wide) { return false }
	file := win.CreateFileW(cstring16(&wide[0]), win.GENERIC_READ | win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if file == win.INVALID_HANDLE_VALUE { return false }
	defer win.CloseHandle(file)
	info := win.MINIDUMP_EXCEPTION_INFORMATION{ThreadId = thread_id, ExceptionPointers = exception, ClientPointers = false}
	if !win.MiniDumpWriteDump(win.GetCurrentProcess(), win.GetCurrentProcessId(), file, CRASH_DUMP_TYPE, exception != nil ? &info : nil, nil, nil) { return false }
	if crash_scrub_dump_file(file) { return true }
	// Fallback: no process parameters at all.
	distance: win.LARGE_INTEGER
	win.SetFilePointerEx(file, distance, nil, win.FILE_BEGIN)
	win.SetEndOfFile(file)
	without := win.MINIDUMP_TYPE(u32(CRASH_DUMP_TYPE) &~ u32(win.MINIDUMP_TYPE.WithProcessThreadData))
	return bool(win.MiniDumpWriteDump(win.GetCurrentProcess(), win.GetCurrentProcessId(), file, without, exception != nil ? &info : nil, nil, nil))
}

@(private = "file")
crash_scrub_dump_file :: proc(file: win.HANDLE) -> bool {
	size: win.LARGE_INTEGER
	if !win.GetFileSizeEx(file, &size) || size <= 0 || size > 1 << 30 { return false }
	mapping := win.CreateFileMappingW(file, nil, win.PAGE_READWRITE, 0, 0, nil)
	if mapping == nil { return false }
	defer win.CloseHandle(mapping)
	view := win.MapViewOfFile(mapping, win.FILE_MAP_WRITE, 0, 0, 0)
	if view == nil { return false }
	defer win.UnmapViewOfFile(view)
	_, ok := md.scrub(([^]u8)(view)[:int(size)])
	win.FlushViewOfFile(view, 0)
	return ok
}

@(private = "file")
crash_filter :: proc "system" (pointers: ^win.EXCEPTION_POINTERS) -> win.LONG {
	// A second fault while reporting the first must not recurse.
	if sync.atomic_add(&g_crash.handling, 1) != 0 { return win.EXCEPTION_CONTINUE_SEARCH }
	context = runtime.default_context()
	record := pointers.ExceptionRecord
	info := Crash_Info{title = "crash report (unhandled exception)", code = u32(record.ExceptionCode), address = uintptr(record.ExceptionAddress)}
	info.code_name = crash_exception_name(info.code)
	info.module_path, info.module_base = crash_module_of(info.address, &g_crash.module_paths[0])
	if info.code == 0xC0000005 && record.NumberParameters >= 2 {
		switch uintptr(record.ExceptionInformation[0]) {
		case 0: info.access = "read"
		case 1: info.access = "write"
		case 8: info.access = "execute"
		case: info.access = "access"
		}
		info.access_address = uintptr(record.ExceptionInformation[1])
	}
	// The filter runs on the faulting thread above the exception dispatcher,
	// so the walk continues into the frames that faulted.
	frames := int(win.RtlCaptureStackBackTrace(0, len(g_crash.stack), cast([^]rawptr)&g_crash.stack[0], nil))
	module_slots := len(g_crash.module_paths) - 1
	for i in 0 ..< frames {
		if i < module_slots {
			g_crash.stack_modules[i], g_crash.stack_bases[i] = crash_module_of(g_crash.stack[i], &g_crash.module_paths[i + 1])
		}
	}
	info.stack = g_crash.stack[:frames]
	info.stack_modules = g_crash.stack_modules[:min(frames, module_slots)]
	info.stack_bases = g_crash.stack_bases[:min(frames, module_slots)]
	info.detail = "Please send the logs folder: crash.log and crash.dmp (plus gl-debug.log if you ran with --gl-debug)."
	paths := &g_crash.paths
	written := crash_log_write(paths.crash_log, info, .CRASH)
	crash_write_dump(paths.crash_dump, pointers, win.GetCurrentThreadId())
	if written { fmt.eprintln("\n[Crash] Report written to", paths.crash_log) }
	return win.EXCEPTION_CONTINUE_SEARCH
}

// The main thread's instruction pointer (briefly suspending it), and its module.
@(private = "file")
crash_main_thread_address :: proc(path_buffer: ^[260]u8) -> (address: uintptr, module_path: string, module_base: uintptr) {
	if g_crash.main_thread == nil || win.SuspendThread(g_crash.main_thread) == ~win.DWORD(0) { return }
	g_crash.context_buffer.ctx = {}
	g_crash.context_buffer.ctx.ContextFlags = CONTEXT_AMD64_CONTROL
	if win.GetThreadContext(g_crash.main_thread, &g_crash.context_buffer.ctx) {
		address = uintptr(g_crash.context_buffer.ctx.Rip)
	}
	win.ResumeThread(g_crash.main_thread)
	module_path, module_base = crash_module_of(address, path_buffer)
	return
}

@(private = "file")
crash_watchdog :: proc(t: ^thread.Thread) {
	cpu_pin_current_thread_off_game_core()
	last_frame := sync.atomic_load_explicit(&g_diag.frame, .Acquire)
	last_change := time.tick_now()
	stage := 0 // 0 running, 1 hang reported, 2 second dump written
	for !sync.atomic_load(&g_crash.watchdog_stop) {
		time.sleep(time.Duration(g_crash_config.poll_ms) * time.Millisecond)
		frame := sync.atomic_load_explicit(&g_diag.frame, .Acquire)
		if sync.atomic_load(&g_crash.watchdog_pause) {
			// A modal message box (the GPU reset notice) is not a hang.
			last_frame, last_change = frame, time.tick_now()
			continue
		}
		if frame != last_frame {
			if stage > 0 { crash_hang_recovered(time.duration_seconds(time.tick_since(last_change)), frame) }
			last_frame, last_change, stage = frame, time.tick_now(), 0
			continue
		}
		if frame == 0 { continue }
		stalled := time.duration_seconds(time.tick_since(last_change))
		if stage == 0 && stalled >= g_crash_config.hang_seconds {
			stage = 1
			crash_write_hang_report(last_change)
		} else if stage == 1 && stalled >= g_crash_config.second_dump_seconds {
			stage = 2
			crash_write_late_hang_dump(stalled)
		}
	}
}

@(private = "file")
crash_write_hang_report :: proc(stall_tick: time.Tick) {
	title_buffer: [96]u8
	info := Crash_Info{title = fmt.bprintf(title_buffer[:], "hang report (main loop stopped for %.0f seconds)", g_crash_config.hang_seconds), stall_tick = stall_tick, live = true}
	info.address, info.module_path, info.module_base = crash_main_thread_address(&g_crash.hang_module)
	if info.address != 0 {
		info.detail = "Address is the main thread's instruction pointer. Dragging or resizing the window also pauses the loop (phase: poll events). The watchdog keeps watching: a recovery time or a second dump is appended below."
	}
	sync.atomic_store(&g_crash.hang_reported, true)
	paths := &g_crash.paths
	crash_log_write(paths.hang_log, info, .WATCHDOG)
	crash_write_dump(paths.hang_dump, nil, 0)
	fmt.eprintln("[Hang] Main loop has not finished a frame for", g_crash_config.hang_seconds, "seconds; wrote", paths.hang_log)
}

@(private = "file")
crash_write_late_hang_dump :: proc(stalled: f64) {
	paths := &g_crash.paths
	address, module_path, module_base := crash_main_thread_address(&g_crash.hang_module)
	dumped := crash_write_dump(paths.hang_dump_late, nil, 0)
	buffer: [1024]u8
	text := fmt.bprintf(buffer[:], "\n== Still not responding ==\nAfter %.1f s the main thread is at 0x%X = %s+0x%X. %s %s.\n", stalled, address,
		len(module_path) > 0 ? module_path : "(no module)", address - module_base, dumped ? "Wrote" : "Could not write", paths.hang_dump_late)
	crash_log_append(paths.hang_log, text, .WATCHDOG)
	fmt.eprintln("[Hang] Still not responding after", stalled, "seconds; wrote", paths.hang_dump_late)
}

// Main loop resumed after a hang report: append how long it was stuck and
// ask the main loop to check for a GPU reset straight away.
crash_hang_recovered :: proc(stalled: f64, frame: u32) {
	buffer: [512]u8
	text := fmt.bprintf(buffer[:], "\n== Recovery ==\nMain loop recovered after %.1f s (frame %d finished). The GPU reset check that follows is appended below.\n", stalled, frame)
	crash_log_append(g_crash.paths.hang_log, text, .WATCHDOG)
	sync.atomic_store(&g_diag.gl_reset_check_requested, true)
	fmt.eprintf("[Hang] Main loop recovered after %.1f s\n", stalled)
}

crash_hang_was_reported :: proc() -> bool {
	return sync.atomic_load(&g_crash.hang_reported)
}

crash_hang_log_path :: proc() -> string {
	return len(g_crash.paths.hang_log) > 0 ? g_crash.paths.hang_log : HANG_LOG_PATH
}

// Message boxes are modal; the watchdog must not call them a hang.
crash_watchdog_pause :: proc(paused: bool) {
	sync.atomic_store(&g_crash.watchdog_pause, paused)
}

// The GPU reset notice: a plain message box instead of a frozen window.
gpu_reset_show_message :: proc(text: string) {
	wide: [1024]u16
	length := win.MultiByteToWideChar(win.CP_UTF8, 0, raw_data(text), i32(len(text)), &wide[0], len(wide) - 1)
	if length <= 0 { return }
	wide[length] = 0
	crash_watchdog_pause(true)
	defer crash_watchdog_pause(false)
	win.MessageBoxW(nil, cstring16(&wide[0]), win.L("Krodin: graphics driver reset"), win.MB_OK | win.MB_ICONERROR | win.MB_TOPMOST)
}

// Installs the unhandled-exception filter and the hang watchdog. Call from the
// main thread. Reports include the GL strings once diagnostics_capture_gl_info
// has run; the watchdog ignores the time before the first frame.
crash_handler_install :: proc() {
	if g_crash.installed { return }
	g_crash.installed = true
	crash_paths_init(g_crash_config.log_dir)
	g_crash.previous_filter = win.SetUnhandledExceptionFilter(crash_filter)
	process := win.GetCurrentProcess()
	win.DuplicateHandle(process, win.GetCurrentThread(), process, &g_crash.main_thread, 0, false, win.DUPLICATE_SAME_ACCESS)
	g_crash.watchdog = thread.create(crash_watchdog, name = "Krodin hang watchdog")
	if g_crash.watchdog != nil { thread.start(g_crash.watchdog) }
}

crash_handler_uninstall :: proc() {
	if !g_crash.installed { return }
	sync.atomic_store(&g_crash.watchdog_stop, true)
	if g_crash.watchdog != nil {
		thread.join(g_crash.watchdog)
		thread.destroy(g_crash.watchdog)
		g_crash.watchdog = nil
	}
	win.SetUnhandledExceptionFilter(g_crash.previous_filter)
	g_crash.previous_filter = nil
	if g_crash.main_thread != nil { win.CloseHandle(g_crash.main_thread); g_crash.main_thread = nil }
	g_crash.installed = false
	g_crash.watchdog_stop = false
	g_crash.watchdog_pause = false
	g_crash.hang_reported = false
}


// Removes every environment variable whose name env_name_is_secret matches
// from this process's environment and appends the names (allocated) to
// `names`. Each value is first overwritten in place with '*'s of the same
// length, so no stale copy is left in the environment block, then deleted.
// Values are never read.
env_scrub_secrets :: proc(names: ^[dynamic]string) {
	block := win.GetEnvironmentStringsW()
	if block == nil { return }
	first := len(names)
	entries := ([^]u16)(block)
	for at := 0; entries[at] != 0; {
		length := 0
		for entries[at + length] != 0 { length += 1 }
		entry := entries[at:at + length]
		at += length + 1
		// Skip the name's first character: "=C:=C:\dir" entries start with '='.
		equals := -1
		for c, i in entry[1:] { if c == '=' { equals = i + 1; break } }
		if equals <= 0 { continue }
		name, err := win.wstring_to_utf8_alloc(cstring16(&entry[0]), equals, context.allocator)
		if err != nil { continue }
		if env_name_is_secret(name) { append(names, name) } else { delete(name) }
	}
	win.FreeEnvironmentStringsW(block)
	for name in names[first:] {
		wide := win.utf8_to_wstring(name, context.temp_allocator)
		size := win.GetEnvironmentVariableW(wide, nil, 0)
		if size > 1 {
			stars := make([]u16, int(size), context.temp_allocator)
			for &c in stars[:size - 1] { c = '*' }
			win.SetEnvironmentVariableW(wide, cstring16(&stars[0]))
		}
		win.SetEnvironmentVariableW(wide, nil)
	}
}
