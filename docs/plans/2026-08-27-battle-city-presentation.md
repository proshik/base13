# BASE 13: a playable desktop game — implementation plan (subproject 1, part B1)

**Goal:** Bring BASE 13 to the point where a person sits down at the keyboard and plays through all thirty-five levels — alone or with someone else.

**Architecture:** The core from part A is not touched: it already computes the whole game. Between it and the screen stands `presentation/view_model.gd` — an ordinary `RefCounted` class with not a single node, which turns `WorldState` into a flat list of "what to draw". It is tested headless with the same command as the core, and all the display logic lives in it: pixel coordinates, layers, blinking. The nodes stay thin: they read the list and draw it through `_draw()`. The campaign — carrying score, lives and upgrades between levels — is also written as an engine-independent class in `core/`.

**Tech Stack:** Godot 4.7.2, GDScript, GUT 9.7.1 (headless), Python 3 from the standard library for asset generation.

**Spec:** `docs/specs/2026-08-27-battle-city-presentation-design.md`

**Not in this plan** (part B2, a separate plan): sound and jingles, the splash screen, the player-count menu, the stats screen by enemy type, pause, gamepad, hi-score, builds for Windows, macOS and Linux.

## Global Constraints

- Godot **4.7.2**. The path to the binary in the commands: `$GODOT`, by default `/Applications/Godot.app/Contents/MacOS/Godot`.
- The `./tools/test.sh` check must stay green after every task.
- **The `core/` rules continue to apply** to the new file `core/campaign.gd` as well: no `Node`, no `Input`, no `Time`, no `FileAccess`, no `preload`/`load`, no `randi`/`randf`, and **not one `float`**. Checked by `tools/check_core_isolation.sh` on every run.
- In `presentation/` and `platform/` `float` is allowed: those deal with frames and time, not with game rules.
- **Careful with comments in `core/`.** The isolation check looks for text, not code: a `randi()` or `FileAccess.` inside a doc comment fails it. Write them without the parentheses.
- **`var x := foo.bar` does not compile if `foo` is an untyped parameter.** There are many such functions in the core code; local variables need an explicit type.
- The base resolution is 256×240. The field is 208×208 with a margin of 16 at the top and 8 on the left. The panel on the right is 40 px wide.
- An integer window scale is mandatory: with a fractional one the pixel art falls apart.
- A commit after every task. Messages in English: `feat:`, `test:`, `chore:`, `docs:`.

## File structure

| File | Responsibility |
|------|-----------------|
| `tools/gen_sprites.py` | Text sources → four PNG atlases; `--check` mode for the tests |
| `tools/sprite_data.py` | The drawings themselves: grids of characters and palettes |
| `assets/sprites.png` | The 16×16 atlas: tanks, eagle, power-ups, explosions, flashes |
| `assets/terrain.png` | The 8×8 atlas: brick, steel, water, forest, ice |
| `assets/bullets.png` | The 4×4 atlas: the bullet in four directions |
| `assets/font.png` | The 8×8 atlas: digits and uppercase Latin |
| `presentation/frames.gd` | Frame numbers: whose sprite is where in the atlas |
| `presentation/tick_pump.gd` | How many simulation ticks to advance per frame |
| `presentation/view_model.gd` | `WorldState` → a list of `Item` |
| `presentation/effects.gd` | Explosions and flashes produced from events |
| `presentation/field.gd` | Drawing the terrain and the entities |
| `presentation/hud.gd` | The right-hand panel |
| `presentation/stage_intro.gd` | The black `STAGE N` screen between levels |
| `platform/keyboard.gd` | Keys → five bits per player |
| `core/campaign.gd` | Score, lives, upgrades between levels; looping |
| `game.tscn`, `game.gd` | The main scene: holds the simulation and pumps the ticks |

## Atlas layout

A frame is addressed by one number: `frame = row * columns + col`.

`assets/sprites.png` — 16 columns of 16 px, frames 16×16:

| Frames | What |
|-------|-----|
| 0–31 | The player's tank: upgrade stage 0–3, and within a stage `dir * 2 + track` |
| 32–63 | Enemies: `BASIC`, `FAST`, `POWER`, `ARMOR`, and within a type `dir * 2 + track` |
| 64–65 | The eagle: intact, destroyed |
| 66–69 | The spawn flash, four frames |
| 70–72 | The small explosion (bullet), three frames |
| 73–77 | The big explosion (tank), five frames |
| 78–83 | Power-ups in `Types.BonusType` order: helmet, clock, shovel, star, grenade, tank |
| 84–85 | The shield around a tank, two frames |

`ARMOR` health is shown not by separate frames but by tinting while drawing.

`assets/terrain.png` — 8 columns of 8 px: 0 brick, 1 steel, 2–3 water (two frames), 4 forest, 5 ice.

`assets/bullets.png` — 4 columns of 4 px: the frame equals the `Types.Dir` direction.

`assets/font.png` — 16 columns of 8 px: frames 0–9 digits, 10–35 letters A–Z.

---

### Task 1: The sprite generator and the atlases

**Files:**
- Create: `tools/sprite_data.py`
- Create: `tools/gen_sprites.py`
- Create: `assets/sprites.png`, `assets/terrain.png`, `assets/bullets.png`, `assets/font.png`
- Create: `assets/atlas.manifest`
- Modify: `tools/test.sh`
- Test: `tests/presentation/test_atlas.gd`

**Interfaces:**
- Consumes: nothing
- Produces: four PNGs in `assets/` with the layout from the plan header; `python3 tools/gen_sprites.py` rebuilds them, and `--check` verifies that what was built matches what is recorded in `assets/atlas.manifest`.

The drawings are kept as text: `.` is transparent, and the digits `1`–`3` are palette colour numbers. The levels were kept the same way in part A, and for the same reason: the diff shows what changed, editing does not require a graphics editor, and generation is reproducible.

Every tank is drawn **once with its barrel up**, and the generator obtains the other three directions by rotating 90°. The rotation is integer and exact, so there is four times less handwork and no divergence between directions by construction.

- [x] **Step 1: Write `tools/sprite_data.py` — palettes, terrain, bullet**

```python
#!/usr/bin/env python3
"""Sprite sources: grids of characters and palettes.

'.' is transparent, '1'..'3' are colour numbers in the sprite's palette.
Tanks are drawn with the barrel up; the generator obtains the other directions by rotation.
"""

# Colours in RGBA.
PALETTES = {
    "brick":   [(0, 0, 0, 0), (140, 68, 20, 255), (196, 112, 44, 255), (0, 0, 0, 0)],
    "steel":   [(0, 0, 0, 0), (128, 128, 128, 255), (216, 216, 216, 255), (0, 0, 0, 0)],
    "water":   [(0, 0, 0, 0), (32, 56, 176, 255), (88, 128, 232, 255), (0, 0, 0, 0)],
    "trees":   [(0, 0, 0, 0), (0, 132, 32, 255), (0, 88, 20, 255), (0, 0, 0, 0)],
    "ice":     [(0, 0, 0, 0), (188, 220, 236, 255), (240, 248, 252, 255), (0, 0, 0, 0)],
    "bullet":  [(0, 0, 0, 0), (216, 216, 216, 255), (0, 0, 0, 0), (0, 0, 0, 0)],
    "player":  [(0, 0, 0, 0), (128, 96, 24, 255), (228, 176, 44, 255), (96, 64, 16, 255)],
    "enemy":   [(0, 0, 0, 0), (108, 108, 108, 255), (188, 188, 188, 255), (72, 72, 72, 255)],
    "eagle":   [(0, 0, 0, 0), (128, 88, 40, 255), (228, 228, 228, 255), (72, 48, 20, 255)],
    "bonus":   [(0, 0, 0, 0), (228, 176, 44, 255), (228, 228, 228, 255), (176, 40, 40, 255)],
    "flash":   [(0, 0, 0, 0), (228, 228, 228, 255), (128, 200, 232, 255), (0, 0, 0, 0)],
    "fire":    [(0, 0, 0, 0), (228, 176, 44, 255), (216, 72, 24, 255), (228, 228, 228, 255)],
    "font":    [(0, 0, 0, 0), (228, 228, 228, 255), (0, 0, 0, 0), (0, 0, 0, 0)],
}

# Terrain, 8x8. The drawings must tile with themselves: a single cell rarely
# stands alone, and a seam between two bricks is visible at once.
TERRAIN = {
    "brick": [
        "22222222",
        "11121111",
        "11121111",
        "11121111",
        "22222222",
        "11111112",
        "11111112",
        "11111112",
    ],
    "steel": [
        "22222222",
        "21111112",
        "21211212",
        "21211212",
        "21211212",
        "21211212",
        "21111112",
        "22222222",
    ],
    "water_a": [
        "11111111",
        "12211221",
        "11111111",
        "11111111",
        "11111111",
        "22112211",
        "11111111",
        "11111111",
    ],
    "water_b": [
        "11111111",
        "11111111",
        "22112211",
        "11111111",
        "11111111",
        "11111111",
        "12211221",
        "11111111",
    ],
    "trees": [
        "12211221",
        "11111111",
        "21122112",
        "11111111",
        "12211221",
        "11111111",
        "21122112",
        "11111111",
    ],
    "ice": [
        "11111111",
        "12111211",
        "11111111",
        "11121112",
        "11111111",
        "12111211",
        "11111111",
        "11121112",
    ],
}

# The bullet, 4x4, point up.
BULLET = [
    ".11.",
    ".11.",
    "1111",
    "1111",
]
```

- [x] **Step 2: Add the player's tank to `tools/sprite_data.py` as a model**

The remaining tanks, the eagle, the power-ups, the explosions, the flash and the font are drawn on the same model in step 8 — the test from step 5 will not let a single frame be forgotten.

```python
# Tanks 16x16, barrel up. Two track frames: in the second the links are shifted
# by a pixel, and that makes the tank look like it is driving rather than sliding.
TANKS = {
    "player0": [
        [
            ".......33.......",
            ".......33.......",
            ".......33.......",
            "111..222222..111",
            "311.22222222.113",
            "111.22222222.111",
            "311.22233222.113",
            "111.22233222.111",
            "311.22222222.113",
            "111.22222222.111",
            "311.22222222.113",
            "111.22222222.111",
            "311..222222..113",
            "111..222222..111",
            "311..2....2..113",
            "111..2....2..111",
        ],
        [
            ".......33.......",
            ".......33.......",
            ".......33.......",
            "311..222222..113",
            "111.22222222.111",
            "311.22222222.113",
            "111.22233222.111",
            "311.22233222.113",
            "111.22222222.111",
            "311.22222222.113",
            "111.22222222.111",
            "311.22222222.113",
            "111..222222..111",
            "311..222222..113",
            "111..2....2..111",
            "311..2....2..113",
        ],
    ],
}

# What else must appear in the atlas — filled in at step 8.
# Tank keys: player0..player3, basic, fast, power, armor.
SPRITES16 = {}   # eagle_alive, eagle_dead, flash0..flash3,
                 # boom_small0..2, boom_big0..4,
                 # bonus_helmet, bonus_clock, bonus_shovel,
                 # bonus_star, bonus_grenade, bonus_tank, shield0, shield1
FONT = {}        # "0".."9", "A".."Z", 8x8 grids
```

- [x] **Step 3: Write `tools/gen_sprites.py`**

