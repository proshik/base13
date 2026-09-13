# BASE 13: sound, screens and builds — implementation plan (subproject 1, part B2)

**Goal:** Close subproject 1: the game sounds like the original, has a splash screen, a menu, a pause, stats and a high score, plays from a gamepad and builds for three desktop platforms.

**Architecture:** The sound is synthesized by a script in the style of the NES sound chip — a pulse with a duty cycle, a stepped triangle, noise on a shift register — and written into WAV, by exactly the device the sprites are assembled with. Playback takes the core's events apart the way the explosions do: `presentation/audio.gd` next to `presentation/effects.gd`. The screens become separate scenes in `ui/`, and a root node swaps them; which screen follows which is a pure function, and it is tested.

**Tech Stack:** Godot 4.7.2, GDScript, GUT 9.7.1 (headless), Python 3 from the standard library.

**Spec:** `docs/specs/2026-08-30-battle-city-shell-design.md`

**Not in this plan:** touch input and mobile builds (subproject 2), network co-op (subproject 3), signing, notarization and publishing (subproject 4).

## Global Constraints

- Godot **4.7.2**. Path to the binary: `$GODOT`, by default `/Applications/Godot.app/Contents/MacOS/Godot`.
- `./tools/test.sh` must stay green after every task.
- **The `core/` rules do not change.** The core plays no sounds and knows nothing about screens: it accumulates events, and the presentation takes them apart. This plan creates no new files in `core/`.
- **Careful with comments in `core/`** — the isolation check looks for text, not code.
- Sound: 44100 Hz, mono, sixteen bits. Volumes are integers from 0 to 15, as on the chip.
- A commit after every task. Messages in English: `feat:`, `test:`, `chore:`, `docs:`.

## File structure

| File | Responsibility |
|------|----------------|
| `tools/sound_data.py` | Sound descriptions: segments, channels, frequencies, envelopes |
| `tools/gen_sounds.py` | Synthesis in the 2A03 style, WAV writing, the manifest, `--check` mode |
| `assets/sfx/*.wav` | Fifteen sounds |
| `assets/sfx.manifest` | PCM fingerprints for verification |
| `presentation/audio.gd` | Event → sound, engine hum, ducking |
| `ui/screen_flow.gd` | Which screen follows which — a pure function |
| `ui/app.gd`, `app.tscn` | The root node: holds the current screen and swaps it |
| `ui/splash.gd`, `ui/splash.tscn` | The splash screen |
| `ui/menu.gd`, `ui/menu.tscn` | Choosing one player or two |
| `ui/stats.gd`, `ui/stats.tscn` | The tally by enemy type and the score |
| `ui/game.gd`, `ui/game.tscn` | The game screen — moves out of the root |
| `ui/pause.gd` | The pause overlay on top of the game |
| `platform/score_store.gd` | The high score in `user://base13.cfg` |
| `platform/gamepad.gd` | Gamepad → the same five bits |
| `tools/build.sh` | Builds for three platforms |
| `export_presets.cfg` | The export presets — taken off `.gitignore` |

## The sound catalogue

Fifteen files in `assets/sfx/`. The first twelve are tied to core events, the last three to state and screens.

| File | When it sounds |
|------|----------------|
| `shot.wav` | `SHOT_FIRED` |
| `hit_brick.wav` | `BULLET_HIT_BRICK` |
| `hit_steel.wav` | `BULLET_HIT_STEEL` |
| `hit_bullet.wav` | `BULLET_HIT_BULLET` |
| `boom_tank.wav` | `TANK_DESTROYED` |
| `boom_player.wav` | `PLAYER_DESTROYED` |
| `boom_base.wav` | `BASE_DESTROYED` |
| `bonus_appear.wav` | `BONUS_SPAWNED` |
| `bonus_take.wav` | `BONUS_TAKEN` |
| `enemy_spawn.wav` | `ENEMY_SPAWNED` |
| `jingle_clear.wav` | `LEVEL_CLEARED` |
| `jingle_gameover.wav` | `GAME_OVER` |
| `engine_idle.wav` | The player's tank is standing — looped |
| `engine_move.wav` | The player's tank is moving — looped |
| `score_tick.wav` | Tallying the score on the stats screen |

---

### Task 1: NES-style sound synthesis

**Files:**
- Create: `tools/sound_data.py`
- Create: `tools/gen_sounds.py`
- Create: `assets/sfx/*.wav`, `assets/sfx.manifest`
- Modify: `tools/test.sh`
- Test: `tests/presentation/test_sfx.gd`

**Interfaces:**
- Consumes: nothing
- Produces: `python3 tools/gen_sounds.py` assembles fifteen WAVs; `--check` verifies them against `assets/sfx.manifest`.

The bar is **as close to the original as possible**, so the synthesis is not "a square wave and noise in general" but a reproduction of what the NES chip had. The difference is audible immediately: an ordinary square wave with no duty cycle sounds like a beeper, not like the tanks.

Three sources:

- **A pulse with a duty cycle** of 12.5%, 25%, 50%, 75% — four different timbres from one shape.
- **A triangle** in steps of sixteen levels up and down: a muffled bottom end with no upper overtones.
- **Noise** on a fifteen-bit shift register with feedback through the first or the sixth bit — not white noise but that particular metallic one.

The volume is an integer from zero to fifteen with a stepped decay. A smooth decay sounds foreign: the characteristic rattle on the tail comes from exactly those sixteen steps.

- [x] **Step 1: Write `tools/sound_data.py`**

```python
#!/usr/bin/env python3
"""Sound descriptions. Each sound is a list of segments, and each segment plays
on one channel of the chip.

ch     - pulse | triangle | noise
duty   - pulse duty cycle: 0.125, 0.25, 0.5, 0.75
f0, f1 - frequency at the start and end of the segment (linear sweep)
period - noise period in samples: the smaller, the brighter
short  - short mode of the shift register: a metallic overtone
ms     - duration
vol    - initial volume, 0..15, as on the chip
decay  - how many volume steps per second the sound falls by
"""

RATE = 44100

SOUNDS = {
    # A shot: a short downward sweep. The sharp descent is what makes it recognisable.
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
    "boom_player": [
        {"ch": "noise", "period": 110, "ms": 420, "vol": 14, "decay": 34},
        {"ch": "triangle", "f0": 90, "f1": 40, "ms": 420, "vol": 12, "decay": 28},
    ],
    "boom_base": [
        {"ch": "noise", "period": 130, "ms": 520, "vol": 15, "decay": 28},
        {"ch": "triangle", "f0": 70, "f1": 30, "ms": 520, "vol": 13, "decay": 24},
    ],
    # A power-up has landed on the field: a two-tone blip.
    "bonus_appear": [
        {"ch": "pulse", "duty": 0.25, "f0": 990, "f1": 990, "ms": 70, "vol": 9, "decay": 0},
        {"ch": "pulse", "duty": 0.25, "f0": 1320, "f1": 1320, "ms": 70, "vol": 9, "decay": 60,
         "at": 70},
    ],
    # Picked up: a quick ascending arpeggio.
    "bonus_take": [
        {"ch": "pulse", "duty": 0.5, "f0": 523, "f1": 523, "ms": 50, "vol": 10, "decay": 0},
        {"ch": "pulse", "duty": 0.5, "f0": 659, "f1": 659, "ms": 50, "vol": 10, "decay": 0, "at": 50},
        {"ch": "pulse", "duty": 0.5, "f0": 784, "f1": 784, "ms": 50, "vol": 10, "decay": 0, "at": 100},
        {"ch": "pulse", "duty": 0.5, "f0": 1047, "f1": 1047, "ms": 90, "vol": 10, "decay": 70, "at": 150},
    ],
    "enemy_spawn": [
        {"ch": "pulse", "duty": 0.125, "f0": 440, "f1": 880, "ms": 60, "vol": 6, "decay": 120},
    ],
    # Level cleared.
    "jingle_clear": [
        {"ch": "pulse", "duty": 0.5, "f0": 784, "f1": 784, "ms": 110, "vol": 11, "decay": 0},
        {"ch": "pulse", "duty": 0.5, "f0": 988, "f1": 988, "ms": 110, "vol": 11, "decay": 0, "at": 110},
        {"ch": "pulse", "duty": 0.5, "f0": 1175, "f1": 1175, "ms": 220, "vol": 11, "decay": 40, "at": 220},
        {"ch": "triangle", "f0": 196, "f1": 196, "ms": 440, "vol": 10, "decay": 18},
    ],
    # Losing: a descending phrase.
    "jingle_gameover": [
        {"ch": "pulse", "duty": 0.5, "f0": 587, "f1": 587, "ms": 160, "vol": 11, "decay": 0},
        {"ch": "pulse", "duty": 0.5, "f0": 494, "f1": 494, "ms": 160, "vol": 11, "decay": 0, "at": 160},
        {"ch": "pulse", "duty": 0.5, "f0": 392, "f1": 392, "ms": 380, "vol": 11, "decay": 26, "at": 320},
        {"ch": "triangle", "f0": 98, "f1": 74, "ms": 700, "vol": 11, "decay": 14},
    ],
    # The engine hum. Looped, so no decay and a whole number of periods.
    "engine_idle": [
        {"ch": "pulse", "duty": 0.125, "f0": 60, "f1": 60, "ms": 100, "vol": 5, "decay": 0},
    ],
    "engine_move": [
        {"ch": "pulse", "duty": 0.25, "f0": 96, "f1": 96, "ms": 100, "vol": 6, "decay": 0},
    ],
    "score_tick": [
        {"ch": "pulse", "duty": 0.25, "f0": 1320, "f1": 1320, "ms": 25, "vol": 8, "decay": 240},
    ],
}

## Looped sounds: they must have no decay, or the seam will be audible.
LOOPED = ["engine_idle", "engine_move"]
```

