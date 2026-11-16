#+build !windows
package main

import "core:sync"
import "core:time"
import curl "vendor:curl"

// Without socket events, the WebSocket thread wakes when the frame thread
// queues a packet, and otherwise polls the socket every millisecond.
Krunker_WS_Wait :: struct {
	wake: sync.Sema,
}

krunker_ws_wait_init :: proc(wait: ^Krunker_WS_Wait) -> bool { return true }

krunker_ws_wait_attach :: proc(wait: ^Krunker_WS_Wait, handle: ^curl.CURL) {}

krunker_ws_wait :: proc(wait: ^Krunker_WS_Wait, timeout_ms: u32) {
	sync.sema_wait_with_timeout(&wait.wake, time.Millisecond * time.Duration(min(timeout_ms, 1)))
}

krunker_ws_wait_wake :: proc(wait: ^Krunker_WS_Wait) { sync.sema_post(&wait.wake) }

krunker_ws_wait_fini :: proc(wait: ^Krunker_WS_Wait) { wait^ = {} }
