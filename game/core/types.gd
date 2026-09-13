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