- [x] **Step 2: Write `tools/gen_sounds.py`**

```python
#!/usr/bin/env python3
"""Sound synthesis in the style of the NES audio chip.

Not "a square wave and noise in general" but exactly the three sources the chip
had: a pulse with a duty cycle, a stepped triangle and noise on a shift
register. That is what makes the timbre recognisable rather than merely beepy.

As with the sprites, what is verified is not the file but the content:
a manifest of PCM fingerprints sits alongside, so --check does not depend on
library versions.
"""
import hashlib
import math
import os
import struct
import sys

import sound_data as data

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "assets", "sfx")
MANIFEST = os.path.join(ROOT, "assets", "sfx.manifest")

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
    for i in range(count):
        freq = sweep(i, count, seg["f0"], seg["f1"])
        phase = (phase + freq / rate) % 1.0
        step = TRIANGLE_STEPS[int(phase * len(TRIANGLE_STEPS)) % len(TRIANGLE_STEPS)]
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
    # Sum the channels and clamp to the range — as the chip's mixer does.
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
```

- [x] **Step 3: Add the sound check to `tools/test.sh`**

Right after the line with the atlas verification:

```bash
(cd tools && python3 gen_sounds.py --check)
```

- [x] **Step 4: Write the failing tests**

`tests/presentation/test_sfx.gd`:

```gdscript
extends GutTest

const NAMES := [
	"shot", "hit_brick", "hit_steel", "hit_bullet",
	"boom_tank", "boom_player", "boom_base",
	"bonus_appear", "bonus_take", "enemy_spawn",
	"jingle_clear", "jingle_gameover",
	"engine_idle", "engine_move", "score_tick",
]

func _stream(name: String) -> AudioStreamWAV:
	var path := "res://assets/sfx/%s.wav" % name
	var stream: AudioStreamWAV = ResourceLoader.load(path)
	assert_not_null(stream, "no sound at %s" % path)
	return stream

func test_every_sound_exists_and_is_not_silent() -> void:
	for name in NAMES:
		var stream := _stream(name)
		assert_gt(stream.data.size(), 0, "sound %s is empty" % name)
		# Silence in sixteen-bit PCM is all zeroes; any non-zero byte means the
		# synthesis drew something.
		var loud := false
		for i in range(0, stream.data.size(), 32):
			if stream.data[i] != 0:
				loud = true
				break
		assert_true(loud, "sound %s is made of silence" % name)

func test_format_matches_the_chip() -> void:
	for name in NAMES:
		var stream := _stream(name)
		assert_eq(stream.mix_rate, 44100, "sample rate of %s" % name)
		assert_false(stream.stereo, "%s must be mono" % name)

func test_engine_sounds_are_short_enough_to_loop() -> void:
	# A second-long looped hum is heard as a repeat; a hundred milliseconds is not.
	for name in ["engine_idle", "engine_move"]:
		assert_lt(_stream(name).get_length(), 0.2, "%s is too long for a loop" % name)

func test_explosions_are_longer_than_clicks() -> void:
	assert_gt(_stream("boom_player").get_length(), _stream("hit_bullet").get_length(),
		"the player's death must sound weightier than a click")
	assert_gt(_stream("jingle_gameover").get_length(), _stream("shot").get_length())
```

- [x] **Step 5: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `gen_sounds.py --check` complains about the missing manifest, and there are no sounds in `assets/sfx/`.

- [x] **Step 6: Build the sounds**

```bash
cd tools && python3 gen_sounds.py; cd ..
ls -la assets/sfx/
```

Expected: fifteen files.

- [x] **Step 7: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: `Sounds: OK`, all tests green.

- [x] **Step 8: Listen**

```bash
for s in shot boom_player bonus_take jingle_clear engine_move; do afplay assets/sfx/$s.wav; done
```

The test checks that the sound is not silence, not that it resembles the original. Resemblance is checked by ear: the shot should click rather than beep; the explosion should crumble rather than hiss evenly; the power-up arpeggio should be recognisable. The numbers in `tools/sound_data.py` were moved into the source precisely so they can be turned.

- [x] **Step 9: Commit**

```bash
git add tools/sound_data.py tools/gen_sounds.py tools/test.sh assets/sfx assets/sfx.manifest tests/presentation/test_sfx.gd
git commit -m "feat: synthesis of fifteen sounds in the style of the NES audio chip"
```

---
### Task 2: Playing sounds from events

**Files:**
- Create: `presentation/audio.gd`
- Modify: `game.gd`, `game.tscn`
- Test: `tests/presentation/test_audio.gd`

**Interfaces:**
- Consumes: `Types.Event`, `SimEvent`
- Produces: an `Audio` node with `Audio.sound_for(event_type: int) -> String`, `Audio.names_for(events: Array) -> Array[String]`, the methods `absorb(events: Array) -> void` and `play(name: String) -> void`, and the constant `Audio.VOICES`.

Taking events apart into sound is arranged exactly like taking them apart into explosions in `presentation/effects.gd`: the core reports what happened, and the presentation decides how to serve it.

**Identical sounds within one tick collapse.** A bullet that chewed out four brick cells produces four events — four layered copies of one click give mush, and the chip had one channel for this. We play each sound at most once per tick.

- [x] **Step 1: Write the failing tests**

`tests/presentation/test_audio.gd`:

```gdscript
extends GutTest

func _event(type: int) -> SimEvent:
	return SimEvent.new(type, Vector2i.ZERO, 0)

func test_every_event_has_a_sound() -> void:
	# If a new event is added to the core, this test will remind us to give it a sound.
	for value in Types.Event.values():
		assert_ne(Audio.sound_for(value), "",
			"event %d was left without a sound" % value)

func test_unknown_event_is_silent_but_does_not_break() -> void:
	assert_eq(Audio.sound_for(9999), "")

func test_shot_and_explosion_are_different_sounds() -> void:
	assert_ne(Audio.sound_for(Types.Event.SHOT_FIRED),
		Audio.sound_for(Types.Event.TANK_DESTROYED))

func test_repeated_events_collapse_into_one_sound() -> void:
	var events := [_event(Types.Event.BULLET_HIT_BRICK),
		_event(Types.Event.BULLET_HIT_BRICK),
		_event(Types.Event.BULLET_HIT_BRICK)]
	assert_eq(Audio.names_for(events).size(), 1,
		"four chewed-out cells are one click, not four")

func test_different_events_all_sound() -> void:
	var events := [_event(Types.Event.SHOT_FIRED), _event(Types.Event.TANK_DESTROYED)]
	assert_eq(Audio.names_for(events),
		[Audio.sound_for(Types.Event.SHOT_FIRED),
		Audio.sound_for(Types.Event.TANK_DESTROYED)] as Array[String])

func test_order_follows_the_events() -> void:
	var events := [_event(Types.Event.TANK_DESTROYED), _event(Types.Event.SHOT_FIRED)]
	assert_eq(Audio.names_for(events)[0], Audio.sound_for(Types.Event.TANK_DESTROYED))

func test_empty_input_gives_nothing() -> void:
	assert_eq(Audio.names_for([]).size(), 0)
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "Audio" not declared`.

