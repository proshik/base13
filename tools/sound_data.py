#!/usr/bin/env python3
"""Sound descriptions. Each sound is a list of segments, and each segment plays
on one channel of the chip.

ch     — pulse | triangle | noise
duty   - pulse duty cycle: 0.125, 0.25, 0.5, 0.75
f0, f1 - frequency at the start and end of the segment (linear sweep)
period - noise period in samples: the smaller, the brighter
short  - short mode of the shift register: a metallic overtone
ms     - duration
at     - offset of the segment start from the start of the sound
vol    - initial volume, 0..15, as on the chip
decay  - how many volume steps per second the sound falls by
"""

RATE = 44100

SOUNDS = {
    # A shot: a short downward sweep. The sharp descent is what makes it
    # recognisable.
    "shot": [
        {"ch": "pulse", "duty": 0.5, "f0": 1200, "f1": 260, "ms": 70, "vol": 11, "decay": 90},
    ],
    # Brick crumbling: dry mid-band noise.
    "hit_brick": [
        {"ch": "noise", "period": 28, "ms": 55, "vol": 9, "decay": 150},
    ],
    # Concrete: brighter noise plus a pulse overtone — metal.
    "hit_steel": [
        {"ch": "noise", "period": 12, "short": True, "ms": 45, "vol": 8, "decay": 180},
        {"ch": "pulse", "duty": 0.125, "f0": 1800, "f1": 1500, "ms": 35, "vol": 6, "decay": 160},
    ],
    "hit_bullet": [
        {"ch": "noise", "period": 16, "short": True, "ms": 30, "vol": 7, "decay": 220},
    ],
    # A tank exploding: noise with decay.
    "boom_tank": [
        {"ch": "noise", "period": 60, "ms": 260, "vol": 13, "decay": 55},
    ],
    # The player dying: the same, lower and longer, with a triangle underneath.
    # The volumes are chosen so the sum of two channels does not hit the
    # ceiling: hard clipping produces a rasp the chip never had.
    "boom_player": [
        {"ch": "noise", "period": 110, "ms": 420, "vol": 12, "decay": 34},
        {"ch": "triangle", "f0": 90, "f1": 40, "ms": 420, "vol": 10, "decay": 28},
    ],
    "boom_base": [
        {"ch": "noise", "period": 130, "ms": 520, "vol": 13, "decay": 28},
        {"ch": "triangle", "f0": 70, "f1": 30, "ms": 520, "vol": 11, "decay": 24},
    ],
    # A bonus landing on the field: a two-tone blip.
    "bonus_appear": [
        {"ch": "pulse", "duty": 0.25, "f0": 990, "f1": 990, "ms": 70, "vol": 9, "decay": 0},
        {"ch": "pulse", "duty": 0.25, "f0": 1320, "f1": 1320, "ms": 70, "vol": 9,
         "decay": 60, "at": 70},
    ],
    # Picked up: a quick rising arpeggio.
    "bonus_take": [
        {"ch": "pulse", "duty": 0.5, "f0": 523, "f1": 523, "ms": 50, "vol": 10, "decay": 0},
        {"ch": "pulse", "duty": 0.5, "f0": 659, "f1": 659, "ms": 50, "vol": 10,
         "decay": 0, "at": 50},
        {"ch": "pulse", "duty": 0.5, "f0": 784, "f1": 784, "ms": 50, "vol": 10,
         "decay": 0, "at": 100},
        {"ch": "pulse", "duty": 0.5, "f0": 1047, "f1": 1047, "ms": 90, "vol": 10,
         "decay": 70, "at": 150},
    ],
    "enemy_spawn": [
        {"ch": "pulse", "duty": 0.125, "f0": 440, "f1": 880, "ms": 60, "vol": 6, "decay": 120},
    ],
    # Level cleared.
    "jingle_clear": [
        {"ch": "pulse", "duty": 0.5, "f0": 784, "f1": 784, "ms": 110, "vol": 11, "decay": 0},
        {"ch": "pulse", "duty": 0.5, "f0": 988, "f1": 988, "ms": 110, "vol": 11,
         "decay": 0, "at": 110},
        {"ch": "pulse", "duty": 0.5, "f0": 1175, "f1": 1175, "ms": 220, "vol": 11,
         "decay": 40, "at": 220},
        {"ch": "triangle", "f0": 196, "f1": 196, "ms": 440, "vol": 10, "decay": 18},
    ],
    # Game over: a descending phrase.
    "jingle_gameover": [
        {"ch": "pulse", "duty": 0.5, "f0": 587, "f1": 587, "ms": 160, "vol": 11, "decay": 0},
        {"ch": "pulse", "duty": 0.5, "f0": 494, "f1": 494, "ms": 160, "vol": 11,
         "decay": 0, "at": 160},
        {"ch": "pulse", "duty": 0.5, "f0": 392, "f1": 392, "ms": 380, "vol": 11,
         "decay": 26, "at": 320},
        {"ch": "triangle", "f0": 98, "f1": 74, "ms": 700, "vol": 11, "decay": 14},
    ],
    # Engine hum. Looped, hence no decay.
    #
    # The frequencies must be multiples of ten hertz: a whole number of periods
    # then fits into the 100 ms segment, and the loop does not click at the
    # seam. A 50% duty cycle is the softest of the four timbres: odd harmonics
    # only, muted. At 12.5% it turns into a buzz, grating in a continuous sound.
    # The volume is low: the hum is background and must not argue with the
    # effects.
    "engine_idle": [
        {"ch": "pulse", "duty": 0.5, "f0": 80, "f1": 80, "ms": 100, "vol": 3, "decay": 0},
    ],
    "engine_move": [
        {"ch": "pulse", "duty": 0.5, "f0": 120, "f1": 120, "ms": 100, "vol": 4, "decay": 0},
    ],
    "score_tick": [
        {"ch": "pulse", "duty": 0.25, "f0": 1320, "f1": 1320, "ms": 25, "vol": 8, "decay": 240},
    ],
}

# Looped sounds: they must have no decay, or the seam becomes audible.
LOOPED = ["engine_idle", "engine_move"]
