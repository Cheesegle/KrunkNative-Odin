package main

import "core:math"
import "core:slice"
import ma "vendor:miniaudio"

// Speaker ring for multichannel output, built from the output channel map.
// Standard azimuths (ITU-R BS.775 / Dolby): front L/R +-30, centre 0;
// 5.1 surrounds +-110; 7.1 sides +-90 and backs +-150. LFE gets nothing.
SURROUND_MAX_CHANNELS :: 8

Surround_Speaker :: struct {
	channel: int,
	azimuth: f32,                 // Degrees in [0, 360), clockwise, 0 = front, 90 = right.
}

Surround_Layout :: struct {
	channels: int,
	speakers: [SURROUND_MAX_CHANNELS]Surround_Speaker,
	count: int,                   // Speakers on the horizontal ring, sorted by azimuth.
	front_left, front_right: int, // Channels that receive non-spatial (local, UI) audio.
}

// Returns false when the map has no usable ring (mono, stereo or unknown layouts).
surround_layout_from_map :: proc(channel_map: []ma.channel) -> (layout: Surround_Layout, ok: bool) {
	channels := len(channel_map)
	if channels <= 2 || channels > SURROUND_MAX_CHANNELS { return }
	layout.channels = channels
	layout.front_left, layout.front_right = -1, -1
	has_side, has_back := false, false
	for position in channel_map {
		#partial switch position {
		case .SIDE_LEFT, .SIDE_RIGHT: has_side = true
		case .BACK_LEFT, .BACK_RIGHT: has_back = true
		}
	}
	both := has_side && has_back
	for position, channel in channel_map {
		azimuth: f32
		#partial switch position {
		case .FRONT_LEFT: azimuth = -30; layout.front_left = channel
		case .FRONT_RIGHT: azimuth = 30; layout.front_right = channel
		case .FRONT_CENTER: azimuth = 0
		case .SIDE_LEFT: azimuth = both ? -90 : -110
		case .SIDE_RIGHT: azimuth = both ? 90 : 110
		case .BACK_LEFT: azimuth = both ? -150 : -110
		case .BACK_RIGHT: azimuth = both ? 150 : 110
		case .BACK_CENTER: azimuth = 180
		case: continue // LFE and anything off the ring.
		}
		layout.speakers[layout.count] = {channel, math.mod(azimuth + 360, 360)}
		layout.count += 1
	}
	if layout.count < 3 || layout.front_left < 0 || layout.front_right < 0 { return {}, false }
	slice.sort_by(layout.speakers[:layout.count], proc(a, b: Surround_Speaker) -> bool { return a.azimuth < b.azimuth })
	return layout, true
}

surround_layout_standard :: proc(channels: int) -> (Surround_Layout, bool) {
	channel_map: [SURROUND_MAX_CHANNELS]ma.channel
	if channels <= 2 || channels > SURROUND_MAX_CHANNELS { return {}, false }
	ma.channel_map_init_standard(.microsoft, &channel_map[0], SURROUND_MAX_CHANNELS, u32(channels))
	return surround_layout_from_map(channel_map[:channels])
}

// Pairwise constant-power panning between the two ring speakers either side
// of the source: gains cos/sin of the normalised angle between them.
surround_gains :: proc "contextless" (layout: ^Surround_Layout, azimuth: f32) -> (gains: [SURROUND_MAX_CHANNELS]f32) {
	az := math.mod(azimuth, 360)
	if az < 0 { az += 360 }
	n := layout.count
	a := n - 1
	for i in 0 ..< n { if layout.speakers[i].azimuth <= az { a = i } }
	b := (a + 1) % n
	gap := layout.speakers[b].azimuth - layout.speakers[a].azimuth
	if gap <= 0 { gap += 360 }
	offset := az - layout.speakers[a].azimuth
	if offset < 0 { offset += 360 }
	t := clamp(offset / gap, 0, 1)
	gains[layout.speakers[a].channel] += math.cos(t * math.PI / 2)
	gains[layout.speakers[b].channel] += math.sin(t * math.PI / 2)
	return
}
