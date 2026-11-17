#+build !windows
#+build !linux
package dedicated

import "core:c/libc"
import "core:sync"
import "core:time"

// Other POSIX systems (macOS, BSD): plain sleeps, which are already
// sub-millisecond there, and SIGINT/SIGTERM through libc.

Precise_Sleeper :: struct {}

precise_sleeper_init :: proc(sleeper: ^Precise_Sleeper) {}

precise_sleeper_destroy :: proc(sleeper: ^Precise_Sleeper) {}

precise_sleeper_kind :: proc(sleeper: ^Precise_Sleeper) -> string {
	return "nanosleep"
}

precise_sleep :: proc(sleeper: ^Precise_Sleeper, ns: i64) {
	if ns > 0 {
		time.sleep(time.Duration(ns))
	}
}

@(private)
g_quit_requested: bool

quit_requested :: proc() -> bool {
	return sync.atomic_load(&g_quit_requested)
}

request_quit :: proc() {
	sync.atomic_store(&g_quit_requested, true)
}

shutdown_finished :: proc() {
}

@(private)
quit_signal_handler :: proc "c" (sig: libc.int) {
	sync.atomic_store(&g_quit_requested, true)
}

install_shutdown_handlers :: proc() -> bool {
	ok_int := rawptr(libc.signal(libc.SIGINT, quit_signal_handler)) != libc.SIG_ERR
	ok_term := rawptr(libc.signal(libc.SIGTERM, quit_signal_handler)) != libc.SIG_ERR
	return ok_int && ok_term
}
