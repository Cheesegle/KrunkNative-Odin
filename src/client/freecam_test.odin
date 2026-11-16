package main

import "core:testing"

when ODIN_TEST {
	@(test)
	freecam_is_offline_only :: proc(t: ^testing.T) {
		client := new(Client)
		defer free(client)
		testing.expect(t, client_freecam_allowed(client), "Local Practice allows the ] freecam")
		client.krunker.connected = true
		testing.expect(t, !client_freecam_allowed(client), "live Krunker lobbies refuse freecam")
		client.krunker.connected = false
		client.net.connected = true
		testing.expect(t, !client_freecam_allowed(client), "online Krodin servers refuse freecam")
	}
}
