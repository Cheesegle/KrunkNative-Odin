package main

import "core:fmt"
import "core:slice"
import shared "../shared"
import kproto "../krunker"

// Krunker's syncLeaders sends at most 16 sorted entries.
SCOREBOARD_MAX_ROWS :: 16
SCOREBOARD_MAX_COLUMNS :: 8
// Native and local sessions track Krunker's FFA/TDM leaderStats.
SCOREBOARD_NATIVE_STATS := [?]string{"score", "kills", "deaths"}
MATCH_TEAM_COLORS := [2]shared.Vec4{{0.93, 0.22, 0.27, 1}, {0.25, 0.55, 1, 1}}

Scoreboard_Row :: struct {
	name: string,
	team: i32,
	is_you: bool,
	// Server board position or join order; breaks equal sort keys.
	order: i32,
	sort_key: f64,
	cells: [SCOREBOARD_MAX_COLUMNS]string,
}

// One data model for the held in-match board and the end-of-game table.
// Strings are temp-allocated for the current frame.
Scoreboard :: struct {
	columns: [SCOREBOARD_MAX_COLUMNS]string,
	column_count: int,
	teams: bool,
	local_team: i32,
	team_names: [2]string,
	team_scores: [3]u32,
	rows: []Scoreboard_Row,
	// Header above the rank counters: none in-game, "#" on the end table.
	rank_label: string,
}

// Krunker abbreviates leaderboard numbers with k/m/b and two decimals.
scoreboard_format_stat :: proc(value: i64) -> string {
	magnitude := abs(value)
	switch {
	case magnitude >= 1_000_000_000: return fmt.tprintf("%.2fb", f64(value)/1e9)
	case magnitude >= 1_000_000: return fmt.tprintf("%.2fm", f64(value)/1e6)
	case magnitude >= 1_000: return fmt.tprintf("%.2fk", f64(value)/1e3)
	}
	return fmt.tprintf("%d", value)
}

// Column headers capitalize the browser stat key ("score" -> "Score").
scoreboard_column_label :: proc(key: string) -> string {
	if len(key) == 0 || key[0] < 'a' || key[0] > 'z' { return key }
	return fmt.tprintf("%c%s", key[0]-32, key[1:])
}

// Score descending; equal scores keep server/join order, as the browser's
// sort leaves ties in player-list order.
scoreboard_sort_rows :: proc(rows: []Scoreboard_Row) {
	slice.sort_by(rows, proc(a, b: Scoreboard_Row) -> bool {
		if a.sort_key != b.sort_key { return a.sort_key > b.sort_key }
		return a.order < b.order
	})
}

scoreboard_set_columns :: proc(board: ^Scoreboard, keys: []string) {
	board.column_count = min(len(keys), SCOREBOARD_MAX_COLUMNS)
	for key, i in keys[:board.column_count] { board.columns[i] = scoreboard_column_label(key) }
}

// Sorts, caps and groups rows. Team grouping follows the players' teams.
scoreboard_finish :: proc(board: ^Scoreboard, rows: []Scoreboard_Row) {
	scoreboard_sort_rows(rows)
	board.rows = rows[:min(len(rows), SCOREBOARD_MAX_ROWS)]
	for row in board.rows { if row.team == 1 || row.team == 2 { board.teams = true } }
}

// Live lobbies list exactly the players in the latest UPDATE_LEADERS batch, in
// server order, with that mode's leaderStats columns. Without a decoded board
// (unknown mode schema or none received yet) fall back to tracked totals.
scoreboard_from_world :: proc(world: ^kproto.Krunker_World_State) -> Scoreboard {
	board: Scoreboard
	rows := make([dynamic]Scoreboard_Row, 0, len(world.players), context.temp_allocator)
	stats, known := kproto.krunker_mode_leader_stats(world.mode_index)
	ranked := known && world.has_leaders
	for player, i in world.players {
		if player.sid == world.local_sid { board.local_team = player.team }
		if ranked && player.leader_rank <= 0 { continue }
		row := Scoreboard_Row{name = len(player.name) > 0 ? player.name : fmt.tprintf("Player %d", player.sid), team = player.team, is_you = player.sid == world.local_sid}
		if ranked {
			row.order = player.leader_rank
			for i in 0..<min(len(stats), kproto.KRUNKER_LEADER_MAX_STATS) { row.cells[i] = scoreboard_format_stat(i64(player.leader_stats[i])) }
		} else {
			row.order, row.sort_key = i32(i), f64(player.score)
			row.cells[0], row.cells[1], row.cells[2] = scoreboard_format_stat(i64(player.score)), scoreboard_format_stat(i64(player.kills)), scoreboard_format_stat(i64(player.deaths))
		}
		append(&rows, row)
	}
	scoreboard_set_columns(&board, ranked ? stats : SCOREBOARD_NATIVE_STATS[:])
	scoreboard_finish(&board, rows[:])
	return board
}

