package main

import "base:runtime"
import "core:math"
import "core:sync"
import ma "vendor:miniaudio"

// Loudness levelling on the effects bus (every effect and footstep voice; UI
// sounds bypass it). A feed-forward RMS compressor with a soft knee lifts
// quiet sounds through makeup gain and pulls loud ones down, followed by a
// look-ahead peak limiter so the bus never exceeds LEVELLING_CEILING.
LEVELLING_CHUNK :: 16              // Control rate for the detector and gain computer.
LEVELLING_DETECTOR_MS :: 10        // RMS averaging time.
LEVELLING_ATTACK_MS :: 5
LEVELLING_RELEASE_MS :: 250
LEVELLING_KNEE_DB :: 6
LEVELLING_LOOKAHEAD_MS :: 1.5
LEVELLING_LIMIT_RELEASE_MS :: 25
LEVELLING_CEILING :: 0.98          // -0.18 dBFS.
LEVELLING_MAX_LOOKAHEAD :: 128     // Frames; covers 1.5 ms up to 85 kHz.

Levelling_Curve :: struct { threshold_db, ratio, makeup_db: f32 }

// Strength 0 leaves only the safety limiter. At 0.5 (the default strength):
// threshold -20 dBFS RMS, ratio 3.5:1, +7.1 dB makeup. At 1: -30 dBFS, 6:1, +12.5 dB.
levelling_curve :: proc "contextless" (strength: f32) -> Levelling_Curve {
	s := clamp(strength, 0, 1)
	threshold := -10 - 20*s
	ratio := 1 + 5*s
	// Half of the full makeup: quiet sounds rise, loud ones still end up lower.
	return {threshold, ratio, 0.5 * -threshold * (1 - 1/ratio)}
}

// Static gain (dB) for an RMS level, including makeup.
levelling_gain_db :: proc "contextless" (curve: Levelling_Curve, level_db: f32) -> f32 {
	over := level_db - curve.threshold_db
	slope := 1/curve.ratio - 1
	reduction: f32
	if 2*over <= -LEVELLING_KNEE_DB {
		reduction = 0
	} else if 2*abs(over) < LEVELLING_KNEE_DB {
		k := over + LEVELLING_KNEE_DB/2
		reduction = slope * k * k / (2*LEVELLING_KNEE_DB)
	} else {
		reduction = slope * over
	}
	return reduction + curve.makeup_db
}

Levelling_Node :: struct {
	base: ma.node_base,
	enabled: u32,                  // Atomic; written by the game thread.
	strength_bits: u32,            // Atomic f32 bits.
	primed: bool,
	// Mixer-thread state.
	channels, sample_rate, lookahead: int,
	active: bool,
	power, gain_db, limit_gain, limit_smooth, last_gain: f32,
	write: int,
	delay: [LEVELLING_MAX_LOOKAHEAD * SURROUND_MAX_CHANNELS]f32,
	required: [LEVELLING_MAX_LOOKAHEAD]f32, // Limiter gain each delayed frame needs.
}

@(private="file") levelling_vtable := ma.node_vtable{
	onProcess = levelling_node_process,
	inputBusCount = 1,
	outputBusCount = 1,
}

levelling_node_init :: proc(engine: ^ma.engine, node: ^Levelling_Node) -> bool {
	channels := ma.engine_get_channels(engine)
	if !levelling_node_prepare(node, int(channels), int(ma.engine_get_sample_rate(engine))) { return false }
	config := ma.node_config_init()
	config.vtable = &levelling_vtable
	config.pInputChannels = &channels
	config.pOutputChannels = &channels
	if ma.node_init(ma.engine_get_node_graph(engine), &config, nil, cast(^ma.node)node) != .SUCCESS { return false }
	if ma.node_attach_output_bus(cast(^ma.node)node, 0, ma.engine_get_endpoint(engine), 0) != .SUCCESS {
		ma.node_uninit(cast(^ma.node)node, nil)
		return false
	}
	node.primed = true
	return true
}

// Format setup shared by the graph node and offline tests.
levelling_node_prepare :: proc(node: ^Levelling_Node, channels, sample_rate: int) -> bool {
	if channels < 1 || channels > SURROUND_MAX_CHANNELS || sample_rate <= 0 { return false }
	node.channels, node.sample_rate = channels, sample_rate
	node.lookahead = clamp(int(LEVELLING_LOOKAHEAD_MS * f32(sample_rate) / 1000), 1, LEVELLING_MAX_LOOKAHEAD)
	return true
}

levelling_node_uninit :: proc(node: ^Levelling_Node) {
	if !node.primed { return }
	ma.node_uninit(cast(^ma.node)node, nil)
	node.primed = false
}

