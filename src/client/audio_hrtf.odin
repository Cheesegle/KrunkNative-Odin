package main

import "base:intrinsics"
import "core:encoding/endian"
import "core:fmt"
import "core:math"
import "core:os"
import "core:simd"
import "core:slice"
import shared "../shared"

// Binaural rendering with the MIT KEMAR diffuse-field equalized HRIR set (assets/hrtf). Each
// measured response is split at load time into a pure interaural delay and an
// onset-aligned 64-tap filter, resampled to the mixer rate. Directions in
// between are interpolated bilinearly (elevation x azimuth) in that aligned
// form, so neighbouring filters blend without comb filtering.
HRTF_TAPS :: 64
HRTF_PRE :: 2                 // 44.1 kHz samples kept ahead of each onset.
HRTF_DELAY_SIZE :: 128        // Power of two; the largest interaural delay is ~40 samples at 48 kHz.
HRTF_BLOCK :: 256             // Sub-block size; filter and gain changes crossfade across one.
HRTF_SOURCE_RATE :: 44100
HRTF_ASSET :: "hrtf/kemar_diffuse.bin"

Hrtf_Filter :: struct #align(32) {
	fir: [2][HRTF_TAPS]f32,   // Left, right; stored time-reversed for contiguous dot products.
	delay: [2]f32,            // Output samples.
}

Hrtf_Ring :: struct {
	elevation: f32,
	azimuths: []f32,          // Ascending in [0, 360); KEMAR convention, 90 = right.
	filters: []Hrtf_Filter,
}

Hrtf_Set :: struct {
	sample_rate: u32,
	rings: []Hrtf_Ring,
}

// Per-voice binaural state, touched only by the mixer thread.
Hrtf_Voice :: struct {
	current, previous: Hrtf_Filter,
	azimuth, elevation, gain: f32,
	valid: bool,
	write: int,
	delay_line: [2][HRTF_DELAY_SIZE]f32,
	history: [2][HRTF_TAPS - 1 + HRTF_BLOCK]f32,
}

@(private="file")
hrtf_onset :: proc(h: []f32) -> f32 {
	peak: f32
	for v in h { peak = max(peak, abs(v)) }
	threshold := peak * 0.2
	for v, i in h {
		if abs(v) < threshold { continue }
		if i == 0 { return 0 }
		before := abs(h[i-1])
		return f32(i - 1) + (threshold - before) / max(abs(v) - before, 1e-9)
	}
	return 0
}

// Band-limited (Hann-windowed sinc) evaluation of a 44.1 kHz response at a
// fractional sample position; `cutoff` < 1 low-passes when downsampling.
@(private="file")
hrtf_sample_at :: proc(h: []f32, t, cutoff: f32) -> f32 {
	HALF :: 12
	sum: f32
	base := int(math.floor(t))
	for k in base - HALF + 1 ..= base + HALF {
		if k < 0 || k >= len(h) { continue }
		x := t - f32(k)
		if abs(x) >= HALF { continue }
		sinc: f32 = 1
		if abs(x) > 1e-6 { sinc = math.sin(math.PI * cutoff * x) / (math.PI * cutoff * x) }
		window := 0.5 + 0.5*math.cos(math.PI * x / HALF)
		sum += h[k] * cutoff * sinc * window
	}
	return sum
}

hrtf_destroy :: proc(set: ^Hrtf_Set) {
	if set == nil { return }
	for ring in set.rings { delete(ring.azimuths); delete(ring.filters) }
	delete(set.rings)
	free(set)
}

hrtf_load :: proc(sample_rate: u32, path: string = "") -> ^Hrtf_Set {
	file := len(path) > 0 ? path : fmt.tprintf("%s%s", shared.assets_path(), HRTF_ASSET)
	data, err := os.read_entire_file_from_path(file, context.allocator)
	shared.asset_trace(file, err == nil)
	if err != nil {
		fmt.eprintf("[Audio] HRTF data missing (%s); spatial audio falls back to stereo.\n", file)
		return nil
	}
	defer delete(data)
	return hrtf_parse(data, sample_rate)
}

