# BASE 13: the simulation core — implementation plan (subproject 1, part A)

**Goal:** A deterministic core for BASE 13 (a Battle City remake) — all the rules, state and events — fully covered by tests and working without graphics.

**Architecture:** All the game logic lives in `core/` as ordinary GDScript classes (`RefCounted`), with not a single node and no calls to the engine's subsystems. The simulation steps in fixed ticks of 1/60 of a second, taking five bits per player as input, and accumulates a list of events for the future presentation layer. All the arithmetic is integer and the randomness is our own seeded xorshift32, so two runs with identical input give a bit-identical result.

**Tech Stack:** Godot 4.7.2, GDScript, GUT 9.7.1 (headless test runs).

**Spec:** `docs/specs/2026-08-25-battle-city-core-design.md`

**Not in this plan** (part B, a separate plan): rendering, sound, asset generation, screens, HUD, touch input, platform builds. Two things that are easy to mistake for the core's job go there too:

- **Moving between levels and carrying score, lives and upgrades over.** The core lives for exactly one level: it raises the `level_cleared` flag, and who creates the next level's simulation and with what state is a matter of screens.
- **The tick accumulator** (how many times to call `tick()` per frame, the limit of five catch-up ticks). That is the presentation layer's duty; the core knows nothing about frames.

## Global Constraints

- Godot **4.7.2** (the 4.7.x branch). The path to the binary in the commands: `$GODOT`.
- Tests are GUT **9.7.1**, run headless only.
- **`core/` imports nothing from the project's other folders** and does not touch `Node`, `Input`, `Time`, `Engine`, `OS`, `FileAccess`, `ResourceLoader`, `preload`, `load`, `randi`, `randf`, `randomize`. Checked by a script on every test run.
- **There is not one `float` in `core/`.** All positions, speeds and timers are integers.
- The unit of length inside the core is **1/16 of a pixel**, written `u` in the code. A pixel = 16 u.
- Entities are always walked in array order. No dictionary iteration in tick logic.
- A commit after every task. Messages in English, in the form `feat: ...` / `test: ...` / `chore: ...`.

## File structure

| File | Responsibility |
|------|-----------------|
| `core/consts.gd` | Geometric constants: the size of the field, cell, tank, bullet |
| `core/types.gd` | Enums: direction, cell type, tank type, power-up type, event type |
| `core/sim_config.gd` | Every tunable number: speeds, timers, probabilities |
| `core/rng.gd` | Deterministic xorshift32 |
| `core/terrain.gd` | The 26×26 grid: reading, writing, passability, destruction |
| `core/level_data.gd` | Parsing the text level format and validating it |
| `core/entities.gd` | The tank, bullet and power-up structures |
| `core/world_state.gd` | World state, identifiers, counters, hash |
| `core/events.gd` | A simulation event and their accumulator |
| `core/movement.gd` | Grid movement, the snap, collisions |
| `core/combat.gd` | Bullet flight and resolving hits |
| `core/spawner.gd` | The enemy queue and their appearance |
| `core/ai.gd` | Enemy tank behaviour |
| `core/bonuses.gd` | Power-up appearance, pickup and effects |
| `core/sim.gd` | The entry point: the tick, the order of operations, the public interface |
| `platform/level_loader.gd` | Reading level files from disk (outside the core — it uses `FileAccess`) |
| `levels/01.lvl` … `35.lvl` | Level layouts |
| `tools/check_core_isolation.sh` | The `core/` isolation check |
| `tests/…` | GUT tests |

---

### Task 1: The project skeleton, tests and the isolation check

**Files:**
- Create: `project.godot`
- Create: `addons/gut/` (from the GUT release)
- Create: `tools/check_core_isolation.sh`
- Create: `tools/test.sh`
- Create: `core/consts.gd`
- Test: `tests/test_smoke.gd`

**Interfaces:**
- Consumes: nothing
- Produces: `Consts` with the constants `SUBPIXEL`, `TILE_PX`, `CELL_PX`, `GRID`, `FIELD_PX`, `FIELD`, `CELL`, `TANK`, `BULLET`, `TICKS_PER_SECOND`; the command `./tools/test.sh` runs all the tests.

- [x] **Step 1: Install Godot 4.7.2**

Download the macOS build from https://godotengine.org/download/archive/ (the 4.7.2 section) or:

```bash
brew install --cask godot
```

Check the version and note the path:

```bash
export GODOT=/Applications/Godot.app/Contents/MacOS/Godot
"$GODOT" --version
```

Expect a line starting with `4.7.2`. If `brew` installed a different version, download 4.7.2 from the archive by hand.

- [x] **Step 2: Create `project.godot`**

```ini
config_version=5

[application]
config/name="BASE 13"
config/features=PackedStringArray("4.7", "GL Compatibility")

[display]
window/size/viewport_width=256
window/size/viewport_height=240
window/stretch/mode="viewport"
window/stretch/scale_mode="integer"

[rendering]
renderer/rendering_method="gl_compatibility"
textures/canvas_textures/default_texture_filter=0
```

- [x] **Step 3: Install GUT 9.7.1**

```bash
git clone --depth 1 --branch v9.7.1 https://github.com/bitwes/Gut.git /tmp/gut-src
mkdir -p addons
cp -r /tmp/gut-src/addons/gut addons/gut
rm -rf /tmp/gut-src
ls addons/gut/gut_cmdln.gd
```

Expected: the file exists.

- [x] **Step 4: Write `tools/check_core_isolation.sh`**

```bash
#!/usr/bin/env bash
# Checks that core/ does not depend on the engine and does not use float.
set -uo pipefail

fail=0

engine=$(grep -rnE '(^|[^A-Za-z_])(Input|Time|Engine|OS|ResourceLoader|FileAccess|SceneTree|Node2D|Node)[.(]|(^|[^A-Za-z_])(randi|randf|randomize|preload|load)[[:space:]]*\(|^extends[[:space:]]+(Node|Resource)' core/ 2>/dev/null)
if [ -n "$engine" ]; then
  echo "ERROR: core/ touches the engine:"
  echo "$engine"
  fail=1
fi

floats=$(grep -rnE ':[[:space:]]*float\b|->[[:space:]]*float\b|(^|[^A-Za-z_])float[[:space:]]*\(' core/ 2>/dev/null)
if [ -n "$floats" ]; then
  echo "ERROR: float is used in core/:"
  echo "$floats"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "core/ isolation: OK"
fi
exit $fail
```

```bash
chmod +x tools/check_core_isolation.sh
```

- [x] **Step 5: Write `tools/test.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"

./tools/check_core_isolation.sh

"$GODOT" --headless --import >/dev/null 2>&1 || true
"$GODOT" --headless -s addons/gut/gut_cmdln.gd \
  -gdir=res://tests -ginclude_subdirs -gexit
```

```bash
chmod +x tools/test.sh
```

- [x] **Step 6: Write the failing test**

`tests/test_smoke.gd`:

```gdscript
extends GutTest

func test_field_geometry_is_consistent() -> void:
	assert_eq(Consts.GRID, 26, "the field is 26 cells per side")
	assert_eq(Consts.CELL_PX, 8, "a terrain cell is 8 pixels")
	assert_eq(Consts.FIELD_PX, 208, "the field is 208 pixels")
	assert_eq(Consts.FIELD, 3328, "the field is 3328 units")
	assert_eq(Consts.TANK, 256, "a tank is 16 pixels = 256 units")
	assert_eq(Consts.CELL, 128, "a cell is 8 pixels = 128 units")
```

- [x] **Step 7: Run the test and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Consts` is not defined (`Identifier "Consts" not declared`).

- [x] **Step 8: Write `core/consts.gd`**

```gdscript
class_name Consts

## Units in one pixel. All the core's arithmetic is in these units.
const SUBPIXEL := 16

const TILE_PX := 16   ## A field tile
const CELL_PX := 8    ## A terrain cell — half a tile
const GRID := 26      ## Cells per side of the field

const FIELD_PX := GRID * CELL_PX        ## 208
const FIELD := FIELD_PX * SUBPIXEL      ## 3328 u
const CELL := CELL_PX * SUBPIXEL        ## 128 u
const TILE := TILE_PX * SUBPIXEL        ## 256 u
const TANK := TILE_PX * SUBPIXEL        ## 256 u
const BULLET := 4 * SUBPIXEL            ## 64 u

const TICKS_PER_SECOND := 60
```

- [x] **Step 9: Run the test and make sure it passes**

Run: `./tools/test.sh`
Expected: `core/ isolation: OK`, then 1 passing.

- [x] **Step 10: Commit**

```bash
git add project.godot addons tools core tests .gitignore
git commit -m "chore: Godot 4.7 project skeleton, GUT and the core isolation check"
```

---

### Task 2: A deterministic random number generator

**Files:**
- Create: `core/rng.gd`
- Test: `tests/core/test_rng.gd`

**Interfaces:**
- Consumes: nothing
- Produces: `Rng.new(seed_value: int)` with the methods `next_u32() -> int`, `next_range(lo: int, hi: int) -> int` (the half-open interval `[lo, hi)`), `chance(percent: int) -> bool`, `pick(items: Array) -> Variant`, and the field `_state` for serialising into the hash.

- [x] **Step 1: Write the failing tests**

`tests/core/test_rng.gd`:

```gdscript
extends GutTest

func test_same_seed_gives_same_sequence() -> void:
	var a := Rng.new(12345)
	var b := Rng.new(12345)
	for i in 100:
		assert_eq(a.next_u32(), b.next_u32(), "step %d must match" % i)

func test_different_seeds_diverge() -> void:
	var a := Rng.new(1)
	var b := Rng.new(2)
	var same := 0
	for i in 50:
		if a.next_u32() == b.next_u32():
			same += 1
	assert_lt(same, 5, "different seeds must not give almost identical streams")

func test_next_u32_stays_in_32_bits() -> void:
	var r := Rng.new(999)
	for i in 1000:
		var v := r.next_u32()
		assert_between(v, 0, 0xFFFFFFFF, "value outside 32 bits")

func test_zero_seed_does_not_lock_up() -> void:
	var r := Rng.new(0)
	var first := r.next_u32()
	var second := r.next_u32()
	assert_ne(first, 0, "a zero state would lock the generator up")
	assert_ne(first, second, "the stream must not stand still")

func test_next_range_respects_bounds() -> void:
	var r := Rng.new(7)
	for i in 500:
		var v := r.next_range(3, 8)
		assert_between(v, 3, 7, "next_range is the half-open interval [3, 8)")

func test_next_range_covers_whole_interval() -> void:
	var r := Rng.new(7)
	var seen := {}
	for i in 500:
		seen[r.next_range(0, 4)] = true
	assert_eq(seen.size(), 4, "all four values must occur")

func test_chance_zero_and_hundred_are_absolute() -> void:
	var r := Rng.new(42)
	for i in 100:
		assert_false(r.chance(0), "chance(0) never fires")
		assert_true(r.chance(100), "chance(100) always fires")
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "Rng" not declared`.

- [x] **Step 3: Write `core/rng.gd`**

```gdscript
class_name Rng

## Deterministic xorshift32. The only source of randomness in the core:
## calls to randi()/randf() are forbidden because they break reproducibility.

const MASK := 0xFFFFFFFF
const FALLBACK_SEED := 0x9E3779B9

var _state: int

func _init(seed_value: int) -> void:
	_state = seed_value & MASK
	if _state == 0:
		# A zero state is a fixed point of xorshift; the stream would stop forever.
		_state = FALLBACK_SEED

func next_u32() -> int:
	var x := _state
	x = (x ^ (x << 13)) & MASK
	x = x ^ (x >> 17)
	x = (x ^ (x << 5)) & MASK
	_state = x
	return _state

func next_range(lo: int, hi: int) -> int:
	if hi <= lo:
		return lo
	return lo + (next_u32() % (hi - lo))

func chance(percent: int) -> bool:
	if percent <= 0:
		return false
	if percent >= 100:
		return true
	return next_range(0, 100) < percent

func pick(items: Array) -> Variant:
	if items.is_empty():
		return null
	return items[next_range(0, items.size())]

func get_state() -> int:
	return _state
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 5: Commit**

```bash
git add core/rng.gd tests/core/test_rng.gd
git commit -m "feat: deterministic xorshift32 random number generator"
```

---

### Task 3: Enums and the simulation config

**Files:**
- Create: `core/types.gd`
- Create: `core/sim_config.gd`
- Test: `tests/core/test_sim_config.gd`

**Interfaces:**
- Consumes: `Consts`
- Produces: `Types` with the enums `Dir`, `Cell`, `TankType`, `BonusType`, `Event` and the constant `Types.DIR_VEC`; `SimConfig.new()` with every tunable number and the methods `enemy_speed(type) -> int`, `enemy_score(type) -> int`, `enemy_health(type) -> int`.

- [x] **Step 1: Write the failing tests**

`tests/core/test_sim_config.gd`:

```gdscript
extends GutTest

func test_direction_vectors_are_unit_and_ordered() -> void:
	assert_eq(Types.DIR_VEC[Types.Dir.UP], Vector2i(0, -1))
	assert_eq(Types.DIR_VEC[Types.Dir.RIGHT], Vector2i(1, 0))
	assert_eq(Types.DIR_VEC[Types.Dir.DOWN], Vector2i(0, 1))
	assert_eq(Types.DIR_VEC[Types.Dir.LEFT], Vector2i(-1, 0))

func test_opposite_direction() -> void:
	assert_eq(Types.opposite(Types.Dir.UP), Types.Dir.DOWN)
	assert_eq(Types.opposite(Types.Dir.LEFT), Types.Dir.RIGHT)

func test_enemy_stats_match_spec() -> void:
	var c := SimConfig.new()
	assert_eq(c.enemy_speed(Types.TankType.BASIC), 8)
	assert_eq(c.enemy_speed(Types.TankType.FAST), 16)
	assert_eq(c.enemy_speed(Types.TankType.POWER), 8)
	assert_eq(c.enemy_speed(Types.TankType.ARMOR), 8)
	assert_eq(c.enemy_health(Types.TankType.ARMOR), 4)
	assert_eq(c.enemy_health(Types.TankType.BASIC), 1)
	assert_eq(c.enemy_score(Types.TankType.BASIC), 100)
	assert_eq(c.enemy_score(Types.TankType.FAST), 200)
	assert_eq(c.enemy_score(Types.TankType.POWER), 300)
	assert_eq(c.enemy_score(Types.TankType.ARMOR), 400)

func test_core_timings_match_spec() -> void:
	var c := SimConfig.new()
	assert_eq(c.player_speed, 12)
	assert_eq(c.bullet_speed, 32)
	assert_eq(c.bullet_speed_fast, 48)
	assert_eq(c.enemies_per_level, 20)
	assert_eq(c.max_enemies_alive, 4)
	assert_eq(c.spawn_blink_ticks, 60)
	assert_eq(c.spawn_interval_ticks, 180)
	assert_eq(c.shield_ticks, 600)
	assert_eq(c.respawn_shield_ticks, 180)
	assert_eq(c.freeze_ticks, 600)
	assert_eq(c.shovel_ticks, 1200)
	assert_eq(c.bonus_life_ticks, 900)
	assert_eq(c.ice_slide_ticks, 30)
	assert_eq(c.ally_stun_ticks, 60)
	assert_eq(c.bonus_score, 500)
	assert_eq(c.start_lives, 3)
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "Types" not declared`.

- [x] **Step 3: Write `core/types.gd`**

```gdscript
class_name Types

enum Dir { UP, RIGHT, DOWN, LEFT }

## The order matches Dir. The Y axis points down.
const DIR_VEC: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(-1, 0),
]

enum Cell { EMPTY, BRICK, STEEL, WATER, TREES, ICE }

enum TankType { PLAYER, BASIC, FAST, POWER, ARMOR }

enum BonusType { HELMET, CLOCK, SHOVEL, STAR, GRENADE, TANK }

enum Event {
	SHOT_FIRED,
	BULLET_HIT_BRICK,
	BULLET_HIT_STEEL,
	BULLET_HIT_BULLET,
	TANK_DESTROYED,
	PLAYER_DESTROYED,
	BASE_DESTROYED,
	BONUS_SPAWNED,
	BONUS_TAKEN,
	ENEMY_SPAWNED,
	LEVEL_CLEARED,
	GAME_OVER,
}

## Input bits. One int per player.
const IN_UP := 1
const IN_DOWN := 2
const IN_LEFT := 4
const IN_RIGHT := 8
const IN_FIRE := 16

static func opposite(dir: int) -> int:
	return (dir + 2) % 4

static func is_enemy(tank_type: int) -> bool:
	return tank_type != TankType.PLAYER
```

- [x] **Step 4: Write `core/sim_config.gd`**

```gdscript
class_name SimConfig

## Every tunable number is gathered here: the "recognizable, without obsession"
## bar means the final values are determined by feel while playing.

# Speeds, u per tick (1 pixel = 16 u)
var player_speed := 12
var bullet_speed := 32
var bullet_speed_fast := 48

# The enemy wave
var enemies_per_level := 20
var max_enemies_alive := 4
var spawn_blink_ticks := 60
var spawn_interval_ticks := 180

# Effect timers
var shield_ticks := 600          ## helmet
var respawn_shield_ticks := 180  ## the shield after respawning
var freeze_ticks := 600          ## clock
var shovel_ticks := 1200         ## shovel
var shovel_blink_ticks := 180    ## blinking before the shovel expires
var bonus_life_ticks := 900      ## how long a power-up lies on the field
var bonus_blink_ticks := 180
var ice_slide_ticks := 30
var ally_stun_ticks := 60

# The player
var start_lives := 3
var bonus_score := 500

# AI
var ai_dir_change_min := 30
var ai_dir_change_max := 120
var ai_fire_min := 20
var ai_fire_max := 60
var ai_target_chance := 25        ## probability of moving toward the target, %
var ai_target_chance_late := 40   ## the same from level ai_late_level on
var ai_base_target_chance := 50   ## the target is the base, otherwise a player, %
var ai_late_level := 20

func enemy_speed(tank_type: int) -> int:
	match tank_type:
		Types.TankType.FAST:
			return 16
		_:
			return 8

func enemy_health(tank_type: int) -> int:
	match tank_type:
		Types.TankType.ARMOR:
			return 4
		_:
			return 1

func enemy_score(tank_type: int) -> int:
	match tank_type:
		Types.TankType.BASIC:
			return 100
		Types.TankType.FAST:
			return 200
		Types.TankType.POWER:
			return 300
		Types.TankType.ARMOR:
			return 400
		_:
			return 0

func enemy_bullet_speed(tank_type: int) -> int:
	if tank_type == Types.TankType.POWER:
		return bullet_speed_fast
	return bullet_speed

func ai_target_chance_for_level(level: int) -> int:
	if level >= ai_late_level:
		return ai_target_chance_late
	return ai_target_chance
```

