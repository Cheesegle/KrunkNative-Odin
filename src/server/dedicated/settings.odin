package dedicated

// Dedicated server settings: defaults < assets/config/game.toml `tick_rate`
// (kept as a compatibility fallback) < assets/config/server.toml < command
// line flags. Every step is a pure proc so the precedence and the clamping
// can be tested without a socket, a file or a process.

import "core:fmt"
import "core:strconv"
import "core:strings"

import shared "../../shared"

SERVER_CONFIG_PATH :: "config/server.toml" // relative to shared.assets_path()

DEFAULT_PORT :: 21015
DEFAULT_TICK_RATE :: 64
MIN_TICK_RATE :: 30 // Krunker's serverTickFrequency
MAX_TICK_RATE :: 128
DEFAULT_MAX_PLAYERS :: 8
MIN_MAX_PLAYERS :: 1
// Krunker caps custom games at 10 (maxPlayers max:10); Krodin allows up to 16
// for now so 8v8 can be tried. MAX_PLAYERS_PER_MATCH (32) is the wire limit.
MAX_MAX_PLAYERS :: 16
DEFAULT_TEAM_SIZE :: 4
MIN_TEAM_SIZE :: 1
MAX_TEAM_SIZE :: 4 // Krunker tmSize options: 1v1 .. 4v4
// Krunker shows the end screen for endTimer (25e3 ms) before initNewGameAsync
// loads the next map. The custom-game intermission (intermTmr) is 5..120 s.
DEFAULT_INTERMISSION :: 25.0
MIN_INTERMISSION :: 5.0
MAX_INTERMISSION :: 120.0
// Snapshots per second. Krunker's sendFrequency comes from the game's `snf`
// (default 10) or the mode's `sendR` (Race, Trade, Zombies: 5), next to the
// 30 Hz tickFrequency (`tf`). Krodin defaults to one snapshot per tick (0 here
// means "the tick rate"), like CS; lower rates send every Nth tick.
DEFAULT_SNAPSHOT_RATE :: 0
MIN_SNAPSHOT_RATE :: 10 // Krunker's default snf
// Players further than this from the recipient are left out of its
// snapshots (Krunker's mode `viewDis`: 500, 1000 or 2000 in the modes that set
// it). Hardpoint and FFA set none, so 0 (off) is the default.
DEFAULT_VIEW_DISTANCE :: 0.0
MIN_VIEW_DISTANCE :: 100.0
MAX_VIEW_DISTANCE :: 10000.0
DEFAULT_STATS_INTERVAL :: 10.0
MAX_STATS_INTERVAL :: 3600.0
MAX_SERVER_NAME_LEN :: 32
DEFAULT_SERVER_NAME :: "Krodin Server"
DEFAULT_BIND :: "0.0.0.0"

Rotation_Order :: enum u8 {
	SHUFFLE, // a random map that is not the one just played (Krunker public games pick at random)
	SEQUENTIAL, // the configured order, wrapping around
}

// Server modes by config name. Only the existing objective ruleset exists
// today (mode index 0, see shared/modes.odin); true FFA and competitive teams
// arrive with the modes phase.
SERVER_MODE_NAMES := [?]string{"hardpoint"}

Server_Settings :: struct {
	port:           int,
	bind:           string,
	tick_rate:      int,
	snapshot_rate:  int, // Hz; 0 until validated, then the tick rate's divisor-friendly value
	view_distance:  f32, // 0: no culling
	max_players:    int,
	name:           string,
	// Rotation slots: indices into shared.ROTATION_MAPS, which is the map table
	// the native protocol's MATCH_STATE.map_index refers to on every client.
	maps:           [dynamic]i32,
	rotation:       Rotation_Order,
	mode:           i32,
	team_size:      int,
	// Stored for the admin phase. It must never be printed or logged.
	admin_password: string,
	intermission:   f32,
	stats_interval: f32,
	// Krodin testing aid: exit cleanly after this many seconds (0 = run forever).
	quit_after:     f32,
	seed:           u64,
	config_path:    string,
}

