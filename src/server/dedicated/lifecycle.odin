package dedicated

// Match lifecycle: PLAYING until the sim reports the match ENDED, then an
// intermission (Krunker's endTimer, 25 s on public games) on the end screen,
// then the next rotation map. Driven only by the sim delta, so tests can run
// it with fake time.

import shared "../../shared"

Lifecycle_State :: enum u8 {
	PLAYING,
	INTERMISSION,
}

Lifecycle :: struct {
	state:        Lifecycle_State,
	intermission: f32,
	remaining:    f32,
	rotation:     []i32, // ROTATION_MAPS slots, borrowed from the settings
	order:        Rotation_Order,
	position:     int, // index into rotation of the map being played
	rng:          u64,
	matches:      int, // matches started, including the first
}

lifecycle_init :: proc(lc: ^Lifecycle, rotation: []i32, order: Rotation_Order, intermission: f32, seed: u64) {
	lc^ = Lifecycle{
		intermission = intermission,
		rotation     = rotation,
		order        = order,
		rng          = seed != 0 ? seed : 0x9E3779B97F4A7C15,
	}
	if order == .SHUFFLE && len(rotation) > 1 {
		lc.position = int(lifecycle_rand(lc) % u64(len(rotation)))
	}
}

// xorshift64*: deterministic for a given seed, no global state.
@(private)
lifecycle_rand :: proc(lc: ^Lifecycle) -> u64 {
	x := lc.rng
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	lc.rng = x
	return x * 0x2545F4914F6CDD1D
}

lifecycle_current_slot :: proc(lc: ^Lifecycle) -> i32 {
	if len(lc.rotation) == 0 { return -1 }
	return lc.rotation[lc.position]
}

// lifecycle_advance moves to the next map. Shuffle never repeats the map just
// played when there is another to choose.
lifecycle_advance :: proc(lc: ^Lifecycle) -> i32 {
	n := len(lc.rotation)
	if n == 0 { return -1 }
	switch lc.order {
	case .SEQUENTIAL:
		lc.position = (lc.position + 1) % n
	case .SHUFFLE:
		if n > 1 {
			step := 1 + int(lifecycle_rand(lc) % u64(n - 1))
			lc.position = (lc.position + step) % n
		}
	}
	return lc.rotation[lc.position]
}

// lifecycle_update returns start_next = true exactly once per ended match,
// when the intermission has run out; the caller then loads next_slot.
lifecycle_update :: proc(lc: ^Lifecycle, phase: shared.Match_Phase, delta: f32) -> (start_next: bool, next_slot: i32) {
	switch lc.state {
	case .PLAYING:
		if phase == .ENDED {
			lc.state = .INTERMISSION
			lc.remaining = lc.intermission
		}
	case .INTERMISSION:
		lc.remaining = max(0, lc.remaining - delta)
		if lc.remaining <= 0 {
			lc.state = .PLAYING
			lc.matches += 1
			return true, lifecycle_advance(lc)
		}
	}
	return false, -1
}

// ---------------------------------------------------------------------------
// Tick scheduling and the tick budget log

// Tick_Clock schedules ticks on absolute deadlines (start + n * period), so
// sleep jitter never accumulates into drift. Times are nanoseconds on any
// monotonic clock; the real loop and the tests feed it the same way.
Tick_Clock :: struct {
	period:  i64,
	next:    i64, // deadline of the next tick
	resyncs: int, // stalls longer than MAX_TICK_STALL that were skipped
}

MAX_TICK_STALL :: 250_000_000 // ns; never try to catch up a longer stall

tick_clock_init :: proc(clock: ^Tick_Clock, tick_rate: int, now: i64) {
	clock^ = Tick_Clock{period = 1_000_000_000 / i64(max(1, tick_rate)), next = now}
}

// tick_clock_due reports whether a tick is due at `now` and how late it is. A
// stall longer than MAX_TICK_STALL drops the missed ticks instead of running
// them all back to back.
tick_clock_due :: proc(clock: ^Tick_Clock, now: i64) -> (due: bool, lateness: i64) {
	if now - clock.next > MAX_TICK_STALL {
		clock.next = now
		clock.resyncs += 1
	}
	if now < clock.next { return false, 0 }
	return true, now - clock.next
}

tick_clock_advance :: proc(clock: ^Tick_Clock) {
	clock.next += clock.period
}

// tick_clock_wait is how long to sleep before the next deadline (0 if due).
tick_clock_wait :: proc(clock: ^Tick_Clock, now: i64) -> i64 {
	return max(0, clock.next - now)
}

Tick_Budget :: struct {
	budget_ms:   f64,
	ticks:       int,
	sum_ms:      f64,
	max_ms:      f64,
	late:        int, // ticks that started a full period or more after their deadline
	over:        int, // ticks whose work took longer than the budget
	window:      f64, // seconds since the last report
}

tick_budget_init :: proc(b: ^Tick_Budget, tick_rate: int) {
	b^ = Tick_Budget{budget_ms = 1000.0 / f64(max(1, tick_rate))}
}

tick_budget_record :: proc(b: ^Tick_Budget, work_ms: f64, lateness_ms: f64) {
	b.ticks += 1
	b.sum_ms += work_ms
	b.max_ms = max(b.max_ms, work_ms)
	if lateness_ms >= b.budget_ms { b.late += 1 }
	if work_ms > b.budget_ms { b.over += 1 }
	b.window += b.budget_ms / 1000.0
}

tick_budget_average :: proc(b: ^Tick_Budget) -> f64 {
	return b.ticks > 0 ? b.sum_ms / f64(b.ticks) : 0
}

tick_budget_reset :: proc(b: ^Tick_Budget) {
	budget := b.budget_ms
	b^ = Tick_Budget{budget_ms = budget}
}