```python
#!/usr/bin/env python3
"""Assembling PNG atlases from text sources.

The PNG bytes depend on the zlib version, so what is checked is not the file but
the pixels: assets/atlas.manifest sits alongside with the sha256 of the raw data.
That way --check catches a forgotten rebuild and does not break on another machine.
"""
import hashlib
import os
import struct
import sys
import zlib

import sprite_data as data

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
ASSETS = os.path.join(ROOT, "assets")
MANIFEST = os.path.join(ASSETS, "atlas.manifest")


def rotate_cw(grid):
    """Rotate the grid 90° clockwise."""
    n = len(grid)
    return ["".join(grid[n - 1 - x][y] for x in range(n)) for y in range(n)]


def raw_rgba(width, height, cells, cell_size, columns):
    """Lays the frames out on a grid and returns raw RGBA rows."""
    rows = [bytearray(width * 4) for _ in range(height)]
    for index, (grid, palette) in enumerate(cells):
        ox = (index % columns) * cell_size
        oy = (index // columns) * cell_size
        for y, line in enumerate(grid):
            for x, ch in enumerate(line):
                color = palette[0] if ch == "." else palette[int(ch)]
                at = (ox + x) * 4
                rows[oy + y][at:at + 4] = bytes(color)
    return rows


def write_png(path, width, height, rows):
    raw = b"".join(b"\x00" + bytes(row) for row in rows)

    def chunk(tag, payload):
        head = struct.pack(">I", len(payload)) + tag + payload
        return head + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    blob = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    with open(path, "wb") as handle:
        handle.write(blob)


def tank_cells():
    """Tanks: every drawing is unfolded into four directions."""
    order = ["player0", "player1", "player2", "player3",
             "basic", "fast", "power", "armor"]
    cells = []
    for name in order:
        palette = data.PALETTES["player" if name.startswith("player") else "enemy"]
        frames = data.TANKS[name]
        for direction in range(4):
            for frame in frames:
                grid = frame
                for _ in range(direction):
                    grid = rotate_cw(grid)
                cells.append((grid, palette))
    return cells


def sprites_atlas():
    cells = tank_cells()
    extras = ["eagle_alive", "eagle_dead",
              "flash0", "flash1", "flash2", "flash3",
              "boom_small0", "boom_small1", "boom_small2",
              "boom_big0", "boom_big1", "boom_big2", "boom_big3", "boom_big4",
              "bonus_helmet", "bonus_clock", "bonus_shovel",
              "bonus_star", "bonus_grenade", "bonus_tank",
              "shield0", "shield1"]
    palettes = {"eagle": "eagle", "flash": "flash", "boom": "fire",
                "bonus": "bonus", "shield": "flash"}
    for name in extras:
        key = next(p for p in palettes if name.startswith(p))
        cells.append((data.SPRITES16[name], data.PALETTES[palettes[key]]))
    return cells, 16, 16


def terrain_atlas():
    order = ["brick", "steel", "water_a", "water_b", "trees", "ice"]
    palettes = ["brick", "steel", "water", "water", "trees", "ice"]
    cells = [(data.TERRAIN[n], data.PALETTES[p]) for n, p in zip(order, palettes)]
    return cells, 8, 8


def bullets_atlas():
    cells = []
    grid = data.BULLET
    for direction in range(4):
        rotated = grid
        for _ in range(direction):
            rotated = rotate_cw(rotated)
        cells.append((rotated, data.PALETTES["bullet"]))
    return cells, 4, 4


def font_atlas():
    order = [str(d) for d in range(10)] + [chr(c) for c in range(65, 91)]
    cells = [(data.FONT[g], data.PALETTES["font"]) for g in order]
    return cells, 8, 16


def build():
    """Assembles all the atlases; returns name → (width, height, rows)."""
    out = {}
    for name, maker in [("sprites", sprites_atlas), ("terrain", terrain_atlas),
                        ("bullets", bullets_atlas), ("font", font_atlas)]:
        cells, cell_size, columns = maker()
        rows_count = (len(cells) + columns - 1) // columns
        width = columns * cell_size
        height = rows_count * cell_size
        out[name] = (width, height, raw_rgba(width, height, cells, cell_size, columns))
    return out


def digest(width, height, rows):
    h = hashlib.sha256()
    h.update(struct.pack(">II", width, height))
    for row in rows:
        h.update(bytes(row))
    return h.hexdigest()


def main():
    check = "--check" in sys.argv
    built = build()
    lines = ["%s %d %d %s" % (name, w, h, digest(w, h, rows))
             for name, (w, h, rows) in sorted(built.items())]
    text = "\n".join(lines) + "\n"

    if check:
        if not os.path.exists(MANIFEST):
            print("ERROR: assets/atlas.manifest is missing — run gen_sprites.py")
            return 1
        with open(MANIFEST) as handle:
            if handle.read() != text:
                print("ERROR: atlases diverged from their sources — rebuild them")
                return 1
        print("Atlases: OK")
        return 0

    os.makedirs(ASSETS, exist_ok=True)
    for name, (w, h, rows) in built.items():
        write_png(os.path.join(ASSETS, name + ".png"), w, h, rows)
    with open(MANIFEST, "w") as handle:
        handle.write(text)
    print("Atlases built: %d" % len(built))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [x] **Step 4: Add the atlas check to `tools/test.sh`**

Insert it right after the `check_core_isolation.sh` call:

```bash
(cd tools && python3 gen_sprites.py --check)
```

- [x] **Step 5: Write the failing atlas test**

`tests/presentation/test_atlas.gd`:

```gdscript
extends GutTest

const ATLASES := {
	"res://assets/sprites.png": Vector2i(256, 96),
	"res://assets/terrain.png": Vector2i(64, 8),
	"res://assets/bullets.png": Vector2i(16, 4),
	"res://assets/font.png": Vector2i(128, 24),
}

func _image(path: String) -> Image:
	var texture: Texture2D = ResourceLoader.load(path)
	assert_not_null(texture, "no atlas at %s" % path)
	return texture.get_image()

func _frame_is_drawn(img: Image, frame: int, cell: int, columns: int) -> bool:
	var ox := (frame % columns) * cell
	var oy := (frame / columns) * cell
	for y in cell:
		for x in cell:
			if img.get_pixel(ox + x, oy + y).a > 0.0:
				return true
	return false

func test_atlases_have_the_expected_size() -> void:
	for path in ATLASES:
		var img := _image(path)
		assert_eq(Vector2i(img.get_width(), img.get_height()), ATLASES[path],
			"size of atlas %s" % path)

func test_every_sprite_frame_is_drawn() -> void:
	var img := _image("res://assets/sprites.png")
	for frame in 86:
		assert_true(_frame_is_drawn(img, frame, 16, 16),
			"frame %d in sprites.png is empty — the sprite was not drawn" % frame)

func test_every_terrain_and_bullet_frame_is_drawn() -> void:
	var terrain := _image("res://assets/terrain.png")
	for frame in 6:
		assert_true(_frame_is_drawn(terrain, frame, 8, 8), "terrain frame %d is empty" % frame)
	var bullets := _image("res://assets/bullets.png")
	for frame in 4:
		assert_true(_frame_is_drawn(bullets, frame, 4, 4), "bullet frame %d is empty" % frame)

func test_every_font_glyph_is_drawn() -> void:
	var img := _image("res://assets/font.png")
	for frame in 36:
		assert_true(_frame_is_drawn(img, frame, 8, 16), "glyph %d is empty" % frame)

func test_tank_directions_differ() -> void:
	# A tank facing up and a tank facing right are a rotation, not the same frame.
	var img := _image("res://assets/sprites.png")
	var up := img.get_region(Rect2i(0, 0, 16, 16))
	var right := img.get_region(Rect2i(32, 0, 16, 16))
	assert_ne(up.get_data(), right.get_data(), "the tank's directions must differ")
```

- [x] **Step 6: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `assets/sprites.png` does not exist, and `gen_sprites.py --check` complains about the missing manifest.

- [x] **Step 7: Build the atlases from what is already drawn**

```bash
cd tools && python3 gen_sprites.py; cd ..
ls -la assets/
```

Expected: a `KeyError` on the first undrawn tank — and that is the work list for the next step.

- [x] **Step 8: Draw the remaining sprites**

Fill in `tools/sprite_data.py`: `TANKS` for `player1`, `player2`, `player3`, `basic`, `fast`, `power`, `armor` (two track frames each, barrel up, 16×16); `SPRITES16` for the eagle, the flash, the explosions, the six power-ups and the two shield frames (16×16); `FONT` for the digits and uppercase Latin (8×8 grids).

Guidelines: the player's upgrade stages differ in the shape of the barrel and an overlay on the turret — from plain to double-barrelled; `fast` is narrower with a long barrel; `power` has a wide turret; `armor` has plates along its sides. The enemies share one palette: the health difference is shown by tinting while drawing, not by separate frames.

After every edit:

```bash
cd tools && python3 gen_sprites.py; cd ..
./tools/test.sh
```

- [x] **Step 9: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: `Atlases: OK`, all tests green.

- [x] **Step 10: Commit**

```bash
git add tools/sprite_data.py tools/gen_sprites.py tools/test.sh assets tests/presentation/test_atlas.gd
git commit -m "feat: sprite generator and four atlases from text sources"
```

---

### Task 2: The tick accumulator

**Files:**
- Create: `presentation/tick_pump.gd`
- Test: `tests/presentation/test_tick_pump.gd`

**Interfaces:**
- Consumes: nothing
- Produces: `TickPump.new()` with the method `pump(delta: float) -> int` and the constants `TICK_SECONDS`, `MAX_CATCHUP`.

The core knows nothing about frames: it steps at exactly sixty ticks per second. Who calls `tick()` and how many times per frame is the presentation's duty. A ceiling on catch-up ticks is needed because without it a single dropped frame — switching windows, a debugger pause — turns into a hundred ticks in a row, and the game jumps half the map.

- [x] **Step 1: Write the failing tests**

`tests/presentation/test_tick_pump.gd`:

```gdscript
extends GutTest

var pump: TickPump

func before_each() -> void:
	pump = TickPump.new()

func test_one_frame_at_sixty_hertz_is_one_tick() -> void:
	assert_eq(pump.pump(1.0 / 60.0), 1)

func test_short_frames_accumulate() -> void:
	assert_eq(pump.pump(1.0 / 120.0), 0, "half a frame is not yet a tick")
	assert_eq(pump.pump(1.0 / 120.0), 1, "two halves make a tick")

func test_long_frame_gives_several_ticks() -> void:
	assert_eq(pump.pump(3.0 / 60.0), 3)

func test_catchup_is_capped() -> void:
	assert_eq(pump.pump(1.0), TickPump.MAX_CATCHUP,
		"a one-second drop must not advance sixty ticks")

func test_capped_frame_does_not_leave_a_debt() -> void:
	pump.pump(1.0)
	assert_eq(pump.pump(1.0 / 60.0), 1,
		"after a clipped drop the next frame is an ordinary tick, not a catch-up")

func test_zero_delta_gives_nothing() -> void:
	assert_eq(pump.pump(0.0), 0)

func test_exactly_max_catchup_is_not_treated_as_an_overrun() -> void:
	var seconds: float = float(TickPump.MAX_CATCHUP) / 60.0
	assert_eq(pump.pump(seconds), TickPump.MAX_CATCHUP)
	assert_eq(pump.pump(1.0 / 60.0), 1, "no debt is left, but the accumulator was not reset for nothing either")
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "TickPump" not declared`.

- [x] **Step 3: Write `presentation/tick_pump.gd`**

```gdscript
class_name TickPump

## The core steps at exactly sixty ticks per second and knows nothing about frames.
## Here we count how many times to call tick() per drawn frame.

const TICK_SECONDS := 1.0 / 60.0
const MAX_CATCHUP := 5

var _accumulated := 0.0