hrtf_parse :: proc(data: []u8, sample_rate: u32) -> ^Hrtf_Set {
	if len(data) < 20 || string(data[:4]) != "KHRT" || sample_rate == 0 { return nil }
	version, _ := endian.get_u32(data[4:], .Little)
	source_rate, _ := endian.get_u32(data[8:], .Little)
	taps32, _ := endian.get_u32(data[12:], .Little)
	count32, _ := endian.get_u32(data[16:], .Little)
	taps, count := int(taps32), int(count32)
	record := 4 + taps*4
	if version != 1 || source_rate != HRTF_SOURCE_RATE || taps < 16 || count == 0 || len(data) != 20 + count*record { return nil }

	Measurement :: struct { elevation, azimuth: f32, ears: [2][]f32, onset: [2]f32 }
	measurements := make([dynamic]Measurement, 0, count*2)
	defer {
		for m in measurements { if m.azimuth <= 180 { delete(m.ears[0]); delete(m.ears[1]) } }
		delete(measurements)
	}
	min_onset := max(f32)
	for i in 0 ..< count {
		at := 20 + i*record
		elevation, _ := endian.get_i16(data[at:], .Little)
		azimuth, _ := endian.get_i16(data[at+2:], .Little)
		if azimuth < 0 || azimuth > 180 { return nil }
		m := Measurement{elevation = f32(elevation), azimuth = f32(azimuth)}
		for ear in 0 ..< 2 {
			m.ears[ear] = make([]f32, taps)
			for n in 0 ..< taps {
				v, _ := endian.get_i16(data[at + 4 + (n*2 + ear)*2:], .Little)
				m.ears[ear][n] = f32(v) / 32768
			}
			m.onset[ear] = hrtf_onset(m.ears[ear])
			min_onset = min(min_onset, m.onset[ear])
		}
		append(&measurements, m)
		// The compact set is symmetric: the left half mirrors the right with ears swapped.
		if azimuth != 0 && azimuth != 180 {
			append(&measurements, Measurement{
				elevation = f32(elevation), azimuth = 360 - f32(azimuth),
				ears = {m.ears[1], m.ears[0]}, onset = {m.onset[1], m.onset[0]},
			})
		}
	}
	slice.sort_by(measurements[:], proc(a, b: Measurement) -> bool {
		return a.elevation < b.elevation || a.elevation == b.elevation && a.azimuth < b.azimuth
	})

	set := new(Hrtf_Set)
	set.sample_rate = sample_rate
	ratio := f32(HRTF_SOURCE_RATE) / f32(sample_rate)   // Source samples per output sample.
	cutoff := min(1, 1 / ratio)
	rings := make([dynamic]Hrtf_Ring)
	for start := 0; start < len(measurements); {
		end := start
		for end < len(measurements) && measurements[end].elevation == measurements[start].elevation { end += 1 }
		ring := Hrtf_Ring{elevation = measurements[start].elevation, azimuths = make([]f32, end - start), filters = make([]Hrtf_Filter, end - start)}
		for m, j in measurements[start:end] {
			ring.azimuths[j] = m.azimuth
			for ear in 0 ..< 2 {
				origin := m.onset[ear] - HRTF_PRE
				for n in 0 ..< HRTF_TAPS {
					// Scaling by `ratio` keeps the magnitude response when the tap spacing changes.
					v := hrtf_sample_at(m.ears[ear], origin + f32(n)*ratio, cutoff) * ratio
					ring.filters[j].fir[ear][HRTF_TAPS - 1 - n] = v
				}
				// One sample of base latency keeps the cubic interpolator on written samples.
				ring.filters[j].delay[ear] = (m.onset[ear] - min_onset) / ratio + 1
			}
		}
		append(&rings, ring)
		start = end
	}
	// Level-match the equal-power panner: a source straight ahead reaches each
	// ear at -3 dB (cos 45 deg) through the 150 Hz - 2 kHz band, where most of
	// the game's effects carry their energy.
	front_power: f64
	for ring in rings {
		if ring.elevation != 0 { continue }
		for ear in 0 ..< 2 { front_power += hrtf_band_power(&ring.filters[0].fir[ear], f32(sample_rate), 150, 2000) / 2 }
	}
	set.rings = rings[:]
	if len(rings) < 2 || front_power <= 0 {
		hrtf_destroy(set)
		return nil
	}
	scale := f32(math.sqrt(0.5 / front_power))
	for ring in rings { for &f in ring.filters { for &ear in f.fir { for &v in ear { v *= scale } } } }
	return set
}

