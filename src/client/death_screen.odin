package main

import "core:fmt"
import "core:math"
import glfw "vendor:glfw"
import shared "../shared"
import kproto "../krunker"

// Death screen and life transitions.
//
// Krunker (krunkbox game.deob.js, KILL_PLAYER handler near line 227456;
// Krunker-Reverse game.deob.js has the same markup):
//   - On your death it hides the game UI (toggleGameUI(false), which also
//     hides #topRight and its killfeed), adds .onDeathScrn to #uiBase and
//     fills #deathUIHolder at once. The pointer stays locked.
//   - Killed by another player: .death-ui-bottom, three columns. Left (the
//     killer): "[weapon]" in the skin's rarity colour with the weapon
//     image, then how many times they have killed you (killedBy), and under
//     it the player card with class icon, "lvl N" and the alias with one
//     career stat ("1.92 KDR"). Middle: "-" over "VS". Right (you): how many
//     times you have killed them, your "[weapon]" and image, your card,
//     class and name. .death-stats follows.
//   - Otherwise .death-ui-bottom-empty: "You" / "Died" with .death-stats.
//   - .death-stats rows, when the server sends them: Time Survived, Shots
//     Fired, Accuracy, Kills, Score ("Unknown" for a missing value).
//   - Kill Cams (kCams) pan the camera toward the killer (kill_cam.odin).
//   - After deathDelay (0xaf0 = 2800 ms) a still-locked pointer resumes
//     straight into enterGame (an automatic respawn); an unlocked one shows
//     the menu. START hides #deathUIHolder.
// The .death-ui-* stylesheet is not in either dump, so sizes below are
// Krodin's, laid out from the markup.
//
// Krodin's own, asked for by testers: the card waits DEATH_SCREEN_DELAY
// (the kill cam plays first) and then pops in; letterbox bars, a vignette
// and a red flash frame the death; the camera tilts and sinks when there is
// no kill cam; the respawn bar; the killer's health left; and a short fade
// when a life starts. None of it holds input: it is drawn only, and
// respawns follow the same timers as before.
DEATH_SCREEN_DELAY      :: 1.5   // Krodin: seconds before the card pops in
DEATH_SCREEN_POP        :: 0.45  // Krodin: pop-in length
DEATH_SCREEN_RESPAWN    :: 2.8   // Krunker deathDelay (0xaf0 ms)
DEATH_SCREEN_EXIT       :: 0.3   // Krodin: card and bars leave after respawn
DEATH_SCREEN_FLASH      :: 0.5   // Krodin: red flash at the moment of death
DEATH_SCREEN_BARS_IN    :: 0.6   // Krodin: letterbox slide in
DEATH_SCREEN_BAR_HEIGHT :: 0.085 // Krodin: each bar, fraction of the height
DEATH_SCREEN_TILT_TIME  :: 0.7   // Krodin: death camera without a kill cam
DEATH_SCREEN_TILT_ROLL  :: f32(0.14)
DEATH_SCREEN_TILT_DROP  :: f32(1.6)
SPAWN_IN_LENGTH         :: 0.4   // Krodin: fade when a life starts
SPAWN_IN_DARK           :: f32(0.55)
// A server that respawns on its own (auto_respawn) gets this long before
// the client asks itself, so a late snapshot never causes a second spawn.
DEATH_SCREEN_AUTO_MARGIN :: 1.0
// A kill record and the snapshot that ends your life can arrive a frame or
// two apart, in either order.
DEATH_SCREEN_RECORD_WINDOW :: 1.0
DEATH_SCREEN_RIVALS :: 32
DEATH_SCREEN_TEXT :: 32
DEATH_SCREEN_STAT_LABELS := [5]string{"Time Survived", "Shots Fired", "Accuracy", "Kills", "Score"}

Death_Rival :: struct {
	uid: i32,
	killed_you, you_killed: i32,
}

// The kill that ended your last life, from either kill source.
Death_Record :: struct {
	at: f64,
	valid: bool,
	killer_uid: i32,
	weapon_id: i32,
	headshot, fists, thrown: bool,
}

Death_Text :: struct {
	bytes: [DEATH_SCREEN_TEXT]u8,
	length: int,
}

Death_Side :: struct {
	name: Kill_Feed_Name,
	class_index: i32,
	weapon_id: i32,
	kills: i32,
	level: i32, // 0: unknown
}

