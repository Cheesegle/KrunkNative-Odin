#+build !windows
package main

import "core:fmt"
import "core:strings"

// Reports are Windows-only for now; these keep the shared report code building.

diagnostics_name_thread :: proc(name: string) {}

diagnostics_capture_system_info :: proc() {
	b := strings.builder_from_bytes(g_diag.system_text[:])
	fmt.sbprintf(&b, "OS: %v\n", ODIN_OS)
	g_diag.system_len = len(strings.to_string(b))
}

diagnostics_write_live_system :: proc(b: ^strings.Builder, live: bool) {}