server_settings_default :: proc() -> Server_Settings {
	return Server_Settings{
		port           = DEFAULT_PORT,
		bind           = strings.clone(DEFAULT_BIND),
		tick_rate      = DEFAULT_TICK_RATE,
		snapshot_rate  = DEFAULT_SNAPSHOT_RATE,
		view_distance  = DEFAULT_VIEW_DISTANCE,
		max_players    = DEFAULT_MAX_PLAYERS,
		name           = strings.clone(DEFAULT_SERVER_NAME),
		rotation       = .SHUFFLE,
		mode           = 0,
		team_size      = DEFAULT_TEAM_SIZE,
		admin_password = strings.clone(""),
		intermission   = DEFAULT_INTERMISSION,
		stats_interval = DEFAULT_STATS_INTERVAL,
		config_path    = strings.clone(""),
	}
}

server_settings_destroy :: proc(s: ^Server_Settings) {
	delete(s.bind)
	delete(s.name)
	delete(s.admin_password)
	delete(s.config_path)
	delete(s.maps)
	s^ = {}
}

@(private)
settings_set_string :: proc(dst: ^string, value: string) {
	delete(dst^)
	dst^ = strings.clone(value)
}

@(private)
warnf :: proc(warnings: ^[dynamic]string, format: string, args: ..any) {
	if warnings != nil {
		append(warnings, fmt.aprintf(format, ..args))
	}
}

warnings_destroy :: proc(warnings: ^[dynamic]string) {
	for w in warnings { delete(w) }
	delete(warnings^)
}

// map_name_to_slot resolves a map name to its ROTATION_MAPS slot. A known map
// outside the client rotation table returns registry_only = true: the native
// protocol identifies maps by rotation slot, so clients could not load it.
map_name_to_slot :: proc(raw: string) -> (slot: i32, registry_only: bool, ok: bool) {
	name := strings.to_lower(strings.trim_space(raw), context.temp_allocator)
	if name == "ss_v3" || name == "sandstorm_v3" { name = "sandstorm" }
	for registry_name, registry_index in shared.DEFAULT_MAP_NAMES {
		if registry_name != name { continue }
		for rotation_index, rotation_slot in shared.ROTATION_MAPS {
			if rotation_index == registry_index { return i32(rotation_slot), false, true }
		}
		return -1, true, false
	}
	return -1, false, false
}

map_slot_name :: proc(slot: i32) -> string {
	if slot < 0 || int(slot) >= len(shared.ROTATION_MAPS) { return "?" }
	return shared.DEFAULT_MAP_NAMES[shared.ROTATION_MAPS[slot]]
}

// settings_set_maps replaces the rotation from a list of names, skipping (with
// a warning) names the clients cannot load.
@(private)
settings_set_maps :: proc(s: ^Server_Settings, names: []string, warnings: ^[dynamic]string) {
	clear(&s.maps)
	for name in names {
		if len(strings.trim_space(name)) == 0 { continue }
		slot, registry_only, ok := map_name_to_slot(name)
		switch {
		case ok:
			append(&s.maps, slot)
		case registry_only:
			warnf(warnings, "map %q is not in the client map table (shared.ROTATION_MAPS) and cannot be served yet; skipped", name)
		case:
			warnf(warnings, "unknown map %q; skipped", name)
		}
	}
}

@(private)
parse_rotation :: proc(value: string) -> (Rotation_Order, bool) {
	switch strings.to_lower(strings.trim_space(value), context.temp_allocator) {
	case "shuffle", "random": return .SHUFFLE, true
	case "sequential", "ordered", "in_order": return .SEQUENTIAL, true
	}
	return .SHUFFLE, false
}

@(private)
parse_mode :: proc(value: string) -> (i32, bool) {
	lower := strings.to_lower(strings.trim_space(value), context.temp_allocator)
	for name, index in SERVER_MODE_NAMES {
		if name == lower { return i32(index), true }
	}
	return 0, false
}