Death_Stat :: struct {
	label: string,
	value: Death_Text,
}

Death_Screen :: struct {
	active: bool,
	died_at: f64,
	// Native and offline sessions: earliest client-side re-entry.
	respawn_at: f64,
	// When the next life started; the exit and spawn-in play from here.
	ended_at: f64,
	has_ended: bool,
	// How long the death lasted (0 for a first spawn).
	ended_after: f32,
	filled: bool,
	popped: bool,
	// Krunker resumes into enterGame once per death; a refused entry then
	// shows the menu with the server's reason.
	auto_requested: bool,
	auto_requested_at: f64,
	has_killer: bool,
	killer_uid: i32,
	killer, you: Death_Side,
	killer_stat: Death_Text,
	killer_health, killer_max_health: f32,
	headshot, fists, thrown: bool,
	stats: [5]Death_Stat,
	stat_count: int,
	// Death camera (no kill cam): the pose it tilts away from.
	tilt_base: shared.Vec3,
	tilt_rotation: shared.Vec3,
	tilting: bool,
	record: Death_Record,
	record_revision: u64,
	rivals: [DEATH_SCREEN_RIVALS]Death_Rival,
	rival_count: int,
	live_revision: u64,
	// Life tracking for the native stats and the spawn-in.
	was_active: bool,
	spawned_at: f64,
	kills_at_spawn, score_at_spawn: u32,
}

death_text :: proc(value: string) -> (text: Death_Text) {
	length := min(len(value), DEATH_SCREEN_TEXT)
	for length > 0 && length < len(value) && value[length] & 0xc0 == 0x80 { length -= 1 }
	text.length = copy(text.bytes[:], value[:length])
	return
}

death_text_string :: proc(text: ^Death_Text) -> string { return string(text.bytes[:text.length]) }

// Krunker's duration formatter as the death stats call it: "1h 2m 5s".
death_screen_duration :: proc(ms: f64) -> string {
	seconds := int(max(0, math.floor(ms / 1000)))
	hours, minutes := seconds / 3600, (seconds / 60) % 60
	seconds %= 60
	if hours > 0 { return fmt.tprintf("%dh %dm %ds", hours, minutes, seconds) }
	if minutes > 0 { return fmt.tprintf("%dm %ds", minutes, seconds) }
	return fmt.tprintf("%ds", seconds)
}

// lvl = max(1, floor(0.03 * sqrt(xp)) + 1).
death_screen_level :: proc(xp: f64) -> i32 {
	return max(1, i32(math.floor(0.03 * math.sqrt(max(0, xp)))) + 1)
}

death_screen_number :: proc(value: f64) -> string {
	if value == math.floor(value) { return fmt.tprintf("%d", i64(value)) }
	return fmt.tprintf("%.2f", value)
}

death_screen_value_text :: proc(value: ^kproto.Krunker_Death_Value) -> string {
	if !value.known { return "Unknown" }
	if value.is_text { return kproto.krunker_death_value_text(value) }
	return death_screen_number(value.number)
}

death_screen_rival :: proc(ds: ^Death_Screen, uid: i32) -> ^Death_Rival {
	for i in 0..<ds.rival_count {
		if ds.rivals[i].uid == uid { return &ds.rivals[i] }
	}
	if ds.rival_count == DEATH_SCREEN_RIVALS {
		copy(ds.rivals[:DEATH_SCREEN_RIVALS-1], ds.rivals[1:])
		ds.rival_count -= 1
	}
	ds.rivals[ds.rival_count] = {uid = uid}
	ds.rival_count += 1
	return &ds.rivals[ds.rival_count-1]
}

// Krunker's killedBy counters between you and one player.
death_screen_tally :: proc(ds: ^Death_Screen, local_uid, victim, killer: i32) {
	if killer < 0 || local_uid < 0 || victim == killer { return }
	if victim == local_uid { death_screen_rival(ds, killer).killed_you += 1 }
	else if killer == local_uid { death_screen_rival(ds, victim).you_killed += 1 }
}

client_death_screen_local_uid :: proc(client: ^Client) -> i32 {
	if client.krunker.connected { return client.krunker_world.local_sid }
	return client.me != nil ? client.me.uid : -1
}