// Native server and local practice: the authoritative simulation's totals.
scoreboard_from_game :: proc(game: ^shared.Game) -> Scoreboard {
	board: Scoreboard
	rows := make([dynamic]Scoreboard_Row, 0, len(game.players), context.temp_allocator)
	for player in game.players {
		if player == nil { continue }
		if player.is_you { board.local_team = player.team }
		row := Scoreboard_Row{name = player.is_you ? "You" : fmt.tprintf("Player %d", player.uid), team = player.team, is_you = player.is_you, order = player.uid, sort_key = f64(player.score)}
		row.cells[0], row.cells[1], row.cells[2] = scoreboard_format_stat(i64(player.score)), scoreboard_format_stat(i64(player.kills)), scoreboard_format_stat(i64(player.deaths))
		append(&rows, row)
	}
	scoreboard_set_columns(&board, SCOREBOARD_NATIVE_STATS[:])
	scoreboard_finish(&board, rows[:])
	return board
}

client_scoreboard :: proc(client: ^Client) -> Scoreboard {
	board := client.krunker.connected ? scoreboard_from_world(&client.krunker_world) : scoreboard_from_game(&client.game)
	board.team_names = client_team_names(client)
	board.team_scores = client.game.match.team_scores
	return board
}

client_team_names :: proc(client: ^Client) -> [2]string {
	names := [2]string{"Alpha", "Bravo"}
	if client.game.config.team1_name != "Team 1" && len(client.game.config.team1_name) > 0 { names[0] = client.game.config.team1_name }
	if client.game.config.team2_name != "Team 2" && len(client.game.config.team2_name) > 0 { names[1] = client.game.config.team2_name }
	if client.krunker.connected {
		for name, i in client.krunker_world.lobby_team_names { if len(name) > 0 { names[i] = name } }
	}
	if client.net.connected { names = client.net.lobby.team_names }
	return names
}

// Krunker's default scoreBoardTrigger is Continuous (Hold). The board exists
// only in gameplay: menus own Tab for keyboard navigation.
client_scoreboard_update :: proc(client: ^Client, read := client_binding_down) -> bool {
	client.scoreboard_open = client.mouse_state.locked && client_action_down(client, .LEADERBOARD, read)
	return client.scoreboard_open
}

// Browser end-table name colors: you, teammates, then everyone else (#eb5656).
scoreboard_name_color :: proc(row: Scoreboard_Row, local_team: i32) -> shared.Vec4 {
	if row.is_you { return {1, 1, 1, 1} }
	if local_team > 0 && row.team == local_team { return {1, 1, 1, 0.6} }
	return shared.hex_to_vec(0xeb5656)
}

scoreboard_fit_text :: proc(ui: ^UI, text: string, size, width: f32) -> string {
	if ui_measure_text(ui, text, size) <= width { return text }
	for end := len(text)-1; end > 0; end -= 1 {
		candidate := fmt.tprintf("%s..", text[:end])
		if ui_measure_text(ui, candidate, size) <= width { return candidate }
	}
	return ""
}

SCOREBOARD_NAME_WIDTH :: 360.0
SCOREBOARD_STAT_WIDTH :: 120.0
SCOREBOARD_ROW_HEIGHT :: 44.0
SCOREBOARD_TEAM_HEIGHT :: 60.0
SCOREBOARD_COLUMN_HEIGHT :: 40.0

// Team groups are drawn side by side in team order; FFA uses one group. Each
// group numbers its own rows, like the browser's per-team containers.
scoreboard_group_size :: proc(board: ^Scoreboard, team: i32, s: f32) -> (width, height: f32, count: int) {
	for row in board.rows { if !board.teams || row.team == team { count += 1 } }
	width = (76 + SCOREBOARD_NAME_WIDTH + f32(board.column_count)*SCOREBOARD_STAT_WIDTH)*s
	height = ((board.teams ? SCOREBOARD_TEAM_HEIGHT : 0) + SCOREBOARD_COLUMN_HEIGHT + f32(count)*SCOREBOARD_ROW_HEIGHT + 12)*s
	return
}