// game_toml_tick_rate_fallback applies [game] tick_rate from game.toml, which
// was the only server knob before server.toml existed.
server_settings_apply_game_toml_tick_rate :: proc(s: ^Server_Settings, game_tick_rate: i32) {
	if game_tick_rate > 0 {
		s.tick_rate = int(game_tick_rate)
	}
}

// server_settings_apply_toml applies a server.toml document. Keys may live at
// the top level or under a [server] table. Unknown keys are reported.
server_settings_apply_toml :: proc(s: ^Server_Settings, source: string, warnings: ^[dynamic]string) -> bool {
	root, ok := shared.toml_parse(source)
	if !ok {
		warnf(warnings, "server.toml: parse error; using defaults and flags only")
		if root != nil { shared.toml_destroy(root) }
		return false
	}
	defer shared.toml_destroy(root)
	if table, has := root.tables["server"]; has {
		settings_apply_table(s, table, warnings)
	}
	settings_apply_table(s, root, warnings)
	return true
}

@(private)
settings_apply_table :: proc(s: ^Server_Settings, table: ^shared.Toml_Table, warnings: ^[dynamic]string) {
	for key, value in table.values {
		switch key {
		case "port":
			if n, is_int := value.(i64); is_int { s.port = int(n) } else { warnf(warnings, "server.toml: port must be an integer") }
		case "bind":
			if text, is_str := value.(string); is_str { settings_set_string(&s.bind, text) } else { warnf(warnings, "server.toml: bind must be a string") }
		case "tick_rate":
			if n, is_int := value.(i64); is_int { s.tick_rate = int(n) } else { warnf(warnings, "server.toml: tick_rate must be an integer") }
		case "snapshot_rate":
			if n, is_int := value.(i64); is_int { s.snapshot_rate = int(n) } else { warnf(warnings, "server.toml: snapshot_rate must be an integer (Hz, 0 = tick rate)") }
		case "view_distance":
			if f, num := shared.toml_get_f32(table, key); num { s.view_distance = f } else { warnf(warnings, "server.toml: view_distance must be a number (0 = off)") }
		case "max_players":
			if n, is_int := value.(i64); is_int { s.max_players = int(n) } else { warnf(warnings, "server.toml: max_players must be an integer") }
		case "team_size":
			if n, is_int := value.(i64); is_int { s.team_size = int(n) } else { warnf(warnings, "server.toml: team_size must be an integer") }
		case "name":
			if text, is_str := value.(string); is_str { settings_set_string(&s.name, text) } else { warnf(warnings, "server.toml: name must be a string") }
		case "admin_password":
			if text, is_str := value.(string); is_str { settings_set_string(&s.admin_password, text) } else { warnf(warnings, "server.toml: admin_password must be a string") }
		case "mode":
			if text, is_str := value.(string); is_str {
				if mode, known := parse_mode(text); known { s.mode = mode } else { warnf(warnings, "server.toml: unknown mode %q; keeping %s", text, SERVER_MODE_NAMES[s.mode]) }
			} else { warnf(warnings, "server.toml: mode must be a string") }
		case "rotation":
			if text, is_str := value.(string); is_str {
				if order, known := parse_rotation(text); known { s.rotation = order } else { warnf(warnings, "server.toml: rotation must be \"shuffle\" or \"sequential\"") }
			} else { warnf(warnings, "server.toml: rotation must be a string") }
		case "maps":
			if list, is_list := value.([]shared.Toml_Value); is_list {
				names := make([dynamic]string, 0, len(list), context.temp_allocator)
				for item in list {
					if text, is_str := item.(string); is_str { append(&names, text) } else { warnf(warnings, "server.toml: maps entries must be strings") }
				}
				settings_set_maps(s, names[:], warnings)
			} else { warnf(warnings, "server.toml: maps must be an array of map names") }
		case "intermission":
			if f, num := shared.toml_get_f32(table, key); num { s.intermission = f } else { warnf(warnings, "server.toml: intermission must be a number of seconds") }
		case "stats_interval":
			if f, num := shared.toml_get_f32(table, key); num { s.stats_interval = f } else { warnf(warnings, "server.toml: stats_interval must be a number of seconds") }
		case:
			warnf(warnings, "server.toml: unknown key %q", key)
		}
	}
}

