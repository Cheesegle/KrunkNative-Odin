#+build windows
package main

import "core:fmt"
import "core:strings"
import win "core:sys/windows"
import dxgi "vendor:directx/dxgi"

// System facts for crash and hang reports (Windows). Gathered once at startup
// (diagnostics_capture_system_info); the report only adds free RAM and the
// AC/battery state, two syscalls that need no heap.

foreign import powrprof "system:PowrProf.lib"

@(default_calling_convention = "system")
foreign powrprof {
	PowerGetActiveScheme :: proc(UserRootPowerKey: win.HKEY, ActivePolicyGuid: ^^win.GUID) -> win.DWORD ---
	PowerReadFriendlyName :: proc(RootPowerKey: win.HKEY, SchemeGuid: ^win.GUID, SubGroupOfPowerSettingsGuid: ^win.GUID, PowerSettingGuid: ^win.GUID, Buffer: [^]u8, BufferSize: ^win.DWORD) -> win.DWORD ---
}

@(private = "file")
wide_to_utf8 :: proc(wide: []u16, out: []u8) -> string {
	length := 0
	for length < len(wide) && wide[length] != 0 { length += 1 }
	if length == 0 || len(out) == 0 { return "" }
	bytes := win.WideCharToMultiByte(win.CP_UTF8, 0, cstring16(&wide[0]), i32(length), &out[0], i32(len(out)), nil, nil)
	return string(out[:max(bytes, 0)])
}

@(private = "file")
registry_string :: proc(subkey, value: cstring16, out: []u8) -> string {
	wide: [256]u16
	size := win.DWORD(size_of(wide) - 2)
	if win.RegGetValueW(win.HKEY_LOCAL_MACHINE, subkey, value, win.RRF_RT_REG_SZ, nil, &wide[0], &size) != 0 { return "" }
	return strings.trim_space(wide_to_utf8(wide[:], out))
}

@(private = "file")
registry_dword :: proc(subkey, value: cstring16) -> (result: u32, ok: bool) {
	size := win.DWORD(size_of(result))
	ok = win.RegGetValueW(win.HKEY_LOCAL_MACHINE, subkey, value, win.RRF_RT_REG_DWORD, nil, &result, &size) == 0
	return
}

// Names the calling thread; the name shows in debuggers, in minidumps
// (ThreadNamesStream) and in tools/symbolicate's output.
diagnostics_name_thread :: proc(name: string) {
	wide: [64]u16
	length := win.MultiByteToWideChar(win.CP_UTF8, 0, raw_data(name), i32(len(name)), &wide[0], len(wide) - 1)
	if length <= 0 { return }
	wide[length] = 0
	win.SetThreadDescription(win.GetCurrentThread(), cstring16(&wide[0]))
}

diagnostics_vendor_name :: proc(vendor_id: u32) -> string {
	switch vendor_id {
	case 0x8086: return "Intel"
	case 0x10DE: return "NVIDIA"
	case 0x1002, 0x1022: return "AMD"
	case 0x1414: return "Microsoft"
	case 0x5143: return "Qualcomm"
	}
	return "unknown vendor"
}

@(private = "file")
capture_adapters :: proc(b: ^strings.Builder) {
	factory: ^dxgi.IFactory1
	if dxgi.CreateDXGIFactory1(dxgi.IFactory1_UUID, (^rawptr)(&factory)) < 0 || factory == nil {
		strings.write_string(b, "Display adapters: (DXGI unavailable)\n")
		return
	}
	defer factory->Release()
	strings.write_string(b, "Display adapters:\n")
	for index in u32(0) ..< 16 {
		adapter: ^dxgi.IAdapter1
		if factory->EnumAdapters1(index, &adapter) < 0 || adapter == nil { break }
		desc: dxgi.ADAPTER_DESC1
		if adapter->GetDesc1(&desc) >= 0 {
			name_buffer: [256]u8
			name := wide_to_utf8(desc.Description[:], name_buffer[:])
			// The user-mode driver version, as Device Manager shows it.
			version: win.LARGE_INTEGER
			driver: [64]u8
			driver_text := "unknown"
			if adapter->CheckInterfaceSupport(dxgi.IDevice_UUID, &version) >= 0 {
				v := u64(version)
				driver_text = fmt.bprintf(driver[:], "%d.%d.%d.%d", v >> 48, (v >> 32) & 0xFFFF, (v >> 16) & 0xFFFF, v & 0xFFFF)
			}
			software := .SOFTWARE in desc.Flags
			fmt.sbprintf(b, "  %d: %s (%s 0x%04X:0x%04X), driver %s, VRAM %d MB, shared %d MB%s\n", index, name,
				diagnostics_vendor_name(desc.VendorId), desc.VendorId, desc.DeviceId, driver_text,
				u64(desc.DedicatedVideoMemory) / (1024 * 1024), u64(desc.SharedSystemMemory) / (1024 * 1024), software ? ", software" : "")
		}
		adapter->Release()
	}
}