// Reads this frame's kill sources before the killfeed drains them.
client_death_screen_track :: proc(client: ^Client, now: f64) {
	ds := &client.death_screen
	local := client_death_screen_local_uid(client)
	if client.krunker.connected {
		world := &client.krunker_world
		for kill in world.kills {
			// Your own deaths are counted from the death revision below,
			// which also covers kills the server hid from the feed.
			if kill.victim_sid != local { death_screen_tally(ds, local, kill.victim_sid, kill.killer_sid) }
		}
		if world.local_death_revision < ds.record_revision { ds.record_revision = world.local_death_revision }
		if world.local_death_revision != ds.record_revision {
			ds.record_revision = world.local_death_revision
			record := Death_Record{at = now, valid = true, killer_uid = world.local_killer_sid, weapon_id = world.local_death.weapon_id}
			for kill in world.kills {
				if kill.victim_sid != local { continue }
				record.headshot, record.fists, record.thrown = kill.headshot, kill.fists, kill.thrown
				if record.weapon_id < 0 { record.weapon_id = kill.weapon_id }
			}
			ds.record = record
			death_screen_tally(ds, local, local, record.killer_uid)
		}
	} else {
		for event in client.game.kill_events {
			death_screen_tally(ds, local, event.victim_uid, event.killer_uid)
			if event.victim_uid == local && local >= 0 {
				ds.record = {at = now, valid = true, killer_uid = event.killer_uid, weapon_id = event.weapon_id, headshot = event.headshot}
			}
		}
	}
}

// Starts the death screen for a local death. True while the pointer should
// stay locked, as Krunker keeps it through deathDelay. The unlock sites
// (client_lobby_tick, krunker_client_sync_world) ask this first.
client_death_screen_begin :: proc(client: ^Client, now: f64) -> bool {
	ds := &client.death_screen
	if client_match_ended(client) || client.end_screen_active { return false }
	if !ds.active {
		if client.krunker.connected {
			// Only KILL_PLAYER for you is a death; a round switch or
			// removal also ends the life without one.
			world := &client.krunker_world
			if world.local_death_revision < ds.live_revision { ds.live_revision = world.local_death_revision }
			if world.local_death_revision == ds.live_revision { return false }
			ds.live_revision = world.local_death_revision
		} else {
			// Native lives end only through player_kill.
			if client.me == nil || client.me.active || !ds.was_active { return false }
		}
		death_screen_start(client, now)
	}
	return client.mouse_state.locked
}

death_screen_start :: proc(client: ^Client, now: f64) {
	ds := &client.death_screen
	ds.active, ds.died_at, ds.has_ended, ds.ended_after = true, now, false, 0
	ds.filled, ds.popped, ds.tilting, ds.auto_requested = false, false, false, false
	if !client.krunker.connected {
		delay := f64(max(0, client.game.config.respawn_delay))
		// The authority respawns on its own; ask only if it has not.
		ds.respawn_at = now + (client.game.config.auto_respawn != 0 ? delay + DEATH_SCREEN_AUTO_MARGIN : max(DEATH_SCREEN_RESPAWN, delay))
	}
}

// The automatic re-entry of a still-locked pointer waits for Krunker's
// deathDelay (live) or the authority's respawn timer (native and offline),
// and is asked for once per death. Without a death screen nothing waits.
client_death_screen_allows_respawn :: proc(client: ^Client, now: f64) -> bool {
	ds := &client.death_screen
	if !ds.active { return true }
	if ds.auto_requested { return false }
	ready := client.krunker.connected ? krunker_client_respawn_remaining(client, now) <= 0 : now >= ds.respawn_at
	if ready { ds.auto_requested, ds.auto_requested_at = true, now }
	return ready
}

// Seconds until the respawn and that wait's length, for the respawn bar.
client_death_screen_respawn :: proc(client: ^Client, now: f64) -> (remaining, total: f32) {
	ds := &client.death_screen
	if client.krunker.connected {
		return krunker_client_respawn_remaining(client, now), DEATH_SCREEN_RESPAWN
	}
	total = max(0, client.game.config.respawn_delay)
	if client.game.config.auto_respawn == 0 { total = max(DEATH_SCREEN_RESPAWN, total) }
	return max(0, total - f32(now - ds.died_at)), total
}