- [x] **Step 3: Write `presentation/audio.gd`**

```gdscript
class_name Audio
extends Node

## Taking core events apart into sound — exactly the way effects.gd takes them
## apart into explosions. The core plays no sounds and knows nothing about them.

const SFX_PATH := "res://assets/sfx/%s.wav"
const VOICES := 8

## Event → sound name. Empty means "deliberately silent".
const EVENT_SOUNDS := {
	Types.Event.SHOT_FIRED: "shot",
	Types.Event.BULLET_HIT_BRICK: "hit_brick",
	Types.Event.BULLET_HIT_STEEL: "hit_steel",
	Types.Event.BULLET_HIT_BULLET: "hit_bullet",
	Types.Event.TANK_DESTROYED: "boom_tank",
	Types.Event.PLAYER_DESTROYED: "boom_player",
	Types.Event.BASE_DESTROYED: "boom_base",
	Types.Event.BONUS_SPAWNED: "bonus_appear",
	Types.Event.BONUS_TAKEN: "bonus_take",
	Types.Event.ENEMY_SPAWNED: "enemy_spawn",
	Types.Event.LEVEL_CLEARED: "jingle_clear",
	Types.Event.GAME_OVER: "jingle_gameover",
}

var _voices: Array = []
var _streams := {}

static func sound_for(event_type: int) -> String:
	return EVENT_SOUNDS.get(event_type, "")

## Identical sounds within a tick collapse: the chip had one channel for each,
## and four layered copies of a click give mush.
static func names_for(events: Array) -> Array[String]:
	var out: Array[String] = []
	for e in events:
		var name: String = sound_for(e.type)
		if name != "" and not out.has(name):
			out.append(name)
	return out

func _ready() -> void:
	for i in VOICES:
		var player := AudioStreamPlayer.new()
		add_child(player)
		_voices.append(player)

func absorb(events: Array) -> void:
	for name in names_for(events):
		play(name)

func play(name: String) -> void:
	if name == "":
		return
	var stream := _stream(name)
	if stream == null:
		return
	for player in _voices:
		if not player.playing:
			player.stream = stream
			player.play()
			return
	# Every voice is busy — the oldest gives way: silence is worse than a cut-off.
	_voices[0].stream = stream
	_voices[0].play()

func _stream(name: String):
	if not _streams.has(name):
		_streams[name] = ResourceLoader.load(SFX_PATH % name)
	return _streams[name]
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 5: Wire it into `game.tscn`**

Into the scene header:

```
[ext_resource type="Script" path="res://presentation/audio.gd" id="5_audio"]
```

As a node:

```
[node name="Audio" type="Node" parent="."]
script = ExtResource("5_audio")
```

Raise `load_steps` to `6`.

- [x] **Step 6: Wire it into `game.gd`**

A field:

```gdscript
@onready var _audio: Audio = $Audio
```

In `_advance`, where the events go into explosions, hand the same ones to the sound:

```gdscript
	for i in _pump.pump(delta):
		_sim.tick([Keyboard.bits(0), Keyboard.bits(1)])
		var events := _sim.drain_events()
		_effects.absorb(events)
		_audio.absorb(events)
		_effects.advance()
```

The events now have two consumers, so `drain_events()` is called once and the result is handed to both: a second call would return nothing.

- [x] **Step 7: Run it and listen**

```bash
"$GODOT"
```

Expected: the shot clicks, a hit on brick crumbles, a downed enemy explodes, a power-up rings both when it appears and when it is picked up.

- [x] **Step 8: Commit**

```bash
git add presentation/audio.gd game.gd game.tscn tests/presentation/test_audio.gd
git commit -m "feat: event sounds with repeats collapsed within a tick"
```

---

### Task 3: The engine hum

**Files:**
- Modify: `presentation/audio.gd`
- Modify: `game.gd`
- Test: `tests/presentation/test_audio.gd`

**Interfaces:**
- Consumes: `WorldState`
- Produces: `Audio.engine_sound(alive: bool, moving: bool) -> String`, the method `set_engine(name: String) -> void`, the constant `Audio.DUCK_DB`.

In the original the engine sounds continuously and changes tone when the tank moves. Without it the game sounds like a set of clicks in silence — that is half of the recognizability by ear, and the subproject 1 design simply forgot it.

There is one hum for two players: two layered give mush, and the chip had one channel.

- [x] **Step 1: Add the failing tests**

At the end of `tests/presentation/test_audio.gd`:

```gdscript
func test_engine_changes_tone_when_moving() -> void:
	assert_ne(Audio.engine_sound(true, true), Audio.engine_sound(true, false),
		"a moving and a standing tank sound different — that is the recognizability")

func test_engine_is_silent_without_a_tank() -> void:
	assert_eq(Audio.engine_sound(false, true), "",
		"a dead tank's engine does not hum")
	assert_eq(Audio.engine_sound(false, false), "")

func test_engine_sounds_are_the_looped_ones() -> void:
	assert_eq(Audio.engine_sound(true, false), "engine_idle")
	assert_eq(Audio.engine_sound(true, true), "engine_move")
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Cannot find member "engine_sound" in base "Audio"`.

- [x] **Step 3: Add to `presentation/audio.gd`**

```gdscript
const DUCK_DB := -8.0   ## how much to duck the hum for the duration of an effect

var _engine: AudioStreamPlayer = null
var _engine_name := ""

## There is one hum for two players: the chip had one channel, and two layered
## hums give mush instead of an engine.
static func engine_sound(alive: bool, moving: bool) -> String:
	if not alive:
		return ""
	return "engine_move" if moving else "engine_idle"

func set_engine(name: String) -> void:
	if name == _engine_name:
		return
	_engine_name = name
	if _engine == null:
		_engine = AudioStreamPlayer.new()
		add_child(_engine)
	if name == "":
		_engine.stop()
		return
	var stream := _stream(name)
	if stream is AudioStreamWAV:
		# The loop is set here rather than in the file: the WAV import does not
		# set it, and keeping a service chunk in the generator for one flag is
		# more than it is worth.
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_end = stream.data.size() / 2
	_engine.stream = stream
	_engine.play()
```

And in `play()`, before choosing a voice, the ducking:

```gdscript
	if _engine != null and _engine.playing:
		_engine.volume_db = DUCK_DB
		get_tree().create_timer(0.12).timeout.connect(
			func() -> void:
				if _engine != null:
					_engine.volume_db = 0.0)
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 5: Feed the hum from `game.gd`**

A field, and an update at the end of `_advance`:

```gdscript
var _engine_was := Vector2i.ZERO

	var tanks := state.player_tanks()
	var alive := not tanks.is_empty()
	var moving := false
	if alive:
		var pos: Vector2i = tanks[0].pos
		moving = pos != _engine_was
		_engine_was = pos
	_audio.set_engine(Audio.engine_sound(alive, moving))
```

Movement is determined by comparing positions between frames rather than by a flag from the core: the core knows nothing about sound, and adding a "moving" field to it for the sake of the hum is not allowed.

- [x] **Step 6: Run it and listen**

```bash
"$GODOT"
```

Expected: the engine hums constantly, the tone is higher while moving, it falls silent when the tank dies and comes back on respawn. A shot ducks the hum for a moment.

- [x] **Step 7: Commit**

```bash
git add presentation/audio.gd game.gd tests/presentation/test_audio.gd
git commit -m "feat: engine hum with different tones moving and standing"
```