- [x] **Step 5: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 6: Commit**

```bash
git add core/types.gd core/sim_config.gd tests/core/test_sim_config.gd
git commit -m "feat: enums and the simulation config"
```

---

### Task 4: Terrain

**Files:**
- Create: `core/terrain.gd`
- Test: `tests/core/test_terrain.gd`

**Interfaces:**
- Consumes: `Consts`, `Types`
- Produces: `Terrain.new()` with the methods `get_cell(cx, cy) -> int`, `set_cell(cx, cy, value)`, `blocks_tank(cx, cy) -> bool`, `blocks_bullet(cx, cy) -> bool`, `rect_blocks_tank(pos: Vector2i, size: int) -> bool`, `destroy_cell(cx, cy, can_break_steel: bool) -> int`, `cell_at_unit(v: Vector2i) -> Vector2i`, `clone() -> Terrain`, `cells_checksum() -> int`.

The convention: **beyond the field's boundary the terrain counts as steel.** That way the boundaries are handled by the same code as the walls, with no separate checks in every place.

- [x] **Step 1: Write the failing tests**

`tests/core/test_terrain.gd`:

```gdscript
extends GutTest

var t: Terrain

func before_each() -> void:
	t = Terrain.new()

func test_starts_empty() -> void:
	for cy in Consts.GRID:
		for cx in Consts.GRID:
			assert_eq(t.get_cell(cx, cy), Types.Cell.EMPTY)

func test_set_and_get() -> void:
	t.set_cell(3, 4, Types.Cell.BRICK)
	assert_eq(t.get_cell(3, 4), Types.Cell.BRICK)
	assert_eq(t.get_cell(4, 3), Types.Cell.EMPTY, "neighbouring cells are untouched")

func test_out_of_bounds_reads_as_steel() -> void:
	assert_eq(t.get_cell(-1, 0), Types.Cell.STEEL)
	assert_eq(t.get_cell(0, -1), Types.Cell.STEEL)
	assert_eq(t.get_cell(Consts.GRID, 0), Types.Cell.STEEL)
	assert_true(t.blocks_tank(-1, 0), "beyond the boundary a tank does not pass")
	assert_true(t.blocks_bullet(-1, 0), "beyond the boundary a bullet stops")

func test_blocking_rules() -> void:
	t.set_cell(1, 1, Types.Cell.BRICK)
	t.set_cell(2, 1, Types.Cell.STEEL)
	t.set_cell(3, 1, Types.Cell.WATER)
	t.set_cell(4, 1, Types.Cell.TREES)
	t.set_cell(5, 1, Types.Cell.ICE)

	assert_true(t.blocks_tank(1, 1), "brick holds a tank")
	assert_true(t.blocks_tank(2, 1), "steel holds a tank")
	assert_true(t.blocks_tank(3, 1), "water holds a tank")
	assert_false(t.blocks_tank(4, 1), "a tank drives through forest")
	assert_false(t.blocks_tank(5, 1), "a tank drives over ice")

	assert_true(t.blocks_bullet(1, 1), "brick holds a bullet")
	assert_true(t.blocks_bullet(2, 1), "steel holds a bullet")
	assert_false(t.blocks_bullet(3, 1), "a bullet flies over water")
	assert_false(t.blocks_bullet(4, 1), "a bullet flies through forest")
	assert_false(t.blocks_bullet(5, 1), "a bullet flies over ice")

func test_cell_at_unit() -> void:
	assert_eq(t.cell_at_unit(Vector2i(0, 0)), Vector2i(0, 0))
	assert_eq(t.cell_at_unit(Vector2i(Consts.CELL - 1, 0)), Vector2i(0, 0))
	assert_eq(t.cell_at_unit(Vector2i(Consts.CELL, 0)), Vector2i(1, 0))

func test_rect_blocks_tank_covers_all_touched_cells() -> void:
	# A 256 u tank covers exactly two cells on each axis when aligned to the grid.
	t.set_cell(2, 0, Types.Cell.BRICK)
	assert_true(t.rect_blocks_tank(Vector2i(Consts.CELL, 0), Consts.TANK),
		"a tank on cells 1..2 touches the brick in cell 2")
	assert_false(t.rect_blocks_tank(Vector2i(0, 0), Consts.TANK),
		"a tank on cells 0..1 does not touch the brick")

func test_rect_outside_field_is_blocked() -> void:
	assert_true(t.rect_blocks_tank(Vector2i(-1, 0), Consts.TANK))
	assert_true(t.rect_blocks_tank(Vector2i(Consts.FIELD - Consts.TANK + 1, 0), Consts.TANK))
	assert_false(t.rect_blocks_tank(Vector2i(Consts.FIELD - Consts.TANK, 0), Consts.TANK),
		"flush against the right edge — still allowed")

func test_destroy_brick() -> void:
	t.set_cell(5, 5, Types.Cell.BRICK)
	assert_eq(t.destroy_cell(5, 5, false), Types.Cell.BRICK, "the destroyed type came back")
	assert_eq(t.get_cell(5, 5), Types.Cell.EMPTY)

func test_steel_needs_power() -> void:
	t.set_cell(5, 5, Types.Cell.STEEL)
	assert_eq(t.destroy_cell(5, 5, false), -1, "without the third star steel does not give")
	assert_eq(t.get_cell(5, 5), Types.Cell.STEEL)
	assert_eq(t.destroy_cell(5, 5, true), Types.Cell.STEEL)
	assert_eq(t.get_cell(5, 5), Types.Cell.EMPTY)

func test_water_and_trees_are_indestructible() -> void:
	t.set_cell(5, 5, Types.Cell.WATER)
	t.set_cell(6, 5, Types.Cell.TREES)
	assert_eq(t.destroy_cell(5, 5, true), -1)
	assert_eq(t.destroy_cell(6, 5, true), -1)

func test_clone_is_independent() -> void:
	t.set_cell(1, 1, Types.Cell.BRICK)
	var copy := t.clone()
	copy.set_cell(1, 1, Types.Cell.EMPTY)
	assert_eq(t.get_cell(1, 1), Types.Cell.BRICK, "the original must not change")

func test_checksum_reacts_to_change() -> void:
	var before := t.cells_checksum()
	t.set_cell(7, 7, Types.Cell.BRICK)
	assert_ne(before, t.cells_checksum())
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "Terrain" not declared`.

- [x] **Step 3: Write `core/terrain.gd`**

```gdscript
class_name Terrain

## A 26×26 grid of 8-pixel cells. It is fine (twice finer than a tile) because
## a bullet chews a quarter out of a brick rather than the whole block.

var _cells: PackedByteArray

func _init() -> void:
	_cells = PackedByteArray()
	_cells.resize(Consts.GRID * Consts.GRID)
	_cells.fill(Types.Cell.EMPTY)

static func in_bounds(cx: int, cy: int) -> bool:
	return cx >= 0 and cy >= 0 and cx < Consts.GRID and cy < Consts.GRID

func get_cell(cx: int, cy: int) -> int:
	# Beyond the field's boundary it is steel: boundaries are handled by the same code as walls.
	if not in_bounds(cx, cy):
		return Types.Cell.STEEL
	return _cells[cy * Consts.GRID + cx]

func set_cell(cx: int, cy: int, value: int) -> void:
	if not in_bounds(cx, cy):
		return
	_cells[cy * Consts.GRID + cx] = value

func blocks_tank(cx: int, cy: int) -> bool:
	var c := get_cell(cx, cy)
	return c == Types.Cell.BRICK or c == Types.Cell.STEEL or c == Types.Cell.WATER

func blocks_bullet(cx: int, cy: int) -> bool:
	var c := get_cell(cx, cy)
	return c == Types.Cell.BRICK or c == Types.Cell.STEEL

func cell_at_unit(v: Vector2i) -> Vector2i:
	return Vector2i(_div_floor(v.x, Consts.CELL), _div_floor(v.y, Consts.CELL))

func rect_blocks_tank(pos: Vector2i, size: int) -> bool:
	var c0 := cell_at_unit(pos)
	var c1 := cell_at_unit(pos + Vector2i(size - 1, size - 1))
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			if blocks_tank(cx, cy):
				return true
	return false

func destroy_cell(cx: int, cy: int, can_break_steel: bool) -> int:
	var c := get_cell(cx, cy)
	if c == Types.Cell.BRICK or (c == Types.Cell.STEEL and can_break_steel and in_bounds(cx, cy)):
		set_cell(cx, cy, Types.Cell.EMPTY)
		return c
	return -1

func clone() -> Terrain:
	var copy := Terrain.new()
	copy._cells = _cells.duplicate()
	return copy

func cells_checksum() -> int:
	var h := 2166136261
	for i in _cells.size():
		h = (h ^ _cells[i]) & 0xFFFFFFFF
		h = (h * 16777619) & 0xFFFFFFFF
	return h

## Floor division: GDScript's built-in integer division truncates toward zero,
## which would give the wrong cell for a negative coordinate.
static func _div_floor(a: int, b: int) -> int:
	if a >= 0:
		return a / b
	return -(((-a) + b - 1) / b)
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 5: Commit**

```bash
git add core/terrain.gd tests/core/test_terrain.gd
git commit -m "feat: terrain on a 26x26 grid with passability and destruction rules"
```

---

### Task 5: The field layout and the level format

**Files:**
- Modify: `core/consts.gd` (add the layout constants)
- Create: `core/level_data.gd`
- Test: `tests/core/test_level_data.gd`

**Interfaces:**
- Consumes: `Consts`, `Types`, `Terrain`
- Produces: `Consts.BASE_TILE`, `Consts.BASE_CELLS`, `Consts.BASE_WALL_CELLS`, `Consts.PLAYER_SPAWN_TILES`, `Consts.ENEMY_SPAWN_TILES`, `Consts.tile_to_unit(t: Vector2i) -> Vector2i`; `LevelData.parse(text: String) -> LevelData` with the fields `terrain: Terrain`, `enemy_queue: Array[int]`, `bonus_indices: Array[int]`, `error: String` (an empty string = the level is valid).

- [x] **Step 1: Add the layout constants to `core/consts.gd`**

Add at the end of the file:

```gdscript
## The field layout in tiles (13×13 tiles of 16 pixels).
const BASE_TILE := Vector2i(6, 12)
const PLAYER_SPAWN_TILES: Array[Vector2i] = [Vector2i(4, 12), Vector2i(8, 12)]
const ENEMY_SPAWN_TILES: Array[Vector2i] = [Vector2i(0, 0), Vector2i(6, 0), Vector2i(12, 0)]

## The cells occupied by the eagle (tile 6,12 is cells 12..13 × 24..25).
const BASE_CELLS: Array[Vector2i] = [
	Vector2i(12, 24), Vector2i(13, 24),
	Vector2i(12, 25), Vector2i(13, 25),
]

## The ring of brick around the eagle. The shovel turns it into steel and back.
const BASE_WALL_CELLS: Array[Vector2i] = [
	Vector2i(11, 23), Vector2i(12, 23), Vector2i(13, 23), Vector2i(14, 23),
	Vector2i(11, 24), Vector2i(14, 24),
	Vector2i(11, 25), Vector2i(14, 25),
]

static func tile_to_unit(t: Vector2i) -> Vector2i:
	return Vector2i(t.x * TILE, t.y * TILE)
```

- [x] **Step 2: Write the failing tests**

`tests/core/test_level_data.gd`:

```gdscript
extends GutTest

const ENEMIES_LINE := "enemies: BBBBBBBBBBBBBBFFFFPP"
const BONUS_LINE := "bonus: 3,10,17"

func _terrain_rows(fill: String = ".") -> String:
	var rows: Array[String] = []
	for y in Consts.GRID:
		rows.append(fill.repeat(Consts.GRID))
	return "\n".join(rows)

## Assembles a valid level text: an empty field plus the mandatory ring around the base.
func _valid_text() -> String:
	var grid: Array = []
	for y in Consts.GRID:
		grid.append(".".repeat(Consts.GRID).split(""))
	for c in Consts.BASE_WALL_CELLS:
		grid[c.y][c.x] = "#"
	var rows: Array[String] = []
	for y in Consts.GRID:
		rows.append("".join(grid[y]))
	return "%s\n%s\n---\n%s" % [ENEMIES_LINE, BONUS_LINE, "\n".join(rows)]

func test_parses_valid_level() -> void:
	var lvl := LevelData.parse(_valid_text())
	assert_eq(lvl.error, "", "a valid level must not produce an error")
	assert_eq(lvl.enemy_queue.size(), 20)
	assert_eq(lvl.enemy_queue[0], Types.TankType.BASIC)
	assert_eq(lvl.enemy_queue[14], Types.TankType.FAST)
	assert_eq(lvl.enemy_queue[18], Types.TankType.POWER)
	assert_eq(lvl.bonus_indices, [3, 10, 17] as Array[int])

func test_terrain_characters_map_to_cells() -> void:
	var text := _valid_text().replace("---\n.", "---\n#")
	var lvl := LevelData.parse(text)
	assert_eq(lvl.error, "")
	assert_eq(lvl.terrain.get_cell(0, 0), Types.Cell.BRICK)

func test_base_wall_is_loaded() -> void:
	var lvl := LevelData.parse(_valid_text())
	for c in Consts.BASE_WALL_CELLS:
		assert_eq(lvl.terrain.get_cell(c.x, c.y), Types.Cell.BRICK,
			"cell %s must be brick" % c)

func test_missing_separator_is_an_error() -> void:
	var lvl := LevelData.parse("%s\n%s\n%s" % [ENEMIES_LINE, BONUS_LINE, _terrain_rows()])
	assert_string_contains(lvl.error, "separator")

func test_wrong_row_count_is_an_error() -> void:
	var rows := _terrain_rows().split("\n")
	rows.remove_at(0)
	var text := "%s\n%s\n---\n%s" % [ENEMIES_LINE, BONUS_LINE, "\n".join(rows)]
	assert_string_contains(LevelData.parse(text).error, "rows")

func test_wrong_row_length_is_an_error() -> void:
	var rows := _terrain_rows().split("\n")
	rows[0] = rows[0] + "."
	var text := "%s\n%s\n---\n%s" % [ENEMIES_LINE, BONUS_LINE, "\n".join(rows)]
	assert_string_contains(LevelData.parse(text).error, "characters long")

func test_unknown_terrain_character_is_an_error() -> void:
	var text := _valid_text().replace("---\n.", "---\nZ")
	assert_string_contains(LevelData.parse(text).error, "unknown character")

func test_wrong_enemy_count_is_an_error() -> void:
	var text := _valid_text().replace(ENEMIES_LINE, "enemies: BBB")
	assert_string_contains(LevelData.parse(text).error, "20")

func test_unknown_enemy_character_is_an_error() -> void:
	var text := _valid_text().replace(ENEMIES_LINE, "enemies: ZBBBBBBBBBBBBBFFFFPP")
	assert_string_contains(LevelData.parse(text).error, "enemy type")

func test_bonus_index_out_of_range_is_an_error() -> void:
	var text := _valid_text().replace(BONUS_LINE, "bonus: 3,99")
	assert_string_contains(LevelData.parse(text).error, "bonus index")

func test_missing_base_wall_is_an_error() -> void:
	var lvl := LevelData.parse("%s\n%s\n---\n%s" % [ENEMIES_LINE, BONUS_LINE, _terrain_rows()])
	assert_string_contains(lvl.error, "base")

func test_base_cells_must_stay_empty() -> void:
	var text := _valid_text()
	var rows := text.split("---\n")[1].split("\n")
	var row: Array = rows[24].split("")
	row[12] = "#"
	rows[24] = "".join(row)
	var broken := "%s\n%s\n---\n%s" % [ENEMIES_LINE, BONUS_LINE, "\n".join(rows)]
	assert_string_contains(LevelData.parse(broken).error, "base")
```

- [x] **Step 3: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "LevelData" not declared`.

- [x] **Step 4: Write `core/level_data.gd`**

