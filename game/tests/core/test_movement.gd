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
	assert_eq(Movement.snap_to_cell(63), 0, "less than half a cell rounds down")
	assert_eq(Movement.snap_to_cell(64), 128, "exactly half rounds up")
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
	# a subset of the three it occupied unaligned. A neighbouring tank is another
	# matter — the snap can ride onto it, and then it must be rolled back or the
	# tanks stick together.
	var other := _tank(Vector2i(770, 1024))
	var t := _tank(Vector2i(1030, 1024), Types.Dir.RIGHT)
	Movement.turn(state, t, Types.Dir.UP)
	assert_eq(t.pos.x, 1030, "the snap is rolled back if it puts the tank on top of a neighbour")
	assert_eq(t.dir, Types.Dir.UP, "the direction changes either way")
	assert_not_null(other)

func test_stops_flush_against_brick() -> void:
	state.terrain.set_cell(10, 8, Types.Cell.BRICK)
	var t := _tank(Vector2i(1024, 1024), Types.Dir.RIGHT)
	var moved := Movement.step(state, t, Types.Dir.RIGHT, 100)
	assert_eq(t.pos.x, 1024, "the tank is already flush: cell 10 starts at 1280 and the tank spans 1024..1279")
	assert_eq(moved, 0)

func test_moves_until_it_touches_the_wall() -> void:
	state.terrain.set_cell(11, 8, Types.Cell.BRICK)
	var t := _tank(Vector2i(1024, 1024), Types.Dir.RIGHT)
	Movement.step(state, t, Types.Dir.RIGHT, 200)
	assert_eq(t.pos.x, 1152, "it stops flush: 1408 - 256 = 1152")

func test_water_blocks_tank() -> void:
	state.terrain.set_cell(10, 8, Types.Cell.WATER)
	var t := _tank(Vector2i(1024, 1024), Types.Dir.RIGHT)
	assert_eq(Movement.step(state, t, Types.Dir.RIGHT, 16), 0, "water stops a tank")

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
		"a blinking tank does not physically exist yet")

func test_on_ice_checks_the_cell_under_the_centre() -> void:
	var t := _tank(Vector2i(1024, 1024))
	assert_false(Movement.on_ice(state, t))
	var c := state.terrain.cell_at_unit(t.center())
	state.terrain.set_cell(c.x, c.y, Types.Cell.ICE)
	assert_true(Movement.on_ice(state, t))
