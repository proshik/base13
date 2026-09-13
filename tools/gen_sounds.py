#!/usr/bin/env python3
"""Sound synthesis in the style of the NES audio chip.

Not "a square wave and some noise" but the three sources the chip actually
had: a pulse wave with a duty cycle, a stepped triangle and shift-register
noise. That is what makes the timbre recognisable rather than merely beepy.

As with the sprites, it is the content that is checked and not the file:
a manifest of PCM fingerprints sits alongside, so --check does not depend on
library versions.
"""
import hashlib
import os
import struct
import sys

import sound_data as data

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "game", "assets", "sfx")
MANIFEST = os.path.join(ROOT, "game", "assets", "sfx.manifest")

TRIANGLE_STEPS = list(range(15, -1, -1)) + list(range(0, 16))


def envelope(index, rate, volume, decay):
    """Stepped decay: the chip had sixteen volume levels, and that is exactly
    why the tail rattles. A smooth fade would sound foreign here."""
    if decay <= 0:
        return volume
    dropped = int(index * decay / rate)
    return max(0, volume - dropped)


def sweep(index, count, f0, f1):
    if count <= 1:
        return f0
    return f0 + (f1 - f0) * index / float(count - 1)


def render_pulse(count, rate, seg):
    duty = seg.get("duty", 0.5)
    volume = seg["vol"]
    decay = seg.get("decay", 0)
    out = [0.0] * count
    phase = 0.0
    for i in range(count):
        freq = sweep(i, count, seg["f0"], seg["f1"])
        phase = (phase + freq / rate) % 1.0
        level = envelope(i, rate, volume, decay)
        out[i] = (1.0 if phase < duty else -1.0) * level / 15.0
    return out


def render_triangle(count, rate, seg):
    volume = seg["vol"]
    decay = seg.get("decay", 0)
    out = [0.0] * count
    phase = 0.0
    steps = len(TRIANGLE_STEPS)
    for i in range(count):
        freq = sweep(i, count, seg["f0"], seg["f1"])
        phase = (phase + freq / rate) % 1.0
        step = TRIANGLE_STEPS[int(phase * steps) % steps]
        level = envelope(i, rate, volume, decay)
        out[i] = ((step - 7.5) / 7.5) * level / 15.0
    return out


def render_noise(count, rate, seg):
    """A fifteen-bit shift register — that very metallic noise.
    Feedback through the sixth bit ("short mode") adds the ringing overtone."""
    period = max(1, seg.get("period", 32))
    short = seg.get("short", False)
    volume = seg["vol"]
    decay = seg.get("decay", 0)
    reg = 1
    out = [0.0] * count
    acc = 0
    for i in range(count):
        acc += 1
        if acc >= period:
            acc = 0
            tap = (reg >> (6 if short else 1)) & 1
            bit = (reg & 1) ^ tap
            reg = (reg >> 1) | (bit << 14)
        level = envelope(i, rate, volume, decay)
        out[i] = (1.0 if (reg & 1) == 0 else -1.0) * level / 15.0
    return out


RENDERERS = {"pulse": render_pulse, "triangle": render_triangle, "noise": render_noise}


def render(segments, rate):
    total_ms = max(seg.get("at", 0) + seg["ms"] for seg in segments)
    total = int(total_ms * rate / 1000)
    mix = [0.0] * total
    for seg in segments:
        count = int(seg["ms"] * rate / 1000)
        start = int(seg.get("at", 0) * rate / 1000)
        piece = RENDERERS[seg["ch"]](count, rate, seg)
        for i, value in enumerate(piece):
            if start + i < total:
                mix[start + i] += value
    # Sum the channels and clamp to range, the way the chip's mixer does.
    return [max(-1.0, min(1.0, v * 0.6)) for v in mix]


def to_pcm(samples):
    return b"".join(struct.pack("<h", int(v * 32000)) for v in samples)


def write_wav(path, pcm, rate):
    header = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    header += b"data" + struct.pack("<I", len(pcm))
    with open(path, "wb") as handle:
        handle.write(header + pcm)


def build():
    out = {}
    for name, segments in data.SOUNDS.items():
        out[name] = to_pcm(render(segments, data.RATE))
    return out


def main():
    check = "--check" in sys.argv
    built = build()
    lines = ["%s %d %s" % (name, len(pcm), hashlib.sha256(pcm).hexdigest())
             for name, pcm in sorted(built.items())]
    text = "\n".join(lines) + "\n"

    if check:
        if not os.path.exists(MANIFEST):
            print("ERROR: assets/sfx.manifest is missing — run gen_sounds.py")
            return 1
        with open(MANIFEST) as handle:
            if handle.read() != text:
                print("ERROR: sounds diverged from their sources — rebuild them")
                return 1
        print("Sounds: OK")
        return 0

    os.makedirs(OUT, exist_ok=True)
    for name, pcm in built.items():
        write_wav(os.path.join(OUT, name + ".wav"), pcm, data.RATE)
    with open(MANIFEST, "w") as handle:
        handle.write(text)
    print("Sounds built: %d" % len(built))
    return 0


if __name__ == "__main__":
    sys.exit(main())
