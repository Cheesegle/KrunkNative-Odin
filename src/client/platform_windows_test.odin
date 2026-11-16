#+build windows

package main

import "core:log"
import "core:testing"
import "core:thread"
import win "core:sys/windows"

when ODIN_TEST {
	// The test executable is built from this package, so it carries the same
	// exports as krodin_client.exe; look them up the way the drivers do.
	@(test)
	platform_gpu_hints_are_exported :: proc(t: ^testing.T) {
		exe := win.HMODULE(win.GetModuleHandleW(nil))
		nvidia := (^u32)(win.GetProcAddress(exe, "NvOptimusEnablement"))
		amd := (^i32)(win.GetProcAddress(exe, "AmdPowerXpressRequestHighPerformance"))
		if !testing.expect(t, nvidia != nil, "NvOptimusEnablement must be in the export table") do return
		if !testing.expect(t, amd != nil, "AmdPowerXpressRequestHighPerformance must be in the export table") do return
		testing.expect_value(t, nvidia^, 1)
		testing.expect_value(t, amd^, 1)
		testing.expect(t, platform_gpu_exports_present())
	}

	@(test)
	platform_mmcss_missing_dll_fails_gracefully :: proc(t: ^testing.T) {
		api, failure := mmcss_api_load("krodin_missing_avrt.dll")
		testing.expect(t, api.module == nil && api.set == nil && api.revert == nil)
		testing.expect(t, len(failure) > 0)
		registration, register_failure := mmcss_register_current_thread(&api)
		testing.expect(t, registration.handle == nil)
		testing.expect_value(t, register_failure, "unavailable")
		testing.expect(t, !mmcss_revert_current_thread(&api, &registration), "reverting nothing must be a no-op")
		_, nil_failure := mmcss_register_current_thread(nil)
		testing.expect_value(t, nil_failure, "unavailable")
	}

	@(test)
	platform_mmcss_missing_procs_fail_gracefully :: proc(t: ^testing.T) {
		// version.dll is a System32 DLL without the avrt functions.
		api, failure := mmcss_api_load("version.dll")
		testing.expect(t, api.module == nil && api.set == nil, "a DLL without the functions must be released")
		testing.expect(t, len(failure) > 0)
	}

	@(test)
	platform_power_throttling_handles_missing_and_failing_api :: proc(t: ^testing.T) {
		result, error := power_throttling_opt_out(nil)
		testing.expect_value(t, result, Power_Throttling_Result.Unavailable)

		// Windows 10 rejects the timer-resolution flag: fall back to execution speed.
		g_power_test_calls = 0
		rejects_timer_flag :: proc "system" (process: win.HANDLE, class: i32, information: rawptr, size: win.DWORD) -> win.BOOL {
			g_power_test_calls += 1
			state := (^PROCESS_POWER_THROTTLING_STATE)(information)
			if class != PROCESS_INFORMATION_CLASS_POWER_THROTTLING || size != size_of(PROCESS_POWER_THROTTLING_STATE) || state.Version != 1 || state.StateMask != 0 { return false }
			if state.ControlMask & PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION != 0 {
				win.SetLastError(win.ERROR_INVALID_PARAMETER)
				return false
			}
			return state.ControlMask == PROCESS_POWER_THROTTLING_EXECUTION_SPEED
		}
		result, error = power_throttling_opt_out(rejects_timer_flag)
		testing.expect_value(t, result, Power_Throttling_Result.Execution_Speed)
		testing.expect_value(t, error, win.ERROR_INVALID_PARAMETER)
		testing.expect_value(t, g_power_test_calls, 2)

		always_fails :: proc "system" (process: win.HANDLE, class: i32, information: rawptr, size: win.DWORD) -> win.BOOL {
			win.SetLastError(win.ERROR_ACCESS_DENIED)
			return false
		}
		result, error = power_throttling_opt_out(always_fails)
		testing.expect_value(t, result, Power_Throttling_Result.Failed)
		testing.expect_value(t, error, win.ERROR_ACCESS_DENIED)
		testing.expect(t, len(power_throttling_describe(result, error)) > 0)
	}

	g_power_test_calls: int

	// Real calls on this machine. MMCSS registration is per thread, so it runs
	// on its own short-lived thread and is reverted before the thread ends.
	@(test)
	platform_mmcss_and_power_throttling_work_here :: proc(t: ^testing.T) {
		result, error := power_throttling_opt_out(power_throttling_resolve())
		testing.expectf(t, result == .Ok || result == .Execution_Speed, "power throttling opt-out: %v (error %d)", result, error)

		Probe :: struct { loaded, registered, reverted: bool, task_index, error: win.DWORD }
		probe: Probe
		worker := thread.create_and_start_with_data(&probe, proc(data: rawptr) {
			probe := (^Probe)(data)
			api, _ := mmcss_api_load()
			probe.loaded = api.set != nil
			if !probe.loaded { return }
			defer mmcss_api_unload(&api)
			registration, _ := mmcss_register_current_thread(&api)
			if registration.handle == nil { probe.error = win.GetLastError(); return }
			probe.registered = true
			probe.task_index = registration.task_index
			probe.reverted = mmcss_revert_current_thread(&api, &registration)
		})
		if !testing.expect(t, worker != nil) do return
		thread.join(worker)
		thread.destroy(worker)
		if !testing.expect(t, probe.loaded, "avrt.dll must load on Windows") do return
		testing.expectf(t, probe.registered, "MMCSS Games registration failed (error %d)", probe.error)
		testing.expect(t, probe.reverted, "MMCSS revert must succeed")
		log.infof("%s; MMCSS Games registered=%v (task %d) reverted=%v", power_throttling_describe(result, error), probe.registered, probe.task_index, probe.reverted)
	}
}
