#+build !windows

package main

import "core:time"

// POSIX and Apple timers already deliver sub-millisecond waits, so no timer
// resolution change is needed on non-Windows platforms.
client_set_timer_precision :: proc() {
}

client_restore_timer_precision :: proc() {
}

client_timer_yield :: proc() {
	time.sleep(0)
}

client_precise_sleep_high_resolution :: proc() -> bool { return true }

client_precise_sleep :: proc(seconds: f64) {
	if seconds > 0 { time.sleep(time.Duration(seconds * f64(time.Second))) }
}