Args_Result :: enum {
	OK,
	HELP,
	ERROR,
}

// server_args_config_path finds --config before the file is loaded, so the
// flag can name the file whose values the other flags then override.
server_args_config_path :: proc(args: []string) -> (path: string, found: bool) {
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if strings.has_prefix(arg, "--config=") { return arg[len("--config="):], true }
		if arg == "--config" && i + 1 < len(args) { return args[i + 1], true }
	}
	return "", false
}

server_args_wants_help :: proc(args: []string) -> bool {
	for arg in args {
		if arg == "-h" || arg == "--help" || arg == "/?" { return true }
	}
	return false
}

@(private)
int_value :: proc(flag, value: string) -> (int, string) {
	n, ok := strconv.parse_int(strings.trim_space(value), 10)
	if !ok { return 0, fmt.tprintf("%s expects an integer, got %q", flag, value) }
	return n, ""
}

@(private)
f32_value :: proc(flag, value: string) -> (f32, string) {
	n, ok := strconv.parse_f32(strings.trim_space(value))
	if !ok || n != n { return 0, fmt.tprintf("%s expects a number, got %q", flag, value) }
	return n, ""
}

// server_settings_apply_args applies command line flags (`--flag value` or
// `--flag=value`). It does not clamp; call server_settings_validate after.
server_settings_apply_args :: proc(s: ^Server_Settings, args: []string, warnings: ^[dynamic]string) -> (result: Args_Result, err: string) {
	i := 0
	for i < len(args) {
		arg := args[i]
		i += 1
		if arg == "-h" || arg == "--help" || arg == "/?" { return .HELP, "" }
		if !strings.has_prefix(arg, "--") {
			return .ERROR, fmt.tprintf("unexpected argument %q (see --help)", arg)
		}
		flag := arg
		value: string
		has_value := false
		if eq := strings.index_byte(arg, '='); eq >= 0 {
			flag, value, has_value = arg[:eq], arg[eq + 1:], true
		}
		if !has_value {
			if i >= len(args) { return .ERROR, fmt.tprintf("%s needs a value", flag) }
			value = args[i]
			i += 1
		}

		switch flag {
		case "--config":
			settings_set_string(&s.config_path, value)
		case "--port":
			n, e := int_value(flag, value); if len(e) > 0 { return .ERROR, e }
			s.port = n
		case "--bind":
			settings_set_string(&s.bind, value)
		case "--tick-rate":
			n, e := int_value(flag, value); if len(e) > 0 { return .ERROR, e }
			s.tick_rate = n
		case "--snapshot-rate":
			n, e := int_value(flag, value); if len(e) > 0 { return .ERROR, e }
			s.snapshot_rate = n
		case "--view-distance":
			f, e := f32_value(flag, value); if len(e) > 0 { return .ERROR, e }
			s.view_distance = f
		case "--max-players":
			n, e := int_value(flag, value); if len(e) > 0 { return .ERROR, e }
			s.max_players = n
		case "--team-size":
			n, e := int_value(flag, value); if len(e) > 0 { return .ERROR, e }
			s.team_size = n
		case "--name":
			settings_set_string(&s.name, value)
		case "--admin-password":
			settings_set_string(&s.admin_password, value)
		case "--maps", "--map":
			names := strings.split(value, ",", context.temp_allocator)
			settings_set_maps(s, names, warnings)
		case "--rotation":
			order, ok := parse_rotation(value)
			if !ok { return .ERROR, "--rotation expects shuffle or sequential" }
			s.rotation = order
		case "--mode":
			mode, ok := parse_mode(value)
			if !ok { return .ERROR, fmt.tprintf("unknown mode %q (available: hardpoint)", value) }
			s.mode = mode
		case "--intermission":
			f, e := f32_value(flag, value); if len(e) > 0 { return .ERROR, e }
			s.intermission = f
		case "--stats-interval":
			f, e := f32_value(flag, value); if len(e) > 0 { return .ERROR, e }
			s.stats_interval = f
		case "--quit-after":
			f, e := f32_value(flag, value); if len(e) > 0 { return .ERROR, e }
			s.quit_after = max(0, f)
		case "--seed":
			n, ok := strconv.parse_u64(strings.trim_space(value), 10)
			if !ok { return .ERROR, "--seed expects an unsigned integer" }
			s.seed = n
		case:
			return .ERROR, fmt.tprintf("unknown flag %s (see --help)", flag)
		}
	}
	return .OK, ""
}

