"""Pack the MIT KEMAR diffuse-field equalized HRTF set into assets/hrtf/kemar_diffuse.bin.

Source: https://sound.media.mit.edu/resources/KEMAR/diffuse.zip (Gardner & Martin,
MIT Media Lab, 1994): the "compact" 128-point set, diffuse-field equalized with a
minimum-phase inverse of the power average over all directions (do_diffuse_eq.m).
See assets/hrtf/LICENSE-MIT-KEMAR.txt.

Usage: python tools/hrtf_kemar_pack.py <extracted diffuse dir> [output.bin]

The data is repacked verbatim: 368 measurements (elevations -40..90 degrees,
azimuths 0..180 degrees, the left side is the mirror image), each a 128-tap
stereo (left ear, right ear) 16-bit impulse response at 44.1 kHz. The client
derives interaural delays and aligned filters at load time.

Layout (little endian):
  char[4] "KHRT", u32 version = 1, u32 sample_rate, u32 taps, u32 count
  count x { i16 elevation, i16 azimuth, i16 samples[taps * 2] (L, R interleaved) }
"""
import glob
import os
import re
import struct
import sys
import wave


def main() -> None:
    source = sys.argv[1]
    output = sys.argv[2] if len(sys.argv) > 2 else os.path.join("assets", "hrtf", "kemar_diffuse.bin")
    records = []
    for path in glob.glob(os.path.join(source, "elev*", "H*.wav")):
        match = re.search(r"H(-?\d+)e(\d+)a\.wav$", path)
        if not match:
            continue
        with wave.open(path) as w:
            if w.getnchannels() != 2 or w.getsampwidth() != 2 or w.getframerate() != 44100:
                raise SystemExit(f"unexpected format: {path}")
            frames = w.getnframes()
            data = w.readframes(frames)
        records.append((int(match.group(1)), int(match.group(2)), frames, data))
    records.sort(key=lambda r: (r[0], r[1]))
    if len(records) != 368 or any(r[2] != 128 for r in records):
        raise SystemExit(f"expected 368 responses of 128 taps, found {len(records)}")
    os.makedirs(os.path.dirname(output), exist_ok=True)
    with open(output, "wb") as out:
        out.write(b"KHRT" + struct.pack("<IIII", 1, 44100, 128, len(records)))
        for elevation, azimuth, _, data in records:
            out.write(struct.pack("<hh", elevation, azimuth))
            out.write(data)
    print(f"wrote {output}: {len(records)} responses")


if __name__ == "__main__":
    main()
