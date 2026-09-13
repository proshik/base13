class_name Frames

## All atlas addressing in one place: otherwise frame numbers spread through the
## drawing code and a shifted layout has to be caught by eye.

const TANK_BLOCK := 8      ## 4 directions x 2 track frames
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
const SPRITE_HALF := 8     ## half of a 16x16 sprite, for centring decorations

const WATER_PERIOD := 30   ## half a second per frame: water ripples rather than flickers
const TRACK_STEP := 32     ## how many units of travel change the track frame
const FLASH_PERIOD := 8
const SHIELD_PERIOD := 4

static func tank(tank_type: int, stars: int, dir: int, track: int) -> int:
	var base := ENEMY_BASE + (tank_type - Types.TankType.BASIC) * TANK_BLOCK
	if tank_type == Types.TankType.PLAYER:
		base = PLAYER_BASE + clampi(stars, 0, MAX_STARS) * TANK_BLOCK
	return base + dir * 2 + track

## The track frame comes from position rather than time: a standing tank must
## not shuffle its tracks on the spot.
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