```gdscript
class_name LevelData

## Parsing the text level format. It works with a string rather than a file:
## reading from disk is platform/'s duty, so the core does not depend on FileAccess.
##
## The format:
##   enemies: BBBBBBBBBBBBBBFFFFPP
##   bonus: 3,10,17
##   ---
##   26 rows of 26 characters: . empty  # brick  @ steel  ~ water  % forest  - ice

const SEPARATOR := "---"
const ENEMY_COUNT := 20

const CHAR_TO_CELL := {
	".": Types.Cell.EMPTY,
	"#": Types.Cell.BRICK,
	"@": Types.Cell.STEEL,
	"~": Types.Cell.WATER,
	"%": Types.Cell.TREES,
	"-": Types.Cell.ICE,
}

const CHAR_TO_TANK := {
	"B": Types.TankType.BASIC,
	"F": Types.TankType.FAST,
	"P": Types.TankType.POWER,
	"A": Types.TankType.ARMOR,
}

var terrain: Terrain
var enemy_queue: Array[int] = []
var bonus_indices: Array[int] = []
var error := ""

static func parse(text: String) -> LevelData:
	var lvl := LevelData.new()
	lvl.terrain = Terrain.new()

	var parts := text.split(SEPARATOR + "\n", false)
	if parts.size() < 2:
		lvl.error = "no '---' separator between the header and the field"
		return lvl

	var header_error := lvl._parse_header(parts[0])
	if header_error != "":
		lvl.error = header_error
		return lvl

	var body_error := lvl._parse_terrain(parts[1])
	if body_error != "":
		lvl.error = body_error
		return lvl

	lvl.error = lvl._validate_base()
	return lvl

func _parse_header(header: String) -> String:
	var enemies := ""
	var bonus := ""
	for raw_line in header.split("\n", false):
		var line := raw_line.strip_edges()
		if line.begins_with("enemies:"):
			enemies = line.substr(8).strip_edges()
		elif line.begins_with("bonus:"):
			bonus = line.substr(6).strip_edges()

	if enemies.length() != ENEMY_COUNT:
		return "the enemies line must hold exactly %d characters, found %d" % [ENEMY_COUNT, enemies.length()]
	for i in enemies.length():
		var ch := enemies[i]
		if not CHAR_TO_TANK.has(ch):
			return "unknown enemy type '%s' at position %d" % [ch, i]
		enemy_queue.append(CHAR_TO_TANK[ch])

	if bonus != "":
		for piece in bonus.split(",", false):
			var value := piece.strip_edges()
			if not value.is_valid_int():
				return "bonus index '%s' is not a number" % value
			var index := value.to_int()
			if index < 0 or index >= ENEMY_COUNT:
				return "bonus index %d is out of the range 0..%d" % [index, ENEMY_COUNT - 1]
			bonus_indices.append(index)
	return ""

func _parse_terrain(body: String) -> String:
	var rows := body.split("\n", false)
	if rows.size() != Consts.GRID:
		return "the field must span exactly %d rows, found %d" % [Consts.GRID, rows.size()]
	for y in Consts.GRID:
		var row: String = rows[y]
		if row.length() != Consts.GRID:
			return "row %d is %d characters long, expected %d" % [y, row.length(), Consts.GRID]
		for x in Consts.GRID:
			var ch := row[x]
			if not CHAR_TO_CELL.has(ch):
				return "unknown character '%s' in row %d at position %d" % [ch, y, x]
			terrain.set_cell(x, y, CHAR_TO_CELL[ch])
	return ""

func _validate_base() -> String:
	for c in Consts.BASE_WALL_CELLS:
		if terrain.get_cell(c.x, c.y) != Types.Cell.BRICK:
			return "the base is uncovered: cell %s must be brick" % c
	for c in Consts.BASE_CELLS:
		if terrain.get_cell(c.x, c.y) != Types.Cell.EMPTY:
			return "the base stands on a non-empty cell %s" % c
	return ""
```

- [x] **Step 5: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 6: Commit**

```bash
git add core/consts.gd core/level_data.gd tests/core/test_level_data.gd
git commit -m "feat: field layout and parsing of the level format"
```

---

### Task 6: Entities, world state and events

**Files:**
- Create: `core/entities.gd`
- Create: `core/events.gd`
- Create: `core/world_state.gd`
- Test: `tests/core/test_world_state.gd`

**Interfaces:**
- Consumes: `Consts`, `Types`, `Terrain`, `SimConfig`, `LevelData`
- Produces:
  - `Entities.Tank` with the fields `id, type, player_index, pos, dir, health, stars, alive, spawn_ticks, shield_ticks, stun_ticks, slide_ticks, slide_dir, drops_bonus, ai_dir_timer, ai_fire_timer, ai_target_is_base` and the method `center() -> Vector2i`
  - `Entities.Bullet` with the fields `id, owner_id, owner_is_player, pos, dir, speed, power, alive` and the method `center() -> Vector2i`
  - `Entities.Bonus` with the fields `type, pos, ticks_left, active`
  - `Entities.PlayerState` with the fields `index, lives, stars, score, kills, active, respawn_timer, tank_id`
  - `SimEvent.new(type, pos, data)` with the fields `type, pos, data`
  - `WorldState` with the fields `tick, level, terrain, tanks, bullets, bonus, base_alive, freeze_ticks, shovel_ticks, enemy_queue, enemies_left, spawn_timer, spawn_point_index, players, game_over, level_cleared` and the methods `next_id() -> int`, `find_tank(id) -> Entities.Tank`, `player_tanks() -> Array`, `enemy_tanks() -> Array`, `alive_enemy_count() -> int`, `compact()`, `hash_value() -> int`

- [x] **Step 1: Write the failing tests**

`tests/core/test_world_state.gd`:

```gdscript
extends GutTest

var w: WorldState

func before_each() -> void:
	w = WorldState.new()
	w.terrain = Terrain.new()

func _add_tank(type: int, player_index: int = -1) -> Entities.Tank:
	var t := Entities.Tank.new()
	t.id = w.next_id()
	t.type = type
	t.player_index = player_index
	t.alive = true
	w.tanks.append(t)
	return t

func test_ids_are_unique_and_increasing() -> void:
	var a := w.next_id()
	var b := w.next_id()
	assert_ne(a, b)
	assert_lt(a, b, "identifiers must grow — the iteration order depends on it")

func test_find_tank() -> void:
	var t := _add_tank(Types.TankType.BASIC)
	assert_eq(w.find_tank(t.id), t)
	assert_null(w.find_tank(9999))

func test_tank_center() -> void:
	var t := _add_tank(Types.TankType.PLAYER, 0)
	t.pos = Vector2i(0, 0)
	assert_eq(t.center(), Vector2i(Consts.TANK / 2, Consts.TANK / 2))

func test_partitions_players_and_enemies() -> void:
	_add_tank(Types.TankType.PLAYER, 0)
	_add_tank(Types.TankType.BASIC)
	_add_tank(Types.TankType.FAST)
	assert_eq(w.player_tanks().size(), 1)
	assert_eq(w.enemy_tanks().size(), 2)

func test_spawning_enemy_is_not_counted_as_alive_on_field() -> void:
	var e := _add_tank(Types.TankType.BASIC)
	e.spawn_ticks = 10
	assert_eq(w.alive_enemy_count(), 1, "a blinking enemy still occupies a slot on the field")

func test_compact_removes_dead_and_keeps_order() -> void:
	var a := _add_tank(Types.TankType.BASIC)
	var b := _add_tank(Types.TankType.FAST)
	var c := _add_tank(Types.TankType.POWER)
	b.alive = false
	w.compact()
	assert_eq(w.tanks.size(), 2)
	assert_eq(w.tanks[0].id, a.id)
	assert_eq(w.tanks[1].id, c.id, "the order of the survivors must not change")

func test_hash_is_stable_for_identical_states() -> void:
	var other := WorldState.new()
	other.terrain = Terrain.new()
	assert_eq(w.hash_value(), other.hash_value())

func test_hash_reacts_to_tank_position() -> void:
	var t := _add_tank(Types.TankType.PLAYER, 0)
	var before := w.hash_value()
	t.pos += Vector2i(1, 0)
	assert_ne(before, w.hash_value(), "a shift of one unit must change the hash")

func test_hash_reacts_to_terrain() -> void:
	var before := w.hash_value()
	w.terrain.set_cell(4, 4, Types.Cell.BRICK)
	assert_ne(before, w.hash_value())

func test_event_carries_position_and_payload() -> void:
	var e := SimEvent.new(Types.Event.TANK_DESTROYED, Vector2i(10, 20), 400)
	assert_eq(e.type, Types.Event.TANK_DESTROYED)
	assert_eq(e.pos, Vector2i(10, 20))
	assert_eq(e.data, 400)
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "WorldState" not declared`.

- [x] **Step 3: Write `core/entities.gd`**

```gdscript
class_name Entities

class Tank:
	var id := 0
	var type := Types.TankType.BASIC
	var player_index := -1        ## -1 for enemies
	var pos := Vector2i.ZERO      ## top left, u
	var dir := Types.Dir.UP
	var speed := 0
	var health := 1
	var stars := 0                ## players only
	var alive := true
	var spawn_ticks := 0          ## while > 0 the tank is still blinking and does not physically exist
	var shield_ticks := 0
	var stun_ticks := 0
	var slide_ticks := 0          ## inertia on ice
	var slide_dir := Types.Dir.UP
	var drops_bonus := false
	var ai_dir_timer := 0
	var ai_fire_timer := 0
	var ai_target_is_base := true

	func center() -> Vector2i:
		return pos + Vector2i(Consts.TANK / 2, Consts.TANK / 2)

	func is_materialized() -> bool:
		return alive and spawn_ticks == 0

class Bullet:
	var id := 0
	var owner_id := 0
	var owner_is_player := false
	var pos := Vector2i.ZERO      ## top left, u
	var dir := Types.Dir.UP
	var speed := 0
	var power := false            ## pierces steel
	var alive := true

	func center() -> Vector2i:
		return pos + Vector2i(Consts.BULLET / 2, Consts.BULLET / 2)

class Bonus:
	var type := Types.BonusType.STAR
	var pos := Vector2i.ZERO
	var ticks_left := 0
	var active := false

class PlayerState:
	var index := 0
	var lives := 0
	var stars := 0
	var score := 0
	var kills: Array[int] = [0, 0, 0, 0]   ## by index: BASIC, FAST, POWER, ARMOR
	var active := false
	var respawn_timer := 0
	var tank_id := -1
```

- [x] **Step 4: Write `core/events.gd`**

```gdscript
class_name SimEvent

## The core plays no sounds and creates no animations — it reports what happened,
## and the presentation layer decides how to show it. Events are not sent over the
## network: with identical simulations they are identical on both sides.

var type := 0
var pos := Vector2i.ZERO
var data := 0

func _init(p_type: int, p_pos: Vector2i = Vector2i.ZERO, p_data: int = 0) -> void:
	type = p_type
	pos = p_pos
	data = p_data
```

- [x] **Step 5: Write `core/world_state.gd`**

```gdscript
class_name WorldState

var tick := 0
var level := 1
var terrain: Terrain
var tanks: Array = []          ## Entities.Tank, array order = iteration order
var bullets: Array = []        ## Entities.Bullet
var bonus: Entities.Bonus = null
var base_alive := true
var freeze_ticks := 0
var shovel_ticks := 0
var enemy_queue: Array[int] = []
var enemies_left := 0
var spawn_timer := 0
var spawn_point_index := 0
var players: Array = []        ## Entities.PlayerState
var game_over := false
var level_cleared := false

var _next_id := 1

func next_id() -> int:
	var id := _next_id
	_next_id += 1
	return id

func find_tank(id: int) -> Entities.Tank:
	for t in tanks:
		if t.id == id:
			return t
	return null

func player_tanks() -> Array:
	var out: Array = []
	for t in tanks:
		if t.player_index >= 0 and t.alive:
			out.append(t)
	return out

func enemy_tanks() -> Array:
	var out: Array = []
	for t in tanks:
		if t.player_index < 0 and t.alive:
			out.append(t)
	return out

func alive_enemy_count() -> int:
	return enemy_tanks().size()

## Removes the dead, preserving the relative order of the living: iteration order is part of the determinism.
func compact() -> void:
	var live_tanks: Array = []
	for t in tanks:
		if t.alive:
			live_tanks.append(t)
	tanks = live_tanks

	var live_bullets: Array = []
	for b in bullets:
		if b.alive:
			live_bullets.append(b)
	bullets = live_bullets

func hash_value() -> int:
	var h := 2166136261
	h = _mix(h, tick)
	h = _mix(h, level)
	h = _mix(h, terrain.cells_checksum())
	h = _mix(h, 1 if base_alive else 0)
	h = _mix(h, freeze_ticks)
	h = _mix(h, shovel_ticks)
	h = _mix(h, enemies_left)
	h = _mix(h, spawn_timer)
	h = _mix(h, spawn_point_index)
	h = _mix(h, 1 if game_over else 0)
	h = _mix(h, 1 if level_cleared else 0)
	for t in tanks:
		h = _mix(h, t.id)
		h = _mix(h, t.type)
		h = _mix(h, t.pos.x)
		h = _mix(h, t.pos.y)
		h = _mix(h, t.dir)
		h = _mix(h, t.health)
		h = _mix(h, t.stars)
		h = _mix(h, t.spawn_ticks)
		h = _mix(h, t.shield_ticks)
		h = _mix(h, t.stun_ticks)
		h = _mix(h, t.slide_ticks)
	for b in bullets:
		h = _mix(h, b.id)
		h = _mix(h, b.pos.x)
		h = _mix(h, b.pos.y)
		h = _mix(h, b.dir)
	if bonus != null and bonus.active:
		h = _mix(h, bonus.type)
		h = _mix(h, bonus.pos.x)
		h = _mix(h, bonus.pos.y)
		h = _mix(h, bonus.ticks_left)
	for p in players:
		h = _mix(h, p.lives)
		h = _mix(h, p.stars)
		h = _mix(h, p.score)
		h = _mix(h, p.respawn_timer)
	return h

static func _mix(h: int, v: int) -> int:
	var x := (h ^ (v & 0xFFFFFFFF)) & 0xFFFFFFFF
	return (x * 16777619) & 0xFFFFFFFF
```

- [x] **Step 6: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 7: Commit**

```bash
git add core/entities.gd core/events.gd core/world_state.gd tests/core/test_world_state.gd
git commit -m "feat: entities, world state, events and the state hash"
```

---

### Task 7: The simulation skeleton — the tick, timers, end conditions

**Files:**
- Create: `core/sim.gd`
- Test: `tests/core/test_sim_skeleton.gd`
- Test: `tests/helpers/level_fixture.gd`

**Interfaces:**
- Consumes: everything from tasks 2–6
- Produces: `GameSim.new(level: LevelData, seed_value: int, config: SimConfig, level_number: int, player_count: int)` with the methods `tick(inputs: Array)`, `get_state() -> WorldState`, `drain_events() -> Array`, `state_hash() -> int`, `get_config() -> SimConfig`. The empty branches `_update_players`, `_update_enemies`, `_update_bullets`, `_update_bonus`, `_update_spawner` are filled in in tasks 9–17.
- Produces: `LevelFixture.empty_level() -> LevelData`, `LevelFixture.level_with(cells: Dictionary) -> LevelData` — fixtures for all the subsequent tests.

- [x] **Step 1: Write the level fixture**

`tests/helpers/level_fixture.gd`:

```gdscript
class_name LevelFixture

## Assembles LevelData in code, bypassing the text format: the tests almost always
## need an empty field with two or three cells in given places.

static func empty_level() -> LevelData:
	return level_with({})

## cells is a dictionary Vector2i → Types.Cell; the ring around the base is added automatically.
static func level_with(cells: Dictionary) -> LevelData:
	var lvl := LevelData.new()
	lvl.terrain = Terrain.new()
	for c in Consts.BASE_WALL_CELLS:
		lvl.terrain.set_cell(c.x, c.y, Types.Cell.BRICK)
	for key in cells:
		lvl.terrain.set_cell(key.x, key.y, cells[key])
	for i in 20:
		lvl.enemy_queue.append(Types.TankType.BASIC)
	lvl.bonus_indices = [3, 10, 17] as Array[int]
	return lvl
```

- [x] **Step 2: Write the failing tests**

`tests/core/test_sim_skeleton.gd`:

```gdscript
extends GutTest

var sim: GameSim

func before_each() -> void:
	sim = GameSim.new(LevelFixture.empty_level(), 1, SimConfig.new(), 1, 1)

func test_tick_advances_counter() -> void:
	assert_eq(sim.get_state().tick, 0)
	sim.tick([0, 0])
	sim.tick([0, 0])
	assert_eq(sim.get_state().tick, 2)

func test_player_is_placed_at_spawn_tile_with_shield() -> void:
	var s := sim.get_state()
	assert_eq(s.player_tanks().size(), 1)
	var t: Entities.Tank = s.player_tanks()[0]
	assert_eq(t.pos, Consts.tile_to_unit(Consts.PLAYER_SPAWN_TILES[0]))
	assert_eq(t.dir, Types.Dir.UP)
	assert_eq(t.shield_ticks, sim.get_config().respawn_shield_ticks)
	assert_eq(s.players[0].lives, sim.get_config().start_lives)

func test_two_players_get_separate_spawns() -> void:
	var two := GameSim.new(LevelFixture.empty_level(), 1, SimConfig.new(), 1, 2)
	var tanks := two.get_state().player_tanks()
	assert_eq(tanks.size(), 2)
	assert_eq(tanks[0].pos, Consts.tile_to_unit(Consts.PLAYER_SPAWN_TILES[0]))
	assert_eq(tanks[1].pos, Consts.tile_to_unit(Consts.PLAYER_SPAWN_TILES[1]))

func test_timers_count_down_and_stop_at_zero() -> void:
	var s := sim.get_state()
	s.freeze_ticks = 2
	sim.tick([0, 0])
	assert_eq(s.freeze_ticks, 1)
	sim.tick([0, 0])
	assert_eq(s.freeze_ticks, 0)
	sim.tick([0, 0])
	assert_eq(s.freeze_ticks, 0, "the timer must not go negative")

func test_shovel_expiry_returns_steel_walls_to_brick() -> void:
	var s := sim.get_state()
	for c in Consts.BASE_WALL_CELLS:
		s.terrain.set_cell(c.x, c.y, Types.Cell.STEEL)
	s.shovel_ticks = 1
	sim.tick([0, 0])
	for c in Consts.BASE_WALL_CELLS:
		assert_eq(s.terrain.get_cell(c.x, c.y), Types.Cell.BRICK,
			"after the shovel expires the steel comes back as brick")

func test_shovel_expiry_leaves_holes_alone() -> void:
	var s := sim.get_state()
	var hole: Vector2i = Consts.BASE_WALL_CELLS[0]
	s.terrain.set_cell(hole.x, hole.y, Types.Cell.EMPTY)
	s.shovel_ticks = 1
	sim.tick([0, 0])
	assert_eq(s.terrain.get_cell(hole.x, hole.y), Types.Cell.EMPTY,
		"the shovel does not repair a hole that was shot through")

func test_destroyed_base_ends_the_game() -> void:
	sim.get_state().base_alive = false
	sim.tick([0, 0])
	assert_true(sim.get_state().game_over)

func test_game_over_event_is_emitted_once() -> void:
	sim.get_state().base_alive = false
	sim.tick([0, 0])
	var first := _count(sim.drain_events(), Types.Event.GAME_OVER)
	sim.tick([0, 0])
	var second := _count(sim.drain_events(), Types.Event.GAME_OVER)
	assert_eq(first, 1)
	assert_eq(second, 0, "game over is announced once")

func test_level_cleared_when_no_enemies_left() -> void:
	sim.get_state().enemies_left = 0
	sim.tick([0, 0])
	assert_true(sim.get_state().level_cleared)
	assert_eq(_count(sim.drain_events(), Types.Event.LEVEL_CLEARED), 1)

func test_drain_events_empties_the_queue() -> void:
	sim.get_state().enemies_left = 0
	sim.tick([0, 0])
	assert_gt(sim.drain_events().size(), 0)
	assert_eq(sim.drain_events().size(), 0)

func test_hash_matches_between_two_identical_sims() -> void:
	var a := GameSim.new(LevelFixture.empty_level(), 77, SimConfig.new(), 1, 1)
	var b := GameSim.new(LevelFixture.empty_level(), 77, SimConfig.new(), 1, 1)
	for i in 20:
		a.tick([0, 0])
		b.tick([0, 0])
	assert_eq(a.state_hash(), b.state_hash())

func _count(events: Array, type: int) -> int:
	var n := 0
	for e in events:
		if e.type == type:
			n += 1
	return n
```