death_screen_side_name :: proc(client: ^Client, uid: i32, is_you: bool) -> Kill_Feed_Name {
	local_team: i32 = client.me != nil ? client.me.team : 0
	team: i32
	text := fmt.tprintf("Player %d", uid)
	if client.krunker.connected {
		for &player in client.krunker_world.players {
			if player.sid == client.krunker_world.local_sid { local_team = player.team }
		}
		for &player in client.krunker_world.players {
			if player.sid != uid { continue }
			team = player.team
			if len(player.name) > 0 { text = player.name }
		}
	} else if player := client_find_player(client, uid); player != nil {
		team = player.team
	}
	name := kill_feed_name(text, false, team, local_team)
	// Krunker writes your own alias in white on your side of the card.
	if is_you {
		if !client.krunker.connected { name = kill_feed_name("You", true, 0, 0) }
		name.color = KILL_FEED_YOU_COLOR
	}
	return name
}

// Builds the card from the death record (or "You Died" without a killer).
client_death_screen_fill :: proc(client: ^Client, now: f64) {
	ds := &client.death_screen
	me := client.me
	ds.filled = true
	ds.stat_count = 0
	record := ds.record
	usable := record.valid && record.at >= ds.died_at - DEATH_SCREEN_RECORD_WINDOW
	local := client_death_screen_local_uid(client)
	ds.has_killer = usable && record.killer_uid >= 0 && record.killer_uid != local
	ds.headshot, ds.fists, ds.thrown = usable && record.headshot, usable && record.fists, usable && record.thrown
	ds.killer_uid = ds.has_killer ? record.killer_uid : -1
	ds.killer_stat = {}
	ds.killer_health, ds.killer_max_health = 0, 0
	if ds.has_killer {
		killer := client_find_player(client, ds.killer_uid)
		rival := death_screen_rival(ds, ds.killer_uid)
		ds.killer = {name = death_screen_side_name(client, ds.killer_uid, false), class_index = -1, weapon_id = -1, kills = rival.killed_you}
		ds.you = {name = death_screen_side_name(client, local, true), class_index = -1, weapon_id = -1, kills = rival.you_killed}
		if killer != nil {
			ds.killer.class_index = killer.class_index
			ds.killer_health, ds.killer_max_health = max(0, killer.health), f32(killer.max_health)
		}
		weapon := record.weapon_id
		if weapon < 0 && !record.fists { weapon = kill_feed_equipped_weapon(killer) }
		ds.killer.weapon_id = kill_feed_valid_weapon(client, weapon)
		if me != nil {
			ds.you.class_index = me.class_index
			ds.you.weapon_id = kill_feed_valid_weapon(client, kill_feed_equipped_weapon(me))
		}
	}
	if client.krunker.connected {
		info := &client.krunker_world.local_death
		if ds.has_killer {
			if info.killer_xp.known && !info.killer_xp.is_text { ds.killer.level = death_screen_level(info.killer_xp.number) }
			if info.stat_index >= 0 && info.stat.known {
				ds.killer_stat = death_text(fmt.tprintf("%s %s", death_screen_value_text(&info.stat), kproto.KRUNKER_DEATH_STAT_NAMES[info.stat_index]))
			}
		}
		if info.has_stats {
			for i in 0..<len(info.stats) {
				value := &info.stats[i]
				text := i == 0 && value.known && !value.is_text ? death_screen_duration(value.number) : death_screen_value_text(value)
				ds.stats[i] = {label = DEATH_SCREEN_STAT_LABELS[i], value = death_text(text)}
			}
			ds.stat_count = len(info.stats)
		}
	} else if me != nil {
		// The native sim keeps no shot counters; show what it does track.
		survived := ds.spawned_at > 0 ? (ds.died_at - ds.spawned_at) * 1000 : 0
		ds.stats[0] = {label = DEATH_SCREEN_STAT_LABELS[0], value = death_text(death_screen_duration(survived))}
		ds.stats[1] = {label = DEATH_SCREEN_STAT_LABELS[3], value = death_text(fmt.tprintf("%d", me.kills >= ds.kills_at_spawn ? me.kills - ds.kills_at_spawn : 0))}
		ds.stats[2] = {label = DEATH_SCREEN_STAT_LABELS[4], value = death_text(fmt.tprintf("%d", me.score >= ds.score_at_spawn ? me.score - ds.score_at_spawn : 0))}
		ds.stat_count = 3
	}
}

