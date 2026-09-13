class_name Movement

## Movement on a half-tile grid. It is the snap on turning that creates the
## feeling of slipping into gaps by itself; without it the rules are the same
## and the game feels like somebody else's.

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
	var before: Vector2i = tank.pos
	if new_dir == Types.Dir.UP or new_dir == Types.Dir.DOWN:
		tank.pos.x = snap_to_cell(tank.pos.x)
	else:
		tank.pos.y = snap_to_cell(tank.pos.y)
	# The snap can push a tank into a wall — then it is rolled back, or the tank
	# would get stuck.
	if not can_occupy(state, tank, tank.pos):
		tank.pos = before

## Moves one unit at a time, stopping at the first occupied step.
## Returns the distance actually covered.
static func step(state: WorldState, tank, dir: int, distance: int) -> int:
	var delta: Vector2i = Types.DIR_VEC[dir]
	var moved := 0
	for i in distance:
		var next: Vector2i = tank.pos + delta
		if not can_occupy(state, tank, next):
			break
		tank.pos = next
		moved += 1
	return moved

static func on_ice(state: WorldState, tank) -> bool:
	var c := state.terrain.cell_at_unit(tank.center())
	return state.terrain.get_cell(c.x, c.y) == Types.Cell.ICE

## Turning, stepping and arming inertia on ice. The tank's common move: a
## player and an enemy make it identically.
static func drive(state: WorldState, config: SimConfig, tank, dir: int) -> void:
	turn(state, tank, dir)
	var moved := step(state, tank, tank.dir, tank.speed)
	if moved > 0 and on_ice(state, tank):
		tank.slide_ticks = config.ice_slide_ticks
		tank.slide_dir = tank.dir