- [x] **Step 3: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "GameSim" not declared`.

- [x] **Step 4: Write `core/sim.gd`**

```gdscript
class_name GameSim

## The entry point into the simulation. The core knows nothing about the keyboard,
## the screen or the network: the only way in is five bits per player per tick.

var _state: WorldState
var _config: SimConfig
var _rng: Rng
var _events: Array = []
var _bonus_indices: Array[int] = []
var _spawned_count := 0

func _init(level: LevelData, seed_value: int, config: SimConfig = null,
		level_number: int = 1, player_count: int = 1) -> void:
	_config = config if config != null else SimConfig.new()
	_rng = Rng.new(seed_value)
	_bonus_indices = level.bonus_indices.duplicate()

	_state = WorldState.new()
	_state.level = level_number
	_state.terrain = level.terrain.clone()
	_state.enemy_queue = level.enemy_queue.duplicate()
	_state.enemies_left = level.enemy_queue.size()

	for i in player_count:
		var p := Entities.PlayerState.new()
		p.index = i
		p.lives = _config.start_lives
		p.active = true
		_state.players.append(p)
		_spawn_player(i)

## The order of operations is fixed: reproducibility depends on it, so this is
## part of the contract rather than an implementation detail.
func tick(inputs: Array) -> void:
	_state.tick += 1
	_update_timers()
	_update_players(inputs)
	_update_enemies()
	_update_bullets()
	_update_bonus()
	_update_spawner()
	_check_end_conditions()
	_state.compact()

func get_state() -> WorldState:
	return _state

func get_config() -> SimConfig:
	return _config

func drain_events() -> Array:
	var out := _events
	_events = []
	return out

func state_hash() -> int:
	return _state.hash_value()

# --- internals ---

func _emit(type: int, pos: Vector2i = Vector2i.ZERO, data: int = 0) -> void:
	_events.append(SimEvent.new(type, pos, data))

func _spawn_player(index: int) -> void:
	var p: Entities.PlayerState = _state.players[index]
	var t := Entities.Tank.new()
	t.id = _state.next_id()
	t.type = Types.TankType.PLAYER
	t.player_index = index
	t.pos = Consts.tile_to_unit(Consts.PLAYER_SPAWN_TILES[index])
	t.dir = Types.Dir.UP
	t.speed = _config.player_speed
	t.health = 1
	t.stars = p.stars
	t.shield_ticks = _config.respawn_shield_ticks
	_state.tanks.append(t)
	p.tank_id = t.id

func _update_timers() -> void:
	if _state.freeze_ticks > 0:
		_state.freeze_ticks -= 1
	if _state.shovel_ticks > 0:
		_state.shovel_ticks -= 1
		if _state.shovel_ticks == 0:
			_restore_base_wall()
	for t in _state.tanks:
		if t.spawn_ticks > 0:
			t.spawn_ticks -= 1
		if t.shield_ticks > 0:
			t.shield_ticks -= 1
		if t.stun_ticks > 0:
			t.stun_ticks -= 1
	# slide_ticks is deliberately left alone here: it is spent at the moment of
	# coasting (task 9), or the inertia would come out a tick shorter than stated.

## Returns brick only where shovel steel currently stands: the shovel does not
## repair a hole that was shot through — the same as in the original.
func _restore_base_wall() -> void:
	for c in Consts.BASE_WALL_CELLS:
		if _state.terrain.get_cell(c.x, c.y) == Types.Cell.STEEL:
			_state.terrain.set_cell(c.x, c.y, Types.Cell.BRICK)

func _update_players(inputs: Array) -> void:
	pass   # task 9

func _update_enemies() -> void:
	pass   # task 15

func _update_bullets() -> void:
	pass   # tasks 10–12

func _update_bonus() -> void:
	pass   # task 16

func _update_spawner() -> void:
	pass   # task 14

func _check_end_conditions() -> void:
	if _state.game_over or _state.level_cleared:
		return
	if not _state.base_alive:
		_state.game_over = true
		_emit(Types.Event.GAME_OVER, Consts.tile_to_unit(Consts.BASE_TILE))
		return
	if _state.enemies_left <= 0:
		_state.level_cleared = true
		_emit(Types.Event.LEVEL_CLEARED)
		return
	var anyone_left := false
	for p in _state.players:
		if p.active and (p.lives > 0 or p.tank_id != -1):
			anyone_left = true
	if not anyone_left:
		_state.game_over = true
		_emit(Types.Event.GAME_OVER)
```

- [x] **Step 5: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 6: Commit**

```bash
git add core/sim.gd tests/core/test_sim_skeleton.gd tests/helpers/level_fixture.gd
git commit -m "feat: simulation skeleton — the tick, timers, level and game end conditions"
```

---

### Task 8: Grid movement

**Files:**
- Create: `core/movement.gd`
- Test: `tests/core/test_movement.gd`

**Interfaces:**
- Consumes: `Consts`, `Types`, `Terrain`, `WorldState`, `Entities`
- Produces: `Movement.snap_to_cell(v: int) -> int`, `Movement.turn(state: WorldState, tank, new_dir: int)`, `Movement.can_occupy(state: WorldState, tank, pos: Vector2i) -> bool`, `Movement.step(state: WorldState, tank, dir: int, distance: int) -> int`, `Movement.on_ice(state: WorldState, tank) -> bool`, `Movement.overlaps(a: Vector2i, sa: int, b: Vector2i, sb: int) -> bool`

The key device: a tank moves **one unit per step**, up to `distance` steps, and stops at the first occupied one. Speeds do not exceed 16 u per tick, so that is at most 16 checks per tank — but it removes the wall-clamping arithmetic, which is easy to get wrong.

- [x] **Step 1: Write the failing tests**

`tests/core/test_movement.gd`:

```gdscript
extends GutTest

var state: WorldState

func before_each() -> void:
	state = WorldState.new()
	state.terrain = Terrain.new()

func _tank(pos: Vector2i, dir: int = Types.Dir.UP) -> Entities.Tank:
	var t := Entities.Tank.new()
	t.id = state.next_id()
	t.pos = pos
	t.dir = dir
	t.speed = 12
	t.alive = true
	state.tanks.append(t)
	return t

func test_snap_rounds_to_nearest_cell() -> void:
	assert_eq(Movement.snap_to_cell(0), 0)
	assert_eq(Movement.snap_to_cell(63), 0, "less than half a cell — down")
	assert_eq(Movement.snap_to_cell(64), 128, "exactly half — up")
	assert_eq(Movement.snap_to_cell(129), 128)
	assert_eq(Movement.snap_to_cell(200), 256)

func test_step_moves_exactly_the_distance() -> void:
	var t := _tank(Vector2i(1024, 1024))
	assert_eq(Movement.step(state, t, Types.Dir.RIGHT, 12), 12)
	assert_eq(t.pos, Vector2i(1036, 1024))

func test_turn_snaps_perpendicular_axis() -> void:
	var t := _tank(Vector2i(1030, 1024), Types.Dir.RIGHT)
	Movement.turn(state, t, Types.Dir.UP)
	assert_eq(t.dir, Types.Dir.UP)
	assert_eq(t.pos.x, 1024, "turning upward snaps X")
	assert_eq(t.pos.y, 1024, "Y is left alone")

func test_turn_does_not_snap_when_direction_unchanged() -> void:
	var t := _tank(Vector2i(1030, 1024), Types.Dir.RIGHT)
	Movement.turn(state, t, Types.Dir.RIGHT)
	assert_eq(t.pos.x, 1030)

func test_turn_reverts_snap_that_would_push_tank_into_another() -> void:
	# On terrain the snap is safe: an aligned tank occupies exactly two cells,
	# that is, a subset of the three it occupied unaligned. But the snap can push it
	# onto a neighbouring tank — then it has to be rolled back, or the tanks stick together.
	var other := _tank(Vector2i(770, 1024))
	var t := _tank(Vector2i(1030, 1024), Types.Dir.RIGHT)
	Movement.turn(state, t, Types.Dir.UP)
	assert_eq(t.pos.x, 1030, "the snap is rolled back if it makes the tank overlap a neighbour")
	assert_eq(t.dir, Types.Dir.UP, "the direction changes in any case")
	assert_not_null(other)

func test_stops_flush_against_brick() -> void:
	state.terrain.set_cell(10, 8, Types.Cell.BRICK)
	var t := _tank(Vector2i(1024, 1024), Types.Dir.RIGHT)
	var moved := Movement.step(state, t, Types.Dir.RIGHT, 100)
	assert_eq(t.pos.x, 1024, "the tank is already flush: cell 10 starts at 1280, the tank occupies 1024..1279")
	assert_eq(moved, 0)

func test_moves_until_it_touches_the_wall() -> void:
	state.terrain.set_cell(11, 8, Types.Cell.BRICK)
	var t := _tank(Vector2i(1024, 1024), Types.Dir.RIGHT)
	Movement.step(state, t, Types.Dir.RIGHT, 200)
	assert_eq(t.pos.x, 1152, "it stops flush: 1408 - 256 = 1152")

func test_water_blocks_tank() -> void:
	state.terrain.set_cell(10, 8, Types.Cell.WATER)
	var t := _tank(Vector2i(1024, 1024), Types.Dir.RIGHT)
	assert_eq(Movement.step(state, t, Types.Dir.RIGHT, 16), 0, "water holds a tank")

func test_trees_do_not_block_tank() -> void:
	state.terrain.set_cell(10, 8, Types.Cell.TREES)
	var t := _tank(Vector2i(1024, 1024), Types.Dir.RIGHT)
	assert_eq(Movement.step(state, t, Types.Dir.RIGHT, 16), 16, "a tank drives through forest")

func test_ice_does_not_block_tank() -> void:
	state.terrain.set_cell(10, 8, Types.Cell.ICE)
	var t := _tank(Vector2i(1024, 1024), Types.Dir.RIGHT)
	assert_eq(Movement.step(state, t, Types.Dir.RIGHT, 16), 16, "a tank drives over ice")

func test_cannot_leave_the_field() -> void:
	var t := _tank(Vector2i(0, 0), Types.Dir.LEFT)
	assert_eq(Movement.step(state, t, Types.Dir.LEFT, 16), 0)
	t.pos = Vector2i(Consts.FIELD - Consts.TANK, 0)
	assert_eq(Movement.step(state, t, Types.Dir.RIGHT, 16), 0)

func test_tanks_block_each_other() -> void:
	var a := _tank(Vector2i(1024, 1024), Types.Dir.RIGHT)
	var b := _tank(Vector2i(1024 + Consts.TANK, 1024))
	assert_eq(Movement.step(state, a, Types.Dir.RIGHT, 16), 0)
	assert_not_null(b)

func test_spawning_tank_does_not_block() -> void:
	var a := _tank(Vector2i(1024, 1024), Types.Dir.RIGHT)
	var b := _tank(Vector2i(1024 + Consts.TANK, 1024))
	b.spawn_ticks = 30
	assert_eq(Movement.step(state, a, Types.Dir.RIGHT, 16), 16,
		"a blinking tank does not yet physically exist")

func test_on_ice_checks_the_cell_under_the_centre() -> void:
	var t := _tank(Vector2i(1024, 1024))
	assert_false(Movement.on_ice(state, t))
	var c := state.terrain.cell_at_unit(t.center())
	state.terrain.set_cell(c.x, c.y, Types.Cell.ICE)
	assert_true(Movement.on_ice(state, t))
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `Identifier "Movement" not declared`.

- [x] **Step 3: Write `core/movement.gd`**

```gdscript
class_name Movement

## Movement on the half-tile grid. It is the snap on turning that creates the
## feeling of landing in gaps by itself; without it the game feels foreign.

static func snap_to_cell(v: int) -> int:
	return ((v + Consts.CELL / 2) / Consts.CELL) * Consts.CELL

static func overlaps(a: Vector2i, sa: int, b: Vector2i, sb: int) -> bool:
	return a.x < b.x + sb and b.x < a.x + sa and a.y < b.y + sb and b.y < a.y + sa

static func can_occupy(state: WorldState, tank, pos: Vector2i) -> bool:
	if state.terrain.rect_blocks_tank(pos, Consts.TANK):
		return false
	for other in state.tanks:
		if other.id == tank.id or not other.is_materialized():
			continue
		if overlaps(pos, Consts.TANK, other.pos, Consts.TANK):
			return false
	return true

static func turn(state: WorldState, tank, new_dir: int) -> void:
	if tank.dir == new_dir:
		return
	tank.dir = new_dir
	var before := tank.pos
	if new_dir == Types.Dir.UP or new_dir == Types.Dir.DOWN:
		tank.pos.x = snap_to_cell(tank.pos.x)
	else:
		tank.pos.y = snap_to_cell(tank.pos.y)
	# The snap can push a tank into a wall — then we roll it back, or it gets stuck.
	if not can_occupy(state, tank, tank.pos):
		tank.pos = before

## Moves one unit at a time, stopping at the first occupied step.
## Returns the distance actually covered.
static func step(state: WorldState, tank, dir: int, distance: int) -> int:
	var delta: Vector2i = Types.DIR_VEC[dir]
	var moved := 0
	for i in distance:
		var next := tank.pos + delta
		if not can_occupy(state, tank, next):
			break
		tank.pos = next
		moved += 1
	return moved

static func on_ice(state: WorldState, tank) -> bool:
	var c := state.terrain.cell_at_unit(tank.center())
	return state.terrain.get_cell(c.x, c.y) == Types.Cell.ICE
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 5: Commit**

```bash
git add core/movement.gd tests/core/test_movement.gd
git commit -m "feat: movement on the half-tile grid with the snap and collisions"
```

---

### Task 9: Player control

**Files:**
- Modify: `core/sim.gd` (`_update_players` and its helpers)
- Test: `tests/core/test_player_control.gd`

**Interfaces:**
- Consumes: `Movement`, `Types`, `SimConfig`
- Produces: `GameSim` gains `_dir_from_bits(bits: int) -> int`, `_control_tank(tank, bits: int)`, `_drive(tank, dir: int)`. `_drive` is reused by the enemies in task 14.

- [x] **Step 1: Write the failing tests**

`tests/core/test_player_control.gd`:

```gdscript
extends GutTest

var sim: GameSim
var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()
	sim = GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 1)

func _player() -> Entities.Tank:
	return sim.get_state().player_tanks()[0]

func test_moving_right_turns_and_advances() -> void:
	var start := _player().pos
	sim.tick([Types.IN_RIGHT, 0])
	assert_eq(_player().dir, Types.Dir.RIGHT)
	assert_eq(_player().pos, start + Vector2i(cfg.player_speed, 0))

func test_holding_the_key_keeps_moving() -> void:
	var start := _player().pos
	for i in 3:
		sim.tick([Types.IN_UP, 0])
	assert_eq(_player().pos, start - Vector2i(0, cfg.player_speed * 3))

func test_releasing_the_key_stops_the_tank() -> void:
	sim.tick([Types.IN_UP, 0])
	var after := _player().pos
	sim.tick([0, 0])
	assert_eq(_player().pos, after)

func test_input_priority_is_fixed() -> void:
	# The order in which the bits are polled is part of the determinism: up, down, left, right.
	sim.tick([Types.IN_UP | Types.IN_RIGHT, 0])
	assert_eq(_player().dir, Types.Dir.UP)

func test_turning_snaps_to_the_half_tile_grid() -> void:
	for i in 5:
		sim.tick([Types.IN_UP, 0])       # moved 60 u up — Y is not a multiple of a cell
	assert_ne(_player().pos.y % Consts.CELL, 0)
	sim.tick([Types.IN_RIGHT, 0])
	assert_eq(_player().pos.y % Consts.CELL, 0, "turning sideways snaps Y")

func test_stunned_player_does_not_move() -> void:
	var t := _player()
	t.stun_ticks = 5
	var start := t.pos
	sim.tick([Types.IN_UP, 0])
	assert_eq(t.pos, start)

func test_second_player_reads_its_own_bits() -> void:
	var two := GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 2)
	var p1: Entities.Tank = two.get_state().player_tanks()[0]
	var p2: Entities.Tank = two.get_state().player_tanks()[1]
	var start1 := p1.pos
	var start2 := p2.pos
	two.tick([0, Types.IN_UP])
	assert_eq(p1.pos, start1, "the first player received no input")
	assert_eq(p2.pos, start2 - Vector2i(0, cfg.player_speed))

func test_ice_keeps_the_tank_sliding_after_release() -> void:
	var cells := {}
	for cy in range(18, 26):
		cells[Vector2i(9, cy)] = Types.Cell.ICE
	var iced := GameSim.new(LevelFixture.level_with(cells), 1, cfg, 1, 1)
	var t: Entities.Tank = iced.get_state().player_tanks()[0]

	iced.tick([Types.IN_UP, 0])
	assert_eq(t.slide_ticks, cfg.ice_slide_ticks, "driving over ice arms the inertia")
	var after_release := t.pos

	for i in cfg.ice_slide_ticks:
		iced.tick([0, 0])
	assert_eq(t.pos, after_release - Vector2i(0, cfg.player_speed * cfg.ice_slide_ticks),
		"after release the tank coasts for exactly ice_slide_ticks ticks")

	var settled := t.pos
	iced.tick([0, 0])
	assert_eq(t.pos, settled, "the inertia is over — the tank stands")