// Mean power gain of a time-reversed filter over a log-spaced band.
@(private="file")
hrtf_band_power :: proc(reversed: ^[HRTF_TAPS]f32, sample_rate, low, high: f32) -> f64 {
	STEPS :: 24
	sum: f64
	for s in 0 ..< STEPS {
		f := f64(low) * math.pow(f64(high / low), f64(s) / (STEPS - 1))
		re, im: f64
		for n in 0 ..< HRTF_TAPS {
			w := 2 * math.PI * f * f64(n) / f64(sample_rate)
			re += f64(reversed[HRTF_TAPS - 1 - n]) * math.cos(w)
			im -= f64(reversed[HRTF_TAPS - 1 - n]) * math.sin(w)
		}
		sum += re*re + im*im
	}
	return sum / STEPS
}

// Interpolate the filter for a WebAudio azimuth (+90 = right) and elevation.
hrtf_lookup :: proc "contextless" (set: ^Hrtf_Set, azimuth, elevation: f32, out: ^Hrtf_Filter) {
	out^ = {}
	rings := set.rings
	el := clamp(elevation, rings[0].elevation, rings[len(rings)-1].elevation)
	upper := 1
	for upper < len(rings) - 1 && rings[upper].elevation < el { upper += 1 }
	lower := upper - 1
	span := rings[upper].elevation - rings[lower].elevation
	t := span > 0 ? (el - rings[lower].elevation) / span : 0
	az := math.mod(azimuth, 360)
	if az < 0 { az += 360 }
	hrtf_accumulate_ring(&rings[lower], az, 1 - t, out)
	hrtf_accumulate_ring(&rings[upper], az, t, out)
}

@(private="file")
hrtf_accumulate_ring :: proc "contextless" (ring: ^Hrtf_Ring, azimuth, weight: f32, out: ^Hrtf_Filter) {
	if weight <= 0 { return }
	count := len(ring.azimuths)
	a := count - 1
	for i in 0 ..< count { if ring.azimuths[i] <= azimuth { a = i } else { break } }
	b := (a + 1) % count
	gap := ring.azimuths[b] - ring.azimuths[a]
	if gap <= 0 { gap += 360 }
	offset := azimuth - ring.azimuths[a]
	if offset < 0 { offset += 360 }
	t := count > 1 ? clamp(offset / gap, 0, 1) : 0
	hrtf_add_scaled(out, &ring.filters[a], weight * (1 - t))
	if t > 0 { hrtf_add_scaled(out, &ring.filters[b], weight * t) }
}