scoreboard_render :: proc(ui: ^UI, board: ^Scoreboard, min_top: f32, centered := true) {
	s := ui.scale
	white := shared.Vec4{1, 1, 1, 1}
	muted := shared.Vec4{1, 1, 1, 0.55}
	panel := shared.Vec4{0, 0, 0, 0.6}
	if len(board.rows) == 0 {
		label := "Empty Lobby" // leaderboard.empty
		width := ui_measure_text(ui, label, 26*s) + 48*s
		x, y := (ui.width-width)*0.5, max(min_top, ui.height*0.4)
		ui_round_rect(ui, panel, x, y, width, 52*s, 6*s)
		ui_fill_text(ui, white, label, x+24*s, overlay_numeric_baseline(y, 52*s, 26*s), 26*s)
		return
	}
	groups: [2]i32 = {0, -1}
	if board.teams { groups = {1, 2} }
	total, tallest: f32
	visible := 0
	for team in groups {
		if team < 0 { continue }
		width, height, count := scoreboard_group_size(board, team, s)
		if count == 0 { continue }
		total += width + (visible > 0 ? 20*s : 0)
		tallest = max(tallest, height)
		visible += 1
	}
	x := (ui.width-total)*0.5
	top := centered ? max(min_top, (ui.height-tallest)*0.5) : min_top
	for team in groups {
		if team < 0 { continue }
		width, height, count := scoreboard_group_size(board, team, s)
		if count == 0 { continue }
		ui_round_rect(ui, panel, x, top, width, height, 6*s)
		y := top
		if board.teams {
			name, score := board.team_names[team-1], fmt.tprintf("%d", board.team_scores[team])
			ui_fill_rect(ui, MATCH_TEAM_COLORS[team-1], x, y+SCOREBOARD_TEAM_HEIGHT*s-3*s, width, 3*s)
			score_width := ui_measure_text(ui, score, 40*s)
			ui_fill_text(ui, white, scoreboard_fit_text(ui, name, 36*s, width-score_width-64*s), x+20*s, overlay_numeric_baseline(y, SCOREBOARD_TEAM_HEIGHT*s, 36*s), 36*s)
			ui_fill_text(ui, white, score, x+width-20*s-score_width, overlay_numeric_baseline(y, SCOREBOARD_TEAM_HEIGHT*s, 40*s), 40*s)
			y += SCOREBOARD_TEAM_HEIGHT*s
		}
		name_x := x + 64*s
		stats_x := name_x + SCOREBOARD_NAME_WIDTH*s
		column_size := 24*s
		ui_fill_text(ui, muted, "Name", name_x, overlay_numeric_baseline(y, SCOREBOARD_COLUMN_HEIGHT*s, column_size), column_size)
		if len(board.rank_label) > 0 { ui_fill_text(ui, muted, board.rank_label, name_x-12*s-ui_measure_text(ui, board.rank_label, column_size), overlay_numeric_baseline(y, SCOREBOARD_COLUMN_HEIGHT*s, column_size), column_size) }
		for column, i in board.columns[:board.column_count] {
			cx := stats_x + (f32(i)+0.5)*SCOREBOARD_STAT_WIDTH*s
			ui_fill_text(ui, muted, column, cx-ui_measure_text(ui, column, column_size)*0.5, overlay_numeric_baseline(y, SCOREBOARD_COLUMN_HEIGHT*s, column_size), column_size)
		}
		y += SCOREBOARD_COLUMN_HEIGHT*s
		rank := 1
		for row in board.rows {
			if board.teams && row.team != team { continue }
			if row.is_you { ui_fill_rect(ui, {1, 1, 1, 0.12}, x, y, width, SCOREBOARD_ROW_HEIGHT*s) }
			else if rank%2 == 0 { ui_fill_rect(ui, {1, 1, 1, 0.04}, x, y, width, SCOREBOARD_ROW_HEIGHT*s) }
			size := 30*s
			baseline := overlay_numeric_baseline(y, SCOREBOARD_ROW_HEIGHT*s, size)
			counter := fmt.tprintf("%d.", rank)
			ui_fill_text(ui, muted, counter, name_x-12*s-ui_measure_text(ui, counter, size), baseline, size)
			ui_fill_text(ui, scoreboard_name_color(row, board.local_team), scoreboard_fit_text(ui, row.name, size, SCOREBOARD_NAME_WIDTH*s-12*s), name_x, baseline, size)
			for i in 0..<board.column_count {
				cell := row.cells[i]
				cx := stats_x + (f32(i)+0.5)*SCOREBOARD_STAT_WIDTH*s
				ui_fill_text(ui, white, cell, cx-ui_measure_text(ui, cell, size)*0.5, baseline, size)
			}
			y += SCOREBOARD_ROW_HEIGHT*s
			rank += 1
		}
		x += width + 20*s
	}
}
