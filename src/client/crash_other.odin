#+build !windows

package main

import "core:fmt"
import "core:os"

// Crash and hang reports are Windows-only for now; elsewhere the OS's own
// core dumps cover crashes. The writer still works so tests can use it.

crash_file_write :: proc(path: string, data: []u8) -> bool {
	diagnostics_make_log_dir()
	return os.write_entire_file(path, data) == nil
}

crash_file_append :: proc(path: string, data: []u8) -> bool {
	file, err := os.open(path, {.Write, .Append, .Create})
	if err != nil { return false }
	defer os.close(file)
	_, write_err := os.write(file, data)
	return write_err == nil
}

crash_handler_install :: proc() {}

crash_handler_uninstall :: proc() {}

crash_watchdog_pause :: proc(paused: bool) {}

crash_hang_was_reported :: proc() -> bool { return false }

crash_hang_log_path :: proc() -> string { return HANG_LOG_PATH }

// The GPU reset notice; Windows shows a message box.
gpu_reset_show_message :: proc(text: string) { fmt.eprintln(text) }