---
### Task 4: The screen switcher

**Files:**
- Create: `ui/screen_flow.gd`
- Create: `ui/app.gd`, `app.tscn`
- Move: `game.gd` → `ui/game.gd`, `game.tscn` → `ui/game.tscn`
- Modify: `project.godot`
- Test: `tests/ui/test_screen_flow.gd`

**Interfaces:**
- Consumes: `Campaign`
- Produces: `ScreenFlow.Screen { SPLASH, MENU, GAME, STATS, GAMEOVER }`, `ScreenFlow.Outcome { CONTINUE, LOST }`, `ScreenFlow.next(screen: int, outcome: int) -> int`; the root node `App` with `_show(screen: int)`; **the screen contract:** every screen scene declares `signal finished(outcome: int)` and an optional method `configure(campaign: Campaign, players: int, best: int) -> void`.

Every screen is its own scene, and the root node swaps them. Which follows which is a pure function with not a single node, so the flow is checked by tests rather than by clicking.

The game screen moves into `ui/` along with the rest. Its internal machine (`INTRO → PLAY → OUTRO → OVER`) is left untouched: it is about a level's lifecycle, not about screens.

**The campaign lives in the root, not in the game screen.** The game screen is recreated for every level, and the score and lives must outlive it.

- [x] **Step 1: Write the failing tests**

`tests/ui/test_screen_flow.gd`:

```gdscript
extends GutTest

func test_splash_leads_to_the_menu() -> void:
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.SPLASH, ScreenFlow.Outcome.CONTINUE),
		ScreenFlow.Screen.MENU)

func test_menu_starts_the_game() -> void:
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.MENU, ScreenFlow.Outcome.CONTINUE),
		ScreenFlow.Screen.GAME)

func test_level_always_ends_with_statistics() -> void:
	# Both a win and a loss show the tally — that is how the original works.
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.GAME, ScreenFlow.Outcome.CONTINUE),
		ScreenFlow.Screen.STATS)
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.GAME, ScreenFlow.Outcome.LOST),
		ScreenFlow.Screen.STATS)

func test_statistics_decide_where_to_go() -> void:
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.STATS, ScreenFlow.Outcome.CONTINUE),
		ScreenFlow.Screen.GAME)
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.STATS, ScreenFlow.Outcome.LOST),
		ScreenFlow.Screen.GAMEOVER)

func test_game_over_returns_to_the_menu() -> void:
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.GAMEOVER, ScreenFlow.Outcome.CONTINUE),
		ScreenFlow.Screen.MENU)

func test_unknown_screen_falls_back_to_the_menu() -> void:
	assert_eq(ScreenFlow.next(9999, ScreenFlow.Outcome.CONTINUE), ScreenFlow.Screen.MENU,
		"an unknown screen is no reason to hang with no way out")

func test_the_loop_closes() -> void:
	# Going round from the menu, we must come back to the menu rather than get stuck.
	var screen := ScreenFlow.Screen.MENU
	screen = ScreenFlow.next(screen, ScreenFlow.Outcome.CONTINUE)   # GAME
	screen = ScreenFlow.next(screen, ScreenFlow.Outcome.LOST)       # STATS
	screen = ScreenFlow.next(screen, ScreenFlow.Outcome.LOST)       # GAMEOVER
	screen = ScreenFlow.next(screen, ScreenFlow.Outcome.CONTINUE)   # MENU
	assert_eq(screen, ScreenFlow.Screen.MENU)
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "ScreenFlow" not declared`.

- [x] **Step 3: Write `ui/screen_flow.gd`**

```gdscript
class_name ScreenFlow

## Which screen follows which. Separate from the nodes, because the screen flow
## is a rule and not markup: a rule is checked by a test, markup is checked by
## running it.

enum Screen { SPLASH, MENU, GAME, STATS, GAMEOVER }
enum Outcome { CONTINUE, LOST }

static func next(screen: int, outcome: int) -> int:
	match screen:
		Screen.SPLASH:
			return Screen.MENU
		Screen.MENU:
			return Screen.GAME
		Screen.GAME:
			# Both a win and a loss lead to the tally — that is how the original works.
			return Screen.STATS
		Screen.STATS:
			return Screen.GAMEOVER if outcome == Outcome.LOST else Screen.GAME
		Screen.GAMEOVER:
			return Screen.MENU
	return Screen.MENU
```

- [x] **Step 4: Move the game screen into `ui/`**

```bash
mkdir -p ui tests/ui
git mv game.gd ui/game.gd
git mv game.tscn ui/game.tscn
```

Fix the paths inside `ui/game.tscn`: `path="res://game.gd"` → `path="res://ui/game.gd"`.

- [x] **Step 5: Write `ui/app.gd`**

```gdscript
extends Node

## The root node: holds the current screen and swaps it. It has no game logic
## of its own — only the campaign, which must outlive a change of screens.

const SCENES := {
	ScreenFlow.Screen.SPLASH: "res://ui/splash.tscn",
	ScreenFlow.Screen.MENU: "res://ui/menu.tscn",
	ScreenFlow.Screen.GAME: "res://ui/game.tscn",
	ScreenFlow.Screen.STATS: "res://ui/stats.tscn",
	ScreenFlow.Screen.GAMEOVER: "res://ui/gameover.tscn",
}

const BASE_SEED := 20260827

var _screen := ScreenFlow.Screen.SPLASH
var _current: Node = null
var _campaign: Campaign = null
var _players := 1
var _best := 0

func _ready() -> void:
	_show(_screen)

func _show(screen: int) -> void:
	if _current != null:
		_current.queue_free()
		_current = null
	_screen = screen
	if screen == ScreenFlow.Screen.GAME and _campaign == null:
		_campaign = Campaign.new(_players, SimConfig.new(), BASE_SEED)
	_current = load(SCENES[screen]).instantiate()
	add_child(_current)
	if _current.has_method("configure"):
		_current.configure(_campaign, _players, _best)
	_current.finished.connect(_on_finished)

func _on_finished(outcome: int) -> void:
	if _screen == ScreenFlow.Screen.MENU:
		_players = outcome + 1     # the menu hands out the player count minus one
		_campaign = null
		_show(ScreenFlow.Screen.GAME)
		return
	if _screen == ScreenFlow.Screen.GAMEOVER:
		_campaign = null
	_show(ScreenFlow.next(_screen, outcome))
```

- [x] **Step 6: Write `app.tscn` and switch the main scene**

`app.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://ui/app.gd" id="1_app"]

[node name="App" type="Node"]
script = ExtResource("1_app")
```

In `project.godot`:

```ini
run/main_scene="res://app.tscn"
```

- [x] **Step 7: Move the window and fullscreen handling into the root**

`_fit_window`, `_toggle_fullscreen` and the `KEY_F` handling move from `ui/game.gd` into `ui/app.gd`. Fitting the window size is the application's business, not the level's: otherwise `F` would work neither in the menu nor on the stats screen, and the window size would be recomputed on every change of screen.

In `ui/app.gd`:

```gdscript
func _ready() -> void:
	_fit_window()
	_best = ScoreStore.load_best()
	_show(_screen)

## Fits the window to the display at an integer scale. A fractional one would
## stretch the pixels unevenly, and the pixel art would fall apart.
func _fit_window() -> void:
	var screen := DisplayServer.window_get_current_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var size := WindowScale.BASE * WindowScale.best_scale(usable.size)
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_position(usable.position + (usable.size - size) / 2)

func _toggle_fullscreen() -> void:
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		_fit_window()
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F:
		_toggle_fullscreen()
```

The line `_best = ScoreStore.load_best()` will appear in task 9; skip it for now.

- [x] **Step 8: Emit the signal from the game screen**

At the top of `ui/game.gd`:

```gdscript
signal finished(outcome: int)
```

Remove `_restart` and the `1`/`2` hotkeys — their job has moved into the menu. The campaign comes from outside:

```gdscript
func configure(campaign: Campaign, players: int, best: int) -> void:
	_campaign = campaign
	_best = best
	_begin_level()
```

And instead of restarting, `_finish_level` reports upwards:

```gdscript
func _finish_level() -> void:
	_campaign.finish_level(_sim.get_state())
	var outcome := ScreenFlow.Outcome.LOST if _campaign.game_over else ScreenFlow.Outcome.CONTINUE
	finished.emit(outcome)
```

The `GAME OVER` banner leaves the game screen: it is a separate screen now.

- [x] **Step 9: Run the tests**

Run: `./tools/test.sh`
Expected: all tests green. The game does not run yet — the splash, menu, stats and game over scenes do not exist; they appear in tasks 5, 6, 8 and 10.

- [x] **Step 10: Commit**

```bash
git add ui app.tscn project.godot tests/ui/test_screen_flow.gd
git commit -m "feat: the screen flow and the root switcher"
```

---

### Task 5: The splash screen

**Files:**
- Create: `ui/splash.gd`, `ui/splash.tscn`

**Interfaces:**
- Consumes: `TextPainter`
- Produces: the splash scene with `signal finished(outcome: int)` and `configure(campaign, players, best)`.

The first thing a person sees. The title, the high score and a hint about what to do next. It leaves on any key or by itself after a few seconds — everyone hates a splash screen you cannot skip.

- [x] **Step 1: Write `ui/splash.gd`**

```gdscript
extends Node2D

## The splash screen. It leaves on any key or by itself: everyone hates a splash
## screen you cannot skip.

signal finished(outcome: int)

const SCREEN := Vector2(256, 240)
const SECONDS := 4.0

var _font: Texture2D = preload("res://assets/font.png")
var _best := 0
var _timer := SECONDS

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func configure(_campaign, _players: int, best: int) -> void:
	_best = best
	queue_redraw()

func _process(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_leave()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		_leave()

func _leave() -> void:
	set_process(false)
	finished.emit(ScreenFlow.Outcome.CONTINUE)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0))
	_centred("BASE 13", 88)
	_centred("HI %d" % _best, 120)
	_centred("PRESS ANY KEY", 168)

func _centred(text: String, y: int) -> void:
	var x := (int(SCREEN.x) - TextPainter.width_of(text)) / 2
	TextPainter.draw_line(self, _font, text, Vector2i(x, y))
```

- [x] **Step 2: Write `ui/splash.tscn`**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://ui/splash.gd" id="1_splash"]

[node name="Splash" type="Node2D"]
script = ExtResource("1_splash")
```

- [x] **Step 3: Run the tests**

Run: `./tools/test.sh`
Expected: all tests green. There are no new tests: the scene only draws and waits for a key.

- [x] **Step 4: Commit**

```bash
git add ui/splash.gd ui/splash.tscn
git commit -m "feat: splash screen with the title and the high score"
```

---
### Task 6: The menu

**Files:**
- Create: `ui/menu.gd`, `ui/menu.tscn`

**Interfaces:**
- Consumes: `TextPainter`, `Frames`
- Produces: the menu scene; `finished` hands out the **index of the choice** — 0 for one player, 1 for two. The root node adds one.

Two lines and a tank cursor next to the selected one — as in the original. Up and down arrows to move, fire to choose.

- [x] **Step 1: Write `ui/menu.gd`**

```gdscript
extends Node2D

## Choosing the number of players. The cursor is a tank, as in the original:
## it is cheaper than a highlight and says at once what we are playing.

signal finished(outcome: int)

const SCREEN := Vector2(256, 240)
const ITEMS := ["1 PLAYER", "2 PLAYERS"]
const FIRST_Y := 120
const STEP_Y := 24
const TEXT_X := 96

var _font: Texture2D = preload("res://assets/font.png")
var _sprites: Texture2D = preload("res://assets/sprites.png")
var _best := 0
var _choice := 0

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func configure(_campaign, _players: int, best: int) -> void:
	_best = best
	queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_UP, KEY_W:
			_choice = (_choice + ITEMS.size() - 1) % ITEMS.size()
			queue_redraw()
		KEY_DOWN, KEY_S:
			_choice = (_choice + 1) % ITEMS.size()
			queue_redraw()
		KEY_ENTER, KEY_SPACE:
			finished.emit(_choice)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0))
	_centred("BASE 13", 56)
	_centred("HI %d" % _best, 80)
	for i in ITEMS.size():
		TextPainter.draw_line(self, _font, ITEMS[i], Vector2i(TEXT_X, FIRST_Y + i * STEP_Y))
	_draw_cursor()

func _draw_cursor() -> void:
	var frame := Frames.tank(Types.TankType.PLAYER, 0, Types.Dir.RIGHT, 0)
	var src := Rect2i((frame % 16) * 16, (frame / 16) * 16, 16, 16)
	var at := Vector2(TEXT_X - 24, FIRST_Y + _choice * STEP_Y - 4)
	draw_texture_rect_region(_sprites, Rect2(at, Vector2(16, 16)), src)

func _centred(text: String, y: int) -> void:
	var x := (int(SCREEN.x) - TextPainter.width_of(text)) / 2
	TextPainter.draw_line(self, _font, text, Vector2i(x, y))
```

- [x] **Step 2: Write `ui/menu.tscn`**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://ui/menu.gd" id="1_menu"]

[node name="Menu" type="Node2D"]
script = ExtResource("1_menu")
```

- [x] **Step 3: Run the tests and launch it**

```bash
./tools/test.sh
"$GODOT"
```

Expected: the splash screen, then the menu; the arrows move the tank cursor, and Enter starts the game with the chosen line-up.

- [x] **Step 4: Commit**

```bash
git add ui/menu.gd ui/menu.tscn
git commit -m "feat: player-count menu with a tank cursor"
```

---

### Task 7: Pause

**Files:**
- Modify: `presentation/tick_pump.gd`
- Create: `ui/pause.gd`
- Modify: `ui/game.gd`, `ui/game.tscn`
- Test: `tests/presentation/test_tick_pump.gd`

**Interfaces:**
- Consumes: `TextPainter`
- Produces: `TickPump.reset() -> void`; the `PauseOverlay` overlay with the method `set_shown(value: bool)`.

Pause is not a screen but an overlay on top of the game: the simulation stops ticking and the picture stays. That way the field is visible and no context is lost.

**The accumulator must be reset when the pause is lifted.** Otherwise the first frame after it hands out a full stock of catch-up ticks, and the game jerks at exactly the moment the person has taken hold of the keys again. That is the "releases it without a jerk" from the readiness criteria.

- [x] **Step 1: Add the failing test**

At the end of `tests/presentation/test_tick_pump.gd`:

```gdscript
func test_reset_drops_the_accumulated_debt() -> void:
	# Exactly the case of lifting a pause: time passed while we stood, but there
	# is nothing to catch up on.
	pump.pump(0.9)
	pump.reset()
	assert_eq(pump.pump(1.0 / 120.0), 0,
		"after a reset half a frame is still half a frame, not a catch-up")
	assert_eq(pump.pump(1.0 / 120.0), 1)
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Invalid call. Nonexistent function 'reset'`.

- [x] **Step 3: Add to `presentation/tick_pump.gd`**

```gdscript
## A reset when the pause is lifted: time passed while we stood, but there is
## nothing to catch up on.
func reset() -> void:
	_accumulated = 0.0
```

- [x] **Step 4: Write `ui/pause.gd`**

```gdscript
class_name PauseOverlay
extends Node2D

## An overlay, not a screen: the field shows through it, and the person does not
## lose track of where they stopped.

const SCREEN := Vector2(256, 240)
const VEIL := Color(0, 0, 0, 0.55)

var _font: Texture2D = preload("res://assets/font.png")

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	visible = false

func set_shown(value: bool) -> void:
	visible = value
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), VEIL)
	var text := "PAUSE"
	var x := (int(SCREEN.x) - TextPainter.width_of(text)) / 2
	TextPainter.draw_line(self, _font, text, Vector2i(x, 112))
```

- [x] **Step 5: Wire it into `ui/game.tscn`**

Into the header:

```
[ext_resource type="Script" path="res://ui/pause.gd" id="6_pause"]
```

As the last node, on top of everything:

```
[node name="Pause" type="Node2D" parent="."]
script = ExtResource("6_pause")
```

Raise `load_steps`.