@(private="file")
hrtf_add_scaled :: proc "contextless" (out, filter: ^Hrtf_Filter, weight: f32) {
	w: #simd[8]f32 = weight
	for ear in 0 ..< 2 {
		for k := 0; k < HRTF_TAPS; k += 8 {
			dst := (^#simd[8]f32)(&out.fir[ear][k])
			dst^ += w * (^#simd[8]f32)(&filter.fir[ear][k])^
		}
		out.delay[ear] += weight * filter.delay[ear]
	}
}

@(private="file")
hrtf_dot :: #force_inline proc "contextless" (taps: ^[HRTF_TAPS]f32, x: [^]f32) -> f32 {
	acc0, acc1: #simd[8]f32
	for k := 0; k < HRTF_TAPS; k += 16 {
		acc0 += (^#simd[8]f32)(&taps[k])^ * intrinsics.unaligned_load((^#simd[8]f32)(&x[k]))
		acc1 += (^#simd[8]f32)(&taps[k+8])^ * intrinsics.unaligned_load((^#simd[8]f32)(&x[k+8]))
	}
	return simd.reduce_add_pairs(acc0 + acc1)
}

@(private="file")
hrtf_fir8 :: #force_inline proc "contextless" (taps: ^[HRTF_TAPS]f32, x: [^]f32) -> #simd[8]f32 {
	acc0, acc1: #simd[8]f32
	for k := 0; k < HRTF_TAPS; k += 2 {
		w0: #simd[8]f32 = taps[k]
		w1: #simd[8]f32 = taps[k+1]
		acc0 += w0 * intrinsics.unaligned_load((^#simd[8]f32)(&x[k]))
		acc1 += w1 * intrinsics.unaligned_load((^#simd[8]f32)(&x[k+1]))
	}
	return acc0 + acc1
}

// Cubic Hermite read from a delay line `delay` samples behind `position`.
@(private="file")
hrtf_read_delay :: #force_inline proc "contextless" (line: ^[HRTF_DELAY_SIZE]f32, position: int, delay: f32) -> f32 {
	MASK :: HRTF_DELAY_SIZE - 1
	whole := int(delay)
	frac := delay - f32(whole)
	i := position - whole
	y0, y1 := line[(i + 1) & MASK], line[i & MASK]
	y2, y3 := line[(i - 1) & MASK], line[(i - 2) & MASK]
	c1 := 0.5 * (y2 - y0)
	c2 := y0 - 2.5*y1 + 2*y2 - 0.5*y3
	c3 := 0.5*(y3 - y0) + 1.5*(y1 - y2)
	return ((c3*frac + c2)*frac + c1)*frac + y1
}

// Render one block. `snap` starts a new sound: no crossfade, cleared history.
hrtf_voice_process :: proc "contextless" (voice: ^Hrtf_Voice, set: ^Hrtf_Set, params: Spatial_Params, snap: bool, input, output: [^]f32, count: int) {
	if snap || !voice.valid {
		voice.delay_line = {}
		voice.history = {}
		voice.write = 0
		hrtf_lookup(set, params.azimuth, params.elevation, &voice.current)
		voice.azimuth, voice.elevation, voice.gain, voice.valid = params.azimuth, params.elevation, params.gain, true
	}
	for offset := 0; offset < count; offset += HRTF_BLOCK {
		n := min(HRTF_BLOCK, count - offset)
		crossfade := abs(params.azimuth - voice.azimuth) > 0.1 || abs(params.elevation - voice.elevation) > 0.1
		if crossfade {
			voice.previous = voice.current
			hrtf_lookup(set, params.azimuth, params.elevation, &voice.current)
			voice.azimuth, voice.elevation = params.azimuth, params.elevation
		}
		inv := 1 / f32(n)
		for ear in 0 ..< 2 {
			channel := params.stereo_source ? ear : 0
			d0 := crossfade ? voice.previous.delay[ear] : voice.current.delay[ear]
			d1 := voice.current.delay[ear]
			x := &voice.history[ear]
			line := &voice.delay_line[ear]
			for i in 0 ..< n {
				position := voice.write + i
				line[position & (HRTF_DELAY_SIZE - 1)] = input[(offset + i)*2 + channel]
				x[HRTF_TAPS - 1 + i] = hrtf_read_delay(line, position, d0 + (d1 - d0)*f32(i + 1)*inv)
			}
		}
		voice.write = (voice.write + n) & (HRTF_DELAY_SIZE - 1)
		g0, g1 := voice.gain, params.gain
		lanes := #simd[8]f32{1, 2, 3, 4, 5, 6, 7, 8}
		for ear in 0 ..< 2 {
			x := raw_data(voice.history[ear][:])
			current := &voice.current.fir[ear]
			previous := &voice.previous.fir[ear]
			// Eight outputs at a time: one broadcast multiply-add per tap, no horizontal sums.
			i := 0
			for ; i + 8 <= n; i += 8 {
				t := (lanes + f32(i)) * inv
				y := hrtf_fir8(current, x[i:])
				if crossfade {
					a := hrtf_fir8(previous, x[i:])
					y = a + (y - a)*t
				}
				y *= g0 + (g1 - g0)*t
				values := transmute([8]f32)y
				for l in 0 ..< 8 { output[(offset + i + l)*2 + ear] = values[l] }
			}
			for ; i < n; i += 1 {
				t := f32(i + 1) * inv
				y := hrtf_dot(current, x[i:])
				if crossfade {
					a := hrtf_dot(previous, x[i:])
					y = a + (y - a)*t
				}
				output[(offset + i)*2 + ear] = y * (g0 + (g1 - g0)*t)
			}
			copy(voice.history[ear][:HRTF_TAPS - 1], voice.history[ear][n:n + HRTF_TAPS - 1])
		}
		voice.gain = g1
	}
}