// Once per frame after the kill cam, before the killfeed drain.
client_death_screen_update :: proc(client: ^Client, now: f64) {
	ds := &client.death_screen
	client_death_screen_track(client, now)
	me := client.me
	alive := me != nil && me.active
	if alive && !ds.was_active {
		// START / spawn: the card leaves and the new life fades in.
		ds.ended_after = ds.active ? f32(now - ds.died_at) : 0
		ds.active, ds.ended_at, ds.has_ended = false, now, true
		ds.spawned_at = now
		ds.kills_at_spawn, ds.score_at_spawn = me.kills, me.score
		if ds.tilting { client.camera.rotation.z = 0 }
		ds.tilting = false
	}
	if !alive && ds.was_active && !ds.active { client_death_screen_begin(client, now) }
	ds.was_active = alive
	if !ds.active { return }
	if me == nil || client_match_ended(client) || client.end_screen_active {
		ds.active, ds.has_ended = false, false
		if ds.tilting { client.camera.rotation.z = 0 }
		ds.tilting = false
		return
	}
	// The server refused the automatic entry (fe, or no confirmation):
	// show the menu and its reason instead of a death screen that never ends.
	if ds.auto_requested && !client.spawn_pending && client.mouse_state.locked && now - ds.auto_requested_at > 0.25 && client.krunker.connected {
		if client.window != nil { glfw.SetInputMode(client.window, glfw.CURSOR, glfw.CURSOR_NORMAL) }
		client.mouse_state.locked = false
	}
	elapsed := now - ds.died_at
	if !ds.filled && (ds.record.valid && ds.record.at >= ds.died_at - DEATH_SCREEN_RECORD_WINDOW || elapsed > DEATH_SCREEN_RECORD_WINDOW) {
		client_death_screen_fill(client, now)
	}
	if !ds.popped && elapsed >= DEATH_SCREEN_DELAY {
		ds.popped = true
		if !ds.filled { client_death_screen_fill(client, now) }
		audio_play_effect(client.audio, "woosh_0", .UI, 0.35)
	}
	// Krodin's death camera when no kill cam is panning.
	if client.kill_cam.active || client.freecam_enabled {
		ds.tilting = false
		return
	}
	if !ds.tilting {
		ds.tilting = true
		ds.tilt_base, ds.tilt_rotation = client.camera.position, client.camera.rotation
	}
	p := death_ease_out(f32(elapsed) / DEATH_SCREEN_TILT_TIME)
	client.camera.position = ds.tilt_base - shared.Vec3{0, DEATH_SCREEN_TILT_DROP * p, 0}
	client.camera.rotation = {ds.tilt_rotation.x, ds.tilt_rotation.y, DEATH_SCREEN_TILT_ROLL * p}
}

// The game HUD stays hidden while dead (Krunker's toggleGameUI(false)).
client_death_screen_hides_hud :: proc(client: ^Client) -> bool { return client.death_screen.active }

death_ease_out :: proc(t: f32) -> f32 {
	x := clamp(t, 0, 1)
	return 1 - (1-x)*(1-x)*(1-x)
}

// easeOutBack: overshoots by about 10% and settles.
death_ease_back :: proc(t: f32) -> f32 {
	x := clamp(t, 0, 1)
	c1 :: f32(1.70158)
	c3 :: c1 + 1
	return 1 + c3*(x-1)*(x-1)*(x-1) + c1*(x-1)*(x-1)
}

death_alpha :: proc(color: shared.Vec4, alpha: f32) -> shared.Vec4 { return {color.x, color.y, color.z, color.w * clamp(alpha, 0, 1)} }

// Letterbox, vignette and the death flash. bars and mood run 0..1.
death_screen_frame_render :: proc(ui: ^UI, bars, mood, flash: f32) {
	if mood > 0 {
		ui_fill_rect(ui, {0, 0, 0, 0.28 * mood}, 0, 0, ui.width, ui.height)
		if ui.vignette != 0 { ui_draw_image(ui, ui.vignette, 0, 0, ui.width, ui.height, {0, 0, 0, 0.85 * mood}) }
	}
	if flash > 0 {
		if ui.vignette != 0 { ui_draw_image(ui, ui.vignette, 0, 0, ui.width, ui.height, {0.75, 0.05, 0.05, flash}) }
		ui_fill_rect(ui, {0.6, 0.02, 0.02, 0.22 * flash}, 0, 0, ui.width, ui.height)
	}
	if bars > 0 {
		h := ui.height * DEATH_SCREEN_BAR_HEIGHT * bars
		ui_fill_rect(ui, {0, 0, 0, 1}, 0, 0, ui.width, h)
		ui_fill_rect(ui, {0, 0, 0, 1}, 0, ui.height - h, ui.width, h)
	}
}