func test_no_ice_means_no_sliding() -> void:
	sim.tick([Types.IN_UP, 0])
	assert_eq(_player().slide_ticks, 0)
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — the tank does not move, `_update_players` is still empty.

- [x] **Step 3: Replace `_update_players` in `core/sim.gd`**

```gdscript
func _update_players(inputs: Array) -> void:
	for p in _state.players:
		if p.tank_id == -1:
			continue
		var t := _state.find_tank(p.tank_id)
		if t == null or not t.alive or t.stun_ticks > 0:
			continue
		var bits: int = inputs[p.index] if p.index < inputs.size() else 0
		_control_tank(t, bits)

func _control_tank(t, bits: int) -> void:
	var dir := _dir_from_bits(bits)
	if dir >= 0:
		_drive(t, dir)
	elif t.slide_ticks > 0:
		# Inertia on ice: we spend exactly one tick per coast.
		t.slide_ticks -= 1
		Movement.step(_state, t, t.slide_dir, t.speed)
	if bits & Types.IN_FIRE:
		_try_fire(t)

## Turning, stepping and arming the inertia. Reused by the enemies as is.
func _drive(t, dir: int) -> void:
	Movement.turn(_state, t, dir)
	var moved := Movement.step(_state, t, t.dir, t.speed)
	if moved > 0 and Movement.on_ice(_state, t):
		t.slide_ticks = _config.ice_slide_ticks
		t.slide_dir = t.dir

## The order in which the bits are polled is fixed — it is part of the determinism.
func _dir_from_bits(bits: int) -> int:
	if bits & Types.IN_UP:
		return Types.Dir.UP
	if bits & Types.IN_DOWN:
		return Types.Dir.DOWN
	if bits & Types.IN_LEFT:
		return Types.Dir.LEFT
	if bits & Types.IN_RIGHT:
		return Types.Dir.RIGHT
	return -1

## A stub until task 10 — firing appears there.
func _try_fire(t) -> void:
	pass
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 5: Commit**

```bash
git add core/sim.gd tests/core/test_player_control.gd
git commit -m "feat: player control, the snap on turning and inertia on ice"
```

---

### Task 10: Firing and bullet flight

**Files:**
- Modify: `core/sim.gd` (`_try_fire`, `_update_bullets`)
- Test: `tests/core/test_bullets_flight.gd`

**Interfaces:**
- Consumes: `Entities.Bullet`, `Movement.overlaps`
- Produces: `GameSim` gains `_try_fire(tank)`, `_bullet_limit(tank) -> int`, `_bullet_speed(tank) -> int`, `_count_bullets_of(owner_id: int) -> int`, `_update_bullets()`, `_advance_bullet(bullet) -> bool` (returns `true` if the bullet survived the tick), `_resolve_bullet_pair_collisions()`. In task 11 hits on terrain, tanks and the base are added to `_advance_bullet`.

- [x] **Step 1: Write the failing tests**

`tests/core/test_bullets_flight.gd`:

```gdscript
extends GutTest

var sim: GameSim
var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()
	sim = GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 1)

func _player() -> Entities.Tank:
	return sim.get_state().player_tanks()[0]

func _bullets() -> Array:
	return sim.get_state().bullets

## We count a particular tank's bullets: from task 13 on, enemy bullets appear on
## the field too, and a test counting everything would start failing out of nowhere.
func _own_bullets(owner_id: int) -> int:
	var n := 0
	for b in sim.get_state().bullets:
		if b.owner_id == owner_id:
			n += 1
	return n

func test_fire_creates_one_bullet_in_front_of_the_tank() -> void:
	var t := _player()
	sim.tick([Types.IN_FIRE, 0])
	assert_eq(_bullets().size(), 1)
	var b: Entities.Bullet = _bullets()[0]
	assert_eq(b.dir, Types.Dir.UP)
	assert_eq(b.owner_id, t.id)
	assert_true(b.owner_is_player)
	assert_lt(b.center().y, t.center().y, "the bullet flies out along the tank's direction")
	assert_eq(b.center().x, t.center().x, "and along the centre of the barrel")

func test_shot_fired_event_is_emitted() -> void:
	sim.tick([Types.IN_FIRE, 0])
	var types: Array[int] = []
	for e in sim.drain_events():
		types.append(e.type)
	assert_has(types, Types.Event.SHOT_FIRED)

func test_one_bullet_at_a_time_without_stars() -> void:
	var id := _player().id
	sim.tick([Types.IN_FIRE, 0])
	sim.tick([Types.IN_FIRE, 0])
	assert_eq(_own_bullets(id), 1, "with no stars only one bullet is in flight")

func test_two_stars_allow_two_bullets() -> void:
	var id := _player().id
	_player().stars = 2
	sim.tick([Types.IN_FIRE, 0])
	sim.tick([Types.IN_FIRE, 0])
	assert_eq(_own_bullets(id), 2)
	sim.tick([Types.IN_FIRE, 0])
	assert_eq(_own_bullets(id), 2, "a third one does not fly out")

func test_first_star_makes_the_bullet_faster() -> void:
	sim.tick([Types.IN_FIRE, 0])
	assert_eq(_bullets()[0].speed, cfg.bullet_speed)

	var fast := GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 1)
	fast.get_state().player_tanks()[0].stars = 1
	fast.tick([Types.IN_FIRE, 0])
	assert_eq(fast.get_state().bullets[0].speed, cfg.bullet_speed_fast)

func test_third_star_makes_the_bullet_powerful() -> void:
	_player().stars = 3
	sim.tick([Types.IN_FIRE, 0])
	assert_true(_bullets()[0].power, "with the third star the bullet pierces steel")

func test_bullet_travels_at_its_speed() -> void:
	sim.tick([Types.IN_FIRE, 0])
	var b: Entities.Bullet = _bullets()[0]
	var y := b.pos.y
	sim.tick([0, 0])
	assert_eq(b.pos.y, y - cfg.bullet_speed)

func test_bullet_dies_at_the_field_edge() -> void:
	sim.tick([Types.IN_FIRE, 0])
	var b: Entities.Bullet = _bullets()[0]
	for i in 300:
		sim.tick([0, 0])
		if not b.alive:
			break
	assert_false(b.alive, "the bullet must vanish on reaching the field's edge")

func test_opposing_bullets_cancel_each_other() -> void:
	var s := sim.get_state()
	var a := Entities.Bullet.new()
	a.id = s.next_id()
	a.owner_id = 100
	a.owner_is_player = true
	a.dir = Types.Dir.RIGHT
	a.speed = cfg.bullet_speed
	a.pos = Vector2i(1600, 1600)
	var b := Entities.Bullet.new()
	b.id = s.next_id()
	b.owner_id = 200
	b.owner_is_player = false
	b.dir = Types.Dir.LEFT
	b.speed = cfg.bullet_speed
	b.pos = Vector2i(1600 + Consts.BULLET, 1600)
	s.bullets.append(a)
	s.bullets.append(b)

	sim.tick([0, 0])
	assert_eq(s.bullets.size(), 0, "oncoming bullets cancel each other out")

func test_bullets_of_the_same_tank_do_not_cancel() -> void:
	var s := sim.get_state()
	for i in 2:
		var b := Entities.Bullet.new()
		b.id = s.next_id()
		b.owner_id = 42
		b.owner_is_player = true
		b.dir = Types.Dir.UP
		b.speed = 0
		b.pos = Vector2i(1600, 1600)
		s.bullets.append(b)
	sim.tick([0, 0])
	assert_eq(s.bullets.size(), 2, "two of your own bullets in one point must not cancel each other")
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — bullets are not created.

- [x] **Step 3: Replace `_try_fire` and `_update_bullets` in `core/sim.gd`**

```gdscript
func _try_fire(t) -> void:
	if _count_bullets_of(t.id) >= _bullet_limit(t):
		return
	var b := Entities.Bullet.new()
	b.id = _state.next_id()
	b.owner_id = t.id
	b.owner_is_player = t.player_index >= 0
	b.dir = t.dir
	b.speed = _bullet_speed(t)
	b.power = t.player_index >= 0 and t.stars >= 3
	# We place the bullet at the muzzle: the tank's centre plus half a hull minus half a bullet.
	var muzzle: Vector2i = t.center() + Types.DIR_VEC[t.dir] * (Consts.TANK / 2 - Consts.BULLET / 2)
	b.pos = muzzle - Vector2i(Consts.BULLET / 2, Consts.BULLET / 2)
	_state.bullets.append(b)
	_emit(Types.Event.SHOT_FIRED, b.pos, b.dir)

func _bullet_limit(t) -> int:
	if t.player_index >= 0 and t.stars >= 2:
		return 2
	return 1

func _bullet_speed(t) -> int:
	if t.player_index >= 0:
		return _config.bullet_speed_fast if t.stars >= 1 else _config.bullet_speed
	return _config.enemy_bullet_speed(t.type)

func _count_bullets_of(owner_id: int) -> int:
	var n := 0
	for b in _state.bullets:
		if b.alive and b.owner_id == owner_id:
			n += 1
	return n

func _update_bullets() -> void:
	for b in _state.bullets:
		if not b.alive:
			continue
		if not _advance_bullet(b):
			b.alive = false
	_resolve_bullet_pair_collisions()

## A bullet advances one unit at a time: that way a hit is recorded in exactly the
## cell it entered, with no clamping arithmetic. Returns false if the bullet died.
func _advance_bullet(b) -> bool:
	var delta: Vector2i = Types.DIR_VEC[b.dir]
	for i in b.speed:
		var next: Vector2i = b.pos + delta
		if _bullet_out_of_field(next):
			_emit(Types.Event.BULLET_HIT_STEEL, b.pos, b.dir)
			return false
		b.pos = next
	return true

func _bullet_out_of_field(pos: Vector2i) -> bool:
	return pos.x < 0 or pos.y < 0 \
		or pos.x + Consts.BULLET > Consts.FIELD \
		or pos.y + Consts.BULLET > Consts.FIELD

func _resolve_bullet_pair_collisions() -> void:
	for i in _state.bullets.size():
		var a = _state.bullets[i]
		if not a.alive:
			continue
		for j in range(i + 1, _state.bullets.size()):
			var b = _state.bullets[j]
			if not b.alive or a.owner_id == b.owner_id:
				continue
			if Movement.overlaps(a.pos, Consts.BULLET, b.pos, Consts.BULLET):
				a.alive = false
				b.alive = false
				_emit(Types.Event.BULLET_HIT_BULLET, a.pos)
				break
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 5: Commit**

```bash
git add core/sim.gd tests/core/test_bullets_flight.gd
git commit -m "feat: firing, bullet limits, flight and mutual cancellation"
```

---

### Task 11: Hits — terrain, tanks, base

**Files:**
- Modify: `core/sim.gd` (`_advance_bullet` and hit resolution)
- Test: `tests/core/test_bullet_hits.gd`

**Interfaces:**
- Consumes: `Terrain.destroy_cell`, `Movement.overlaps`
- Produces: `GameSim` gains `_bullet_leading_point(bullet) -> Vector2i`, `_bullet_hits_terrain(bullet) -> bool`, `_destroy_band(bullet)`, `_bullet_hits_tank(bullet) -> Entities.Tank`, `_apply_bullet_to_tank(bullet, tank)`, `_hits_base(bullet) -> bool`, `_destroy_base(bullet)`, `_on_enemy_destroyed(tank, bullet)`, `_on_player_destroyed(tank)`. The last two are extended in tasks 12 and 15.

Destruction relies on an invariant: **the cross-axis coordinate of a bullet's centre is always a multiple of a cell.** The tank is aligned on the cross axis (the snap on turning), the bullet flies out of its centre, and moving along the firing axis does not change the cross coordinate. So the destruction strip is exactly two cells, `centre/CELL − 1` and `centre/CELL`, that is 16 pixels: one shot is enough to open a passage.

- [x] **Step 1: Write the failing tests**

`tests/core/test_bullet_hits.gd`:

```gdscript
extends GutTest

var sim: GameSim
var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()
	sim = GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 1)

func _state() -> WorldState:
	return sim.get_state()

func _player() -> Entities.Tank:
	return _state().player_tanks()[0]

## A bullet with its centre at X = 1152 (exactly the boundary of cells 8 and 9) — the core's working invariant.
func _shoot_up(from_y: int, is_player := true, power := false, owner_id := 999) -> Entities.Bullet:
	var b := Entities.Bullet.new()
	b.id = _state().next_id()
	b.owner_id = owner_id
	b.owner_is_player = is_player
	b.dir = Types.Dir.UP
	b.speed = cfg.bullet_speed
	b.power = power
	b.pos = Vector2i(1120, from_y)
	_state().bullets.append(b)
	return b

func _add_enemy(pos: Vector2i, type := Types.TankType.BASIC) -> Entities.Tank:
	var t := Entities.Tank.new()
	t.id = _state().next_id()
	t.type = type
	t.player_index = -1
	t.pos = pos
	t.dir = Types.Dir.DOWN
	t.speed = cfg.enemy_speed(type)
	t.health = cfg.enemy_health(type)
	t.alive = true
	_state().tanks.append(t)
	return t

func _event_types() -> Array[int]:
	var out: Array[int] = []
	for e in sim.drain_events():
		out.append(e.type)
	return out

# --- terrain ---

func test_bullet_carves_a_tank_wide_hole_in_brick() -> void:
	var s := _state()
	for cy in [9, 10]:
		s.terrain.set_cell(8, cy, Types.Cell.BRICK)
		s.terrain.set_cell(9, cy, Types.Cell.BRICK)
	_shoot_up(1416)
	sim.tick([0, 0])
	assert_eq(s.terrain.get_cell(8, 10), Types.Cell.EMPTY, "the left half of the gap")
	assert_eq(s.terrain.get_cell(9, 10), Types.Cell.EMPTY, "the right half of the gap")
	assert_eq(s.terrain.get_cell(8, 9), Types.Cell.BRICK, "an ordinary bullet takes one cell of depth")
	assert_eq(s.terrain.get_cell(9, 9), Types.Cell.BRICK)
	assert_eq(s.bullets.size(), 0, "the bullet dies on the brick")
	assert_has(_event_types(), Types.Event.BULLET_HIT_BRICK)

func test_powerful_bullet_goes_twice_as_deep() -> void:
	var s := _state()
	for cy in [9, 10]:
		s.terrain.set_cell(8, cy, Types.Cell.BRICK)
		s.terrain.set_cell(9, cy, Types.Cell.BRICK)
	_shoot_up(1416, true, true)
	sim.tick([0, 0])
	for cy in [9, 10]:
		assert_eq(s.terrain.get_cell(8, cy), Types.Cell.EMPTY)
		assert_eq(s.terrain.get_cell(9, cy), Types.Cell.EMPTY)

func test_steel_survives_an_ordinary_bullet() -> void:
	var s := _state()
	s.terrain.set_cell(8, 10, Types.Cell.STEEL)
	s.terrain.set_cell(9, 10, Types.Cell.STEEL)
	_shoot_up(1416)
	sim.tick([0, 0])
	assert_eq(s.terrain.get_cell(9, 10), Types.Cell.STEEL)
	assert_eq(s.bullets.size(), 0, "the bullet dies anyway")
	assert_has(_event_types(), Types.Event.BULLET_HIT_STEEL)

func test_third_star_breaks_steel() -> void:
	var s := _state()
	s.terrain.set_cell(8, 10, Types.Cell.STEEL)
	s.terrain.set_cell(9, 10, Types.Cell.STEEL)
	_shoot_up(1416, true, true)
	sim.tick([0, 0])
	assert_eq(s.terrain.get_cell(8, 10), Types.Cell.EMPTY)
	assert_eq(s.terrain.get_cell(9, 10), Types.Cell.EMPTY)

func test_bullet_flies_over_water_and_trees() -> void:
	var s := _state()
	s.terrain.set_cell(8, 10, Types.Cell.WATER)
	s.terrain.set_cell(9, 10, Types.Cell.TREES)
	var b := _shoot_up(1416)
	sim.tick([0, 0])
	assert_eq(s.bullets.size(), 1, "a bullet flies over water and through forest")
	assert_eq(b.pos.y, 1416 - cfg.bullet_speed)

# --- tanks ---

func test_player_bullet_kills_an_enemy_and_scores() -> void:
	var owner := _player()
	var enemy := _add_enemy(Vector2i(1024, 1280))
	var before := _state().enemies_left
	_shoot_up(1560, true, false, owner.id)
	for i in 3:
		sim.tick([0, 0])
	assert_false(enemy.alive)
	assert_eq(_state().enemies_left, before - 1)
	assert_eq(_state().players[0].score, cfg.enemy_score(Types.TankType.BASIC))
	assert_eq(_state().players[0].kills[0], 1, "the killed BASIC went into the tally")
	assert_has(_event_types(), Types.Event.TANK_DESTROYED)

func test_armor_tank_needs_four_hits() -> void:
	var owner := _player()
	var enemy := _add_enemy(Vector2i(1024, 1280), Types.TankType.ARMOR)
	for shot in 3:
		_shoot_up(1560, true, false, owner.id)
		for i in 3:
			sim.tick([0, 0])
		assert_true(enemy.alive, "after %d hits the heavy one is still alive" % (shot + 1))
	_shoot_up(1560, true, false, owner.id)
	for i in 3:
		sim.tick([0, 0])
	assert_false(enemy.alive, "the fourth hit finishes it")

func test_enemy_bullet_passes_through_another_enemy() -> void:
	var victim := _add_enemy(Vector2i(1024, 1280))
	var shooter := _add_enemy(Vector2i(1024, 1600))
	var b := _shoot_up(1560, false, false, shooter.id)
	sim.tick([0, 0])
	assert_true(victim.alive, "enemy bullets do not harm enemies")
	assert_true(b.alive)

