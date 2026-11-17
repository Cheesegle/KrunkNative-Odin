package menu

import clay "../third_party/clay"
import shared "../shared"

// Krunker's Settings > Network > netRate ("Amount of data sent to server",
// game.deob.js `'netRate': {`): a select of 30/60/120/144/240/360, default
// 144 on desktop. Stored as the rate in Hz; Krunker's export uses the option
// index (0-5). Krodin sends this many input commands per second to a native
// (tcp://) server; live Krunker lobbies keep their fixed 360 Hz sampling.
NET_RATE_LABELS := [len(shared.NET_RATES)]string{"30 Hz", "60 Hz", "120 Hz", "144 Hz", "240 Hz", "360 Hz"}

net_rate_index :: proc(rate: i32) -> i32 {
	valid := shared.net_rate_validate(rate)
	for value, i in shared.NET_RATES { if value == valid { return i32(i) } }
	return 0
}

settings_net_rate_row :: proc(state: ^State) {
	if !settings_search_show(state, "Net rate") { return }
	if clay.UI(clay.ID("NetRateRow"))(settings_row(state)) {
		settings_label("Net rate", state.scale)
		spacer()
		settings_dropdown_field(state, NET_RATE_LABELS[net_rate_index(state.settings_draft.net_rate)], "NetRate", .NET_RATE)
	}
}