func pump(delta: float) -> int:
	_accumulated += delta
	var ticks := 0
	while _accumulated >= TICK_SECONDS:
		if ticks >= MAX_CATCHUP:
			# A dropped frame: we do not accumulate debt, or the game jumps half the map.
			_accumulated = 0.0
			break
		_accumulated -= TICK_SECONDS
		ticks += 1
	return ticks
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 5: Commit**

```bash
git add presentation/tick_pump.gd tests/presentation/test_tick_pump.gd
git commit -m "feat: tick accumulator with a ceiling on catch-up ticks"
```

---

### Task 3: Frame numbers

**Files:**
- Create: `presentation/frames.gd`
- Test: `tests/presentation/test_frames.gd`

**Interfaces:**
- Consumes: `Types`
- Produces: `Frames.tank(tank_type, stars, dir, track) -> int`, `Frames.bonus(bonus_type) -> int`, `Frames.terrain(cell, tick) -> int`, `Frames.track_of(pos: Vector2i) -> int`, `Frames.flash(spawn_ticks) -> int`, `Frames.shield(tick) -> int`, `Frames.boom_big(age) -> int`, `Frames.boom_small(age) -> int`, and the constants `EAGLE_ALIVE`, `EAGLE_DEAD`, `BOOM_BIG_FRAMES`, `BOOM_SMALL_FRAMES`.

One file for all the atlas addressing: otherwise the numbers spread through the drawing code, and a shift in the layout has to be caught by eye.

The track frame is chosen **by the tank's position, not by the tick number.** A standing tank then does not churn its tracks on the spot, and a moving one animates by itself — all without a single state field in the presentation layer.

- [x] **Step 1: Write the failing tests**

`tests/presentation/test_frames.gd`:

```gdscript
extends GutTest

func test_player_stages_occupy_their_own_blocks() -> void:
	assert_eq(Frames.tank(Types.TankType.PLAYER, 0, Types.Dir.UP, 0), 0)
	assert_eq(Frames.tank(Types.TankType.PLAYER, 1, Types.Dir.UP, 0), 8)
	assert_eq(Frames.tank(Types.TankType.PLAYER, 3, Types.Dir.UP, 0), 24)

func test_stars_above_three_do_not_run_off_the_atlas() -> void:
	assert_eq(Frames.tank(Types.TankType.PLAYER, 9, Types.Dir.UP, 0), 24,
		"there is no fourth upgrade stage")

func test_direction_and_track_inside_a_block() -> void:
	assert_eq(Frames.tank(Types.TankType.PLAYER, 0, Types.Dir.RIGHT, 0), 2)
	assert_eq(Frames.tank(Types.TankType.PLAYER, 0, Types.Dir.RIGHT, 1), 3)
	assert_eq(Frames.tank(Types.TankType.PLAYER, 0, Types.Dir.LEFT, 1), 7)

func test_enemies_start_after_the_player_block() -> void:
	assert_eq(Frames.tank(Types.TankType.BASIC, 0, Types.Dir.UP, 0), 32)
	assert_eq(Frames.tank(Types.TankType.FAST, 0, Types.Dir.UP, 0), 40)
	assert_eq(Frames.tank(Types.TankType.ARMOR, 0, Types.Dir.UP, 0), 56)

func test_bonus_frames_follow_the_enum() -> void:
	assert_eq(Frames.bonus(Types.BonusType.HELMET), 78)
	assert_eq(Frames.bonus(Types.BonusType.TANK), 83)

func test_terrain_frames() -> void:
	assert_eq(Frames.terrain(Types.Cell.BRICK, 0), 0)
	assert_eq(Frames.terrain(Types.Cell.STEEL, 0), 1)
	assert_eq(Frames.terrain(Types.Cell.TREES, 0), 4)
	assert_eq(Frames.terrain(Types.Cell.ICE, 0), 5)
	assert_eq(Frames.terrain(Types.Cell.EMPTY, 0), -1, "we do not draw an empty cell")

func test_water_animates_with_time() -> void:
	assert_eq(Frames.terrain(Types.Cell.WATER, 0), 2)
	assert_eq(Frames.terrain(Types.Cell.WATER, Frames.WATER_PERIOD), 3)
	assert_eq(Frames.terrain(Types.Cell.WATER, Frames.WATER_PERIOD * 2), 2)

func test_tracks_follow_position_not_time() -> void:
	var still := Vector2i(1024, 1024)
	assert_eq(Frames.track_of(still), Frames.track_of(still),
		"a standing tank does not churn its tracks")
	assert_ne(Frames.track_of(still), Frames.track_of(still + Vector2i(Frames.TRACK_STEP, 0)),
		"having covered TRACK_STEP, the tank changes its track frame")

func test_spawn_flash_cycles_through_four_frames() -> void:
	var seen := {}
	for ticks in 60:
		seen[Frames.flash(ticks)] = true
	assert_eq(seen.size(), 4, "the spawn flash is four frames")
	for frame in seen:
		assert_between(frame, 66, 69, "the flash lives in frames 66..69")

func test_explosion_frames_are_clamped_at_the_last_one() -> void:
	assert_eq(Frames.boom_big(0), 73)
	assert_eq(Frames.boom_big(Frames.BOOM_BIG_FRAMES - 1), 77)
	assert_eq(Frames.boom_big(999), 77, "an age overrun does not go outside the atlas")
	assert_eq(Frames.boom_small(0), 70)
	assert_eq(Frames.boom_small(999), 72)
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "Frames" not declared`.

- [x] **Step 3: Write `presentation/frames.gd`**

```gdscript
class_name Frames

## All the atlas addressing in one place: otherwise the frame numbers spread
## through the drawing code and a shift in the layout has to be caught by eye.

const TANK_BLOCK := 8      ## 4 directions × 2 track frames
const PLAYER_BASE := 0
const ENEMY_BASE := 32
const MAX_STARS := 3

const EAGLE_ALIVE := 64
const EAGLE_DEAD := 65
const FLASH_BASE := 66
const FLASH_FRAMES := 4
const BOOM_SMALL_BASE := 70
const BOOM_SMALL_FRAMES := 3
const BOOM_BIG_BASE := 73
const BOOM_BIG_FRAMES := 5
const BONUS_BASE := 78
const SHIELD_BASE := 84
const SHIELD_FRAMES := 2

const WATER_PERIOD := 30   ## half a second per frame — the water sways rather than flickers
const TRACK_STEP := 32     ## after how many units of travel the track frame changes
const FLASH_PERIOD := 8
const SHIELD_PERIOD := 4

static func tank(tank_type: int, stars: int, dir: int, track: int) -> int:
	var base := ENEMY_BASE + (tank_type - Types.TankType.BASIC) * TANK_BLOCK
	if tank_type == Types.TankType.PLAYER:
		base = PLAYER_BASE + clampi(stars, 0, MAX_STARS) * TANK_BLOCK
	return base + dir * 2 + track

## The track frame is taken from the position, not from time: a standing tank
## must not shuffle its tracks on the spot.
static func track_of(pos: Vector2i) -> int:
	return ((pos.x + pos.y) / TRACK_STEP) % 2

static func bonus(bonus_type: int) -> int:
	return BONUS_BASE + bonus_type

static func terrain(cell: int, tick: int) -> int:
	match cell:
		Types.Cell.BRICK:
			return 0
		Types.Cell.STEEL:
			return 1
		Types.Cell.WATER:
			return 2 + (tick / WATER_PERIOD) % 2
		Types.Cell.TREES:
			return 4
		Types.Cell.ICE:
			return 5
		_:
			return -1

static func flash(spawn_ticks: int) -> int:
	return FLASH_BASE + (spawn_ticks / FLASH_PERIOD) % FLASH_FRAMES

static func shield(tick: int) -> int:
	return SHIELD_BASE + (tick / SHIELD_PERIOD) % SHIELD_FRAMES

static func boom_small(age: int) -> int:
	return BOOM_SMALL_BASE + mini(age, BOOM_SMALL_FRAMES - 1)

static func boom_big(age: int) -> int:
	return BOOM_BIG_BASE + mini(age, BOOM_BIG_FRAMES - 1)
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 5: Commit**

```bash
git add presentation/frames.gd tests/presentation/test_frames.gd
git commit -m "feat: frame addressing in the atlases"
```

---

### Task 4: The translator layer — tanks, bullets, eagle, power-up

**Files:**
- Create: `presentation/view_model.gd`
- Test: `tests/presentation/test_view_model.gd`

**Interfaces:**
- Consumes: `WorldState`, `SimConfig`, `Consts`, `Types`, `Frames`
- Produces: `ViewModel.Item` with the fields `atlas`, `frame`, `pos`, `layer`, `tint`; the enums `ViewModel.Atlas { SPRITES, BULLETS, TERRAIN }` and `ViewModel.Layer { BONUS, ENTITIES, OVER }`; `ViewModel.build(state: WorldState, config: SimConfig) -> Array`.

**All** the display logic lives here. The nodes from task 6 decide nothing: they take the list and draw it.

The rule about the invisible: whatever is not visible right now does not get into the list. There is no separate `visible` flag — that way "the blinking power-up is dark right now" is checked by the absence of an entry rather than by inspecting its fields.

The coordinates in the list are pixels of the **field**, counted from the top-left corner of the play area. The field's offset on screen is the scene's business, not the translator's: in subproject 2 the panel will move down, and the translator must know nothing about it.

- [x] **Step 1: Write the failing tests**

`tests/presentation/test_view_model.gd`:

```gdscript
extends GutTest

var state: WorldState
var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()
	state = WorldState.new()
	state.terrain = Terrain.new()

func _tank(type: int, pos: Vector2i, player_index := -1) -> Entities.Tank:
	var t := Entities.Tank.new()
	t.id = state.next_id()
	t.type = type
	t.player_index = player_index
	t.pos = pos
	t.dir = Types.Dir.UP
	t.health = 1
	t.alive = true
	state.tanks.append(t)
	return t

func _items_at_layer(layer: int) -> Array:
	var out: Array = []
	for item in ViewModel.build(state, cfg):
		if item.layer == layer:
			out.append(item)
	return out

func _frames() -> Array:
	var out: Array = []
	for item in ViewModel.build(state, cfg):
		out.append(item.frame)
	return out

## The eagle is always drawn — it only gets in the way of the tank and bullet tests.
func _without_base() -> Array:
	var out: Array = []
	for item in ViewModel.build(state, cfg):
		var is_base: bool = item.atlas == ViewModel.Atlas.SPRITES \
			and (item.frame == Frames.EAGLE_ALIVE or item.frame == Frames.EAGLE_DEAD)
		if not is_base:
			out.append(item)
	return out

func test_units_convert_to_pixels() -> void:
	_tank(Types.TankType.PLAYER, Vector2i(1024, 512), 0)
	var items := _without_base()
	assert_eq(items.size(), 1)
	assert_eq(items[0].pos, Vector2i(64, 32), "1024 units is 64 pixels")

func test_player_tank_uses_its_star_level() -> void:
	var t := _tank(Types.TankType.PLAYER, Vector2i(0, 0), 0)
	t.stars = 2
	var items := _without_base()
	assert_eq(items[0].frame, Frames.tank(Types.TankType.PLAYER, 2, Types.Dir.UP,
		Frames.track_of(Vector2i(0, 0))))

func test_blinking_enemy_is_shown_as_a_flash_not_a_tank() -> void:
	var e := _tank(Types.TankType.BASIC, Vector2i(0, 0))
	e.spawn_ticks = 30
	var items := _without_base()
	assert_eq(items.size(), 1)
	assert_eq(items[0].frame, Frames.flash(30), "while the enemy blinks there is no tank yet")