- [x] **Step 6: Handle the pause in `ui/game.gd`**

A field and a reference to the node:

```gdscript
var _paused := false

@onready var _pause: PauseOverlay = $Pause
```

In `_unhandled_input`:

```gdscript
		KEY_ESCAPE:
			_toggle_pause()
```

```gdscript
func _toggle_pause() -> void:
	_paused = not _paused
	_pause.set_shown(_paused)
	if not _paused:
		# Time passed while we stood: without a reset the first frame hands out
		# the stock of catch-up ticks and the game jerks.
		_pump.reset()
	_audio.set_engine("")
```

And as the first line of `_process`:

```gdscript
	if _paused:
		return
```

- [x] **Step 7: Run it and check by hand**

```bash
./tools/test.sh
"$GODOT"
```

Expected: Esc stops the game and dims the field with a `PAUSE` caption, and the engine falls silent; Esc again releases it with no jump.

- [x] **Step 8: Commit**

```bash
git add presentation/tick_pump.gd ui/pause.gd ui/game.gd ui/game.tscn tests/presentation/test_tick_pump.gd
git commit -m "feat: pause with the tick accumulator reset"
```

---

### Task 8: The stats screen

**Files:**
- Modify: `core/entities.gd`, `core/campaign.gd`
- Create: `ui/stats.gd`, `ui/stats.tscn`
- Test: `tests/core/test_campaign.gd`

**Interfaces:**
- Consumes: `Campaign`, `TextPainter`
- Produces: `Entities.Carryover.kills: Array[int]`; `Campaign.last_kills: Array` — the tally by type for the level just completed; the stats scene.

The screen shows exactly whom you shot down: four rows per player — basic, fast, power, armor — the points for the match and the total score.

**The tally has to be carried through the campaign.** By the time the stats are shown, the game screen has already been destroyed along with the state of the world, so who killed whom has to be remembered at the moment the level ended. That is a game fact of the same kind as the score, so it lives in `core/` rather than in the screens.

- [x] **Step 1: Add the failing tests**

At the end of `tests/core/test_campaign.gd`:

```gdscript
func test_kills_of_the_finished_level_are_remembered() -> void:
	var c := Campaign.new(1, cfg, 7)
	var s := _finished(true, [3], [400])
	s.players[0].kills = [2, 1, 0, 1] as Array[int]
	c.finish_level(s)
	assert_eq(c.last_kills[0], [2, 1, 0, 1] as Array[int],
		"the stats screen is built from these numbers")

func test_kills_accumulate_across_levels() -> void:
	var c := Campaign.new(1, cfg, 7)
	var first := _finished(true, [3], [400])
	first.players[0].kills = [2, 0, 0, 0] as Array[int]
	c.finish_level(first)
	var second := _finished(true, [3], [800])
	second.players[0].kills = [1, 3, 0, 0] as Array[int]
	c.finish_level(second)
	assert_eq(c.carryover()[0].kills, [3, 3, 0, 0] as Array[int],
		"the match total is the sum over the levels")
	assert_eq(c.last_kills[0], [1, 3, 0, 0] as Array[int],
		"while the last level stays separate")

func test_kills_start_empty() -> void:
	var c := Campaign.new(2, cfg, 7)
	assert_eq(c.carryover()[0].kills, [0, 0, 0, 0] as Array[int])
	assert_eq(c.last_kills.size(), 2, "a row per player from the very start")
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Invalid access to property "last_kills"`.

- [x] **Step 3: Add to `core/entities.gd`**

In the `Carryover` class:

```gdscript
	var kills: Array[int] = [0, 0, 0, 0]   ## by index: BASIC, FAST, POWER, ARMOR
```

- [x] **Step 4: Add to `core/campaign.gd`**

A field:

```gdscript
var last_kills: Array = []     ## the tally for the level just completed
```

In `_init`, inside the loop over players:

```gdscript
		last_kills.append([0, 0, 0, 0] as Array[int])
```

In `finish_level`, next to carrying the score over:

```gdscript
		var counted: Array[int] = [0, 0, 0, 0]
		for k in counted.size():
			counted[k] = p.kills[k]
			slots[i].kills[k] += p.kills[k]
		last_kills[i] = counted
```

- [x] **Step 5: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green, the `core/` isolation included.

- [x] **Step 6: Write `ui/stats.gd`**

```gdscript
extends Node2D

## Whom you shot down over the level. The numbers come from the campaign: by
## this point the game screen has been destroyed along with the state of the world.

signal finished(outcome: int)

const SCREEN := Vector2(256, 240)
const KINDS := ["BASIC", "FAST", "POWER", "ARMOR"]
const SECONDS := 4.0

var _font: Texture2D = preload("res://assets/font.png")
var _campaign: Campaign = null
var _best := 0
var _timer := SECONDS
var _lost := false

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func configure(campaign: Campaign, _players: int, best: int) -> void:
	_campaign = campaign
	_best = best
	_lost = campaign.game_over
	queue_redraw()

func _process(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_leave()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		_leave()

func _leave() -> void:
	set_process(false)
	finished.emit(ScreenFlow.Outcome.LOST if _lost else ScreenFlow.Outcome.CONTINUE)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0))
	if _campaign == null:
		return
	_centred("HI %d" % _best, 16)
	_centred("STAGE %d" % _campaign.level_number, 32)
	var y := 64
	for i in _campaign.slots.size():
		TextPainter.draw_line(self, _font, "%dP  %d" % [i + 1, _campaign.slots[i].score],
			Vector2i(24, y))
		y += 14
		for k in KINDS.size():
			TextPainter.draw_line(self, _font,
				"%s %d" % [KINDS[k], _campaign.last_kills[i][k]], Vector2i(40, y))
			y += 12
		y += 8
	_centred("TOTAL %d" % _campaign.total_score(), 208)

func _centred(text: String, y: int) -> void:
	var x := (int(SCREEN.x) - TextPainter.width_of(text)) / 2
	TextPainter.draw_line(self, _font, text, Vector2i(x, y))
```

- [x] **Step 7: Write `ui/stats.tscn`**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://ui/stats.gd" id="1_stats"]

[node name="Stats" type="Node2D"]
script = ExtResource("1_stats")
```

- [x] **Step 8: Run the tests**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 9: Commit**

```bash
git add core/entities.gd core/campaign.gd ui/stats.gd ui/stats.tscn tests/core/test_campaign.gd
git commit -m "feat: stats screen and the kill tally by type in the campaign"
```

---

### Task 9: The high score store

**Files:**
- Create: `platform/score_store.gd`
- Test: `tests/platform/test_score_store.gd`

**Interfaces:**
- Consumes: nothing
- Produces: `ScoreStore.PATH`, `ScoreStore.parse(text: String) -> int`, `ScoreStore.serialise(best: int) -> String`, `ScoreStore.load_best() -> int`, `ScoreStore.save_best(best: int) -> void`.

The project's first write to disk. Parsing and assembling the line are pure functions and are tested; reading and writing the file is a thin wrapper over them, three lines long.

**A broken file means "there is no high score" and never means a crash.** A corrupted config is no reason to keep someone from playing, and certainly no reason to show them a stack trace instead of the splash screen.

- [x] **Step 1: Write the failing tests**

`tests/platform/test_score_store.gd`:

```gdscript
extends GutTest

func test_round_trip() -> void:
	assert_eq(ScoreStore.parse(ScoreStore.serialise(20000)), 20000)

func test_reads_a_normal_file() -> void:
	assert_eq(ScoreStore.parse("best=12345\n"), 12345)

func test_ignores_surrounding_whitespace() -> void:
	assert_eq(ScoreStore.parse("  best = 700 \n"), 700)

func test_missing_file_means_no_record() -> void:
	assert_eq(ScoreStore.parse(""), 0)

func test_garbage_means_no_record_and_not_a_crash() -> void:
	# A corrupted config is no reason to keep someone from playing.
	assert_eq(ScoreStore.parse("  garbage"), 0)
	assert_eq(ScoreStore.parse("best=not a number"), 0)
	assert_eq(ScoreStore.parse("entirely the wrong format"), 0)