@(private)
clamp_int :: proc(value: ^int, lo, hi: int, what: string, warnings: ^[dynamic]string) {
	if value^ < lo || value^ > hi {
		clamped := clamp(value^, lo, hi)
		warnf(warnings, "%s %d is outside %d..%d; using %d", what, value^, lo, hi, clamped)
		value^ = clamped
	}
}

// server_settings_validate clamps every value into its range, warning for each
// change, and fills an empty rotation with the whole client map table.
server_settings_validate :: proc(s: ^Server_Settings, warnings: ^[dynamic]string) {
	clamp_int(&s.port, 0, 65535, "port", warnings) // 0: the OS picks a free port
	clamp_int(&s.tick_rate, MIN_TICK_RATE, MAX_TICK_RATE, "tick_rate", warnings)
	if s.snapshot_rate <= 0 {
		s.snapshot_rate = s.tick_rate
	} else {
		clamp_int(&s.snapshot_rate, min(MIN_SNAPSHOT_RATE, s.tick_rate), s.tick_rate, "snapshot_rate", warnings)
	}
	if divisor := server_snapshot_divisor(s); s.tick_rate % divisor != 0 || s.tick_rate / divisor != s.snapshot_rate {
		warnf(warnings, "snapshot_rate %d is not the tick rate %d divided by a whole number; sending every %d ticks (%.1f Hz)",
			s.snapshot_rate, s.tick_rate, divisor, f32(s.tick_rate) / f32(divisor))
	}
	if !(s.view_distance == 0 || s.view_distance >= MIN_VIEW_DISTANCE && s.view_distance <= MAX_VIEW_DISTANCE) {
		clamped := s.view_distance != s.view_distance || s.view_distance < 0 ? 0 : clamp(s.view_distance, MIN_VIEW_DISTANCE, MAX_VIEW_DISTANCE)
		warnf(warnings, "view_distance %.0f is outside %.0f..%.0f (0 = off); using %.0f", s.view_distance, MIN_VIEW_DISTANCE, MAX_VIEW_DISTANCE, clamped)
		s.view_distance = clamped
	}
	clamp_int(&s.max_players, MIN_MAX_PLAYERS, MAX_MAX_PLAYERS, "max_players", warnings)
	clamp_int(&s.team_size, MIN_TEAM_SIZE, MAX_TEAM_SIZE, "team_size", warnings)

	if !(s.intermission >= MIN_INTERMISSION && s.intermission <= MAX_INTERMISSION) {
		clamped := s.intermission != s.intermission ? DEFAULT_INTERMISSION : clamp(s.intermission, MIN_INTERMISSION, MAX_INTERMISSION)
		warnf(warnings, "intermission %.1f s is outside %.0f..%.0f; using %.1f", s.intermission, MIN_INTERMISSION, MAX_INTERMISSION, clamped)
		s.intermission = clamped
	}
	if !(s.stats_interval >= 0 && s.stats_interval <= MAX_STATS_INTERVAL) {
		clamped := s.stats_interval != s.stats_interval ? DEFAULT_STATS_INTERVAL : clamp(s.stats_interval, 0, MAX_STATS_INTERVAL)
		warnf(warnings, "stats_interval %.1f s is outside 0..%.0f; using %.1f", s.stats_interval, MAX_STATS_INTERVAL, clamped)
		s.stats_interval = clamped
	}

	trimmed := strings.trim_space(s.name)
	if len(trimmed) == 0 {
		warnf(warnings, "server name is empty; using %q", DEFAULT_SERVER_NAME)
		settings_set_string(&s.name, DEFAULT_SERVER_NAME)
	} else if len(trimmed) != len(s.name) {
		settings_set_string(&s.name, trimmed)
	}
	if len(s.name) > MAX_SERVER_NAME_LEN {
		// Cut on a rune boundary so the name stays valid UTF-8.
		cut := 0
		for _, offset in s.name {
			if offset > MAX_SERVER_NAME_LEN { break }
			cut = offset
		}
		if cut == 0 { cut = MAX_SERVER_NAME_LEN }
		warnf(warnings, "server name is longer than %d bytes; truncated", MAX_SERVER_NAME_LEN)
		settings_set_string(&s.name, s.name[:cut])
	}
	if len(strings.trim_space(s.bind)) == 0 {
		settings_set_string(&s.bind, DEFAULT_BIND)
	}

	if len(s.maps) == 0 {
		for _, slot in shared.ROTATION_MAPS { append(&s.maps, i32(slot)) }
	}
	if s.mode < 0 || int(s.mode) >= len(SERVER_MODE_NAMES) { s.mode = 0 }
}

