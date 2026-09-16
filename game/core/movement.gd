class_name Movement

## Movement on a half-tile grid. It is the snap on turning that creates the
## feeling of slipping into gaps by itself; without it the rules are the same
## and the game feels like somebody else's.

static func snap_to_cell(v: int) -> int:
	return ((v + Consts.CELL / 2) / Consts.CELL) * Consts.CELL

static func overlaps(a: Vector2i, sa: int, b: Vector2i, sb: int) -> bool:
	return a.x < b.x + sb and b.x < a.x + sa and a.y < b.y + sb and b.y < a.y + sa

static func can_occupy(state: WorldState, tank: Entities.Tank, pos: Vector2i) -> bool:
	if state.terrain.rect_blocks_tank(pos, Consts.TANK):
		return false
	var id: int = tank.id
	for o in state.tanks:
		var other: Entities.Tank = o
		if other.id == id or not other.alive or other.spawn_ticks != 0:
			continue
		if overlaps(pos, Consts.TANK, other.pos, Consts.TANK):
			return false
	return true

static func turn(state: WorldState, tank: Entities.Tank, new_dir: int) -> void:
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
##
## Like the bullet's walk, this asks the same question of the same standing
## world up to a dozen times a tick, so what cannot change while the tank steps
## is settled first: the tank keeps one coordinate, the others do not move, and
## the cells it covers change only at a cell boundary. The answer is the one
## can_occupy would give at every step.
static func step(state: WorldState, tank: Entities.Tank, dir: int, distance: int) -> int:
	var delta: Vector2i = Types.DIR_VEC[dir]
	var vertical: bool = delta.x == 0
	var blockers := _blockers_on_line(state, tank, vertical)
	var terrain: Terrain = state.terrain
	# No cell has these indices, so the first step always looks at the terrain.
	var cx0 := Consts.GRID + 1
	var cy0 := cx0
	var cx1 := cx0
	var cy1 := cx0
	var moved := 0
	for i in distance:
		var next: Vector2i = tank.pos + delta
		var nx0 := Terrain.cell_index(next.x)
		var ny0 := Terrain.cell_index(next.y)
		var nx1 := Terrain.cell_index(next.x + Consts.TANK - 1)
		var ny1 := Terrain.cell_index(next.y + Consts.TANK - 1)
		if nx0 != cx0 or ny0 != cy0 or nx1 != cx1 or ny1 != cy1:
			cx0 = nx0
			cy0 = ny0
			cx1 = nx1
			cy1 = ny1
			if terrain.blocks_tank_rect(cx0, cy0, cx1, cy1):
				break
		var along: int = next.y if vertical else next.x
		var stopped := false
		for item in blockers:
			var other: Entities.Tank = item
			if bands_meet(along, Consts.TANK,
					other.pos.y if vertical else other.pos.x, Consts.TANK):
				stopped = true
				break
		if stopped:
			break
		tank.pos = next
		moved += 1
	return moved

## overlaps along one axis: whether two spans of that axis meet.
static func bands_meet(a: int, sa: int, b: int, sb: int) -> bool:
	return a < b + sb and b < a + sa

## The tanks that could stop this one, settled before it steps: it keeps one
## coordinate the whole way, and a tank off that band can never be in the way.
static func _blockers_on_line(state: WorldState, tank: Entities.Tank, vertical: bool) -> Array:
	var out: Array = []
	var id: int = tank.id
	var fixed: int = tank.pos.x if vertical else tank.pos.y
	for o in state.tanks:
		var other: Entities.Tank = o
		if other.id == id or not other.alive or other.spawn_ticks != 0:
			continue
		if not bands_meet(fixed, Consts.TANK,
				other.pos.x if vertical else other.pos.y, Consts.TANK):
			continue
		out.append(other)
	return out

static func on_ice(state: WorldState, tank: Entities.Tank) -> bool:
	var c := state.terrain.cell_at_unit(tank.center())
	return state.terrain.get_cell(c.x, c.y) == Types.Cell.ICE

## Turning, stepping and arming inertia on ice. The tank's common move: a
## player and an enemy make it identically.
static func drive(state: WorldState, config: SimConfig, tank: Entities.Tank, dir: int) -> void:
	turn(state, tank, dir)
	var moved := step(state, tank, tank.dir, tank.speed)
	if moved > 0 and on_ice(state, tank):
		tank.slide_ticks = config.ice_slide_ticks
		tank.slide_dir = tank.dir
