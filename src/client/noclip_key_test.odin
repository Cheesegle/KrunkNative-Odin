package main

import "core:testing"

when ODIN_TEST {
	@(test)
	noclip_key_is_dev_only :: proc(t: ^testing.T) {
		client := new(Client)
		defer free(client)
		testing.expect_value(t, client_noclip_key_allowed(client), KRODIN_DEV)
		client.krunker.connected = true
		testing.expect(t, !client_noclip_key_allowed(client), "live Krunker lobbies never allow the N noclip key")
	}
}