death_class_icon :: proc(client: ^Client, class_index: i32) -> Gpu_Texture {
	if class_index < 0 || int(class_index) >= len(client.game.classes) { return 0 }
	icon_index := client.game.classes[class_index].icon_index
	if class_icons == nil { class_icons = make(map[i32]Gpu_Texture) }
	icon, cached := class_icons[icon_index]
	if !cached {
		path := shared.concat(shared.assets_path(), fmt.tprintf("textures/classes/icon_%d.png", icon_index))
		icon = load_texture(path)
		delete(path)
		class_icons[icon_index] = icon
	}
	return icon
}

DEATH_CARD_SIDE   :: f32(360) // one column, CSS px before the HUD scale
DEATH_CARD_CENTER :: f32(120) // the "- / VS" column
DEATH_CARD_HEIGHT :: f32(160)
DEATH_MUTED :: shared.Vec4{1, 1, 1, 0.7}

// One side of the VS card. mirrored: the right (your) side, kills first.
death_card_side_render :: proc(client: ^Client, side: ^Death_Side, stat: string, health, max_health: f32, x, y, s, alpha: f32, mirrored: bool) {
	ui := client.ui
	w := DEATH_CARD_SIDE * s
	white := death_alpha({1, 1, 1, 1}, alpha)
	muted := death_alpha(DEATH_MUTED, alpha)
	// Row 1: [weapon] + image, and the kill count toward the middle.
	icon, weapon := overlay_weapon_icon(client, side.weapon_id)
	label := weapon != nil ? fmt.tprintf("[%s]", weapon.name) : ""
	if side.weapon_id < 0 && !mirrored && client.death_screen.fists { label = "[Fists]" }
	if !mirrored && client.death_screen.thrown && len(label) > 0 { label = fmt.tprintf("Thrown %s", label) }
	kills := fmt.tprintf("%d", side.kills)
	kills_size := 46 * s
	kills_width := ui_measure_text(ui, kills, kills_size)
	label_size := 20 * s
	img_w, img_h := 96 * s, 48 * s
	row_baseline := y + 44 * s
	if !mirrored {
		right := x + w
		ui_fill_text(ui, white, kills, right - kills_width, row_baseline + 4 * s, kills_size)
		cursor := right - kills_width - 18 * s
		if icon != 0 {
			cursor -= img_w
			ui_draw_image(ui, icon, cursor, y + 4 * s, img_w, img_h, muted, true)
			cursor -= 8 * s
		}
		if client.death_screen.headshot {
			if hs := kill_feed_load_icon(&kill_feed_icon_headshot, "img/headshot_0.png"); hs != 0 {
				cursor -= 30 * s
				ui_draw_image(ui, hs, cursor, y + 12 * s, 28 * s, 28 * s, white)
				cursor -= 6 * s
			}
		}
		ui_fill_text(ui, muted, label, cursor - ui_measure_text(ui, label, label_size), row_baseline - 4 * s, label_size)
	} else {
		ui_fill_text(ui, white, kills, x, row_baseline + 4 * s, kills_size)
		cursor := x + kills_width + 18 * s
		ui_fill_text(ui, muted, label, cursor, row_baseline - 4 * s, label_size)
		cursor += ui_measure_text(ui, label, label_size) + 8 * s
		if icon != 0 { ui_draw_image(ui, icon, cursor, y + 4 * s, img_w, img_h, muted) }
	}
	// Row 2: the player card.
	card_y := y + 62 * s
	card_h := 92 * s
	ui_round_rect(ui, {0, 0, 0, 0.55 * alpha}, x, card_y, w, card_h, 8 * s)
	ui_fill_rect(ui, death_alpha(side.name.color, alpha * 0.9), mirrored ? x : x + w - 4 * s, card_y + 10 * s, 4 * s, card_h - 20 * s)
	class_size := 64 * s
	class_x := x + 12 * s
	if class_icon := death_class_icon(client, side.class_index); class_icon != 0 {
		ui_draw_image(ui, class_icon, class_x, card_y + 8 * s, class_size, class_size, white)
	}
	if side.level > 0 {
		level := fmt.tprintf("lvl %d", side.level)
		ui_fill_text(ui, muted, level, class_x + (class_size - ui_measure_text(ui, level, 14 * s)) * 0.5, card_y + card_h - 6 * s, 14 * s)
	}
	text_x := class_x + class_size + 14 * s
	name := kill_feed_name_text(&side.name)
	ui_fill_text(ui, death_alpha(side.name.color, alpha), name, text_x, card_y + 40 * s, 28 * s)
	if len(stat) > 0 { ui_fill_text(ui, muted, stat, text_x, card_y + 66 * s, 17 * s) }
	// Krodin: the killer's health left, as the kill cam's bar shows it.
	if max_health > 0 {
		bar_w := w - (text_x - x) - 20 * s
		bar_y := card_y + card_h - 14 * s
		ratio := clamp(health / max_health, 0, 1)
		ui_round_rect(ui, {1, 1, 1, 0.15 * alpha}, text_x, bar_y, bar_w, 5 * s, 2.5 * s)
		if ratio > 0 { ui_round_rect(ui, death_alpha(shared.hex_to_vec(0x9eeb56), alpha), text_x, bar_y, bar_w * ratio, 5 * s, 2.5 * s) }
		hp := fmt.tprintf("%d HP", int(math.ceil(health)))
		ui_fill_text(ui, muted, hp, x + w - 16 * s - ui_measure_text(ui, hp, 18 * s), card_y + 28 * s, 18 * s)
	}
}

