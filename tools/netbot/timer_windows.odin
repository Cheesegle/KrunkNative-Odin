package netbot

import "core:time"
import win "core:sys/windows"

// Sleep(1) rounds up to the 15.6 ms system tick (and Windows 11 may ignore
// timeBeginPeriod for background processes), which would add tens of ms of
// fake latency on top of the simulated one. A high-resolution waitable timer
// wakes within a fraction of a millisecond, like the server's tick loop.
@(private = "file") g_timer: win.HANDLE

bot_sleep_begin :: proc() {
	g_timer = win.CreateWaitableTimerExW(nil, nil, win.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win.TIMER_ALL_ACCESS)
	if g_timer == nil { win.timeBeginPeriod(1) }
}

bot_sleep_end :: proc() {
	if g_timer != nil { win.CloseHandle(g_timer); g_timer = nil } else { win.timeEndPeriod(1) }
}

bot_sleep :: proc(d: time.Duration) {
	if g_timer != nil {
		due := win.LARGE_INTEGER(-max(1, i64(d) / 100)) // relative, 100 ns units
		if win.SetWaitableTimerEx(g_timer, &due, 0, nil, nil, nil, 0) {
			win.WaitForSingleObject(g_timer, win.INFINITE)
			return
		}
	}
	time.sleep(d)
}