func test_negative_is_treated_as_no_record() -> void:
	assert_eq(ScoreStore.parse("best=-5"), 0)

func test_unknown_keys_do_not_confuse_it() -> void:
	assert_eq(ScoreStore.parse("volume=3\nbest=42\nlanguage=en\n"), 42)
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "ScoreStore" not declared`.

- [x] **Step 3: Write `platform/score_store.gd`**

```gdscript
class_name ScoreStore

## The high score between launches. Parsing and assembling are pure functions,
## reading and writing a thin wrapper: that way the checkable part is checked by
## a test rather than by running the game.

const PATH := "user://base13.cfg"
const KEY := "best"

static func serialise(best: int) -> String:
	return "%s=%d\n" % [KEY, maxi(0, best)]

## A broken file means "there is no high score". A corrupted config is no reason
## to keep someone from playing, and even less a reason to show a stack trace.
static func parse(text: String) -> int:
	for raw_line in text.split("\n", false):
		var line := raw_line.strip_edges()
		if not line.begins_with(KEY):
			continue
		var parts := line.split("=", false, 1)
		if parts.size() != 2:
			continue
		var value := parts[1].strip_edges()
		if not value.is_valid_int():
			continue
		return maxi(0, value.to_int())
	return 0

static func load_best() -> int:
	if not FileAccess.file_exists(PATH):
		return 0
	var handle := FileAccess.open(PATH, FileAccess.READ)
	if handle == null:
		return 0
	return parse(handle.get_as_text())

static func save_best(best: int) -> void:
	var handle := FileAccess.open(PATH, FileAccess.WRITE)
	if handle == null:
		return
	handle.store_string(serialise(best))
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 5: Commit**

```bash
git add platform/score_store.gd tests/platform/test_score_store.gd
git commit -m "feat: high score between launches, a broken file does not crash the game"
```

---

### Task 10: The game over screen and the high score

**Files:**
- Create: `ui/gameover.gd`, `ui/gameover.tscn`
- Modify: `ui/app.gd`
- Test: `tests/ui/test_screen_flow.gd`

**Interfaces:**
- Consumes: `ScoreStore`, `Campaign`, `TextPainter`
- Produces: the game over scene; `App` reads the high score at launch and writes it after a match.

The last screen of the loop. It shows the final score and — if it was beaten — that the record is new. The high score is updated here rather than during play: the match may still end differently, and there is no point writing to disk for every downed tank.

- [x] **Step 1: Add a test that the loop closes**

At the end of `tests/ui/test_screen_flow.gd`:

```gdscript
func test_a_full_game_returns_to_the_menu() -> void:
	# Splash, menu, level, stats, loss, menu — the loop must close.
	var screen := ScreenFlow.Screen.SPLASH
	var seen: Array[int] = [screen]
	var outcomes := [ScreenFlow.Outcome.CONTINUE, ScreenFlow.Outcome.CONTINUE,
		ScreenFlow.Outcome.CONTINUE, ScreenFlow.Outcome.LOST, ScreenFlow.Outcome.CONTINUE]
	for outcome in outcomes:
		screen = ScreenFlow.next(screen, outcome)
		seen.append(screen)
	assert_eq(seen, [ScreenFlow.Screen.SPLASH, ScreenFlow.Screen.MENU,
		ScreenFlow.Screen.GAME, ScreenFlow.Screen.STATS, ScreenFlow.Screen.GAMEOVER,
		ScreenFlow.Screen.MENU] as Array[int])
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — the order of screens differs from the expected one.

If the test is unexpectedly green, the flow is already correct; keep the test anyway — it stands guard over future edits.

- [x] **Step 3: Write `ui/gameover.gd`**

```gdscript
extends Node2D

## The outcome of a match. The high score is updated here rather than during
## play: there is no point writing to disk for every downed tank, and until the
## last moment the match may still end differently.

signal finished(outcome: int)

const SCREEN := Vector2(256, 240)
const SECONDS := 6.0

var _font: Texture2D = preload("res://assets/font.png")
var _score := 0
var _best := 0
var _new_record := false
var _timer := SECONDS

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func configure(campaign: Campaign, _players: int, best: int) -> void:
	_score = campaign.total_score() if campaign != null else 0
	_new_record = _score > best
	_best = maxi(best, _score)
	queue_redraw()

func score() -> int:
	return _score

func best() -> int:
	return _best

func _process(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_leave()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		_leave()

func _leave() -> void:
	set_process(false)
	finished.emit(ScreenFlow.Outcome.CONTINUE)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0))
	_centred("GAME OVER", 96)
	_centred("SCORE %d" % _score, 128)
	if _new_record:
		_centred("NEW RECORD", 152)
	else:
		_centred("HI %d" % _best, 152)

func _centred(text: String, y: int) -> void:
	var x := (int(SCREEN.x) - TextPainter.width_of(text)) / 2
	TextPainter.draw_line(self, _font, text, Vector2i(x, y))
```

- [x] **Step 4: Write `ui/gameover.tscn`**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://ui/gameover.gd" id="1_over"]

[node name="GameOver" type="Node2D"]
script = ExtResource("1_over")
```

- [x] **Step 5: Read and write the high score in `ui/app.gd`**

In `_ready`, before showing the first screen:

```gdscript
	_best = ScoreStore.load_best()
```

In `_on_finished`, in the game-over branch, before clearing the campaign:

```gdscript
	if _screen == ScreenFlow.Screen.GAMEOVER:
		if _current != null and _current.has_method("best"):
			var updated: int = _current.best()
			if updated > _best:
				_best = updated
				ScoreStore.save_best(_best)
		_campaign = null
```

- [x] **Step 6: Run it and go round the loop by hand**

```bash
./tools/test.sh
"$GODOT"
```

Expected: splash, menu, game, stats, game over, menu. The score on the game over screen matches the total in the stats; on the very first loss `NEW RECORD` is shown, and on the next one the previous high score, if it was not beaten.

Check separately that the high score survives a restart: close the window, open it again and look at the number on the splash screen.

- [x] **Step 7: Commit**

```bash
git add ui/gameover.gd ui/gameover.tscn ui/app.gd tests/ui/test_screen_flow.gd
git commit -m "feat: game over screen and writing the high score to disk"
```

---

### Task 11: The gamepad

**Files:**
- Create: `platform/gamepad.gd`
- Modify: `ui/game.gd`, `ui/menu.gd`
- Test: `tests/platform/test_gamepad.gd`

**Interfaces:**
- Consumes: `Types`
- Produces: `Gamepad.DEADZONE`, `Gamepad.compose(up, down, left, right, fire, stick: Vector2) -> int`, `Gamepad.bits(device: int) -> int`.

The gamepad hands out the same five bits. The sources are OR-ed together bitwise, so the keyboard and the gamepad work at the same time and there is nothing to switch between.

The pure part — OR-ing the d-pad, the stick and the button into a mask — is tested; reading the real `Input` stays a thin wrapper.

**A deadzone is mandatory.** A stick rarely sits at an exact zero, and without one the tank drives by itself — which looks like broken physics, though the hardware is to blame.

- [x] **Step 1: Write the failing tests**

`tests/platform/test_gamepad.gd`:

```gdscript
extends GutTest

func test_dpad_gives_bits() -> void:
	assert_eq(Gamepad.compose(true, false, false, false, false, Vector2.ZERO), Types.IN_UP)
	assert_eq(Gamepad.compose(false, false, false, true, false, Vector2.ZERO), Types.IN_RIGHT)

func test_fire_button() -> void:
	assert_eq(Gamepad.compose(false, false, false, false, true, Vector2.ZERO), Types.IN_FIRE)

func test_stick_beyond_the_deadzone_counts() -> void:
	var far := Gamepad.DEADZONE + 0.2
	assert_eq(Gamepad.compose(false, false, false, false, false, Vector2(0, -far)), Types.IN_UP)
	assert_eq(Gamepad.compose(false, false, false, false, false, Vector2(far, 0)), Types.IN_RIGHT)

func test_stick_inside_the_deadzone_is_ignored() -> void:
	# Without a deadzone the tank drives by itself, and that looks like broken physics.
	var near := Gamepad.DEADZONE - 0.1
	assert_eq(Gamepad.compose(false, false, false, false, false, Vector2(near, -near)), 0)

func test_dpad_and_stick_add_up() -> void:
	var far := Gamepad.DEADZONE + 0.2
	assert_eq(Gamepad.compose(true, false, false, false, false, Vector2(far, 0)),
		Types.IN_UP | Types.IN_RIGHT)

func test_nothing_pressed_is_zero() -> void:
	assert_eq(Gamepad.compose(false, false, false, false, false, Vector2.ZERO), 0)

func test_diagonal_stick_gives_both_axes() -> void:
	var far := Gamepad.DEADZONE + 0.2
	assert_eq(Gamepad.compose(false, false, false, false, false, Vector2(-far, far)),
		Types.IN_LEFT | Types.IN_DOWN)
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "Gamepad" not declared`.