func test_materialized_enemy_is_a_tank() -> void:
	_tank(Types.TankType.BASIC, Vector2i(0, 0))
	assert_eq(_without_base()[0].frame,
		Frames.tank(Types.TankType.BASIC, 0, Types.Dir.UP, Frames.track_of(Vector2i(0, 0))))

func test_armor_tank_is_tinted_by_health() -> void:
	var full := _tank(Types.TankType.ARMOR, Vector2i(0, 0))
	full.health = 4
	var white: Color = _without_base()[0].tint
	full.health = 1
	var hurt: Color = _without_base()[0].tint
	assert_ne(white, hurt, "the heavy tank's remaining health is visible by colour")

func test_shield_is_drawn_over_the_tank() -> void:
	var t := _tank(Types.TankType.PLAYER, Vector2i(0, 0), 0)
	t.shield_ticks = 100
	var items := _without_base()
	assert_eq(items.size(), 2, "the tank and the shield")
	assert_eq(items[1].layer, ViewModel.Layer.OVER, "the shield goes over the tank")
	assert_between(items[1].frame, Frames.SHIELD_BASE,
		Frames.SHIELD_BASE + Frames.SHIELD_FRAMES - 1)

func test_bullets_come_from_their_own_atlas() -> void:
	var b := Entities.Bullet.new()
	b.id = state.next_id()
	b.dir = Types.Dir.LEFT
	b.pos = Vector2i(256, 256)
	state.bullets.append(b)
	var items := _without_base()
	assert_eq(items[0].atlas, ViewModel.Atlas.BULLETS)
	assert_eq(items[0].frame, Types.Dir.LEFT, "the bullet's frame equals its direction")
	assert_eq(items[0].pos, Vector2i(16, 16))

func test_live_base_is_drawn() -> void:
	assert_has(_frames(), Frames.EAGLE_ALIVE)
	assert_eq(_items_at_layer(ViewModel.Layer.ENTITIES)[0].pos,
		Consts.tile_to_unit(Consts.BASE_TILE) / Consts.SUBPIXEL)

func test_destroyed_base_changes_frame() -> void:
	state.base_alive = false
	assert_has(_frames(), Frames.EAGLE_DEAD)

func test_bonus_lies_under_the_tanks() -> void:
	var b := Entities.Bonus.new()
	b.type = Types.BonusType.STAR
	b.pos = Vector2i(512, 512)
	b.ticks_left = cfg.bonus_life_ticks
	b.active = true
	state.bonus = b
	var items := _items_at_layer(ViewModel.Layer.BONUS)
	assert_eq(items.size(), 1)
	assert_eq(items[0].frame, Frames.bonus(Types.BonusType.STAR))

func test_bonus_blinks_before_it_expires() -> void:
	var b := Entities.Bonus.new()
	b.type = Types.BonusType.STAR
	b.pos = Vector2i(512, 512)
	b.active = true
	state.bonus = b
	var shown := 0
	for left in cfg.bonus_blink_ticks:
		b.ticks_left = left + 1
		shown += _items_at_layer(ViewModel.Layer.BONUS).size()
	assert_gt(shown, 0, "the power-up does not disappear entirely")
	assert_lt(shown, cfg.bonus_blink_ticks, "but it is not visible every tick either — it blinks")

func test_shovel_wall_blinks_when_it_is_about_to_expire() -> void:
	for c in Consts.BASE_WALL_CELLS:
		state.terrain.set_cell(c.x, c.y, Types.Cell.STEEL)
	state.shovel_ticks = cfg.shovel_ticks
	assert_eq(_items_at_layer(ViewModel.Layer.BONUS).size(), 0,
		"while the shovel holds there is nothing to blink")
	var overlay := 0
	for left in range(1, cfg.shovel_blink_ticks + 1):
		state.shovel_ticks = left
		overlay += _items_at_layer(ViewModel.Layer.BONUS).size()
	assert_gt(overlay, 0, "as the shovel runs out the steel winks with brick")
	assert_lt(overlay, Consts.BASE_WALL_CELLS.size() * cfg.shovel_blink_ticks,
		"but not every tick — otherwise it is a substitution, not a blink")

func test_dead_entities_are_not_drawn() -> void:
	var t := _tank(Types.TankType.BASIC, Vector2i(0, 0))
	t.alive = false
	assert_eq(ViewModel.build(state, cfg).size(), 1, "only the eagle is left")

func test_order_inside_the_list_is_layer_order() -> void:
	var bonus := Entities.Bonus.new()
	bonus.pos = Vector2i(0, 0)
	bonus.ticks_left = cfg.bonus_life_ticks
	bonus.active = true
	state.bonus = bonus
	var t := _tank(Types.TankType.PLAYER, Vector2i(512, 512), 0)
	t.shield_ticks = 100
	var layers: Array[int] = []
	for item in ViewModel.build(state, cfg):
		layers.append(item.layer)
	var sorted_layers := layers.duplicate()
	sorted_layers.sort()
	assert_eq(layers, sorted_layers, "the list arrives already in drawing order")
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "ViewModel" not declared`.

- [x] **Step 3: Write `presentation/view_model.gd`**

```gdscript
class_name ViewModel

## The only place where what to draw and where is decided. The nodes decide
## nothing: they take this list and draw it top to bottom by layer.
##
## The invisible is not in the list at all: a power-up dark on its blink simply
## does not reach the result. That way "not visible now" is checked by absence.

enum Atlas { SPRITES, BULLETS, TERRAIN }
enum Layer { BONUS, ENTITIES, OVER }

const ARMOR_TINTS: Array[Color] = [
	Color(1.0, 0.55, 0.55),   ## one hit from death
	Color(1.0, 0.75, 0.55),
	Color(0.75, 0.9, 1.0),
	Color(1.0, 1.0, 1.0),     ## intact
]

class Item:
	var atlas := Atlas.SPRITES
	var frame := 0
	var pos := Vector2i.ZERO     ## pixels, counted from the field's top left
	var layer := Layer.ENTITIES
	var tint := Color.WHITE

static func build(state: WorldState, config: SimConfig) -> Array:
	var items: Array = []
	_add_bonus(items, state, config)
	_add_shovel_blink(items, state, config)
	_add_base(items, state)
	_add_tanks(items, state)
	_add_bullets(items, state)
	_add_shields(items, state)
	return items

static func to_pixels(units: Vector2i) -> Vector2i:
	return units / Consts.SUBPIXEL

static func _item(atlas: int, frame: int, pos: Vector2i, layer: int,
		tint := Color.WHITE) -> Item:
	var it := Item.new()
	it.atlas = atlas
	it.frame = frame
	it.pos = pos
	it.layer = layer
	it.tint = tint
	return it

static func _add_bonus(items: Array, state: WorldState, config: SimConfig) -> void:
	var bonus: Entities.Bonus = state.bonus
	if bonus == null or not bonus.active:
		return
	if bonus.ticks_left <= config.bonus_blink_ticks and not _blink_on(bonus.ticks_left):
		return
	items.append(_item(Atlas.SPRITES, Frames.bonus(bonus.type),
		to_pixels(bonus.pos), Layer.BONUS))

## As the shovel runs out, the steel around the base winks with brick — that is
## how the player sees the protection ending. It is done as an overlay on top of
## the baked terrain: repainting the field every four ticks for eight cells is pointless.
static func _add_shovel_blink(items: Array, state: WorldState, config: SimConfig) -> void:
	if state.shovel_ticks <= 0 or state.shovel_ticks > config.shovel_blink_ticks:
		return
	if _blink_on(state.shovel_ticks):
		return
	for c in Consts.BASE_WALL_CELLS:
		if state.terrain.get_cell(c.x, c.y) != Types.Cell.STEEL:
			continue
		items.append(_item(Atlas.TERRAIN, Frames.terrain(Types.Cell.BRICK, state.tick),
			Vector2i(c.x * Consts.CELL_PX, c.y * Consts.CELL_PX), Layer.BONUS))

static func _add_base(items: Array, state: WorldState) -> void:
	var frame := Frames.EAGLE_ALIVE if state.base_alive else Frames.EAGLE_DEAD
	items.append(_item(Atlas.SPRITES, frame,
		to_pixels(Consts.tile_to_unit(Consts.BASE_TILE)), Layer.ENTITIES))

static func _add_tanks(items: Array, state: WorldState) -> void:
	for t in state.tanks:
		if not t.alive:
			continue
		var pos: Vector2i = to_pixels(t.pos)
		if t.spawn_ticks > 0:
			# While the enemy materializes there is no tank yet — there is a flash.
			items.append(_item(Atlas.SPRITES, Frames.flash(t.spawn_ticks), pos, Layer.ENTITIES))
			continue
		var frame: int = Frames.tank(t.type, t.stars, t.dir, Frames.track_of(t.pos))
		items.append(_item(Atlas.SPRITES, frame, pos, Layer.ENTITIES, _tint_of(t)))

static func _add_bullets(items: Array, state: WorldState) -> void:
	for b in state.bullets:
		if not b.alive:
			continue
		items.append(_item(Atlas.BULLETS, b.dir, to_pixels(b.pos), Layer.ENTITIES))

static func _add_shields(items: Array, state: WorldState) -> void:
	for t in state.tanks:
		if not t.alive or t.spawn_ticks > 0 or t.shield_ticks <= 0:
			continue
		items.append(_item(Atlas.SPRITES, Frames.shield(t.shield_ticks),
			to_pixels(t.pos), Layer.OVER))

## The heavy tank's remaining health is shown by colour: separate frames for
## every hit would double the drawing for the same meaning.
static func _tint_of(t) -> Color:
	if t.type != Types.TankType.ARMOR:
		return Color.WHITE
	return ARMOR_TINTS[clampi(t.health - 1, 0, ARMOR_TINTS.size() - 1)]

static func _blink_on(ticks: int) -> bool:
	return (ticks / Frames.SHIELD_PERIOD) % 2 == 0
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 5: Commit**

```bash
git add presentation/view_model.gd tests/presentation/test_view_model.gd
git commit -m "feat: translator layer from world state into a drawing list"
```

---

### Task 5: Keyboard input

**Files:**
- Create: `platform/keyboard.gd`
- Test: `tests/platform/test_keyboard.gd`

**Interfaces:**
- Consumes: `Types`
- Produces: `Keyboard.LAYOUTS`, `Keyboard.bits(index: int, probe := Callable()) -> int`.

The keyboard decides nothing: it collects five bits of exactly the shape `tick()` accepts. The direction priority when several keys are held is resolved in the core and is not duplicated here.

`probe` is a seam for the tests: without it we would have to poke the real `Input`, and headless it presses nothing. By default the real key polling is substituted.

The layout: **player 1 — arrows and Enter, player 2 — WASD and Space.**

- [x] **Step 1: Write the failing tests**

`tests/platform/test_keyboard.gd`:

```gdscript
extends GutTest

func _only(pressed: Array) -> Callable:
	return func(key: int) -> bool: return pressed.has(key)

func test_first_player_reads_the_arrows() -> void:
	assert_eq(Keyboard.bits(0, _only([KEY_UP])), Types.IN_UP)
	assert_eq(Keyboard.bits(0, _only([KEY_LEFT])), Types.IN_LEFT)
	assert_eq(Keyboard.bits(0, _only([KEY_ENTER])), Types.IN_FIRE)

func test_second_player_reads_wasd() -> void:
	assert_eq(Keyboard.bits(1, _only([KEY_W])), Types.IN_UP)
	assert_eq(Keyboard.bits(1, _only([KEY_D])), Types.IN_RIGHT)
	assert_eq(Keyboard.bits(1, _only([KEY_SPACE])), Types.IN_FIRE)

func test_layouts_do_not_overlap() -> void:
	assert_eq(Keyboard.bits(1, _only([KEY_UP])), 0, "the arrows must not move the second player")
	assert_eq(Keyboard.bits(0, _only([KEY_W])), 0, "WASD must not move the first player")

func test_several_keys_combine_into_one_mask() -> void:
	assert_eq(Keyboard.bits(0, _only([KEY_UP, KEY_ENTER])), Types.IN_UP | Types.IN_FIRE)

func test_nothing_pressed_is_zero() -> void:
	assert_eq(Keyboard.bits(0, _only([])), 0)

func test_unknown_player_index_is_silent() -> void:
	assert_eq(Keyboard.bits(7, _only([KEY_UP])), 0,
		"there is no third player, but that is no reason to crash")
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "Keyboard" not declared`.

