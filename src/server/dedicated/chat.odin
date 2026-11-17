package dedicated

import "core:time"
import shared "../../shared"

// Chat on Krodin's native server (Krodin's own protocol; see shared.Packet_Type.CHAT).
// The server checks every request itself: printable ASCII, 1..70 bytes
// (shared.net_chat_text_valid), at most one message per NET_CHAT_INTERVAL per
// client (Krunker's 1.5 s chat-bind interval), and team-only chat goes only to
// the sender's team. Chat text is never printed to the server log.
NET_CHAT_INTERVAL :: 1500 * time.Millisecond
// Krunker's errors.eventBus.rateLimited text.
NET_CHAT_TOO_FAST :: "You're sending messages too fast. Slow down."

Net_Chat_Limit :: struct {
	last: time.Tick,
	sent: bool,
}

// Whether a message may go out at `now`; an allowed message starts the interval.
net_chat_allow :: proc(limit: ^Net_Chat_Limit, now: time.Tick) -> bool {
	if limit.sent && time.tick_diff(limit.last, now) < NET_CHAT_INTERVAL { return false }
	limit.last, limit.sent = now, true
	return true
}

// One CHAT request from `client`. Invalid requests are dropped; a request
// inside the interval gets a server line back to that client only.
net_server_chat :: proc(ns: ^Net_Server, client: ^Net_Client, packet: []byte, now := time.Tick{}) {
	text, team, ok := shared.packet_deserialize_chat_request(packet)
	if !ok || client.player == nil { return }
	now := now
	if now == {} { now = time.tick_now() }
	if !net_chat_allow(&client.chat, now) {
		buf: [shared.NET_CHAT_MAX_SIZE]byte
		if size := shared.packet_serialize_chat(buf[:], shared.NET_CHAT_SYSTEM, false, NET_CHAT_TOO_FAST); size > 0 && !net_server_send(client, buf[:size]) {
			client.active = false
		}
		return
	}
	// Team-only chat needs a team; without one it goes to everyone.
	sender_team := client.player.team
	net_server_broadcast_chat(ns, client.player.uid, team && sender_team > 0 ? sender_team : 0, text)
}