// The death card. t: seconds since it popped; leave: 0..1 on the way out.
death_card_render :: proc(client: ^Client, t, leave: f32) {
	ui := client.ui
	ds := &client.death_screen
	p := clamp(t / DEATH_SCREEN_POP, 0, 1)
	pop := 0.55 + 0.45 * death_ease_back(p)
	alpha := clamp(p * 3, 0, 1) * (1 - leave)
	if alpha <= 0 { return }
	s := ui.scale * pop
	slide := (1 - death_ease_out(p)) * 140 * ui.scale
	drop := death_ease_out(leave) * 60 * ui.scale
	cx := ui.width * 0.5
	bars := ui.height * DEATH_SCREEN_BAR_HEIGHT
	cy := ui.height - bars - (DEATH_CARD_HEIGHT * 0.5 + 34) * ui.scale + drop
	top := cy - DEATH_CARD_HEIGHT * 0.5 * s
	white := death_alpha({1, 1, 1, 1}, alpha)
	if ds.has_killer {
		half := DEATH_CARD_CENTER * 0.5 * s
		stat := death_text_string(&ds.killer_stat)
		death_card_side_render(client, &ds.killer, stat, ds.killer_health, ds.killer_max_health, cx - half - DEATH_CARD_SIDE * s - slide, top, s, alpha, false)
		death_card_side_render(client, &ds.you, "", 0, 0, cx + half + slide, top, s, alpha, true)
		// The middle column pops a beat later and harder.
		vp := clamp((t - 0.12) / DEATH_SCREEN_POP, 0, 1)
		vs_scale := 0.3 + 0.7 * death_ease_back(vp)
		vs_alpha := clamp(vp * 3, 0, 1) * (1 - leave)
		dash_size := 34 * s
		ui_fill_text(ui, death_alpha(DEATH_MUTED, vs_alpha), "-", cx - ui_measure_text(ui, "-", dash_size) * 0.5, top + 44 * s, dash_size)
		vs_size := 56 * s * vs_scale
		ui_fill_text(ui, death_alpha({1, 1, 1, 1}, vs_alpha), "VS", cx - ui_measure_text(ui, "VS", vs_size) * 0.5, top + 62 * s + 50 * s, vs_size)
	} else {
		// .death-ui-bottom-empty: "You" over "Died".
		size := 72 * s
		ui_fill_text(ui, white, "You", cx - ui_measure_text(ui, "You", size) * 0.5, top + 62 * s, size)
		ui_fill_text(ui, death_alpha(KILL_FEED_ENEMY_COLOR, alpha), "Died", cx - ui_measure_text(ui, "Died", size) * 0.5, top + 136 * s, size)
	}
}