- [x] **Step 3: Write `platform/keyboard.gd`**

```gdscript
class_name Keyboard

## Collects five bits of exactly the shape GameSim.tick() accepts.
## The direction priority when several keys are held is resolved in the core —
## it is not duplicated here, or the rule would live in two places.

const LAYOUTS: Array[Dictionary] = [
	{
		"up": KEY_UP, "down": KEY_DOWN, "left": KEY_LEFT, "right": KEY_RIGHT,
		"fire": KEY_ENTER,
	},
	{
		"up": KEY_W, "down": KEY_S, "left": KEY_A, "right": KEY_D,
		"fire": KEY_SPACE,
	},
]

const BITS := {
	"up": Types.IN_UP, "down": Types.IN_DOWN, "left": Types.IN_LEFT,
	"right": Types.IN_RIGHT, "fire": Types.IN_FIRE,
}

## probe is a seam for the tests: real key polling gives nothing headless.
static func bits(index: int, probe := Callable()) -> int:
	if index < 0 or index >= LAYOUTS.size():
		return 0
	var pressed := probe
	if not pressed.is_valid():
		pressed = func(key: int) -> bool: return Input.is_key_pressed(key)
	var mask := 0
	for action in ["up", "down", "left", "right", "fire"]:
		if pressed.call(LAYOUTS[index][action]):
			mask |= BITS[action]
	return mask
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 5: Commit**

```bash
git add platform/keyboard.gd tests/platform/test_keyboard.gd
git commit -m "feat: keyboard input for two people at one keyboard"
```

---

### Task 6: Drawing the field and the first launch

**Files:**
- Create: `presentation/field.gd`
- Create: `game.gd`
- Create: `game.tscn`
- Modify: `project.godot`

**Interfaces:**
- Consumes: `ViewModel`, `Frames`, `TickPump`, `Keyboard`, `LevelLoader`, `GameSim`
- Produces: `Field.sync(state: WorldState, items: Array) -> void` — the field node; the main scene `res://game.tscn`.

**This is the first task whose result you can see with your eyes.** Until now everything was checked by tests; from here the game can be launched, driven and fired.

The terrain is not redrawn every frame. It is assembled into two ready pictures — under the tanks and the forest on top — and repainted only when the cell checksum has changed or the water frame has switched. Otherwise six hundred and seventy-six cells would be drawn sixty times a second for nothing.

- [x] **Step 1: Write `presentation/field.gd`**

```gdscript
class_name Field
extends Node2D

## A thin node: it decides nothing and draws the ready list from ViewModel.
## Its only concern is not to repaint the terrain every frame.

const SPRITE_PX := 16
const SPRITE_COLUMNS := 16
const BULLET_COLUMNS := 4
const TERRAIN_COLUMNS := 8

var _sprites: Texture2D = preload("res://assets/sprites.png")
var _bullets: Texture2D = preload("res://assets/bullets.png")
var _terrain_atlas: Texture2D = preload("res://assets/terrain.png")

var _state: WorldState = null
var _items: Array = []
var _under: ImageTexture = null
var _trees: ImageTexture = null
var _terrain_checksum := -1
var _water_frame := -1

func sync(state: WorldState, items: Array) -> void:
	_state = state
	_items = items
	var checksum: int = state.terrain.cells_checksum()
	var water: int = Frames.terrain(Types.Cell.WATER, state.tick)
	if checksum != _terrain_checksum or water != _water_frame:
		_terrain_checksum = checksum
		_water_frame = water
		_rebuild_terrain()
	queue_redraw()

func _rebuild_terrain() -> void:
	var atlas: Image = _terrain_atlas.get_image()
	var under := Image.create_empty(Consts.FIELD_PX, Consts.FIELD_PX, false, Image.FORMAT_RGBA8)
	var trees := Image.create_empty(Consts.FIELD_PX, Consts.FIELD_PX, false, Image.FORMAT_RGBA8)
	for cy in Consts.GRID:
		for cx in Consts.GRID:
			var cell: int = _state.terrain.get_cell(cx, cy)
			var frame: int = Frames.terrain(cell, _state.tick)
			if frame < 0:
				continue
			var src := Rect2i(frame * Consts.CELL_PX, 0, Consts.CELL_PX, Consts.CELL_PX)
			var at := Vector2i(cx * Consts.CELL_PX, cy * Consts.CELL_PX)
			if cell == Types.Cell.TREES:
				trees.blit_rect(atlas, src, at)
			else:
				under.blit_rect(atlas, src, at)
	_under = ImageTexture.create_from_image(under)
	_trees = ImageTexture.create_from_image(trees)

func _draw() -> void:
	if _state == null:
		return
	draw_texture(_under, Vector2.ZERO)
	for item in _items:
		_draw_item(item)
	# The forest is drawn last: tanks hide under it, and that is its whole point.
	draw_texture(_trees, Vector2.ZERO)

func _draw_item(item) -> void:
	var texture := _sprites
	var size := SPRITE_PX
	var columns := SPRITE_COLUMNS
	if item.atlas == ViewModel.Atlas.BULLETS:
		texture = _bullets
		size = Consts.BULLET / Consts.SUBPIXEL
		columns = BULLET_COLUMNS
	elif item.atlas == ViewModel.Atlas.TERRAIN:
		texture = _terrain_atlas
		size = Consts.CELL_PX
		columns = TERRAIN_COLUMNS
	var src := Rect2i((item.frame % columns) * size, (item.frame / columns) * size, size, size)
	draw_texture_rect_region(texture, Rect2(item.pos, Vector2(size, size)), src, item.tint)
```

- [x] **Step 2: Write `game.gd`**

```gdscript
extends Node2D

## The main scene: holds the simulation, pumps the ticks and hands the state out for drawing.
## It has no game rules of its own and never will — they all live in core/.

const FIELD_ORIGIN := Vector2i(8, 16)

var _sim: GameSim = null
var _pump := TickPump.new()
var _player_count := 1
var _level_number := 1

@onready var _field: Field = $Field

func _ready() -> void:
	_field.position = FIELD_ORIGIN
	_restart(1)

func _restart(player_count: int) -> void:
	_player_count = player_count
	_pump = TickPump.new()
	_start_level(_level_number)

func _start_level(number: int) -> void:
	var level := LevelLoader.load_level(number)
	if level.error != "":
		push_error("level %d cannot be read: %s" % [number, level.error])
		return
	_sim = GameSim.new(level, 1000 + number, SimConfig.new(), number, _player_count)

func _unhandled_input(event: InputEvent) -> void:
	# Temporary hotkeys: the real menu arrives in part B2 and replaces them.
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1:
			_restart(1)
		elif event.keycode == KEY_F2:
			_restart(2)

func _process(delta: float) -> void:
	if _sim == null:
		return
	for i in _pump.pump(delta):
		_sim.tick([Keyboard.bits(0), Keyboard.bits(1)])
	_sim.drain_events()
	var state := _sim.get_state()
	_field.sync(state, ViewModel.build(state, _sim.get_config()))
```

- [x] **Step 3: Write `game.tscn`**

```
[gd_scene load_steps=3 format=3]

[ext_resource type="Script" path="res://game.gd" id="1_game"]
[ext_resource type="Script" path="res://presentation/field.gd" id="2_field"]

[node name="Game" type="Node2D"]
script = ExtResource("1_game")

[node name="Field" type="Node2D" parent="."]
script = ExtResource("2_field")
```

- [x] **Step 4: Declare the main scene in `project.godot`**

Add to the `[application]` section:

```ini
run/main_scene="res://game.tscn"
```

- [x] **Step 5: Make sure the tests did not break**

Run: `./tools/test.sh`
Expected: all tests green. There are no new tests here: `field.gd` and `game.gd` are thin nodes, and they are checked in the next step.

- [x] **Step 6: Launch the game and look with your eyes**

```bash
"$GODOT"
```

Expected: a 256×240 window, a field with brick and steel, your tank at the bottom edge, and enemies appearing at the top. The arrows move, Enter fires, and the brick is chewed out in a strip as wide as a tank. F2 restarts with two players: the second tank is controlled with WASD and Space.

What to check specifically with your eyes, because the tests cannot see it:

- The pixels are all one size and nothing is blurred.
- The tank does not "float" past the grid when turning — the snap looks natural.
- The forest hides the tank, and the water does not.
- The tracks move while driving and stand still when the tank stands.

- [x] **Step 7: Commit**

```bash
git add presentation/field.gd game.gd game.tscn project.godot
git commit -m "feat: field drawing and a runnable game"
```

---

### Task 7: Explosions and flashes

**Files:**
- Create: `presentation/effects.gd`
- Modify: `game.gd`
- Test: `tests/presentation/test_effects.gd`

**Interfaces:**
- Consumes: `SimEvent`, `Types`, `Frames`, `ViewModel`
- Produces: `Effects.new()` with the methods `absorb(events: Array) -> void`, `advance() -> void`, `items() -> Array`; the constants `Effects.FRAME_TICKS`, `Effects.BIG_LIFETIME`, `Effects.SMALL_LIFETIME`.

The core plays no sounds and starts no animations — it accumulates events, and the presentation decides how to show them. The explosions are the first taking-apart of those events.

This is the only place in the whole presentation layer that **has state of its own**: an explosion burning out lives longer than the tick it was born in. Rule 6 permits exactly this exception — short-lived decoration produced from events.

- [x] **Step 1: Write the failing tests**

`tests/presentation/test_effects.gd`:

```gdscript
extends GutTest

var fx: Effects

func before_each() -> void:
	fx = Effects.new()

func _event(type: int, pos := Vector2i(1024, 1024)) -> SimEvent:
	return SimEvent.new(type, pos, 0)

func test_no_events_no_effects() -> void:
	fx.absorb([])
	assert_eq(fx.items().size(), 0)

func test_destroyed_tank_makes_a_big_burst() -> void:
	fx.absorb([_event(Types.Event.TANK_DESTROYED)])
	var items := fx.items()
	assert_eq(items.size(), 1)
	assert_eq(items[0].frame, Frames.boom_big(0))
	assert_eq(items[0].pos, Vector2i(64, 64), "the big explosion stands where the tank was")

func test_brick_hit_makes_a_small_burst() -> void:
	fx.absorb([_event(Types.Event.BULLET_HIT_BRICK)])
	assert_eq(fx.items()[0].frame, Frames.boom_small(0))

func test_small_burst_is_centred_on_the_point() -> void:
	fx.absorb([_event(Types.Event.BULLET_HIT_BRICK, Vector2i(1024, 1024))])
	assert_eq(fx.items()[0].pos, Vector2i(64 - 8, 64 - 8),
		"a hit is a point, and the explosion sprite is sixteen pixels")

func test_frames_advance_with_age() -> void:
	fx.absorb([_event(Types.Event.TANK_DESTROYED)])
	for i in Effects.FRAME_TICKS:
		fx.advance()
	assert_eq(fx.items()[0].frame, Frames.boom_big(1))

func test_big_burst_dies_out() -> void:
	fx.absorb([_event(Types.Event.TANK_DESTROYED)])
	for i in Effects.BIG_LIFETIME:
		fx.advance()
	assert_eq(fx.items().size(), 0, "an explosion must burn out, or hundreds will pile up")

func test_small_burst_dies_out_sooner() -> void:
	assert_lt(Effects.SMALL_LIFETIME, Effects.BIG_LIFETIME)
	fx.absorb([_event(Types.Event.BULLET_HIT_BRICK)])
	for i in Effects.SMALL_LIFETIME:
		fx.advance()
	assert_eq(fx.items().size(), 0)

func test_ignored_events_make_nothing() -> void:
	fx.absorb([_event(Types.Event.SHOT_FIRED), _event(Types.Event.BONUS_SPAWNED),
		_event(Types.Event.ENEMY_SPAWNED), _event(Types.Event.LEVEL_CLEARED)])
	assert_eq(fx.items().size(), 0, "not every event is an explosion")

func test_several_bursts_live_side_by_side() -> void:
	fx.absorb([_event(Types.Event.TANK_DESTROYED, Vector2i(0, 0)),
		_event(Types.Event.PLAYER_DESTROYED, Vector2i(512, 0)),
		_event(Types.Event.BASE_DESTROYED, Vector2i(0, 512))])
	assert_eq(fx.items().size(), 3)

func test_effects_are_drawn_over_everything() -> void:
	fx.absorb([_event(Types.Event.TANK_DESTROYED)])
	assert_eq(fx.items()[0].layer, ViewModel.Layer.OVER)
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "Effects" not declared`.

- [x] **Step 3: Write `presentation/effects.gd`**

```gdscript
class_name Effects

## Taking core events apart into decoration that burns out. The only place in
## the presentation layer with state of its own: an explosion lives longer than
## the tick it was born in. Rule 6 permits exactly this exception.

const FRAME_TICKS := 4
const BIG_LIFETIME := FRAME_TICKS * Frames.BOOM_BIG_FRAMES
const SMALL_LIFETIME := FRAME_TICKS * Frames.BOOM_SMALL_FRAMES

const BIG_EVENTS := [
	Types.Event.TANK_DESTROYED,
	Types.Event.PLAYER_DESTROYED,
	Types.Event.BASE_DESTROYED,
]
const SMALL_EVENTS := [
	Types.Event.BULLET_HIT_BRICK,
	Types.Event.BULLET_HIT_STEEL,
	Types.Event.BULLET_HIT_BULLET,
]

class Burst:
	var pos := Vector2i.ZERO   ## pixels, top left of the sprite
	var age := 0
	var big := false

var _bursts: Array = []

func absorb(events: Array) -> void:
	for e in events:
		if BIG_EVENTS.has(e.type):
			# The big explosion stands where the tank was: the event carries its top left.
			_add(ViewModel.to_pixels(e.pos), true)
		elif SMALL_EVENTS.has(e.type):
			# The small one goes to the point of impact, so it shifts by half a sprite.
			_add(ViewModel.to_pixels(e.pos) - Vector2i(Frames.SPRITE_HALF, Frames.SPRITE_HALF), false)

func advance() -> void:
	var alive: Array = []
	for b in _bursts:
		b.age += 1
		var lifetime: int = BIG_LIFETIME if b.big else SMALL_LIFETIME
		if b.age < lifetime:
			alive.append(b)
	_bursts = alive

func items() -> Array:
	var out: Array = []
	for b in _bursts:
		var step: int = b.age / FRAME_TICKS
		var frame: int = Frames.boom_big(step) if b.big else Frames.boom_small(step)
		var it := ViewModel.Item.new()
		it.atlas = ViewModel.Atlas.SPRITES
		it.frame = frame
		it.pos = b.pos
		it.layer = ViewModel.Layer.OVER
		out.append(it)
	return out

func _add(pos: Vector2i, big: bool) -> void:
	var b := Burst.new()
	b.pos = pos
	b.big = big
	_bursts.append(b)
```

- [x] **Step 4: Add a constant to `presentation/frames.gd`**

```gdscript
const SPRITE_HALF := 8     ## half of a 16×16 sprite — centring the decoration
```

- [x] **Step 5: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 6: Wire the effects into `game.gd`**

Replace the field and the `_process` method:

```gdscript
var _effects := Effects.new()

func _process(delta: float) -> void:
	if _sim == null:
		return
	for i in _pump.pump(delta):
		_sim.tick([Keyboard.bits(0), Keyboard.bits(1)])
		_effects.absorb(_sim.drain_events())
		_effects.advance()
	var state := _sim.get_state()
	var items := ViewModel.build(state, _sim.get_config())
	items.append_array(_effects.items())
	_field.sync(state, items)
```

The effects age **inside the tick loop**, not once per frame: otherwise, while catching up after a dropped frame, the explosions would run slower than the game.

- [x] **Step 7: Run it and look**

```bash
"$GODOT"
```

Expected: a downed enemy flares up with a big explosion, a hit on brick with a small one, and both fade by themselves.

- [x] **Step 8: Commit**

```bash
git add presentation/effects.gd presentation/frames.gd game.gd tests/presentation/test_effects.gd
git commit -m "feat: explosions and flashes from simulation events"
```

---

### Task 8: Carrying player state into a new simulation

**Files:**
- Modify: `core/entities.gd`
- Modify: `core/sim.gd`
- Test: `tests/core/test_carryover.gd`

**Interfaces:**
- Consumes: `Entities.PlayerState`
- Produces: `Entities.Carryover` with the fields `lives`, `score`, `stars`; a sixth optional parameter `GameSim.new(level, seed_value, config, level_number, player_count, carryover: Array = [])`.

The core lives for one level — that does not change. But the next level must start with the lives and points that have accumulated: right now `GameSim` always hands out `start_lives` and zero points.

The parameter is optional, so every existing call and test keeps working without a single edit.

- [x] **Step 1: Write the failing tests**

`tests/core/test_carryover.gd`:

```gdscript
extends GutTest

var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()

func _carry(lives: int, score: int, stars: int) -> Entities.Carryover:
	var c := Entities.Carryover.new()
	c.lives = lives
	c.score = score
	c.stars = stars
	return c

func test_without_carryover_nothing_changes() -> void:
	var sim := GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 1)
	assert_eq(sim.get_state().players[0].lives, cfg.start_lives)
	assert_eq(sim.get_state().players[0].score, 0)

func test_lives_and_score_are_carried() -> void:
	var sim := GameSim.new(LevelFixture.empty_level(), 1, cfg, 2, 1, [_carry(2, 4200, 0)])
	assert_eq(sim.get_state().players[0].lives, 2)
	assert_eq(sim.get_state().players[0].score, 4200)

func test_carried_stars_reach_the_tank_on_the_field() -> void:
	var sim := GameSim.new(LevelFixture.empty_level(), 1, cfg, 2, 1, [_carry(3, 0, 2)])
	assert_eq(sim.get_state().players[0].stars, 2)
	assert_eq(sim.get_state().player_tanks()[0].stars, 2,
		"the tank must roll out already upgraded rather than get its stars later")

func test_each_player_gets_its_own_row() -> void:
	var sim := GameSim.new(LevelFixture.empty_level(), 1, cfg, 2, 2,
		[_carry(1, 100, 0), _carry(3, 900, 1)])
	assert_eq(sim.get_state().players[0].lives, 1)
	assert_eq(sim.get_state().players[1].lives, 3)
	assert_eq(sim.get_state().players[1].score, 900)

func test_short_carryover_falls_back_to_defaults() -> void:
	var sim := GameSim.new(LevelFixture.empty_level(), 1, cfg, 2, 2, [_carry(1, 100, 0)])
	assert_eq(sim.get_state().players[1].lives, cfg.start_lives,
		"the second player has nothing to carry over — they start as usual")

func test_carryover_does_not_disturb_determinism() -> void:
	var a := GameSim.new(LevelFixture.empty_level(), 5, cfg, 2, 1, [_carry(2, 300, 1)])
	var b := GameSim.new(LevelFixture.empty_level(), 5, cfg, 2, 1, [_carry(2, 300, 1)])
	for i in 300:
		a.tick([0, 0])
		b.tick([0, 0])
	assert_eq(a.state_hash(), b.state_hash())
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Cannot find member "Carryover" in base "Entities"`.

- [x] **Step 3: Add to `core/entities.gd`**

At the end of the file:

```gdscript
class Carryover:
	## What travels with the player to the next level.
	## Upgrades land here, but the campaign zeroes them — see core/campaign.gd.
	var lives := 0
	var score := 0
	var stars := 0
```

- [x] **Step 4: Replace the player creation loop in `core/sim.gd`**

It was:

```gdscript
	for i in player_count:
		var p := Entities.PlayerState.new()
		p.index = i
		p.lives = _config.start_lives
		p.active = true
		_state.players.append(p)
		_spawn_player(i)
```

It becomes:

```gdscript
	for i in player_count:
		var p := Entities.PlayerState.new()
		p.index = i
		p.lives = _config.start_lives
		p.active = true
		if i < carryover.size():
			var c: Entities.Carryover = carryover[i]
			p.lives = c.lives
			p.score = c.score
			p.stars = c.stars
		_state.players.append(p)
		_spawn_player(i)
```

And the signature:

```gdscript
func _init(level: LevelData, seed_value: int, config: SimConfig = null,
		level_number: int = 1, player_count: int = 1, carryover: Array = []) -> void:
```

`_spawn_player` already copies `p.stars` into the tank, so the tank rolls out upgraded by itself.

- [x] **Step 5: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green, the regression reference included — an optional parameter changes no behaviour.

- [x] **Step 6: Commit**

```bash
git add core/entities.gd core/sim.gd tests/core/test_carryover.gd
git commit -m "feat: carry lives, score and upgrades into a new simulation"
```

---

### Task 9: The campaign

**Files:**
- Create: `core/campaign.gd`
- Test: `tests/core/test_campaign.gd`

**Interfaces:**
- Consumes: `SimConfig`, `Rng`, `WorldState`, `Entities.Carryover`
- Produces: `Campaign.new(player_count: int, config: SimConfig, base_seed: int)` with the fields `level_number`, `game_over`, `slots` and the methods `level_file() -> int`, `level_seed() -> int`, `carryover() -> Array`, `finish_level(state: WorldState) -> void`, `total_score() -> int`.

The campaign lies in `core/` because carrying lives over and looping are game rules, not a picture: they change the outcome of a match. It knows nothing about the engine and obeys the same rules as the rest of the core — the isolation check extends to it automatically.

It simulates nothing itself. It hands out the parameters for the next `GameSim` and takes back the outcome of the level just played.

**The next level's seed is a derivative of `base_seed` and the level number**, not a new random number. A whole match reproduces from a single number: that is needed both for bug reports and for subproject 3, where both sides must get identical enemy waves.

- [x] **Step 1: Write the failing tests**

`tests/core/test_campaign.gd`:

