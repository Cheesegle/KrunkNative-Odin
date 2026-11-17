package dedicated

import "core:c/libc"
import "core:sync"
import "core:sys/linux"
import "core:time"

// Linux tick sleeping: clock_nanosleep on CLOCK_MONOTONIC with an absolute
// deadline, so an interrupted sleep resumes toward the same instant instead
// of restarting a relative wait.

Precise_Sleeper :: struct {
	unavailable: bool,
}

precise_sleeper_init :: proc(sleeper: ^Precise_Sleeper) {
	sleeper^ = {}
	_, err := linux.clock_gettime(.MONOTONIC)
	sleeper.unavailable = err != .NONE
}

precise_sleeper_destroy :: proc(sleeper: ^Precise_Sleeper) {
	sleeper^ = {}
}

precise_sleeper_kind :: proc(sleeper: ^Precise_Sleeper) -> string {
	return sleeper.unavailable ? "nanosleep" : "clock_nanosleep (CLOCK_MONOTONIC, absolute)"
}

precise_sleep :: proc(sleeper: ^Precise_Sleeper, ns: i64) {
	if ns <= 0 {
		return
	}
	if !sleeper.unavailable {
		if now, err := linux.clock_gettime(.MONOTONIC); err == .NONE {
			target := i64(now.time_sec) * 1_000_000_000 + i64(now.time_nsec) + ns
			deadline := linux.Time_Spec{time_sec = uint(target / 1_000_000_000), time_nsec = uint(target % 1_000_000_000)}
			for _ in 0 ..< 8 {
				if linux.clock_nanosleep(.MONOTONIC, {.ABSTIME}, &deadline, nil) != .EINTR {
					return
				}
			}
			return
		}
	}
	time.sleep(time.Duration(ns))
}

// ---------------------------------------------------------------------------
// Shutdown: SIGINT (Ctrl+C) and SIGTERM (systemd, docker stop, kill).

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