func test_spawning_enemy_cannot_be_hit() -> void:
	var owner := _player()
	var enemy := _add_enemy(Vector2i(1024, 1280))
	enemy.spawn_ticks = 30
	_shoot_up(1560, true, false, owner.id)
	for i in 2:
		sim.tick([0, 0])
	assert_true(enemy.alive, "a blinking enemy does not yet physically exist")

func test_shield_protects_the_player() -> void:
	var t := _player()
	t.shield_ticks = 100
	var enemy := _add_enemy(Vector2i(t.pos.x, t.pos.y - Consts.TANK))
	var b := _shoot_up(t.pos.y - 100, false, false, enemy.id)
	b.dir = Types.Dir.DOWN
	b.pos = Vector2i(t.pos.x + Consts.TANK / 2 - Consts.BULLET / 2, t.pos.y - Consts.BULLET)
	sim.tick([0, 0])
	assert_true(t.alive, "the shield holds the hit")
	assert_eq(_state().bullets.size(), 0, "but it absorbs the bullet")

func test_ally_bullet_only_stuns() -> void:
	var two := GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 2)
	var p1: Entities.Tank = two.get_state().player_tanks()[0]
	var p2: Entities.Tank = two.get_state().player_tanks()[1]
	p2.shield_ticks = 0
	var b := Entities.Bullet.new()
	b.id = two.get_state().next_id()
	b.owner_id = p1.id
	b.owner_is_player = true
	b.dir = Types.Dir.RIGHT
	b.speed = cfg.bullet_speed
	b.pos = Vector2i(p2.pos.x - Consts.BULLET, p2.pos.y + Consts.TANK / 2)
	two.get_state().bullets.append(b)
	two.tick([0, 0])
	assert_true(p2.alive, "an ally cannot be killed with a bullet")
	assert_eq(p2.stun_ticks, cfg.ally_stun_ticks)

# --- the base ---

func test_hitting_the_base_ends_the_game() -> void:
	var s := _state()
	for c in Consts.BASE_WALL_CELLS:
		s.terrain.set_cell(c.x, c.y, Types.Cell.EMPTY)
	var b := Entities.Bullet.new()
	b.id = s.next_id()
	b.owner_id = 999
	b.owner_is_player = false
	b.dir = Types.Dir.DOWN
	b.speed = cfg.bullet_speed
	b.pos = Vector2i(1632, 3000)
	s.bullets.append(b)
	sim.tick([0, 0])
	assert_false(s.base_alive)
	assert_true(s.game_over)
	var types := _event_types()
	assert_has(types, Types.Event.BASE_DESTROYED)
	assert_has(types, Types.Event.GAME_OVER)

func test_own_bullet_also_destroys_the_base() -> void:
	var s := _state()
	for c in Consts.BASE_WALL_CELLS:
		s.terrain.set_cell(c.x, c.y, Types.Cell.EMPTY)
	var b := Entities.Bullet.new()
	b.id = s.next_id()
	b.owner_id = _player().id
	b.owner_is_player = true
	b.dir = Types.Dir.DOWN
	b.speed = cfg.bullet_speed
	b.pos = Vector2i(1632, 3000)
	s.bullets.append(b)
	sim.tick([0, 0])
	assert_false(s.base_alive, "your own bullet kills the eagle just the same")
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — the bullets fly through everything.

- [x] **Step 3: Replace `_advance_bullet` and add hit resolution in `core/sim.gd`**

```gdscript
func _advance_bullet(b) -> bool:
	var delta: Vector2i = Types.DIR_VEC[b.dir]
	for i in b.speed:
		var next: Vector2i = b.pos + delta
		if _bullet_out_of_field(next):
			_emit(Types.Event.BULLET_HIT_STEEL, b.pos, b.dir)
			return false
		b.pos = next
		if _hits_base(b):
			_destroy_base(b)
			return false
		var victim = _bullet_hits_tank(b)
		if victim != null:
			_apply_bullet_to_tank(b, victim)
			return false
		if _bullet_hits_terrain(b):
			_destroy_band(b)
			return false
	return true

## The point on the bullet's leading edge. It is what determines the cell of the
## hit: from the bullet's centre it would be computed one cell later than needed.
func _bullet_leading_point(b) -> Vector2i:
	var c: Vector2i = b.center()
	match b.dir:
		Types.Dir.UP:
			return Vector2i(c.x, b.pos.y)
		Types.Dir.DOWN:
			return Vector2i(c.x, b.pos.y + Consts.BULLET - 1)
		Types.Dir.LEFT:
			return Vector2i(b.pos.x, c.y)
		_:
			return Vector2i(b.pos.x + Consts.BULLET - 1, c.y)

func _bullet_hits_terrain(b) -> bool:
	var c0: Vector2i = _state.terrain.cell_at_unit(b.pos)
	var c1: Vector2i = _state.terrain.cell_at_unit(b.pos + Vector2i(Consts.BULLET - 1, Consts.BULLET - 1))
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			if _state.terrain.blocks_bullet(cx, cy):
				return true
	return false

## A strip as wide as a tank (two cells) and one cell deep,
## and two for a bullet with the third star.
func _destroy_band(b) -> void:
	var horizontal := b.dir == Types.Dir.LEFT or b.dir == Types.Dir.RIGHT
	var impact: Vector2i = _state.terrain.cell_at_unit(_bullet_leading_point(b))
	var centre: Vector2i = b.center()
	var perp_base: int = (centre.y / Consts.CELL - 1) if horizontal else (centre.x / Consts.CELL - 1)
	var forward: int = 1 if (b.dir == Types.Dir.RIGHT or b.dir == Types.Dir.DOWN) else -1
	var depth: int = 2 if b.power else 1

	var broke_brick := false
	var touched_steel := false
	for d in depth:
		for k in 2:
			var cx: int = (impact.x + forward * d) if horizontal else (perp_base + k)
			var cy: int = (perp_base + k) if horizontal else (impact.y + forward * d)
			var before := _state.terrain.get_cell(cx, cy)
			var destroyed := _state.terrain.destroy_cell(cx, cy, b.power)
			if destroyed == Types.Cell.BRICK:
				broke_brick = true
			elif before == Types.Cell.STEEL:
				touched_steel = true

	if broke_brick:
		_emit(Types.Event.BULLET_HIT_BRICK, b.center(), b.dir)
	elif touched_steel:
		_emit(Types.Event.BULLET_HIT_STEEL, b.center(), b.dir)

func _bullet_hits_tank(b):
	for t in _state.tanks:
		if not t.is_materialized() or t.id == b.owner_id:
			continue
		var target_is_player: bool = t.player_index >= 0
		# An enemy does not harm an enemy — the bullet passes right through it.
		if not b.owner_is_player and not target_is_player:
			continue
		if Movement.overlaps(b.pos, Consts.BULLET, t.pos, Consts.TANK):
			return t
	return null

func _apply_bullet_to_tank(b, t) -> void:
	if b.owner_is_player and t.player_index >= 0:
		t.stun_ticks = _config.ally_stun_ticks
		return
	if t.shield_ticks > 0:
		return
	t.health -= 1
	if t.health > 0:
		return
	t.alive = false
	if t.player_index >= 0:
		_emit(Types.Event.PLAYER_DESTROYED, t.pos, t.player_index)
		_on_player_destroyed(t)
	else:
		_emit(Types.Event.TANK_DESTROYED, t.pos, t.type)
		_on_enemy_destroyed(t, b)

func _hits_base(b) -> bool:
	if not _state.base_alive:
		return false
	return Movement.overlaps(b.pos, Consts.BULLET, Consts.tile_to_unit(Consts.BASE_TILE), Consts.TILE)

func _destroy_base(b) -> void:
	_state.base_alive = false
	_emit(Types.Event.BASE_DESTROYED, Consts.tile_to_unit(Consts.BASE_TILE))

func _on_enemy_destroyed(t, b) -> void:
	_state.enemies_left -= 1
	if b == null or not b.owner_is_player:
		return
	var owner = _state.find_tank(b.owner_id)
	if owner == null or owner.player_index < 0:
		return
	var p: Entities.PlayerState = _state.players[owner.player_index]
	p.score += _config.enemy_score(t.type)
	p.kills[t.type - Types.TankType.BASIC] += 1

## Extended in task 12: deducting a life and respawning appear there.
func _on_player_destroyed(t) -> void:
	var p: Entities.PlayerState = _state.players[t.player_index]
	p.tank_id = -1
	p.stars = 0
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 5: Commit**

```bash
git add core/sim.gd tests/core/test_bullet_hits.gd
git commit -m "feat: bullet hits on terrain, tanks and the base"
```

---

### Task 12: Lives, respawning and player upgrades

**Files:**
- Modify: `core/sim.gd` (`_on_player_destroyed`, respawning in `_update_players`)
- Test: `tests/core/test_player_lives.gd`

**Interfaces:**
- Consumes: `SimConfig.start_lives`, `SimConfig.respawn_shield_ticks`
- Produces: `SimConfig.respawn_delay_ticks` (a new field, 60); in `GameSim` — `_update_respawns()`, called at the start of `_update_players`.

- [x] **Step 1: Write the failing tests**

`tests/core/test_player_lives.gd`:

```gdscript
extends GutTest

var sim: GameSim
var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()
	sim = GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 1)

func _kill_player() -> void:
	var t: Entities.Tank = sim.get_state().player_tanks()[0]
	t.shield_ticks = 0
	t.health = 0
	t.alive = false
	sim._on_player_destroyed(t)

func test_death_costs_a_life_and_resets_stars() -> void:
	var s := sim.get_state()
	s.players[0].stars = 3
	_kill_player()
	sim.tick([0, 0])
	assert_eq(s.players[0].lives, cfg.start_lives - 1)
	assert_eq(s.players[0].stars, 0, "upgrades reset — as in the original")

func test_player_respawns_after_the_delay() -> void:
	var s := sim.get_state()
	_kill_player()
	sim.tick([0, 0])
	assert_eq(s.player_tanks().size(), 0, "right after the death there is no tank on the field")
	for i in cfg.respawn_delay_ticks:
		sim.tick([0, 0])
	assert_eq(s.player_tanks().size(), 1, "after respawn_delay_ticks the player comes back")
	var t: Entities.Tank = s.player_tanks()[0]
	assert_eq(t.pos, Consts.tile_to_unit(Consts.PLAYER_SPAWN_TILES[0]))
	assert_eq(t.shield_ticks, cfg.respawn_shield_ticks, "respawning gives a short shield")
	assert_eq(t.stars, 0)

func test_last_life_ends_the_game() -> void:
	var s := sim.get_state()
	s.players[0].lives = 1
	_kill_player()
	sim.tick([0, 0])
	assert_eq(s.players[0].lives, 0)
	for i in cfg.respawn_delay_ticks + 2:
		sim.tick([0, 0])
	assert_eq(s.player_tanks().size(), 0, "there is nothing left to respawn as")
	assert_true(s.game_over)

func test_second_player_keeps_playing_while_the_first_is_out() -> void:
	var two := GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 2)
	var s := two.get_state()
	s.players[0].lives = 1
	var t: Entities.Tank = s.player_tanks()[0]
	t.alive = false
	two._on_player_destroyed(t)
	for i in cfg.respawn_delay_ticks + 2:
		two.tick([0, 0])
	assert_false(s.game_over, "while the second player lives, the game continues")
	assert_eq(s.player_tanks().size(), 1)

func test_respawned_tank_carries_the_current_star_level() -> void:
	var s := sim.get_state()
	_kill_player()
	sim.tick([0, 0])
	s.players[0].stars = 2      # say, a star was picked up while waiting to respawn
	for i in cfg.respawn_delay_ticks:
		sim.tick([0, 0])
	assert_eq(s.player_tanks()[0].stars, 2)
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — `respawn_delay_ticks` does not exist and the player does not respawn.

- [x] **Step 3: Add the field to `core/sim_config.gd`**

```gdscript
var respawn_delay_ticks := 60    ## the pause between death and returning to the field
```

- [x] **Step 4: Replace `_on_player_destroyed` and extend `_update_players` in `core/sim.gd`**

```gdscript
func _on_player_destroyed(t) -> void:
	var p: Entities.PlayerState = _state.players[t.player_index]
	p.tank_id = -1
	p.stars = 0
	p.lives -= 1
	if p.lives > 0:
		p.respawn_timer = _config.respawn_delay_ticks

func _update_respawns() -> void:
	for p in _state.players:
		if not p.active or p.tank_id != -1 or p.respawn_timer <= 0:
			continue
		p.respawn_timer -= 1
		if p.respawn_timer == 0:
			_spawn_player(p.index)
```

And as the first line of `_update_players`:

```gdscript
func _update_players(inputs: Array) -> void:
	_update_respawns()
	for p in _state.players:
		if p.tank_id == -1:
			continue
		var t := _state.find_tank(p.tank_id)
		if t == null or not t.alive or t.stun_ticks > 0:
			continue
		var bits: int = inputs[p.index] if p.index < inputs.size() else 0
		_control_tank(t, bits)
```

- [x] **Step 5: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 6: Commit**

```bash
git add core/sim.gd core/sim_config.gd tests/core/test_player_lives.gd
git commit -m "feat: lives, respawning with a shield and the upgrade reset on death"
```

---

### Task 13: The enemy wave spawner

**Files:**
- Modify: `core/sim.gd` (`_update_spawner`)
- Test: `tests/core/test_spawner.gd`

**Interfaces:**
- Consumes: `Consts.ENEMY_SPAWN_TILES`, `SimConfig.spawn_*`, `Rng`
- Produces: in `GameSim` — `_update_spawner()`, `_spawn_point_blocked(pos: Vector2i) -> bool`, `_spawn_enemy(type: int, pos: Vector2i) -> Entities.Tank`

- [x] **Step 1: Write the failing tests**

`tests/core/test_spawner.gd`:

```gdscript
extends GutTest

var sim: GameSim
var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()
	sim = GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 1)

func _s() -> WorldState:
	return sim.get_state()

## Places an already materialized enemy away from the spawn points.
func _park_enemy(pos: Vector2i) -> Entities.Tank:
	var t := Entities.Tank.new()
	t.id = _s().next_id()
	t.type = Types.TankType.BASIC
	t.player_index = -1
	t.pos = pos
	t.speed = cfg.enemy_speed(Types.TankType.BASIC)
	t.health = 1
	t.alive = true
	_s().tanks.append(t)
	return t

func test_first_enemy_appears_immediately_at_the_first_point() -> void:
	sim.tick([0, 0])
	var enemies := _s().enemy_tanks()
	assert_eq(enemies.size(), 1)
	assert_eq(enemies[0].pos, Consts.tile_to_unit(Consts.ENEMY_SPAWN_TILES[0]))

func test_new_enemy_blinks_before_it_becomes_real() -> void:
	sim.tick([0, 0])
	var e: Entities.Tank = _s().enemy_tanks()[0]
	assert_eq(e.spawn_ticks, cfg.spawn_blink_ticks)
	assert_false(e.is_materialized(), "while it blinks it does not physically exist")
	for i in cfg.spawn_blink_ticks:
		sim.tick([0, 0])
	assert_true(e.is_materialized())

func test_spawn_event_is_emitted() -> void:
	sim.tick([0, 0])
	var types: Array[int] = []
	for ev in sim.drain_events():
		types.append(ev.type)
	assert_has(types, Types.Event.ENEMY_SPAWNED)

func test_spawn_points_rotate() -> void:
	var positions: Array[Vector2i] = []
	for i in 4:
		_s().spawn_timer = 0
		sim.tick([0, 0])
		for t in _s().enemy_tanks():
			positions.append(t.pos)
			t.alive = false
	assert_eq(positions.size(), 4)
	assert_eq(positions[0], Consts.tile_to_unit(Consts.ENEMY_SPAWN_TILES[0]))
	assert_eq(positions[1], Consts.tile_to_unit(Consts.ENEMY_SPAWN_TILES[1]))
	assert_eq(positions[2], Consts.tile_to_unit(Consts.ENEMY_SPAWN_TILES[2]))
	assert_eq(positions[3], Consts.tile_to_unit(Consts.ENEMY_SPAWN_TILES[0]), "in rotation")

func test_interval_between_spawns_is_respected() -> void:
	sim.tick([0, 0])
	for t in _s().enemy_tanks():
		t.alive = false
	for i in cfg.spawn_interval_ticks:
		sim.tick([0, 0])
	assert_eq(_s().enemy_tanks().size(), 0, "nobody appears ahead of time")
	sim.tick([0, 0])
	assert_eq(_s().enemy_tanks().size(), 1, "the spawn happens on the tick where the timer has already reached zero")

func test_field_limit_is_not_exceeded() -> void:
	for i in cfg.max_enemies_alive:
		_park_enemy(Vector2i(Consts.TILE * (i + 2), Consts.TILE * 5))
	_s().spawn_timer = 0
	sim.tick([0, 0])
	assert_eq(_s().enemy_tanks().size(), cfg.max_enemies_alive, "a fifth one does not appear")

func test_spawn_resumes_when_a_slot_frees_up() -> void:
	var parked: Array = []
	for i in cfg.max_enemies_alive:
		parked.append(_park_enemy(Vector2i(Consts.TILE * (i + 2), Consts.TILE * 5)))
	_s().spawn_timer = 0
	sim.tick([0, 0])
	parked[0].alive = false
	_s().spawn_timer = 0
	sim.tick([0, 0])
	assert_eq(_s().enemy_tanks().size(), cfg.max_enemies_alive, "a slot freed up — a new one appeared")

func test_occupied_spawn_point_postpones_the_spawn() -> void:
	_park_enemy(Consts.tile_to_unit(Consts.ENEMY_SPAWN_TILES[0]))
	_s().spawn_timer = 0
	sim.tick([0, 0])
	assert_eq(_s().enemy_tanks().size(), 1, "nobody appears on an occupied point")

func test_all_twenty_enemies_eventually_spawn() -> void:
	var spawned := 0
	for i in 5000:
		sim.tick([0, 0])
		for t in _s().enemy_tanks():
			t.alive = false
			spawned += 1
		_s().spawn_timer = 0
		if _s().enemy_queue.is_empty():
			break
	assert_eq(spawned, 20, "there are exactly twenty enemies in a wave")
	assert_true(_s().enemy_queue.is_empty())

func test_marked_enemies_carry_a_bonus() -> void:
	# The fixture marks the enemies with indices 3, 10 and 17.
	var flags: Array[bool] = []
	for i in 4:
		_s().spawn_timer = 0
		sim.tick([0, 0])
		for t in _s().enemy_tanks():
			flags.append(t.drops_bonus)
			t.alive = false
	assert_false(flags[0])
	assert_false(flags[1])
	assert_false(flags[2])
	assert_true(flags[3], "the fourth enemy by count is marked as carrying a power-up")
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — the enemies do not appear.

- [x] **Step 3: Replace `_update_spawner` in `core/sim.gd`**

```gdscript
func _update_spawner() -> void:
	if _state.enemy_queue.is_empty():
		return
	if _state.spawn_timer > 0:
		_state.spawn_timer -= 1
		return
	if _state.alive_enemy_count() >= _config.max_enemies_alive:
		return

	var pos: Vector2i = Consts.tile_to_unit(Consts.ENEMY_SPAWN_TILES[_state.spawn_point_index])
	if _spawn_point_blocked(pos):
		return

	var type: int = _state.enemy_queue.pop_front()
	_spawn_enemy(type, pos)
	_state.spawn_point_index = (_state.spawn_point_index + 1) % Consts.ENEMY_SPAWN_TILES.size()
	_state.spawn_timer = _config.spawn_interval_ticks

