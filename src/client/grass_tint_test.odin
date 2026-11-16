package main

import "core:fmt"
import "core:testing"
import shared "../shared"

// Uncoloured GRASS tufts take the map's most common grass colour, or the
// fallback green on maps with no coloured tuft, instead of rendering grey.
@(test)
grass_tint_defaults_to_the_map_grass_colour :: proc(t: ^testing.T) {
	Case :: struct { file: string, want: string }
	cases := []Case{
		{"littletown", "#d1f777"}, // 33 coloured tufts, 130 uncoloured
		{"bazaar", "#85aa6c"},     // 45 coloured, 227 uncoloured
		{"burg", ""},              // only uncoloured tufts: the fallback
	}
	for c in cases {
		path := fmt.tprintf("assets/maps/%s.json", c.file)
		map_inst, ok := shared.map_load_from_file(path)
		if !testing.expectf(t, ok, "%s must load", c.file) do continue
		defer shared.map_destroy(map_inst)
		want := shared.MAP_GRASS_FALLBACK_TINT
		if len(c.want) > 0 { want = {1, 1, 1, 1}; shared.parse_hex_color(c.want, &want) }
		got := shared.map_default_grass_tint(map_inst)
		testing.expectf(t, abs(got.x - want.x) < 0.002 && abs(got.y - want.y) < 0.002 && abs(got.z - want.z) < 0.002,
			"%s grass tint must be %v, got %v", c.file, want, got)
	}
}
