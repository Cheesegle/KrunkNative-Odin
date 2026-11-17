package main

import "core:math"
import "core:testing"
import "core:time"
import shared "../shared"

when ODIN_TEST {
	// Local Practice used to stop for good when the clock ran out: a solo
	// player's 0:0 tie went into an overtime nothing could end, and a decided
	// match stayed ENDED with movement locked. Krunker's endGame shows the end
	// screen, waits endTimer (25 s), then initNewGameAsync starts a new game.
	@(test)
	local_practice_match_end_restarts :: proc(t: ^testing.T) {
		started := time.tick_now()
		config := shared.config_load_gameplay()
		defer shared.config_destroy_gameplay(config)
		config.game.game_time = 1
		config.game.warmup_time = 0
		floor := shared.Object{active = true, collision_type = .BOX, position = {0, -10, 0}, scale = {400, 10, 400}}
		map_inst := shared.Map{death_y = -1000}
		append(&map_inst.objects, &floor)
		defer delete(map_inst.objects)
		maps := []^shared.Map{&map_inst}

		client := Client{local_practice = true}
		shared.game_configure(&client.game, &config.game, maps, nil, config.weapons, config.classes)
		shared.game_init(&client.game, 0, 0, true)
		defer {
			client_clear_players(&client)
			shared.game_destroy(&client.game)
		}
		spawn_me :: proc(client: ^Client) {
			me := shared.player_init(&client.game)
			shared.game_players_add(&client.game, me)
			me.is_you, me.team = true, 1
			shared.player_spawn(me, 0)
			client.me, client.in_game, client.has_life = me, true, true
		}
		spawn_me(&client)
		testing.expect(t, client.game.match.phase == .LIVE && client.game.match.time_remaining == 60)

		DT :: f32(1.0 / 64.0)
		now: f32
		ended_at, restarted_at: f32 = -1, -1
		end_screen_frames := 0
		for _ in 0 ..< int((60 + shared.GAME_END_TIMER + 10) / DT) {
			if time.tick_since(started) > 60 * time.Second {
				testing.fail_now(t, "deadline: the match end and the next match start took too long")
			}
			now += DT
			shared.game_tick(&client.game, now, DT)
			client_local_new_game(&client)
			if client_end_screen_update(&client, f64(now), false) {
				end_screen_frames += 1
				if ended_at < 0 {
					ended_at = now
					testing.expect(t, client.game.move_lock && !client.game.match.overtime, "endGame locks movement; a tie is not an endless overtime")
					screen := client_end_screen(&client)
					testing.expectf(t, screen.result == .DRAW, "a solo 0:0 tie is a draw, got %v", screen.result)
				}
			}
			if ended_at >= 0 && client.game.match.phase == .LIVE {
				restarted_at = now
				break
			}
		}
		testing.expectf(t, math.abs(ended_at - 60) < 0.1, "the match ends when the 1 minute clock runs out, at %v", ended_at)
		testing.expectf(t, math.abs(restarted_at - ended_at - shared.GAME_END_TIMER) < 0.1, "the next game starts after Krunker's 25 s endTimer, %v -> %v", ended_at, restarted_at)
		testing.expect(t, end_screen_frames > int(24 / DT), "the end screen stays up through the intermission")
		testing.expect(t, client.me == nil && !client.in_game && !client.has_life && len(client.game.players) == 0, "everyone is back at the menu to deploy into the new game")
		testing.expect(t, !client.game.move_lock && !client.game.new_game_pending && client.game.end_timer == 0)
		testing.expect(t, !client.end_screen_active, "the end screen closes with the new game")
		testing.expect(t, client.game.match.time_remaining == 60 && client.game.map_inst == &map_inst)

		// The new game plays: deploy again, the clock runs and nothing is locked.
		spawn_me(&client)
		for _ in 0 ..< 64 {
			now += DT
			shared.game_tick(&client.game, now, DT)
			client_local_new_game(&client)
		}
		testing.expect(t, client.me.active && client.game.match.phase == .LIVE)
		testing.expectf(t, math.abs(client.game.match.time_remaining - 59) < 0.05, "the new clock counts down, %v", client.game.match.time_remaining)
	}

	// A decided match ends at once with the same intermission, and the
	// objective stays the only thing that can hold the clock at zero.
	@(test)
	local_match_end_rules :: proc(t: ^testing.T) {
		game := shared.Game{ready = true, is_local = true}
		game.match = {phase = .LIVE, rounds_to_win = 1, time_remaining = 0.01, team_scores = {0, 30, 10}}
		game.match.objective.active_object_index = -1
		shared.game_update_match(&game, 0.02)
		testing.expect(t, game.match.phase == .ENDED && game.match.round_wins[1] == 1 && game.move_lock && game.end_timer == shared.GAME_END_TIMER)

		game.match = {phase = .LIVE, rounds_to_win = 1, time_remaining = 0.01}
		game.match.objective = {active_object_index = -1, contested = true}
		game.move_lock, game.end_timer = false, 0
		shared.game_update_match(&game, 0.02)
		testing.expect(t, game.match.phase == .LIVE && game.match.overtime, "a contested objective still holds the clock (Krodin's rule)")
		game.match.objective.contested = false
		shared.game_update_match(&game, 0.02)
		testing.expect(t, game.match.phase == .ENDED && !game.match.overtime, "once uncontested, the tie ends as a draw")

		// Best-of rounds keep playing after a drawn round.
		game.match = {phase = .LIVE, rounds_to_win = 2, round_current = 1, time_remaining = 0.01}
		game.match.objective.active_object_index = -1
		shared.game_update_match(&game, 0.02)
		testing.expect(t, game.match.phase == .LIVE && game.match.round_current == 2)

		// The intermission only counts down; the owner starts the next game.
		game.match = {phase = .ENDED}
		game.end_timer, game.new_game_pending = 1, false
		shared.game_update_match(&game, 0.5)
		testing.expect(t, !game.new_game_pending && game.end_timer == 0.5)
		shared.game_update_match(&game, 0.6)
		testing.expect(t, game.new_game_pending && game.end_timer == 0)
	}
}