- [x] **Step 3: Write `platform/gamepad.gd`**

```gdscript
class_name Gamepad

## The same five bits as from the keyboard. The sources are OR-ed together
## bitwise, so there is nothing to switch between: both work at once.

const DEADZONE := 0.5

## The pure part: from the state of the d-pad, the stick and the button — a mask.
## A deadzone is mandatory: a stick rarely sits at an exact zero, and without one
## the tank drives by itself.
static func compose(up: bool, down: bool, left: bool, right: bool, fire: bool,
		stick: Vector2) -> int:
	var mask := 0
	if up or stick.y < -DEADZONE:
		mask |= Types.IN_UP
	if down or stick.y > DEADZONE:
		mask |= Types.IN_DOWN
	if left or stick.x < -DEADZONE:
		mask |= Types.IN_LEFT
	if right or stick.x > DEADZONE:
		mask |= Types.IN_RIGHT
	if fire:
		mask |= Types.IN_FIRE
	return mask

static func bits(device: int) -> int:
	if device < 0 or device >= Input.get_connected_joypads().size():
		return 0
	var pad: int = Input.get_connected_joypads()[device]
	var stick := Vector2(
		Input.get_joy_axis(pad, JOY_AXIS_LEFT_X),
		Input.get_joy_axis(pad, JOY_AXIS_LEFT_Y))
	return compose(
		Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_UP),
		Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_DOWN),
		Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_LEFT),
		Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_RIGHT),
		Input.is_joy_button_pressed(pad, JOY_BUTTON_A)
			or Input.is_joy_button_pressed(pad, JOY_BUTTON_B),
		stick)
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 5: OR the sources together in `ui/game.gd`**

```gdscript
	for i in _pump.pump(delta):
		_sim.tick([Keyboard.bits(0) | Gamepad.bits(0),
			Keyboard.bits(1) | Gamepad.bits(1)])
```

And pause from the gamepad, in `_unhandled_input`:

```gdscript
	if event is InputEventJoypadButton and event.pressed \
			and event.button_index == JOY_BUTTON_START:
		_toggle_pause()
```

- [x] **Step 6: Let the gamepad walk the menu**

In `ui/menu.gd`, next to the key handling:

```gdscript
	if event is InputEventJoypadButton and event.pressed:
		match event.button_index:
			JOY_BUTTON_DPAD_UP:
				_choice = (_choice + ITEMS.size() - 1) % ITEMS.size()
				queue_redraw()
			JOY_BUTTON_DPAD_DOWN:
				_choice = (_choice + 1) % ITEMS.size()
				queue_redraw()
			JOY_BUTTON_A, JOY_BUTTON_START:
				finished.emit(_choice)
```

- [x] **Step 7: Check by hand, if a gamepad is available**

```bash
"$GODOT"
```

Expected: the d-pad and the left stick steer the tank, the bottom or right button fires, `Start` pauses. The keyboard keeps working alongside.

If there is no gamepad to hand — the pure part is covered by tests, and the wrapper over `Input` is seven lines; mark the step done and check later.

- [x] **Step 8: Commit**

```bash
git add platform/gamepad.gd ui/game.gd ui/menu.gd tests/platform/test_gamepad.gd
git commit -m "feat: gamepad as another source of the same five bits"
```

---

### Task 12: Builds for three platforms

**Files:**
- Modify: `.gitignore`
- Create: `export_presets.cfg`
- Create: `tools/build.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything that is ready
- Produces: `./tools/build.sh` puts three builds into `build/`.

**Two things need permission before this task** — both are visible in the repository and both are decided by a person, not by the implementer:

1. Taking `export_presets.cfg` off `.gitignore`. Without it the build is not reproducible: everyone would get their own. The file holds no secrets for desktop; when Android arrives in subproject 2, the keystore passwords will live in environment variables rather than here.
2. Downloading the Godot export templates — about a gigabyte in `~/Library/Application Support/Godot/export_templates/`.

An honest boundary for verification: from a MacBook you can make sure all three builds are produced and are not empty, and run only the macOS build. Whether Windows and Linux work will become clear on those machines. The macOS build is unsigned: on somebody else's Mac it opens through right-click.

- [x] **Step 1: Ask for permission**

Show the points above and wait for an answer. Without permission the task does not start.

- [x] **Step 2: Download the export templates**

```bash
"$GODOT" --headless --quit
```

Then in the editor: `Editor → Manage Export Templates → Download and Install`. Check:

```bash
ls ~/Library/Application\ Support/Godot/export_templates/
```

Expected: a directory with the version `4.7.2.stable`.

- [x] **Step 3: Take the presets off `.gitignore`**

Delete the line `export_presets.cfg` from `.gitignore`.

- [x] **Step 4: Write `export_presets.cfg`**

```ini
[preset.0]

name="Windows"
platform="Windows Desktop"
runnable=true
export_filter="all_resources"
export_path="build/windows/base13.exe"

[preset.0.options]

binary_format/embed_pck=true

[preset.1]

name="Linux"
platform="Linux"
runnable=true
export_filter="all_resources"
export_path="build/linux/base13.x86_64"

[preset.1.options]

binary_format/embed_pck=true

[preset.2]

name="macOS"
platform="macOS"
runnable=true
export_filter="all_resources"
export_path="build/macos/base13.zip"

[preset.2.options]

codesign/codesign=0
notarization/notarization=0
```

If Godot rewrites the file its own way when opening the project, keep its version: it is guaranteed correct for that build of the engine.

- [x] **Step 5: Write `tools/build.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"

# Builds are only produced on green tests: there is no point shipping broken things.
./tools/test.sh

rm -rf build
mkdir -p build/windows build/linux build/macos

for preset in Windows Linux macOS; do
  echo "=== $preset ==="
  "$GODOT" --headless --export-release "$preset"
done

echo "=== what came out ==="
find build -type f -size +0 -exec ls -lh {} \;
```

```bash
chmod +x tools/build.sh
```

- [x] **Step 6: Build it and check**

```bash
./tools/build.sh
```

Expected: three non-empty files in `build/`. Then unpack and run the macOS build:

```bash
unzip -o build/macos/base13.zip -d build/macos
open build/macos/*.app
```

- [x] **Step 7: Add to `README.md`**

```markdown
## Builds

    ./tools/build.sh

Puts builds for Windows, macOS and Linux into `build/`. You need the Godot 4.7.2
export templates: `Editor → Manage Export Templates`.

The macOS build is unsigned — on somebody else's Mac it opens through right-click.
Signing and notarization belong to subproject 4.
```

- [x] **Step 8: Commit**

```bash
git add .gitignore export_presets.cfg tools/build.sh README.md
git commit -m "feat: builds for Windows, macOS and Linux with one command"
```

---

## Readiness of part B2

1. `./tools/test.sh` green in full, including `core/` isolation and the atlas and sound verification.
2. The game sounds: engine, shots, explosions, power-ups, jingles.
3. The screen flow works from the splash to game over and back to the menu.
4. Pause stops the simulation and releases it without a jerk.
5. The high score survives a restart, and a broken file does not bring the game down.
6. The gamepad plays on equal terms with the keyboard.
7. Three builds are produced, and the macOS build runs.

With that, subproject 1 is closed in full. Next comes subproject 2: touch input, portrait
layout, Android and iOS builds.
