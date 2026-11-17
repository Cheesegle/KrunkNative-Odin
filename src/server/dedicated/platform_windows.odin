package dedicated

import "core:sync"
import "core:time"
import win "core:sys/windows"

// Windows tick sleeping: a high-resolution waitable timer (Windows 10 1803+)
// wakes within a fraction of a millisecond without busy-spinning. Older
// systems fall back to a normal waitable timer with the multimedia timer
// period raised to 1 ms.

Precise_Sleeper :: struct {
	timer:           win.HANDLE,
	high_resolution: bool,
	raised_period:   bool,
}

precise_sleeper_init :: proc(sleeper: ^Precise_Sleeper) {
	sleeper^ = {}
	sleeper.timer = win.CreateWaitableTimerExW(nil, nil, win.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win.TIMER_ALL_ACCESS)
	if sleeper.timer != nil {
		sleeper.high_resolution = true
		return
	}
	sleeper.timer = win.CreateWaitableTimerExW(nil, nil, 0, win.TIMER_ALL_ACCESS)
	win.timeBeginPeriod(1)
	sleeper.raised_period = true
}

precise_sleeper_destroy :: proc(sleeper: ^Precise_Sleeper) {
	if sleeper.timer != nil {
		win.CloseHandle(sleeper.timer)
	}
	if sleeper.raised_period {
		win.timeEndPeriod(1)
	}
	sleeper^ = {}
}

precise_sleeper_kind :: proc(sleeper: ^Precise_Sleeper) -> string {
	switch {
	case sleeper.high_resolution: return "high-resolution waitable timer"
	case sleeper.timer != nil:    return "waitable timer (1 ms period)"
	}
	return "Sleep (1 ms period)"
}

precise_sleep :: proc(sleeper: ^Precise_Sleeper, ns: i64) {
	if ns <= 0 {
		return
	}
	if sleeper.timer != nil {
		// Relative due time in 100 ns units is negative.
		due := win.LARGE_INTEGER(-max(1, ns / 100))
		if win.SetWaitableTimerEx(sleeper.timer, &due, 0, nil, nil, nil, 0) {
			win.WaitForSingleObject(sleeper.timer, win.INFINITE)
			return
		}
	}
	time.sleep(time.Duration(ns))
}

// ---------------------------------------------------------------------------
// Shutdown: Ctrl+C, Ctrl+Break and closing the console window.

@(private)
g_quit_requested: bool
@(private)
g_shutdown_done: bool

quit_requested :: proc() -> bool {
	return sync.atomic_load(&g_quit_requested)
}

request_quit :: proc() {
	sync.atomic_store(&g_quit_requested, true)
}

// shutdown_finished lets a console-close handler return once cleanup is done.
shutdown_finished :: proc() {
	sync.atomic_store(&g_shutdown_done, true)
}

@(private)
console_ctrl_handler :: proc "system" (ctrl_type: win.DWORD) -> win.BOOL {
	switch ctrl_type {
	case win.CTRL_C_EVENT, win.CTRL_BREAK_EVENT:
		sync.atomic_store(&g_quit_requested, true)
		return true
	case win.CTRL_CLOSE_EVENT, win.CTRL_LOGOFF_EVENT, win.CTRL_SHUTDOWN_EVENT:
		// Windows ends the process when this handler returns, so give the main
		// loop up to ~3 s to close sockets first (the system allows 5 s).
		sync.atomic_store(&g_quit_requested, true)
		for _ in 0 ..< 300 {
			if sync.atomic_load(&g_shutdown_done) { break }
			win.Sleep(10)
		}
		return true
	}
	return false
}

install_shutdown_handlers :: proc() -> bool {
	return bool(win.SetConsoleCtrlHandler(console_ctrl_handler, true))
}