// server_snapshot_divisor: a snapshot goes out every this many ticks.
server_snapshot_divisor :: proc(s: ^Server_Settings) -> int {
	rate := s.snapshot_rate > 0 ? s.snapshot_rate : s.tick_rate
	return max(1, int(f32(max(1, s.tick_rate)) / f32(max(1, rate)) + 0.5))
}

// server_settings_summary is the startup log line. It reports whether an admin
// password is set, never the password itself.
server_settings_summary :: proc(s: ^Server_Settings, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "name=%q bind=%s port=%d tick_rate=%d snapshot_rate=%.4g view_distance=%.0f max_players=%d team_size=%d mode=%s rotation=%v intermission=%.0fs admin_password=%s maps=[",
		s.name, s.bind, s.port, s.tick_rate, f32(s.tick_rate) / f32(server_snapshot_divisor(s)), s.view_distance, s.max_players, s.team_size, SERVER_MODE_NAMES[s.mode], s.rotation, s.intermission,
		len(s.admin_password) > 0 ? "set" : "unset")
	for slot, i in s.maps {
		if i > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, map_slot_name(slot))
	}
	strings.write_string(&b, "]")
	return strings.to_string(b)
}

SERVER_HELP :: `Krodin dedicated server

Usage: krodin_server [flags]

Settings come from assets/config/server.toml; every flag overrides the file.

  --config <path>           server.toml to read (default assets/config/server.toml)
  --port <n>                TCP port (default 21015; 0 picks a free port)
  --bind <ip>               listen address (default 0.0.0.0; 127.0.0.1 for local only)
  --name <text>             server name, up to 32 bytes (default "Krodin Server")
  --tick-rate <hz>          simulation tick rate, 30..128 (default 64)
  --snapshot-rate <hz>      snapshots per second, 10..tick rate (default: one per tick)
  --view-distance <units>   leave out players further away, 100..10000 (default 0 = off)
  --max-players <n>         connection limit, 1..16 (default 8)
  --team-size <n>           players per team for team select, 1..4 (default 4)
  --mode <name>             game mode: hardpoint (default)
  --maps <a,b,...>          map rotation (default: every map in the client map table)
  --rotation <order>        shuffle (default) or sequential
  --intermission <s>        end screen before the next map, 5..120 (default 25)
  --stats-interval <s>      tick budget log interval, 0 disables (default 10)
  --admin-password <text>   stored for admin commands (not used yet; never logged)
  --quit-after <s>          exit cleanly after this many seconds (testing)
  --seed <n>                seed for the shuffled rotation
  -h, --help                show this help

Out-of-range values are clamped with a warning. Ctrl+C (or SIGINT/SIGTERM)
shuts the server down cleanly.
`
