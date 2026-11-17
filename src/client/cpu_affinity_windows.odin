package main

import "core:fmt"
import win "core:sys/windows"

// Windows side of CPU pinning (see cpu_affinity.odin).
//
// - The main thread gets hard group affinity and its selected CPU Sets on the
//   game core only, so it never runs on core 0 or anywhere else.
// - The process default CPU Sets are every core but the game core. Threads
//   without their own CPU Sets follow them, including ones this code never
//   sees created: curl's DNS resolver, audio, GLFW and driver threads.
// - Threads Krodin starts itself (HTTP jobs, raw mouse input, crash watchdog)
//   also take hard affinity off the game core (cpu_pin_current_thread_off_game_core).

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32 {
	SetThreadGroupAffinity :: proc(hThread: win.HANDLE, GroupAffinity: ^win.GROUP_AFFINITY, PreviousGroupAffinity: ^win.GROUP_AFFINITY) -> win.BOOL ---
	GetThreadGroupAffinity :: proc(hThread: win.HANDLE, GroupAffinity: ^win.GROUP_AFFINITY) -> win.BOOL ---
}

CPU_MAX_GROUPS :: 32

Cpu_Pinning :: struct {
	active:      bool,
	game:        Cpu_Core,
	// Logical processors each group has, game core removed (for threads that
	// must stay off it).
	other_masks: [CPU_MAX_GROUPS]u64,
}

g_cpu_pinning: Cpu_Pinning

// Every logical processor the OS reports, from GetSystemCpuSetInformation.
cpu_logical_query :: proc(allocator := context.allocator) -> [dynamic]Cpu_Logical {
	result := make([dynamic]Cpu_Logical, allocator)
	needed: win.ULONG
	win.GetSystemCpuSetInformation(nil, 0, &needed, nil, 0)
	if needed == 0 { return result }
	// The records hold a DWORD64, so the buffer must be 8-byte aligned (a
	// []u8 from an arena is not, and the call then fails).
	words := make([]u64, (int(needed) + 7) / 8, context.temp_allocator)
	buffer := ([^]u8)(raw_data(words))
	if !win.GetSystemCpuSetInformation(cast(^win.SYSTEM_CPU_SET_INFORMATION)buffer, needed, &needed, nil, 0) { return result }
	offset := 0
	for offset + size_of(win.DWORD) * 2 <= int(needed) {
		info := cast(^win.SYSTEM_CPU_SET_INFORMATION)&buffer[offset]
		if info.Size == 0 { break }
		if info.Type == .CpuSetInformation {
			set := info.CpuSet
			append(&result, Cpu_Logical{
				id = u32(set.Id), group = u16(set.Group), index = u8(set.LogicalProcessorIndex),
				core = u8(set.CoreIndex), efficiency = u8(set.EfficiencyClass), realtime = set.RealTime != 0,
			})
		}
		offset += int(info.Size)
	}
	return result
}

// Pins the calling thread (the game thread) and moves everything else off
// its core. Returns a line for the log.
cpu_pinning_apply :: proc() -> string {
	logical := cpu_logical_query(context.temp_allocator)
	cores := cpu_cores_from_logical(logical[:], context.temp_allocator)
	pick, ok := cpu_pick_game_core(cores[:])
	if !ok { return fmt.tprintf("CPU pinning skipped: %d physical cores, none besides core 0 to give the game", len(cores)) }
	game := cores[pick]

	pinning := Cpu_Pinning{game = game}
	others := make([dynamic]u32, context.temp_allocator)
	for &core, i in cores {
		if i == pick || int(core.group) >= CPU_MAX_GROUPS { continue }
		pinning.other_masks[core.group] |= core.mask
		append(&others, ..core.ids[:core.id_count])
	}

	thread := win.GetCurrentThread()
	affinity := win.GROUP_AFFINITY{Mask = win.KAFFINITY(game.mask), Group = game.group}
	if !SetThreadGroupAffinity(thread, &affinity, nil) {
		return fmt.tprintf("CPU pinning failed: game thread affinity (error %d)", win.GetLastError())
	}
	game_ids := game.ids
	win.SetThreadSelectedCpuSets(thread, &game_ids[0], win.ULONG(game.id_count))
	defaults_ok := len(others) > 0 && bool(win.SetProcessDefaultCpuSets(win.GetCurrentProcess(), &others[0], win.ULONG(len(others))))
	pinning.active = true
	g_cpu_pinning = pinning
	return fmt.tprintf("game thread on %s; %d other cores for networking and helper threads%s",
		cpu_core_describe(game, cpu_cores_hybrid(cores[:])), len(cores) - 1,
		defaults_ok ? "" : fmt.tprintf(" (process default CPU sets failed, error %d)", win.GetLastError()))
}

// Keeps the calling thread off the game core (hard affinity, within its
// current processor group). A no-op when pinning is off.
cpu_pin_current_thread_off_game_core :: proc() {
	if !g_cpu_pinning.active { return }
	thread := win.GetCurrentThread()
	current: win.GROUP_AFFINITY
	if !GetThreadGroupAffinity(thread, &current) || int(current.Group) >= CPU_MAX_GROUPS { return }
	mask := g_cpu_pinning.other_masks[current.Group]
	if mask == 0 { return }
	affinity := win.GROUP_AFFINITY{Mask = win.KAFFINITY(mask), Group = current.Group}
	SetThreadGroupAffinity(thread, &affinity, nil)
}

// The calling thread's group affinity (tests and diagnostics).
cpu_current_thread_affinity :: proc() -> (group: u16, mask: u64, ok: bool) {
	current: win.GROUP_AFFINITY
	if !GetThreadGroupAffinity(win.GetCurrentThread(), &current) { return }
	return current.Group, u64(current.Mask), true
}

// Undoes the process-wide part (tests). The pinned thread keeps its affinity.
cpu_pinning_reset :: proc() {
	win.SetProcessDefaultCpuSets(win.GetCurrentProcess(), nil, 0)
	g_cpu_pinning = {}
}