func _spawn_point_blocked(pos: Vector2i) -> bool:
	for t in _state.tanks:
		if t.is_materialized() and Movement.overlaps(pos, Consts.TANK, t.pos, Consts.TANK):
			return true
	return false

func _spawn_enemy(type: int, pos: Vector2i) -> Entities.Tank:
	var t := Entities.Tank.new()
	t.id = _state.next_id()
	t.type = type
	t.player_index = -1
	t.pos = pos
	t.dir = Types.Dir.DOWN
	t.speed = _config.enemy_speed(type)
	t.health = _config.enemy_health(type)
	t.spawn_ticks = _config.spawn_blink_ticks
	t.drops_bonus = _bonus_indices.has(_spawned_count)
	# The AI timers come from the shared generator — otherwise the behaviour stops being reproducible.
	t.ai_dir_timer = _rng.next_range(_config.ai_dir_change_min, _config.ai_dir_change_max)
	t.ai_fire_timer = _rng.next_range(_config.ai_fire_min, _config.ai_fire_max)
	t.ai_target_is_base = _rng.chance(_config.ai_base_target_chance)
	_state.tanks.append(t)
	_spawned_count += 1
	_emit(Types.Event.ENEMY_SPAWNED, pos, type)
	return t
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 5: Commit**

```bash
git add core/sim.gd tests/core/test_spawner.gd
git commit -m "feat: enemy wave spawner with blinking and an on-field limit"
```

---

### Task 14: Enemy tank behaviour

**Files:**
- Modify: `core/sim.gd` (`_update_enemies`)
- Test: `tests/core/test_ai.gd`

**Interfaces:**
- Consumes: `Movement`, `Rng`, `SimConfig.ai_*`
- Produces: in `GameSim` — `_update_enemies()`, `_update_enemy(tank)`, `_choose_enemy_direction(tank)`, `_direction_toward(tank, target: Vector2i, options: Array[int]) -> int`, `_enemy_target_point(tank) -> Vector2i`, `_enemy_sees_target(tank) -> bool`

The AI is deliberately simple: in the original it is a bit dim, and that is part of the charm. There is no need to make it smarter — the game would stop being that game.

- [x] **Step 1: Write the failing tests**

`tests/core/test_ai.gd`:

```gdscript
extends GutTest

var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()

func _sim_with_enemy(pos: Vector2i, dir := Types.Dir.DOWN) -> Array:
	var sim := GameSim.new(LevelFixture.empty_level(), 5, cfg, 1, 1)
	var t := Entities.Tank.new()
	t.id = sim.get_state().next_id()
	t.type = Types.TankType.BASIC
	t.player_index = -1
	t.pos = pos
	t.dir = dir
	t.speed = cfg.enemy_speed(Types.TankType.BASIC)
	t.health = 1
	t.alive = true
	t.ai_dir_timer = 999
	t.ai_fire_timer = 999
	sim.get_state().tanks.append(t)
	return [sim, t]

func test_enemy_drives_in_its_direction() -> void:
	var pair := _sim_with_enemy(Vector2i(Consts.TILE * 3, Consts.TILE * 3))
	var sim: GameSim = pair[0]
	var t: Entities.Tank = pair[1]
	var start := t.pos
	sim.tick([0, 0])
	assert_eq(t.pos, start + Vector2i(0, cfg.enemy_speed(Types.TankType.BASIC)))

func test_frozen_enemies_do_not_move_or_shoot() -> void:
	var pair := _sim_with_enemy(Vector2i(Consts.TILE * 3, Consts.TILE * 3))
	var sim: GameSim = pair[0]
	var t: Entities.Tank = pair[1]
	sim.get_state().freeze_ticks = 100
	var start := t.pos
	sim.tick([0, 0])
	assert_eq(t.pos, start, "the clock stops the enemies")
	assert_eq(sim.get_state().bullets.size(), 0)

func test_stuck_enemy_changes_direction() -> void:
	var pair := _sim_with_enemy(Vector2i(0, 0), Types.Dir.UP)
	var sim: GameSim = pair[0]
	var t: Entities.Tank = pair[1]
	sim.tick([0, 0])
	assert_ne(t.dir, Types.Dir.UP, "having run into the edge, an enemy must turn")

func test_enemy_shoots_when_it_sees_the_base() -> void:
	# We put an enemy directly above the base, barrel down, with a clear corridor.
	var sim := GameSim.new(LevelFixture.empty_level(), 5, cfg, 1, 1)
	for c in Consts.BASE_WALL_CELLS:
		sim.get_state().terrain.set_cell(c.x, c.y, Types.Cell.EMPTY)
	var t := Entities.Tank.new()
	t.id = sim.get_state().next_id()
	t.type = Types.TankType.BASIC
	t.player_index = -1
	t.pos = Consts.tile_to_unit(Vector2i(Consts.BASE_TILE.x, 6))
	t.dir = Types.Dir.DOWN
	# The speed must be real: a motionless tank looks stuck every tick,
	# which means it changes direction — and the line of fire drifts away.
	t.speed = cfg.enemy_speed(Types.TankType.BASIC)
	t.health = 1
	t.alive = true
	t.ai_dir_timer = 999
	t.ai_fire_timer = 999
	sim.get_state().tanks.append(t)

	sim.tick([0, 0])
	assert_gt(sim.get_state().bullets.size(), 0, "it sees the eagle — it fires without waiting for the timer")

func test_enemy_does_not_shoot_through_steel() -> void:
	var sim := GameSim.new(LevelFixture.empty_level(), 5, cfg, 1, 1)
	for c in Consts.BASE_WALL_CELLS:
		sim.get_state().terrain.set_cell(c.x, c.y, Types.Cell.EMPTY)
	for cx in range(11, 15):
		sim.get_state().terrain.set_cell(cx, 20, Types.Cell.STEEL)
	var t := Entities.Tank.new()
	t.id = sim.get_state().next_id()
	t.type = Types.TankType.BASIC
	t.player_index = -1
	t.pos = Consts.tile_to_unit(Vector2i(Consts.BASE_TILE.x, 6))
	t.dir = Types.Dir.DOWN
	# The speed must be real: a motionless tank looks stuck every tick,
	# which means it changes direction — and the line of fire drifts away.
	t.speed = cfg.enemy_speed(Types.TankType.BASIC)
	t.health = 1
	t.alive = true
	t.ai_dir_timer = 999
	t.ai_fire_timer = 999
	sim.get_state().tanks.append(t)

	sim.tick([0, 0])
	assert_eq(sim.get_state().bullets.size(), 0, "steel blocks the line of fire")

func test_enemy_respects_the_bullet_limit() -> void:
	var pair := _sim_with_enemy(Vector2i(Consts.TILE * 3, Consts.TILE * 3))
	var sim: GameSim = pair[0]
	var t: Entities.Tank = pair[1]
	t.ai_fire_timer = 0
	for i in 5:
		sim.tick([0, 0])
	var own := 0
	for b in sim.get_state().bullets:
		if b.owner_id == t.id:
			own += 1
	assert_lte(own, 1, "an ordinary enemy has only one bullet in flight")

func test_same_seed_gives_identical_ai_behaviour() -> void:
	var a := GameSim.new(LevelFixture.empty_level(), 31337, cfg, 1, 1)
	var b := GameSim.new(LevelFixture.empty_level(), 31337, cfg, 1, 1)
	for i in 600:
		a.tick([0, 0])
		b.tick([0, 0])
	assert_eq(a.state_hash(), b.state_hash(), "the AI must be reproducible")

func test_different_seeds_diverge() -> void:
	var a := GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 1)
	var b := GameSim.new(LevelFixture.empty_level(), 2, cfg, 1, 1)
	for i in 600:
		a.tick([0, 0])
		b.tick([0, 0])
	assert_ne(a.state_hash(), b.state_hash(), "different seeds must give different matches")
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — the enemies stand still.

- [x] **Step 3: Replace `_update_enemies` in `core/sim.gd`**

```gdscript
func _update_enemies() -> void:
	if _state.freeze_ticks > 0:
		return
	for t in _state.tanks:
		if t.player_index >= 0 or not t.is_materialized() or t.stun_ticks > 0:
			continue
		_update_enemy(t)

func _update_enemy(t) -> void:
	if t.ai_dir_timer > 0:
		t.ai_dir_timer -= 1
	if t.ai_fire_timer > 0:
		t.ai_fire_timer -= 1

	var before: Vector2i = t.pos
	_drive(t, t.dir)
	var stuck: bool = t.pos == before

	if t.ai_dir_timer == 0 or stuck:
		_choose_enemy_direction(t)
		t.ai_dir_timer = _rng.next_range(_config.ai_dir_change_min, _config.ai_dir_change_max)

	if t.ai_fire_timer == 0 or _enemy_sees_target(t):
		_try_fire(t)
		t.ai_fire_timer = _rng.next_range(_config.ai_fire_min, _config.ai_fire_max)

func _choose_enemy_direction(t) -> void:
	var options: Array[int] = []
	for d in 4:
		if Movement.can_occupy(_state, t, t.pos + Types.DIR_VEC[d]):
			options.append(d)
	if options.is_empty():
		return

	if _rng.chance(_config.ai_target_chance_for_level(_state.level)):
		t.ai_target_is_base = _rng.chance(_config.ai_base_target_chance)
		var toward := _direction_toward(t, _enemy_target_point(t), options)
		if toward >= 0:
			Movement.turn(_state, t, toward)
			return
	Movement.turn(_state, t, options[_rng.next_range(0, options.size())])

## Of the available directions it picks the one that shortens the Manhattan
## distance to the target the most. On a tie the lower direction index wins —
## the loop goes in order, and that makes the choice reproducible.
func _direction_toward(t, target: Vector2i, options: Array[int]) -> int:
	var best := -1
	var best_dist := 0
	var here: Vector2i = t.center()
	for d in options:
		var probe: Vector2i = here + Types.DIR_VEC[d] * Consts.CELL
		var dist: int = absi(probe.x - target.x) + absi(probe.y - target.y)
		if best < 0 or dist < best_dist:
			best = d
			best_dist = dist
	return best

func _enemy_target_point(t) -> Vector2i:
	var players := _state.player_tanks()
	if t.ai_target_is_base or players.is_empty():
		return Consts.tile_to_unit(Consts.BASE_TILE) + Vector2i(Consts.TILE / 2, Consts.TILE / 2)
	var nearest = null
	var best := 0
	for p in players:
		var d: int = absi(p.center().x - t.center().x) + absi(p.center().y - t.center().y)
		if nearest == null or d < best:
			nearest = p
			best = d
	return nearest.center()

## A ray over the cells along the barrel up to the first block a bullet cannot pass.
func _enemy_sees_target(t) -> bool:
	var delta: Vector2i = Types.DIR_VEC[t.dir]
	var probe: Vector2i = t.center()
	var base_pos: Vector2i = Consts.tile_to_unit(Consts.BASE_TILE)
	for i in Consts.GRID * 2:
		probe += delta * Consts.CELL
		if probe.x < 0 or probe.y < 0 or probe.x >= Consts.FIELD or probe.y >= Consts.FIELD:
			return false
		var c: Vector2i = _state.terrain.cell_at_unit(probe)
		if _state.terrain.blocks_bullet(c.x, c.y):
			return false
		if _state.base_alive and Movement.overlaps(probe, 1, base_pos, Consts.TILE):
			return true
		for p in _state.player_tanks():
			if p.is_materialized() and Movement.overlaps(probe, 1, p.pos, Consts.TANK):
				return true
	return false
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 5: Commit**

```bash
git add core/sim.gd tests/core/test_ai.gd
git commit -m "feat: enemy tank behaviour — direction changes, aiming and firing"
```

---

### Task 15: Power-ups

**Files:**
- Modify: `core/sim.gd` (`_update_bonus`, `_on_enemy_destroyed`)
- Test: `tests/core/test_bonuses.gd`

**Interfaces:**
- Consumes: `Types.BonusType`, the `SimConfig` power-up timers
- Produces: in `GameSim` — `_spawn_bonus()`, `_random_bonus_tile() -> Vector2i`, `_update_bonus()`, `_apply_bonus(bonus, tank)`, `_destroy_all_enemies()`

- [x] **Step 1: Write the failing tests**

`tests/core/test_bonuses.gd`:

```gdscript
extends GutTest

var sim: GameSim
var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()
	sim = GameSim.new(LevelFixture.empty_level(), 9, cfg, 1, 1)

func _s() -> WorldState:
	return sim.get_state()

func _player() -> Entities.Tank:
	return _s().player_tanks()[0]

## Puts a power-up of the required type right under the player's tracks.
func _put_bonus_under_player(type: int) -> Entities.Bonus:
	var b := Entities.Bonus.new()
	b.type = type
	b.pos = _player().pos
	b.ticks_left = cfg.bonus_life_ticks
	b.active = true
	_s().bonus = b
	return b

func _add_enemy(pos: Vector2i, materialized := true) -> Entities.Tank:
	var t := Entities.Tank.new()
	t.id = _s().next_id()
	t.type = Types.TankType.BASIC
	t.player_index = -1
	t.pos = pos
	t.speed = 0
	t.health = 1
	t.alive = true
	t.spawn_ticks = 0 if materialized else 30
	_s().tanks.append(t)
	return t

func test_marked_enemy_drops_a_bonus() -> void:
	var enemy := _add_enemy(Vector2i(Consts.TILE * 3, Consts.TILE * 3))
	enemy.drops_bonus = true
	enemy.alive = false
	sim._on_enemy_destroyed(enemy, null)
	assert_not_null(_s().bonus)
	assert_true(_s().bonus.active)

func test_unmarked_enemy_drops_nothing() -> void:
	var enemy := _add_enemy(Vector2i(Consts.TILE * 3, Consts.TILE * 3))
	enemy.alive = false
	sim._on_enemy_destroyed(enemy, null)
	assert_null(_s().bonus)

func test_bonus_expires() -> void:
	var b := _put_bonus_under_player(Types.BonusType.STAR)
	b.pos = Vector2i(Consts.TILE * 2, Consts.TILE * 2)   # away from the player
	for i in cfg.bonus_life_ticks:
		sim.tick([0, 0])
	assert_null(_s().bonus, "the power-up disappears by itself")

func test_new_bonus_replaces_the_old_one() -> void:
	_put_bonus_under_player(Types.BonusType.STAR)
	var enemy := _add_enemy(Vector2i(Consts.TILE * 3, Consts.TILE * 3))
	enemy.drops_bonus = true
	enemy.alive = false
	sim._on_enemy_destroyed(enemy, null)
	assert_eq(_s().bonus.ticks_left, cfg.bonus_life_ticks, "only one power-up lies on the field")

func test_pickup_scores_and_emits_event() -> void:
	_put_bonus_under_player(Types.BonusType.STAR)
	sim.tick([0, 0])
	assert_null(_s().bonus)
	assert_eq(_s().players[0].score, cfg.bonus_score)
	var types: Array[int] = []
	for e in sim.drain_events():
		types.append(e.type)
	assert_has(types, Types.Event.BONUS_TAKEN)

func test_helmet_gives_a_shield() -> void:
	_put_bonus_under_player(Types.BonusType.HELMET)
	sim.tick([0, 0])
	assert_eq(_player().shield_ticks, cfg.shield_ticks)

func test_clock_freezes_enemies() -> void:
	var enemy := _add_enemy(Vector2i(Consts.TILE * 3, Consts.TILE * 3))
	enemy.speed = cfg.enemy_speed(Types.TankType.BASIC)
	_put_bonus_under_player(Types.BonusType.CLOCK)
	sim.tick([0, 0])
	assert_eq(_s().freeze_ticks, cfg.freeze_ticks)
	var pos := enemy.pos
	sim.tick([0, 0])
	assert_eq(enemy.pos, pos, "a frozen enemy stands still")

func test_shovel_turns_the_base_wall_to_steel_and_back() -> void:
	_put_bonus_under_player(Types.BonusType.SHOVEL)
	sim.tick([0, 0])
	for c in Consts.BASE_WALL_CELLS:
		assert_eq(_s().terrain.get_cell(c.x, c.y), Types.Cell.STEEL)
	for i in cfg.shovel_ticks:
		sim.tick([0, 0])
	for c in Consts.BASE_WALL_CELLS:
		assert_eq(_s().terrain.get_cell(c.x, c.y), Types.Cell.BRICK, "the shovel runs out")

func test_star_upgrades_and_caps_at_three() -> void:
	for expected in [1, 2, 3, 3]:
		_put_bonus_under_player(Types.BonusType.STAR)
		sim.tick([0, 0])
		assert_eq(_s().players[0].stars, expected)
		assert_eq(_player().stars, expected, "a tank on the field gets the upgrade at once")

func test_grenade_wipes_the_field_but_spares_blinking_enemies() -> void:
	var solid := _add_enemy(Vector2i(Consts.TILE * 3, Consts.TILE * 3))
	var blinking := _add_enemy(Vector2i(Consts.TILE * 6, Consts.TILE * 3), false)
	_put_bonus_under_player(Types.BonusType.GRENADE)
	sim.tick([0, 0])
	assert_false(solid.alive, "a materialized enemy dies")
	assert_true(blinking.alive, "the grenade does not touch one that is still blinking")

func test_grenade_gives_no_score_for_the_wiped_enemies() -> void:
	_add_enemy(Vector2i(Consts.TILE * 3, Consts.TILE * 3))
	_put_bonus_under_player(Types.BonusType.GRENADE)
	sim.tick([0, 0])
	assert_eq(_s().players[0].score, cfg.bonus_score, "only 500 for the power-up itself")

func test_tank_bonus_adds_a_life() -> void:
	var before := _s().players[0].lives
	_put_bonus_under_player(Types.BonusType.TANK)
	sim.tick([0, 0])
	assert_eq(_s().players[0].lives, before + 1)
```

