package menu

import clay "../third_party/clay"

// Krodin's own "Interpolation delay" (Krunker has none; its browser always
// draws remote players one send interval in the past). Like Source's
// cl_interp: how far behind the newest snapshot remote players are drawn on a
// Krodin server. Auto (0, the default) is 2 snapshot intervals plus the
// measured network jitter; a fixed value trades smoothness under jitter for
// latency. Stored in ms.
NET_INTERP_OPTIONS := [?]i32{0, 10, 20, 30, 50, 75, 100, 150, 200}
NET_INTERP_LABELS := [len(NET_INTERP_OPTIONS)]string{"Auto", "10 ms", "20 ms", "30 ms", "50 ms", "75 ms", "100 ms", "150 ms", "200 ms"}

// Unknown values (and files from before the setting) become Auto.
net_interp_validate :: proc(ms: i32) -> i32 {
	for option in NET_INTERP_OPTIONS { if option == ms { return ms } }
	return 0
}

net_interp_index :: proc(ms: i32) -> i32 {
	valid := net_interp_validate(ms)
	for value, i in NET_INTERP_OPTIONS { if value == valid { return i32(i) } }
	return 0
}

settings_net_interp_row :: proc(state: ^State) {
	if !settings_search_show(state, "Interpolation delay") { return }
	if clay.UI(clay.ID("NetInterpRow"))(settings_row(state)) {
		settings_label("Interpolation delay", state.scale)
		spacer()
		settings_dropdown_field(state, NET_INTERP_LABELS[net_interp_index(state.settings_draft.net_interp)], "NetInterp", .NET_INTERP)
	}
}