levelling_node_configure :: proc(node: ^Levelling_Node, enabled: bool, strength: f32) {
	sync.atomic_store_explicit(&node.strength_bits, transmute(u32)clamp(strength, 0, 1), .Relaxed)
	sync.atomic_store_explicit(&node.enabled, enabled ? 1 : 0, .Release)
}

@(private="file")
levelling_node_process :: proc "c" (base: ^ma.node, frames_in: ^[^]f32, frame_count_in: ^u32, frames_out: ^[^]f32, frame_count_out: ^u32) {
	context = runtime.default_context()
	levelling_render(cast(^Levelling_Node)base, frames_in^, frames_out^, int(frame_count_out^))
}

levelling_render :: proc "contextless" (node: ^Levelling_Node, input, output: [^]f32, count: int) {
	channels := node.channels
	enabled := sync.atomic_load_explicit(&node.enabled, .Acquire) != 0
	if !enabled {
		node.active = false
		copy(output[:count*channels], input[:count*channels])
		when ODIN_TEST { levelling_test_capture(output, count*channels) }
		return
	}
	curve := levelling_curve(transmute(f32)sync.atomic_load_explicit(&node.strength_bits, .Relaxed))
	if !node.active {
		// Start clean so a stale envelope cannot duck or boost the first sounds.
		node.active = true
		node.power, node.write = 0, 0
		node.gain_db = curve.makeup_db
		node.last_gain = math.pow(10, node.gain_db / 20)
		node.limit_gain, node.limit_smooth = 1, 1
		node.delay = {}
		for &r in node.required { r = 1 }
	}
	rate := f32(node.sample_rate)
	chunk_seconds := f32(LEVELLING_CHUNK) / rate
	detector := 1 - math.exp(-1 / (LEVELLING_DETECTOR_MS * 0.001 * rate))
	attack := 1 - math.exp(-chunk_seconds / (LEVELLING_ATTACK_MS * 0.001))
	release := 1 - math.exp(-chunk_seconds / (LEVELLING_RELEASE_MS * 0.001))
	limit_release := 1 - math.exp(-1 / (LEVELLING_LIMIT_RELEASE_MS * 0.001 * rate))
	limit_attack := 1 - math.exp(-1 / (0.0002 * rate)) // 0.2 ms smoothing; settles well inside the look-ahead.
	lookahead := node.lookahead
	for start := 0; start < count; start += LEVELLING_CHUNK {
		n := min(LEVELLING_CHUNK, count - start)
		// Detector: RMS of the loudest channel.
		for i in start ..< start + n {
			peak_sq: f32
			for c in 0 ..< channels { v := input[i*channels + c]; peak_sq = max(peak_sq, v*v) }
			node.power += detector * (peak_sq - node.power)
		}
		level := 10 * math.log10(node.power + 1e-12)
		target := levelling_gain_db(curve, level)
		node.gain_db += (target < node.gain_db ? attack : release) * (target - node.gain_db)
		gain := math.pow(10, node.gain_db / 20)
		step := (gain - node.last_gain) / f32(n)
		g := node.last_gain
		for i in start ..< start + n {
			g += step
			slot := node.write
			// Compressed frame enters the look-ahead line; the limiter acts on what leaves it.
			peak: f32
			for c in 0 ..< channels {
				v := input[i*channels + c] * g
				peak = max(peak, abs(v))
				node.delay[slot*channels + c], output[i*channels + c] = v, node.delay[slot*channels + c]
			}
			delayed_required := node.required[slot]
			node.required[slot] = peak > LEVELLING_CEILING ? LEVELLING_CEILING / peak : 1
			window := f32(1)
			for r in node.required[:lookahead] { window = min(window, r) }
			node.limit_gain = min(window, node.limit_gain + limit_release * (1 - node.limit_gain))
			node.limit_smooth += limit_attack * (node.limit_gain - node.limit_smooth)
			limit := min(node.limit_smooth, delayed_required)
			for c in 0 ..< channels {
				v := output[i*channels + c] * limit
				output[i*channels + c] = clamp(v, -1, 1)
			}
			node.write = (slot + 1) % lookahead
		}
		node.last_gain = gain
	}
}

when ODIN_TEST {
	// Real-time tests record the effects bus from the mixer thread.
	levelling_capture: []f32
	levelling_capture_length: int
	levelling_test_capture :: proc "contextless" (samples: [^]f32, count: int) {
		n := min(count, len(levelling_capture) - levelling_capture_length)
		if n <= 0 { return }
		copy(levelling_capture[levelling_capture_length:], samples[:n])
		levelling_capture_length += n
	}
}