- [x] **Step 2: Run it and make sure it fails**

Run: `./tools/test.sh`
Expected: FAIL — power-ups neither appear nor get picked up.

- [x] **Step 3: Add to `core/sim.gd`**

At the start of `_on_enemy_destroyed`, before awarding the points:

```gdscript
func _on_enemy_destroyed(t, b) -> void:
	_state.enemies_left -= 1
	if t.drops_bonus:
		_spawn_bonus()
	if b == null or not b.owner_is_player:
		return
	var owner = _state.find_tank(b.owner_id)
	if owner == null or owner.player_index < 0:
		return
	var p: Entities.PlayerState = _state.players[owner.player_index]
	p.score += _config.enemy_score(t.type)
	p.kills[t.type - Types.TankType.BASIC] += 1
```

And the new methods:

```gdscript
func _spawn_bonus() -> void:
	var b := Entities.Bonus.new()
	b.type = _rng.next_range(0, Types.BonusType.size())
	b.pos = Consts.tile_to_unit(_random_bonus_tile())
	b.ticks_left = _config.bonus_life_ticks
	b.active = true
	_state.bonus = b     # there is never more than one power-up on the field
	_emit(Types.Event.BONUS_SPAWNED, b.pos, b.type)

func _random_bonus_tile() -> Vector2i:
	var tiles_per_side := Consts.GRID / 2
	for attempt in 32:
		var tile := Vector2i(_rng.next_range(0, tiles_per_side), _rng.next_range(0, tiles_per_side))
		if tile != Consts.BASE_TILE:
			return tile
	return Vector2i(0, 0)

func _update_bonus() -> void:
	var b = _state.bonus
	if b == null or not b.active:
		return
	b.ticks_left -= 1
	if b.ticks_left <= 0:
		b.active = false
		_state.bonus = null
		return
	for t in _state.player_tanks():
		if not t.is_materialized():
			continue
		if Movement.overlaps(t.pos, Consts.TANK, b.pos, Consts.TILE):
			_apply_bonus(b, t)
			b.active = false
			_state.bonus = null
			return

func _apply_bonus(b, t) -> void:
	var p: Entities.PlayerState = _state.players[t.player_index]
	p.score += _config.bonus_score
	_emit(Types.Event.BONUS_TAKEN, b.pos, b.type)
	match b.type:
		Types.BonusType.HELMET:
			t.shield_ticks = _config.shield_ticks
		Types.BonusType.CLOCK:
			_state.freeze_ticks = _config.freeze_ticks
		Types.BonusType.SHOVEL:
			for c in Consts.BASE_WALL_CELLS:
				_state.terrain.set_cell(c.x, c.y, Types.Cell.STEEL)
			_state.shovel_ticks = _config.shovel_ticks
		Types.BonusType.STAR:
			p.stars = mini(p.stars + 1, 3)
			t.stars = p.stars
		Types.BonusType.GRENADE:
			_destroy_all_enemies()
		Types.BonusType.TANK:
			p.lives += 1

## The grenade does not touch those still blinking: they are not physically on the field yet.
func _destroy_all_enemies() -> void:
	for t in _state.tanks:
		if t.player_index >= 0 or not t.is_materialized():
			continue
		t.alive = false
		_emit(Types.Event.TANK_DESTROYED, t.pos, t.type)
		_on_enemy_destroyed(t, null)
```

- [x] **Step 4: Run it and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 5: Commit**

```bash
git add core/sim.gd tests/core/test_bonuses.gd
git commit -m "feat: six power-ups — appearance, pickup and effects"
```

---

### Task 16: Determinism and the regression reference

**Files:**
- Test: `tests/core/test_determinism.gd`
- Test: `tests/core/test_regression.gd`

**Interfaces:**
- Consumes: `GameSim.state_hash()`, `Rng`
- Produces: nothing for production code — this is a safety net for every subsequent change and for the network co-op from subproject 3.

- [x] **Step 1: Write the determinism test**

`tests/core/test_determinism.gd`:

```gdscript
extends GutTest

const TICKS := 10000

## The input scenario is built with the same generator as everything else:
## a random but reproducible stream of presses for both players.
func _script(seed_value: int, count: int) -> Array:
	var r := Rng.new(seed_value)
	var frames: Array = []
	for i in count:
		frames.append([r.next_range(0, 32), r.next_range(0, 32)])
	return frames

func _level() -> LevelData:
	var cells := {}
	for cx in range(4, 22):
		cells[Vector2i(cx, 8)] = Types.Cell.BRICK
	for cx in range(6, 20):
		cells[Vector2i(cx, 14)] = Types.Cell.STEEL
	for cx in range(2, 8):
		cells[Vector2i(cx, 18)] = Types.Cell.WATER
	for cx in range(18, 24):
		cells[Vector2i(cx, 18)] = Types.Cell.ICE
	return LevelFixture.level_with(cells)

func test_two_sims_stay_in_lockstep_for_ten_thousand_ticks() -> void:
	var frames := _script(4242, TICKS)
	var a := GameSim.new(_level(), 777, SimConfig.new(), 3, 2)
	var b := GameSim.new(_level(), 777, SimConfig.new(), 3, 2)
	for i in frames.size():
		a.tick(frames[i])
		b.tick(frames[i])
		if a.state_hash() != b.state_hash():
			fail_test("desync on tick %d" % i)
			return
	assert_eq(a.state_hash(), b.state_hash(), "ten thousand ticks without a single divergence")

func test_different_input_gives_different_outcome() -> void:
	var a := GameSim.new(_level(), 777, SimConfig.new(), 3, 2)
	var b := GameSim.new(_level(), 777, SimConfig.new(), 3, 2)
	var fa := _script(1, 600)
	var fb := _script(2, 600)
	for i in 600:
		a.tick(fa[i])
		b.tick(fb[i])
	assert_ne(a.state_hash(), b.state_hash(), "different input must give a different outcome")
```

- [x] **Step 2: Run the determinism test**

Run: `./tools/test.sh`
Expected: PASS. A run of ten thousand ticks takes a few seconds — that is normal.

If the test fails, **do not massage the hash**: a divergence means non-determinism in the logic. Look for a `float`, a call to `randi()`/`randf()`, dictionary iteration on a hot path, or a dependency on an order that can change.

- [x] **Step 3: Write the regression test with an empty reference**

`tests/core/test_regression.gd`:

```gdscript
extends GutTest

## The reference run. The GOLDEN value was obtained by a single run and fixed:
## if it has changed, then the game's behaviour has changed.
## That is no reason to edit the number — it is a reason to find out which rule moved.
const GOLDEN := 0

const TICKS := 3000

func _frames() -> Array:
	var r := Rng.new(20260825)
	var out: Array = []
	for i in TICKS:
		out.append([r.next_range(0, 32), r.next_range(0, 32)])
	return out

func _run() -> int:
	var cells := {}
	for cx in range(4, 22):
		cells[Vector2i(cx, 10)] = Types.Cell.BRICK
	for cx in range(8, 18):
		cells[Vector2i(cx, 16)] = Types.Cell.STEEL
	var sim := GameSim.new(LevelFixture.level_with(cells), 2718, SimConfig.new(), 5, 2)
	var frames := _frames()
	for i in TICKS:
		sim.tick(frames[i])
	return sim.state_hash()

func test_recorded_run_still_produces_the_same_state() -> void:
	var actual := _run()
	assert_eq(actual, GOLDEN, "reference diverged; actual hash: %d" % actual)
```

- [x] **Step 4: Run it, take the actual hash and put it into the reference**

Run: `./tools/test.sh`
Expected: FAIL with a message like `reference diverged; actual hash: 1234567890`.

Take the number from the message and put it into `const GOLDEN := ...`.

- [x] **Step 5: Run it again and make sure it passes**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 6: Commit**

```bash
git add tests/core/test_determinism.gd tests/core/test_regression.gd
git commit -m "test: determinism over 10000 ticks and the regression reference"
```

---

### Task 17: Thirty-five levels and the loader

**Files:**
- Create: `platform/level_loader.gd`
- Create: `tools/gen_levels.py`
- Create: `levels/01.lvl` … `levels/35.lvl`
- Test: `tests/levels/test_levels.gd`

**Interfaces:**
- Consumes: `LevelData.parse`
- Produces: `LevelLoader.load_level(number: int) -> LevelData`, `LevelLoader.level_count() -> int`

The layouts are our own. The original's logic is respected — a simple symmetric first level, then a growing share of steel and water, corridor and labyrinth maps alternating, the base always covered — but the maps are not copied: what goes to the store is our game, and levels copied one for one cannot be defended.

- [x] **Step 1: Write the loader**

`platform/level_loader.gd`:

```gdscript
class_name LevelLoader

## Reading levels from disk lives outside the core: core/ must not know about FileAccess.

const LEVEL_DIR := "res://levels"
const LEVEL_COUNT := 35

static func level_count() -> int:
	return LEVEL_COUNT

static func load_level(number: int) -> LevelData:
	var path := "%s/%02d.lvl" % [LEVEL_DIR, number]
	if not FileAccess.file_exists(path):
		var missing := LevelData.new()
		missing.terrain = Terrain.new()
		missing.error = "level file not found: %s" % path
		return missing
	return LevelData.parse(FileAccess.get_file_as_string(path))
```

- [x] **Step 2: Write the layout generator**

`tools/gen_levels.py`:

```python
#!/usr/bin/env python3
"""A generator for 35 level layouts.

The original's logic but our own maps: the first level is simple and symmetric,
then the share of steel, water and ice grows and the wave gets heavier. Left-right
symmetry is what gives the recognisable look.

The result is the files levels/NN.lvl, which are then edited by hand.
The generator is deterministic: the same run gives the same maps.
"""
import os
import random

GRID = 26
TILES = GRID // 2
LEVELS = 35
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "levels")

EMPTY, BRICK, STEEL, WATER, TREES, ICE = ".", "#", "@", "~", "%", "-"

BASE_TILE = (6, 12)
BASE_CELLS = [(12, 24), (13, 24), (12, 25), (13, 25)]
BASE_WALL = [(11, 23), (12, 23), (13, 23), (14, 23),
             (11, 24), (14, 24), (11, 25), (14, 25)]
ENEMY_SPAWN_TILES = [(0, 0), (6, 0), (12, 0)]
PLAYER_SPAWN_TILES = [(4, 12), (8, 12)]


def reserved_cells():
    """Cells the generator does not touch: the spawn points, the corridors from them and the base."""
    cells = set()
    for tx, ty in ENEMY_SPAWN_TILES:
        for dy in range(6):          # the tile itself plus two tiles of corridor downward
            for dx in range(2):
                cells.add((tx * 2 + dx, ty * 2 + dy))
    for tx, ty in PLAYER_SPAWN_TILES:
        for dy in range(2):
            for dx in range(2):
                cells.add((tx * 2 + dx, ty * 2 + dy))
    cells.update(BASE_CELLS)
    cells.update(BASE_WALL)
    return cells


def put_tile(grid, tx, ty, ch, reserved):
    for dy in range(2):
        for dx in range(2):
            cx, cy = tx * 2 + dx, ty * 2 + dy
            if (cx, cy) in reserved:
                continue
            grid[cy][cx] = ch


def generate(level, rng):
    reserved = reserved_cells()
    grid = [[EMPTY] * GRID for _ in range(GRID)]

    counts = [
        (BRICK, 20 + level // 2),
        (STEEL, max(0, (level - 2) // 3)),
        (WATER, max(0, (level - 5) // 4)),
        (TREES, max(0, (level - 3) // 4)),
        (ICE, max(0, (level - 8) // 5)),
    ]

    for ch, count in counts:
        placed, guard = 0, 0
        while placed < count and guard < 4000:
            guard += 1
            tx = rng.randrange(0, (TILES + 1) // 2)
            ty = rng.randrange(1, TILES - 1)
            mirror = TILES - 1 - tx
            if (tx, ty) == BASE_TILE or (mirror, ty) == BASE_TILE:
                continue
            put_tile(grid, tx, ty, ch, reserved)
            put_tile(grid, mirror, ty, ch, reserved)
            placed += 2

    for cx, cy in BASE_WALL:
        grid[cy][cx] = BRICK
    for cx, cy in BASE_CELLS:
        grid[cy][cx] = EMPTY
    return grid


def enemy_queue(level, rng):
    """Toward the end of the game there are fewer basic tanks and more heavy and fast ones."""
    extra = min(14, (level * 14) // LEVELS)
    armor = extra // 3
    power = extra // 3
    fast = extra - armor - power
    queue = ["B"] * (20 - extra) + ["F"] * fast + ["P"] * power + ["A"] * armor
    rng.shuffle(queue)
    return "".join(queue)


def main():
    os.makedirs(OUT, exist_ok=True)
    for n in range(1, LEVELS + 1):
        rng = random.Random(1000 + n)
        grid = generate(n, rng)
        bonuses = sorted(rng.sample(range(20), 3))
        lines = [
            "enemies: " + enemy_queue(n, rng),
            "bonus: " + ",".join(str(b) for b in bonuses),
            "---",
        ]
        lines += ["".join(row) for row in grid]
        with open(os.path.join(OUT, "%02d.lvl" % n), "w") as handle:
            handle.write("\n".join(lines) + "\n")
    print("Generated %d levels in %s" % (LEVELS, OUT))


if __name__ == "__main__":
    main()
```

- [x] **Step 3: Generate the levels**

```bash
python3 tools/gen_levels.py
ls levels | head -5
head -4 levels/01.lvl
```

Expected: 35 files, and the first one has only `B` letters in its `enemies` line.

- [x] **Step 4: Write the level tests**

`tests/levels/test_levels.gd`:

```gdscript
extends GutTest

func _count_type(lvl: LevelData, type: int) -> int:
	var n := 0
	for t in lvl.enemy_queue:
		if t == type:
			n += 1
	return n

func test_all_levels_parse() -> void:
	for n in range(1, LevelLoader.level_count() + 1):
		var lvl := LevelLoader.load_level(n)
		assert_eq(lvl.error, "", "level %d: %s" % [n, lvl.error])

func test_spawn_points_are_clear() -> void:
	var tiles: Array[Vector2i] = []
	tiles.append_array(Consts.ENEMY_SPAWN_TILES)
	tiles.append_array(Consts.PLAYER_SPAWN_TILES)
	for n in range(1, LevelLoader.level_count() + 1):
		var lvl := LevelLoader.load_level(n)
		for tile in tiles:
			for dy in 2:
				for dx in 2:
					assert_eq(lvl.terrain.get_cell(tile.x * 2 + dx, tile.y * 2 + dy),
						Types.Cell.EMPTY,
					"level %d: spawn point %s is occupied by something" % [n, tile])

func test_levels_are_not_overcrowded() -> void:
	for n in range(1, LevelLoader.level_count() + 1):
		var lvl := LevelLoader.load_level(n)
		var empty := 0
		for cy in Consts.GRID:
			for cx in Consts.GRID:
				if lvl.terrain.get_cell(cx, cy) == Types.Cell.EMPTY:
					empty += 1
		assert_gt(empty, Consts.GRID * Consts.GRID * 2 / 5,
			"level %d is too crowded, there will be nowhere to play" % n)

func test_wave_gets_heavier() -> void:
	var first := LevelLoader.load_level(1)
	var last := LevelLoader.load_level(35)
	assert_eq(_count_type(first, Types.TankType.BASIC), 20,
		"the first level is basic tanks only")
	assert_lt(_count_type(last, Types.TankType.BASIC), 20,
		"toward the end of the game fast and heavy ones appear in the wave")

func test_every_level_survives_ten_seconds_of_simulation() -> void:
	for n in range(1, LevelLoader.level_count() + 1):
		var sim := GameSim.new(LevelLoader.load_level(n), 100 + n, SimConfig.new(), n, 1)
		for i in 600:
			sim.tick([0, 0])
		assert_eq(sim.get_state().tick, 600, "level %d did not count out the ticks" % n)
```

- [x] **Step 5: Run the tests**

Run: `./tools/test.sh`
Expected: all tests green.

- [x] **Step 6: Look the levels over with your eyes**

```bash
sed -n '4,29p' levels/01.lvl
sed -n '4,29p' levels/18.lvl
sed -n '4,29p' levels/35.lvl
```

The generator gives a basis, but an eye is needed: if a map looks like a boring mush or the way to the base has come out too easy, edit the file by hand — that is what the text format is for. The tests from step 4 remain the guarantee that an edit broke nothing.

- [x] **Step 7: Commit**

```bash
git add platform/level_loader.gd tools/gen_levels.py levels tests/levels/test_levels.gd
git commit -m "feat: thirty-five level layouts of our own and the loader"
```

---

## Readiness of part A

The core is considered ready when all of the following hold at once:

1. `./tools/test.sh` green in full, including the `core/` isolation check.
2. The determinism test passes 10,000 ticks with no divergence.
3. The regression reference is fixed and matches.
4. All 35 levels load, pass validation and survive 600 ticks of simulation.
5. There is neither a `float` nor an engine call in `core/`.

After this the part B plan is written: asset generation, rendering, sound, screens, keyboard and gamepad input, builds for Windows, macOS and Linux.