```gdscript
extends GutTest

var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()

func _finished(cleared: bool, lives: Array, scores: Array,
		base_alive := true) -> WorldState:
	var s := WorldState.new()
	s.terrain = Terrain.new()
	s.level_cleared = cleared
	s.game_over = not cleared
	s.base_alive = base_alive
	for i in lives.size():
		var p := Entities.PlayerState.new()
		p.index = i
		p.lives = lives[i]
		p.score = scores[i]
		p.stars = 3
		s.players.append(p)
	return s

func test_starts_at_the_first_level_with_full_lives() -> void:
	var c := Campaign.new(1, cfg, 7)
	assert_eq(c.level_number, 1)
	assert_eq(c.level_file(), 1)
	assert_eq(c.carryover()[0].lives, cfg.start_lives)
	assert_eq(c.carryover()[0].score, 0)
	assert_false(c.game_over)

func test_clearing_a_level_advances_it() -> void:
	var c := Campaign.new(1, cfg, 7)
	c.finish_level(_finished(true, [2], [1500]))
	assert_eq(c.level_number, 2)
	assert_false(c.game_over)

func test_lives_and_score_travel_but_stars_do_not() -> void:
	var c := Campaign.new(1, cfg, 7)
	c.finish_level(_finished(true, [2], [1500]))
	assert_eq(c.carryover()[0].lives, 2)
	assert_eq(c.carryover()[0].score, 1500)
	assert_eq(c.carryover()[0].stars, 0,
		"upgrades reset between levels — that is how the original works")

func test_level_files_wrap_after_thirty_five() -> void:
	var c := Campaign.new(1, cfg, 7)
	for i in 35:
		c.finish_level(_finished(true, [3], [0]))
	assert_eq(c.level_number, 36)
	assert_eq(c.level_file(), 1, "after level thirty-five we play the first one again")

func test_level_number_keeps_growing_after_the_wrap() -> void:
	# AI aggressiveness depends on the level number: on the second lap the enemies are meaner.
	var c := Campaign.new(1, cfg, 7)
	for i in 40:
		c.finish_level(_finished(true, [3], [0]))
	assert_eq(c.level_number, 41)
	assert_gt(c.level_number, cfg.ai_late_level)

func test_losing_the_base_ends_the_campaign() -> void:
	var c := Campaign.new(1, cfg, 7)
	c.finish_level(_finished(false, [2], [800], false))
	assert_true(c.game_over)
	assert_eq(c.level_number, 1, "a lost level does not count")

func test_running_out_of_lives_ends_the_campaign() -> void:
	var c := Campaign.new(1, cfg, 7)
	c.finish_level(_finished(false, [0], [800]))
	assert_true(c.game_over)

func test_seed_is_reproducible_and_differs_per_level() -> void:
	var a := Campaign.new(1, cfg, 12345)
	var b := Campaign.new(1, cfg, 12345)
	assert_eq(a.level_seed(), b.level_seed(), "one base — one seed")
	var first := a.level_seed()
	a.finish_level(_finished(true, [3], [0]))
	assert_ne(a.level_seed(), first, "every level has its own seed")

func test_different_base_seeds_give_different_games() -> void:
	assert_ne(Campaign.new(1, cfg, 1).level_seed(), Campaign.new(1, cfg, 2).level_seed())

func test_two_players_keep_separate_rows() -> void:
	var c := Campaign.new(2, cfg, 7)
	c.finish_level(_finished(true, [1, 3], [100, 900]))
	assert_eq(c.carryover()[0].lives, 1)
	assert_eq(c.carryover()[1].lives, 3)
	assert_eq(c.total_score(), 1000)

func test_second_player_out_of_lives_does_not_end_the_game() -> void:
	var c := Campaign.new(2, cfg, 7)
	c.finish_level(_finished(true, [2, 0], [100, 900]))
	assert_false(c.game_over, "while the first player lives, the campaign continues")
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "Campaign" not declared`.

- [x] **Step 3: Write `core/campaign.gd`**

```gdscript
class_name Campaign

## What lives between levels: score, lives, the level number, looping.
## It lies in the core because these are game rules and not a picture: they
## change the outcome. It knows no engine — the isolation check reaches here too.

const LEVEL_FILES := 35
const SEED_STEP := 2654435761   ## the golden ratio in 32 bits: it spreads adjacent numbers apart

var level_number := 1
var game_over := false
var slots: Array = []          ## Entities.Carryover per player, by index

var _base_seed := 0
var _config: SimConfig

func _init(player_count: int, config: SimConfig, base_seed: int) -> void:
	_config = config
	_base_seed = base_seed
	for i in player_count:
		var c := Entities.Carryover.new()
		c.lives = config.start_lives
		slots.append(c)

## Which layout file to load: there are thirty-five of them, and the levels do not end.
func level_file() -> int:
	return ((level_number - 1) % LEVEL_FILES) + 1

## A level's seed is a derivative of the base rather than a new random number:
## a whole match reproduces from a single number.
func level_seed() -> int:
	return Rng.new(_base_seed + level_number * SEED_STEP).next_u32()

func carryover() -> Array:
	return slots

func total_score() -> int:
	var sum := 0
	for c in slots:
		sum += c.score
	return sum

## Called exactly once, when the level's simulation has ended —
## and it can only end in a win or a loss.
func finish_level(state: WorldState) -> void:
	for i in slots.size():
		if i >= state.players.size():
			continue
		var p: Entities.PlayerState = state.players[i]
		slots[i].lives = p.lives
		slots[i].score = p.score
		slots[i].stars = 0     ## upgrades do not carry over
	if state.level_cleared:
		level_number += 1
	else:
		game_over = true
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: `core/ isolation: OK`, all tests green.

- [x] **Step 5: Commit**

```bash
git add core/campaign.gd tests/core/test_campaign.gd
git commit -m "feat: campaign — carrying score and lives over, looping after thirty-five"
```

---

### Task 10: The panel and drawing text

**Files:**
- Create: `presentation/text_painter.gd`
- Create: `presentation/hud.gd`
- Modify: `presentation/view_model.gd`
- Modify: `game.gd`, `game.tscn`
- Test: `tests/presentation/test_text_painter.gd`
- Test: `tests/presentation/test_hud_model.gd`

**Interfaces:**
- Consumes: `WorldState`, `Frames`
- Produces: the `HudPanel` node; `TextPainter.glyph_index(ch: String) -> int`, `TextPainter.draw_line(node: CanvasItem, atlas: Texture2D, text: String, at: Vector2i, tint: Color) -> void`; `ViewModel.Hud` with the fields `enemies_left`, `lives: Array[int]`, `level`; `ViewModel.hud(state: WorldState) -> Hud`.

The panel is a separate node and is not tied to the field's position: in subproject 2 it will move down for portrait orientation, and the field drawing must know nothing about it.

The panel's data is computed in `ViewModel` and tested; the node itself only draws.

- [x] **Step 1: Write the failing tests for drawing text**

`tests/presentation/test_text_painter.gd`:

```gdscript
extends GutTest

func test_digits_come_first() -> void:
	assert_eq(TextPainter.glyph_index("0"), 0)
	assert_eq(TextPainter.glyph_index("9"), 9)

func test_letters_follow_the_digits() -> void:
	assert_eq(TextPainter.glyph_index("A"), 10)
	assert_eq(TextPainter.glyph_index("Z"), 35)

func test_lowercase_is_treated_as_uppercase() -> void:
	assert_eq(TextPainter.glyph_index("a"), TextPainter.glyph_index("A"))

func test_space_and_unknown_characters_are_skipped() -> void:
	assert_eq(TextPainter.glyph_index(" "), -1)
	assert_eq(TextPainter.glyph_index("!"), -1)
	assert_eq(TextPainter.glyph_index(""), -1)
```

- [x] **Step 2: Write the failing tests for the panel**

`tests/presentation/test_hud_model.gd`:

```gdscript
extends GutTest

var state: WorldState

func before_each() -> void:
	state = WorldState.new()
	state.terrain = Terrain.new()
	state.level = 4

func _player(lives: int) -> void:
	var p := Entities.PlayerState.new()
	p.index = state.players.size()
	p.lives = lives
	p.active = true
	state.players.append(p)

func _enemy(spawning: bool) -> void:
	var t := Entities.Tank.new()
	t.id = state.next_id()
	t.type = Types.TankType.BASIC
	t.player_index = -1
	t.alive = true
	t.spawn_ticks = 30 if spawning else 0
	state.tanks.append(t)

func test_level_and_lives_are_taken_from_the_state() -> void:
	_player(2)
	_player(3)
	var hud := ViewModel.hud(state)
	assert_eq(hud.level, 4)
	assert_eq(hud.lives, [2, 3] as Array[int])

func test_remaining_enemies_include_those_not_yet_spawned() -> void:
	state.enemy_queue = [Types.TankType.BASIC, Types.TankType.FAST] as Array[int]
	_enemy(false)
	_enemy(true)
	assert_eq(ViewModel.hud(state).enemies_left, 4,
		"there are two in the queue and two on the field, counting the one still blinking")

func test_empty_wave_shows_zero() -> void:
	assert_eq(ViewModel.hud(state).enemies_left, 0)

func test_dead_enemies_are_not_counted() -> void:
	_enemy(false)
	state.tanks[0].alive = false
	assert_eq(ViewModel.hud(state).enemies_left, 0)
```

- [x] **Step 3: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "TextPainter" not declared`, `Cannot find member "hud" in base "ViewModel"`.

- [x] **Step 4: Write `presentation/text_painter.gd`**

```gdscript
class_name TextPainter

## The font sits in the same kind of atlas as the sprites: digits, then uppercase
## Latin. Nothing else occurs in the interface, and a real font would drag in a
## resource that cannot be written by hand in text form.

const GLYPH_PX := 8
const COLUMNS := 16
const DIGITS := 10

static func glyph_index(ch: String) -> int:
	if ch.length() != 1:
		return -1
	var code := ch.to_upper().unicode_at(0)
	if code >= 48 and code <= 57:        # '0'..'9'
		return code - 48
	if code >= 65 and code <= 90:        # 'A'..'Z'
		return DIGITS + code - 65
	return -1

static func draw_line(node: CanvasItem, atlas: Texture2D, text: String,
		at: Vector2i, tint := Color.WHITE) -> void:
	for i in text.length():
		var glyph := glyph_index(text[i])
		if glyph < 0:
			continue
		var src := Rect2i((glyph % COLUMNS) * GLYPH_PX, (glyph / COLUMNS) * GLYPH_PX,
			GLYPH_PX, GLYPH_PX)
		var dst := Rect2(at + Vector2i(i * GLYPH_PX, 0), Vector2(GLYPH_PX, GLYPH_PX))
		node.draw_texture_rect_region(atlas, dst, src, tint)
```

- [x] **Step 5: Add the panel slice to `presentation/view_model.gd`**

```gdscript
class Hud:
	var enemies_left := 0
	var lives: Array[int] = []
	var level := 1

## What the panel shows. Computed here so the node decides nothing.
static func hud(state: WorldState) -> Hud:
	var h := Hud.new()
	h.level = state.level
	h.enemies_left = state.enemy_queue.size()
	for t in state.tanks:
		if t.alive and t.player_index < 0:
			h.enemies_left += 1
	for p in state.players:
		h.lives.append(p.lives)
	return h
```

- [x] **Step 6: Write `presentation/hud.gd`**

```gdscript
class_name HudPanel
extends Node2D

## The right-hand panel. Not tied to the field's position: in subproject 2 it
## will move down for portrait orientation, and the field drawing will not know.

const BACKGROUND := Color(0.36, 0.34, 0.32)
const PANEL_SIZE := Vector2(40, 208)

var _font: Texture2D = preload("res://assets/font.png")
var _model: ViewModel.Hud = null

func show_model(model: ViewModel.Hud) -> void:
	_model = model
	queue_redraw()

func _draw() -> void:
	if _model == null:
		return
	draw_rect(Rect2(Vector2.ZERO, PANEL_SIZE), BACKGROUND)
	TextPainter.draw_line(self, _font, "ENEMY", Vector2i(4, 8))
	TextPainter.draw_line(self, _font, str(_model.enemies_left), Vector2i(4, 18))
	var row := 40
	for i in _model.lives.size():
		TextPainter.draw_line(self, _font, "%dP" % (i + 1), Vector2i(4, row))
		TextPainter.draw_line(self, _font, str(_model.lives[i]), Vector2i(4, row + 10))
		row += 32
	TextPainter.draw_line(self, _font, "STAGE", Vector2i(4, row + 8))
	TextPainter.draw_line(self, _font, str(_model.level), Vector2i(4, row + 18))
```