// .death-stats, laid along the top letterbox bar.
death_stats_render :: proc(client: ^Client, alpha: f32) {
	ui := client.ui
	ds := &client.death_screen
	if ds.stat_count == 0 || alpha <= 0 { return }
	s := ui.scale
	size := 26 * s
	gap := 44 * s
	total: f32
	for i in 0..<ds.stat_count {
		stat := &ds.stats[i]
		total += ui_measure_text(ui, fmt.tprintf("%s : ", stat.label), size) + ui_measure_text(ui, death_text_string(&stat.value), size)
		if i > 0 { total += gap }
	}
	x := (ui.width - total) * 0.5
	bar := ui.height * DEATH_SCREEN_BAR_HEIGHT
	baseline := max(bar * 0.5 + size * 0.35, 30 * s)
	for i in 0..<ds.stat_count {
		stat := &ds.stats[i]
		label := fmt.tprintf("%s : ", stat.label)
		x += ui_fill_text(ui, {1, 1, 1, alpha}, label, x, baseline, size)
		x += ui_fill_text(ui, {1, 1, 1, 0.7 * alpha}, death_text_string(&stat.value), x, baseline, size)
		x += gap
	}
}

// Krodin: the respawn wait in the bottom bar.
death_respawn_render :: proc(client: ^Client, now: f64, alpha: f32) {
	ui := client.ui
	if alpha <= 0 { return }
	s := ui.scale
	remaining, total := client_death_screen_respawn(client, now)
	bar := ui.height * DEATH_SCREEN_BAR_HEIGHT
	label := remaining > 0 ? fmt.tprintf("RESPAWNING IN %.1f", remaining) : "RESPAWNING"
	size := 24 * s
	baseline := ui.height - bar * 0.5 - 2 * s
	ui_fill_text(ui, {1, 1, 1, 0.85 * alpha}, label, (ui.width - ui_measure_text(ui, label, size)) * 0.5, baseline, size)
	w := 280 * s
	x := (ui.width - w) * 0.5
	y := baseline + 10 * s
	progress := total > 0 ? clamp(1 - remaining / total, 0, 1) : 1
	ui_fill_rect(ui, {1, 1, 1, 0.18 * alpha}, x, y, w, 3 * s)
	ui_fill_rect(ui, {1, 1, 1, 0.9 * alpha}, x, y, w * progress, 3 * s)
}

// Everything the death screen draws, over the world and instead of the HUD
// while dead; after a respawn only the exit and the spawn-in fade.
death_screen_render :: proc(client: ^Client, now: f64) {
	ds := &client.death_screen
	ui := client.ui
	if ds.active {
		t := f32(now - ds.died_at)
		bars := death_ease_out(t / DEATH_SCREEN_BARS_IN)
		flash := 1 - clamp(t / DEATH_SCREEN_FLASH, 0, 1)
		death_screen_frame_render(ui, bars, death_ease_out(t / DEATH_SCREEN_DELAY), flash * flash)
		if t >= DEATH_SCREEN_DELAY {
			card_t := t - DEATH_SCREEN_DELAY
			death_card_render(client, card_t, 0)
			fade := clamp(card_t / DEATH_SCREEN_POP, 0, 1)
			death_stats_render(client, fade)
			death_respawn_render(client, now, fade)
		}
		return
	}
	if !ds.has_ended { return }
	e := f32(now - ds.ended_at)
	if ds.ended_after > 0 && e < DEATH_SCREEN_EXIT {
		leave := e / DEATH_SCREEN_EXIT
		from := death_ease_out(ds.ended_after / DEATH_SCREEN_BARS_IN)
		mood := death_ease_out(ds.ended_after / DEATH_SCREEN_DELAY)
		death_screen_frame_render(ui, from * (1 - death_ease_out(leave)), mood * (1 - leave), 0)
		if ds.ended_after >= DEATH_SCREEN_DELAY { death_card_render(client, ds.ended_after - DEATH_SCREEN_DELAY, leave) }
	}
	if e < SPAWN_IN_LENGTH {
		dark := SPAWN_IN_DARK * (1 - death_ease_out(e / SPAWN_IN_LENGTH))
		ui_fill_rect(ui, {0, 0, 0, dark}, 0, 0, ui.width, ui.height)
	}
}
