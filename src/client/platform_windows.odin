#+build windows

package main

import "core:fmt"
import win "core:sys/windows"

// Windows platform integrations (Krodin's own; Krunker runs in a browser).
//
// 1. Hybrid-GPU laptops: NVIDIA Optimus and AMD PowerXpress drivers look these
//    two symbols up in the EXE's export table at process start and run the
//    process on the dedicated GPU when the value is 1. They must stay real
//    exports of krodin_client.exe; tools/check_gpu_exports.py verifies a build.
// 2. MMCSS: the render thread (and the raw mouse input thread) join the
//    "Games" multimedia task, so the scheduler favours them under load.
// 3. Power throttling: opt out of EcoQoS execution-speed throttling, and stop
//    Windows 11 ignoring timeBeginPeriod(1) while the window is hidden or
//    minimized (the FPS limiter and waitable timers rely on that resolution).
//
// Everything is resolved at run time, so a missing avrt.dll or an older
// Windows only logs a line; nothing here can stop the client from starting.

@(export, link_name = "NvOptimusEnablement")
NvOptimusEnablement: u32 = 1

@(export, link_name = "AmdPowerXpressRequestHighPerformance")
AmdPowerXpressRequestHighPerformance: i32 = 1

// Reads the hints back through the export table, the way the drivers do.
platform_gpu_exports_present :: proc() -> bool {
	exe := win.HMODULE(win.GetModuleHandleW(nil))
	nvidia := (^u32)(win.GetProcAddress(exe, "NvOptimusEnablement"))
	amd := (^i32)(win.GetProcAddress(exe, "AmdPowerXpressRequestHighPerformance"))
	return nvidia != nil && amd != nil && nvidia^ == 1 && amd^ == 1
}

// ---------------------------------------------------------------------------
// MMCSS (avrt.dll)

MMCSS_DLL :: "avrt.dll"
MMCSS_GAMES_TASK :: "Games"

Mmcss_Set_Proc :: #type proc "system" (task_name: win.LPCWSTR, task_index: ^win.DWORD) -> win.HANDLE
Mmcss_Revert_Proc :: #type proc "system" (handle: win.HANDLE) -> win.BOOL

Mmcss_Api :: struct {
	module: win.HMODULE,
	set:    Mmcss_Set_Proc,
	revert: Mmcss_Revert_Proc,
}

Mmcss_Thread :: struct {
	handle:     win.HANDLE,
	task_index: win.DWORD,
}

// Loads avrt.dll from System32 only. On failure the api is empty, the module
// is released, and `failure` says why.
mmcss_api_load :: proc(dll := MMCSS_DLL) -> (api: Mmcss_Api, failure: string) {
	name := win.utf8_to_wstring(dll, context.temp_allocator)
	module := win.LoadLibraryExW(name, nil, {.LOAD_LIBRARY_SEARCH_SYSTEM32})
	if module == nil { return {}, fmt.tprintf("%s unavailable (error %d)", dll, win.GetLastError()) }
	set := Mmcss_Set_Proc(win.GetProcAddress(module, "AvSetMmThreadCharacteristicsW"))
	revert := Mmcss_Revert_Proc(win.GetProcAddress(module, "AvRevertMmThreadCharacteristics"))
	if set == nil || revert == nil {
		win.FreeLibrary(module)
		return {}, fmt.tprintf("%s lacks the MMCSS functions", dll)
	}
	return {module = module, set = set, revert = revert}, ""
}

mmcss_api_unload :: proc(api: ^Mmcss_Api) {
	if api.module != nil { win.FreeLibrary(api.module) }
	api^ = {}
}

// Registers the calling thread with the MMCSS "Games" task. Safe with an empty api.
mmcss_register_current_thread :: proc(api: ^Mmcss_Api) -> (thread: Mmcss_Thread, failure: string) {
	if api == nil || api.set == nil { return {}, "unavailable" }
	index: win.DWORD
	handle := api.set(win.L(MMCSS_GAMES_TASK), &index)
	if handle == nil { return {}, fmt.tprintf("failed (error %d)", win.GetLastError()) }
	return {handle = handle, task_index = index}, ""
}

// Reverts a registration made on the calling thread. Safe to call twice.
mmcss_revert_current_thread :: proc(api: ^Mmcss_Api, thread: ^Mmcss_Thread) -> bool {
	if thread.handle == nil { return false }
	ok := api != nil && api.revert != nil && bool(api.revert(thread.handle))
	thread^ = {}
	return ok
}

mmcss_describe :: proc(task: string, thread: Mmcss_Thread, failure: string) -> string {
	if thread.handle == nil { return fmt.tprintf("MMCSS %s %s", task, failure) }
	return fmt.tprintf("MMCSS %s ok (task %d)", task, thread.task_index)
}