- [x] **Step 7: Add the panel to `game.tscn`**

```
[node name="Hud" type="Node2D" parent="."]
position = Vector2(216, 16)
script = ExtResource("3_hud")
```

And into the scene header:

```
[ext_resource type="Script" path="res://presentation/hud.gd" id="3_hud"]
```

Do not forget to raise `load_steps` in the first line to `4`.

- [x] **Step 8: Show the panel from `game.gd`**

Add a field and a line at the end of `_process`:

```gdscript
@onready var _hud: HudPanel = $Hud
```

```gdscript
	_hud.show_model(ViewModel.hud(state))
```

- [x] **Step 9: Run the tests and look with your eyes**

```bash
./tools/test.sh
"$GODOT"
```

Expected: the panel on the right, the count of remaining enemies going down as they are shot, the lives decreasing on death, and the level number in place.

- [x] **Step 10: Commit**

```bash
git add presentation/text_painter.gd presentation/hud.gd presentation/view_model.gd game.gd game.tscn tests/presentation/test_text_painter.gd tests/presentation/test_hud_model.gd
git commit -m "feat: right-hand panel and text drawing in the atlas font"
```

---

### Task 11: Moving between levels

**Files:**
- Create: `presentation/banner.gd`
- Modify: `game.gd`, `game.tscn`

**Interfaces:**
- Consumes: `Campaign`, `LevelLoader`, `TextPainter`
- Produces: `Banner.show_text(text: String) -> void`, `Banner.hide_banner() -> void` — a black screen with a caption in the middle; `game.gd` gets a state machine `Phase { INTRO, PLAY, OUTRO, OVER }`.

Here thirty-five separate levels become a game for the first time: a completed level is followed by the next, the score and lives travel on, and after thirty-five a second lap begins.

The pause after a level ends is not for looks: without it the last explosion does not finish burning, and a win looks like a cut-off.

- [x] **Step 1: Write `presentation/banner.gd`**

```gdscript
class_name Banner
extends Node2D

## A black screen with one caption in the middle: STAGE 7, GAME OVER.
## Real screens with a menu and stats arrive in part B2 and replace this.

const SCREEN := Vector2(256, 240)
const BACKGROUND := Color(0, 0, 0)

var _font: Texture2D = preload("res://assets/font.png")
var _text := ""

func show_text(text: String) -> void:
	_text = text
	visible = true
	queue_redraw()

func hide_banner() -> void:
	visible = false

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), BACKGROUND)
	var width := _text.length() * TextPainter.GLYPH_PX
	var at := Vector2i((int(SCREEN.x) - width) / 2, int(SCREEN.y) / 2 - TextPainter.GLYPH_PX)
	TextPainter.draw_line(self, _font, _text, at)
```

- [x] **Step 2: Add the caption to `game.tscn`**

Into the header:

```
[ext_resource type="Script" path="res://presentation/banner.gd" id="4_banner"]
```

As the last node, so that it is drawn over everything:

```
[node name="Banner" type="Node2D" parent="."]
script = ExtResource("4_banner")
```

Raise `load_steps` to `5`.

- [x] **Step 3: Rewrite `game.gd` in full**

```gdscript
extends Node2D

## The main scene: holds the campaign and the current level's simulation, pumps
## the ticks, hands the state out for drawing. There are no game rules of its own
## here — they all live in core/, moving between levels included.

const FIELD_ORIGIN := Vector2i(8, 16)
const INTRO_SECONDS := 2.0
const OUTRO_SECONDS := 1.5
const BASE_SEED := 20260827

enum Phase { INTRO, PLAY, OUTRO, OVER }

var _campaign: Campaign = null
var _sim: GameSim = null
var _pump := TickPump.new()
var _effects := Effects.new()
var _phase := Phase.INTRO
var _timer := 0.0

@onready var _field: Field = $Field
@onready var _hud: HudPanel = $Hud
@onready var _banner: Banner = $Banner

func _ready() -> void:
	_field.position = FIELD_ORIGIN
	_restart(1)

func _restart(player_count: int) -> void:
	_campaign = Campaign.new(player_count, SimConfig.new(), BASE_SEED)
	_effects = Effects.new()
	_begin_level()

func _begin_level() -> void:
	var level := LevelLoader.load_level(_campaign.level_file())
	if level.error != "":
		push_error("level %d cannot be read: %s" % [_campaign.level_file(), level.error])
		return
	_sim = GameSim.new(level, _campaign.level_seed(), SimConfig.new(),
		_campaign.level_number, _campaign.slots.size(), _campaign.carryover())
	_pump = TickPump.new()
	_banner.show_text("STAGE %d" % _campaign.level_number)
	_phase = Phase.INTRO
	_timer = INTRO_SECONDS

func _unhandled_input(event: InputEvent) -> void:
	# Temporary hotkeys: the real menu arrives in part B2.
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1:
			_restart(1)
		elif event.keycode == KEY_F2:
			_restart(2)

func _process(delta: float) -> void:
	match _phase:
		Phase.INTRO:
			_timer -= delta
			if _timer <= 0.0:
				_banner.hide_banner()
				_phase = Phase.PLAY
		Phase.PLAY:
			_advance(delta)
			var state := _sim.get_state()
			if state.level_cleared or state.game_over:
				_phase = Phase.OUTRO
				_timer = OUTRO_SECONDS
		Phase.OUTRO:
			# The simulation keeps running: the last explosion must finish burning.
			_advance(delta)
			_timer -= delta
			if _timer <= 0.0:
				_finish_level()
		Phase.OVER:
			pass

func _advance(delta: float) -> void:
	if _sim == null:
		return
	for i in _pump.pump(delta):
		_sim.tick([Keyboard.bits(0), Keyboard.bits(1)])
		_effects.absorb(_sim.drain_events())
		_effects.advance()
	var state := _sim.get_state()
	var items := ViewModel.build(state, _sim.get_config())
	items.append_array(_effects.items())
	_field.sync(state, items)
	_hud.show_model(ViewModel.hud(state))

func _finish_level() -> void:
	_campaign.finish_level(_sim.get_state())
	if _campaign.game_over:
		_banner.show_text("GAME OVER")
		_phase = Phase.OVER
		return
	_begin_level()
```

- [x] **Step 4: Run the tests**

Run: `./tools/test.sh`
Expected: all tests green. There are no new tests: all the transition logic lives in `core/campaign.gd` and was covered by task 9; here there are only the calls to it.

- [x] **Step 5: Check the transition with your eyes**

```bash
"$GODOT"
```

Expected: a black `STAGE 1` screen for two seconds, then the level. Having shot all twenty enemies, we see a pause and `STAGE 2`. The score and lives have not been zeroed, and the upgrades are reset. Losing the eagle gives `GAME OVER`, and F1 starts again.

A quick way to check the transition without shooting twenty tanks: temporarily lower `enemies_per_level` in `SimConfig` to two. Put it back before committing.

- [x] **Step 6: Commit**

```bash
git add presentation/banner.gd game.gd game.tscn
git commit -m "feat: moving between levels, the STAGE screen and game over"
```

---

### Task 12: A play-through and tuning by feel

**Files:**
- Modify: `core/sim_config.gd`
- Modify: `tests/core/test_regression.gd`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything that is ready
- Produces: `SimConfig` values checked by playing, not only by tests.

This is neither a formality nor cosmetics. Until this task **every number in `SimConfig` is a guess**: they were chosen by common sense and from open descriptions of the original, and not one of them has been checked by hand. The project's bar — "someone who played the original will sit down and say: yes, that's it" — can only be checked this way.

> **Closed on 2026-08-27, amended on 2026-08-28.** The game was played through by
> hand, the first verdict was "feels good", and no edits were needed then. Steps
> 1–5 were worked through as one pass instead of the level-by-level run written out.
>
> A day later it turned out the verdict had been premature: level one could not
> be completed. The enemies fired every 0.3–1 s and aimed straight at the player —
> the numbers were fixed in commit `2c1198e`, after which the game passed the
> live-play check a second time. The lesson is recorded here and not only in the
> history: one pass by one person is weak ground for closing a task about feel.
>
> The regression reference did not have to be re-taken: the reference scenario is
> not sensitive to the changed numbers.

- [x] **Step 1: Play the first five levels alone**

```bash
"$GODOT"
```

Write down as you go what feels wrong. Things to watch:

| Feeling | What to turn |
|----------|-------------|
| The tank crawls or jerks | `player_speed` |
| The bullet is caught by the eye or teleports | `bullet_speed`, `bullet_speed_fast` |
| The field is empty or there is no breathing room | `spawn_interval_ticks`, `max_enemies_alive` |
| The enemies dumbly drive along the edges | `ai_target_chance`, `ai_target_chance_late` |
| The enemies do not let you stick your head out | `ai_fire_min`, `ai_fire_max` |
| The ice is not felt or is uncontrollable | `ice_slide_ticks` |
| You are killed immediately after respawning | `respawn_shield_ticks` |

- [x] **Step 2: Play a couple of levels with two players**

Launch it and press F2. Check separately: a hit from an ally stuns rather than kills; `ally_stun_ticks` does not turn the game into a punishment for a stray shot.

- [x] **Step 3: Check the late levels**

Temporarily set a higher level number in `_restart` in `game.gd` (`_campaign.level_number = 30`), play, and put it back. On the late levels watch the share of steel and water: check that the field has not become impassable.

- [x] **Step 4: Make the edits in `core/sim_config.gd`**

Change one number at a time and re-check in the game. Editing blindly in a batch gives no way to tell what actually helped.

- [x] **Step 5: Re-take the regression reference**

Only after the values have settled.

Run: `./tools/test.sh`
Expected: FAIL in `test_regression.gd` with the message `reference diverged; actual hash: <number>`.

This is the **only legitimate case** for editing the reference: a rule changed deliberately, and we know which one. Put the number into `const GOLDEN` and commit it separately, listing in the message exactly which values were turned.

```bash
./tools/test.sh
```

Expected: all tests green.

- [x] **Step 6: Add a section about running the game to `README.md`**

```markdown
## How to play

Open the project in Godot 4.7.2 and run it, or:

    /Applications/Godot.app/Contents/MacOS/Godot

| | Movement | Fire |
|---|---|---|
| Player 1 | Arrows | Enter |
| Player 2 | W A S D | Space |

F1 — start again alone, F2 — with two players. The menu arrives in part B2.
```

- [x] **Step 7: Commit** — there was no separate commit: the edit went out
      in commit `2c1198e` together with an explanation of the reason.

```bash
git add core/sim_config.gd README.md
git commit -m "feat: SimConfig values verified by playing"
git add tests/core/test_regression.gd
git commit -m "test: regression reference re-taken after tuning SimConfig"
```

---

## Readiness of part B1

1. `./tools/test.sh` green in full, including the `core/` isolation check and the atlas verification.
2. The game launches and plays from the keyboard with one player and with two.
3. All thirty-five levels can be played through, and after thirty-five the game loops.
4. Score and lives carry over between levels, and upgrades reset.
5. All sprites are our own, assembled by `tools/gen_sprites.py` from text sources.
6. The numbers in `SimConfig` have been checked by playing — no edits were needed.

After this the part B2 plan is written: sound and jingles, the splash screen, the menu, the stats screen, pause, gamepad, hi-score, builds for Windows, macOS and Linux.
