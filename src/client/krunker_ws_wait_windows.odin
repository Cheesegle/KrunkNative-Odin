#+build windows
package main

import win "core:sys/windows"
import curl "vendor:curl"

// Lets the WebSocket thread sleep until the socket is readable or writable, or
// the frame thread queues a packet, without polling on a timer.
Krunker_WS_Wait :: struct {
	wake, socket_event: win.HANDLE,
	socket: win.SOCKET,
	selected: bool,
}

// On the frame thread, before the WebSocket thread starts.
krunker_ws_wait_init :: proc(wait: ^Krunker_WS_Wait) -> bool {
	wait.wake = win.CreateEventW(nil, false, false, nil)
	return wait.wake != nil
}

// On the WebSocket thread, once the upgrade has produced a socket.
krunker_ws_wait_attach :: proc(wait: ^Krunker_WS_Wait, handle: ^curl.CURL) {
	// curl_socket_t is a SOCKET (pointer sized) on Windows.
	socket := win.INVALID_SOCKET
	if handle != nil && curl.easy_getinfo(handle, .ACTIVESOCKET, &socket) == .E_OK && socket != win.INVALID_SOCKET {
		wait.socket_event = win.WSACreateEvent()
		if wait.socket_event != nil && win.WSAEventSelect(socket, wait.socket_event, win.FD_READ | win.FD_WRITE | win.FD_CLOSE) == 0 {
			wait.socket, wait.selected = socket, true
		}
	}
}

// Returns early when the socket or the frame thread signals.
krunker_ws_wait :: proc(wait: ^Krunker_WS_Wait, timeout_ms: u32) {
	handles := [2]win.HANDLE{wait.wake, wait.socket_event}
	win.WaitForMultipleObjects(wait.selected ? 2 : 1, &handles[0], false, timeout_ms)
	if wait.selected {
		// Resets the socket event; the next recv/send re-arms it.
		events: win.WSANETWORKEVENTS
		win.WSAEnumNetworkEvents(wait.socket, wait.socket_event, &events)
	}
}

krunker_ws_wait_wake :: proc(wait: ^Krunker_WS_Wait) {
	if wait.wake != nil { win.SetEvent(wait.wake) }
}

// Call after the thread has exited and before curl closes the socket.
krunker_ws_wait_fini :: proc(wait: ^Krunker_WS_Wait) {
	if wait.selected { win.WSAEventSelect(wait.socket, nil, 0) }
	if wait.socket_event != nil { win.WSACloseEvent(wait.socket_event) }
	if wait.wake != nil { win.CloseHandle(wait.wake) }
	wait^ = {}
}