// ---------------------------------------------------------------------------
// Power throttling (kernel32 SetProcessInformation, Windows 8 and later; the
// power throttling class needs Windows 10 1709, the timer flag Windows 11).

PROCESS_POWER_THROTTLING_CURRENT_VERSION :: 1
PROCESS_POWER_THROTTLING_EXECUTION_SPEED :: 0x1
PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION :: 0x4
PROCESS_INFORMATION_CLASS_POWER_THROTTLING :: 4 // ProcessPowerThrottling

PROCESS_POWER_THROTTLING_STATE :: struct {
	Version, ControlMask, StateMask: win.ULONG,
}

Set_Process_Information_Proc :: #type proc "system" (process: win.HANDLE, class: i32, information: rawptr, size: win.DWORD) -> win.BOOL

Power_Throttling_Result :: enum {
	Unavailable,      // No SetProcessInformation (Windows 7).
	Ok,               // Execution speed and timer resolution.
	Execution_Speed,  // Timer flag rejected (Windows 10): execution speed only.
	Failed,
}

power_throttling_resolve :: proc() -> Set_Process_Information_Proc {
	kernel32 := win.HMODULE(win.GetModuleHandleW(win.L("kernel32.dll")))
	if kernel32 == nil { return nil }
	return Set_Process_Information_Proc(win.GetProcAddress(kernel32, "SetProcessInformation"))
}

// Opts the process out of power throttling: the control bits name what we
// decide, a zero state mask says "never throttle".
power_throttling_opt_out :: proc(set_information: Set_Process_Information_Proc) -> (result: Power_Throttling_Result, error: win.DWORD) {
	if set_information == nil { return .Unavailable, 0 }
	state := PROCESS_POWER_THROTTLING_STATE{
		Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION,
		ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED | PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION,
		StateMask = 0,
	}
	process := win.GetCurrentProcess()
	if set_information(process, PROCESS_INFORMATION_CLASS_POWER_THROTTLING, &state, size_of(state)) { return .Ok, 0 }
	error = win.GetLastError()
	state.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED
	if set_information(process, PROCESS_INFORMATION_CLASS_POWER_THROTTLING, &state, size_of(state)) { return .Execution_Speed, error }
	return .Failed, win.GetLastError()
}

power_throttling_describe :: proc(result: Power_Throttling_Result, error: win.DWORD) -> string {
	switch result {
	case .Ok:              return "power throttling opt-out ok"
	case .Execution_Speed: return fmt.tprintf("power throttling opt-out execution speed only (timer flag error %d)", error)
	case .Unavailable:     return "power throttling opt-out unavailable"
	case .Failed:          return fmt.tprintf("power throttling opt-out failed (error %d)", error)
	}
	return ""
}

// ---------------------------------------------------------------------------
// Client entry points (main thread).

@(private = "file")
g_platform: struct {
	mmcss:      Mmcss_Api,
	main_mmcss: Mmcss_Thread,
}

client_platform_init :: proc() {
	power, power_error := power_throttling_opt_out(power_throttling_resolve())
	api, load_failure := mmcss_api_load()
	g_platform.mmcss = api
	failure := load_failure
	if load_failure == "" { g_platform.main_mmcss, failure = mmcss_register_current_thread(&g_platform.mmcss) }
	fmt.printfln("[Platform] dGPU exports %s, %s, %s",
		platform_gpu_exports_present() ? "present" : "MISSING",
		mmcss_describe(MMCSS_GAMES_TASK, g_platform.main_mmcss, failure),
		power_throttling_describe(power, power_error))
}

client_platform_fini :: proc() {
	mmcss_revert_current_thread(&g_platform.mmcss, &g_platform.main_mmcss)
	// avrt.dll stays loaded: the raw input thread may still hold a
	// registration until it is joined, and process exit unloads it anyway.
}

// Called on another thread (the raw mouse input thread) after
// client_platform_init. Returns an empty registration when MMCSS is missing.
client_platform_mmcss_register_thread :: proc(label: string) -> Mmcss_Thread {
	if g_platform.mmcss.set == nil { return {} }
	thread, failure := mmcss_register_current_thread(&g_platform.mmcss)
	if thread.handle == nil { fmt.eprintfln("[Platform] %s thread: %s", label, mmcss_describe(MMCSS_GAMES_TASK, thread, failure)) }
	return thread
}

client_platform_mmcss_revert_thread :: proc(thread: ^Mmcss_Thread) {
	mmcss_revert_current_thread(&g_platform.mmcss, thread)
}