// Startup only: the Windows version, CPU, total RAM and adapters.
diagnostics_capture_system_info :: proc() {
	b := strings.builder_from_bytes(g_diag.system_text[:])
	version := win.OSVERSIONINFOEXW{dwOSVersionInfoSize = size_of(win.OSVERSIONINFOEXW)}
	win.RtlGetVersion(&version)
	current_version :: `SOFTWARE\Microsoft\Windows NT\CurrentVersion`
	display_buffer, edition_buffer: [64]u8
	display := registry_string(win.L(current_version), win.L("DisplayVersion"), display_buffer[:])
	edition := registry_string(win.L(current_version), win.L("EditionID"), edition_buffer[:])
	revision, _ := registry_dword(win.L(current_version), win.L("UBR"))
	fmt.sbprintf(&b, "Windows: %s %s %s (%d.%d.%d.%d)\n", version.dwBuildNumber >= 22000 ? "11" : "10", edition, display,
		version.dwMajorVersion, version.dwMinorVersion, version.dwBuildNumber, revision)

	cpu_buffer: [128]u8
	cpu := registry_string(win.L(`HARDWARE\DESCRIPTION\System\CentralProcessor\0`), win.L("ProcessorNameString"), cpu_buffer[:])
	info: win.SYSTEM_INFO
	win.GetSystemInfo(&info)
	cores := 0
	processors: [256]win.SYSTEM_LOGICAL_PROCESSOR_INFORMATION
	size := win.DWORD(size_of(processors))
	if win.GetLogicalProcessorInformation(&processors[0], &size) {
		for entry in processors[:int(size) / size_of(win.SYSTEM_LOGICAL_PROCESSOR_INFORMATION)] {
			if entry.Relationship == .RelationProcessorCore { cores += 1 }
		}
	}
	fmt.sbprintf(&b, "CPU: %s, %d cores, %d logical processors\n", len(cpu) > 0 ? cpu : "unknown", cores, info.dwNumberOfProcessors)

	memory := win.MEMORYSTATUSEX{dwLength = size_of(win.MEMORYSTATUSEX)}
	if win.GlobalMemoryStatusEx(&memory) {
		fmt.sbprintf(&b, "RAM total: %.1f GB\n", f64(memory.ullTotalPhys) / (1024 * 1024 * 1024))
	}
	capture_adapters(&b)
	g_diag.system_len = len(strings.to_string(b))
	diagnostics_capture_power_plan()
}

diagnostics_capture_power_plan :: proc() {
	scheme: ^win.GUID
	if PowerGetActiveScheme(nil, &scheme) != 0 || scheme == nil { return }
	defer win.LocalFree(scheme)
	wide: [64]u16
	size := win.DWORD(size_of(wide) - 2)
	if PowerReadFriendlyName(nil, scheme, nil, nil, ([^]u8)(&wide[0]), &size) != 0 { return }
	g_diag.power_plan_len = len(wide_to_utf8(wide[:], g_diag.power_plan[:]))
}

// Free RAM and the power source: cheap syscalls without the heap, so the
// crash filter can call this too. `live` also re-reads the power plan.
diagnostics_write_live_system :: proc(b: ^strings.Builder, live: bool) {
	memory := win.MEMORYSTATUSEX{dwLength = size_of(win.MEMORYSTATUSEX)}
	if win.GlobalMemoryStatusEx(&memory) {
		gb :: 1024 * 1024 * 1024
		fmt.sbprintf(b, "RAM free: %.1f of %.1f GB (%d%% in use)\n", f64(memory.ullAvailPhys) / gb, f64(memory.ullTotalPhys) / gb, memory.dwMemoryLoad)
	}
	if live { diagnostics_capture_power_plan() }
	power: win.SYSTEM_POWER_STATUS
	plan := g_diag.power_plan_len > 0 ? string(g_diag.power_plan[:g_diag.power_plan_len]) : "unknown"
	if win.GetSystemPowerStatus(&power) {
		source := power.ACLineStatus == .Online ? "AC power" : power.ACLineStatus == .Offline ? "battery" : "unknown power source"
		if .No_Battery in power.BatteryFlag || power.BatteryLifePercent == 255 {
			fmt.sbprintf(b, "Power: %s, no battery; power plan: %s\n", source, plan)
		} else {
			fmt.sbprintf(b, "Power: %s, battery %d%%%s; power plan: %s\n", source, power.BatteryLifePercent, .Charging in power.BatteryFlag ? " (charging)" : "", plan)
		}
	} else {
		fmt.sbprintf(b, "Power plan: %s\n", plan)
	}
}

// WM_DISPLAYCHANGE from the game window's procedure: the desktop resolution
// changed (an exclusive fullscreen switch, a driver reset, a monitor change).
diagnostics_display_changed :: proc "contextless" (lparam: win.LPARAM) {
	diag_event(.WM_DISPLAYCHANGE, i32(lparam & 0xFFFF), i32((lparam >> 16) & 0xFFFF))
	g_diag.monitors_stale = true
}
