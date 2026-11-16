package main

import win "core:sys/windows"

// Raise the Windows timer resolution to ~1 ms for the client's lifetime, as the
// server does. At the default ~15.6 ms quantum, idle-frame waits overshoot by a
// random amount and menu frame rates land far below the chosen limit.
client_set_timer_precision :: proc() {
	win.timeBeginPeriod(1)
}

client_restore_timer_precision :: proc() {
	win.timeEndPeriod(1)
	if g_frame_timer.handle != nil { win.CloseHandle(g_frame_timer.handle) }
	g_frame_timer = {}
}

// Gives up the rest of the time slice to another ready thread, if any.
client_timer_yield :: proc() {
	win.SwitchToThread()
}

// The game FPS limit's sleep: a high-resolution waitable timer (Windows 10
// 1803 and later), which wakes within a few hundred microseconds instead of on
// the 1 ms timer tick. Older systems get an ordinary waitable timer.
@(private="file")
g_frame_timer: struct {
	handle: win.HANDLE,
	created, high_resolution: bool,
}

@(private="file")
client_frame_timer :: proc() -> win.HANDLE {
	if !g_frame_timer.created {
		g_frame_timer.created = true
		g_frame_timer.handle = win.CreateWaitableTimerExW(nil, nil, win.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win.TIMER_ALL_ACCESS)
		g_frame_timer.high_resolution = g_frame_timer.handle != nil
		if g_frame_timer.handle == nil { g_frame_timer.handle = win.CreateWaitableTimerExW(nil, nil, 0, win.TIMER_ALL_ACCESS) }
	}
	return g_frame_timer.handle
}

client_precise_sleep_high_resolution :: proc() -> bool {
	client_frame_timer()
	return g_frame_timer.high_resolution
}

client_precise_sleep :: proc(seconds: f64) {
	if !(seconds > 0) { return }
	timer := client_frame_timer()
	if timer == nil { win.Sleep(win.DWORD(seconds * 1000)); return }
	due := win.LARGE_INTEGER(-i64(seconds * 1e7)) // Relative, in 100 ns units.
	if due >= 0 { return }
	if !win.SetWaitableTimerEx(timer, &due, 0, nil, nil, nil, 0) { win.Sleep(win.DWORD(seconds * 1000)); return }
	// Bounded, so a lost signal can never stall the frame for long.
	win.WaitForSingleObject(timer, win.DWORD(seconds * 1000) + 50)
}
