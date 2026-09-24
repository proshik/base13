extends GutTest

var sim: GameSim
var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()
	sim = GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 1)

func _s() -> WorldState:
	return sim.get_state()

## Places an already materialised enemy away from the spawn points.
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
	assert_eq(positions[3], Consts.tile_to_unit(Consts.ENEMY_SPAWN_TILES[0]), "in a cycle")

func test_interval_between_spawns_is_respected() -> void:
	sim.tick([0, 0])
	for t in _s().enemy_tanks():
		t.alive = false
	for i in cfg.spawn_interval_ticks:
		sim.tick([0, 0])
	assert_eq(_s().enemy_tanks().size(), 0, "nobody appears ahead of time")
	sim.tick([0, 0])
	assert_eq(_s().enemy_tanks().size(), 1, "a spawn happens on the tick where the timer has already reached zero")

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
	assert_eq(_s().enemy_tanks().size(), cfg.max_enemies_alive, "a slot freed up and a new one appeared")

func _spawn_point(i: int) -> Vector2i:
	return Consts.tile_to_unit(Consts.ENEMY_SPAWN_TILES[i])

func _player() -> Entities.Tank:
	return _s().player_tanks()[0]

func _overlap(a: Entities.Tank, b: Entities.Tank) -> bool:
	return Movement.overlaps(a.pos, Consts.TANK, b.pos, Consts.TANK)

func test_occupied_spawn_point_passes_the_turn_to_the_next() -> void:
	var parked := _park_enemy(_spawn_point(0))
	_s().spawn_timer = 0
	sim.tick([0, 0])
	var enemies := _s().enemy_tanks()
	assert_eq(enemies.size(), 2, "the queue does not wait on one point")
	assert_eq(enemies[1].pos, _spawn_point(1), "nobody spawns on an occupied point")
	assert_eq(_s().spawn_point_index, 2, "the cycle goes on from the point used")
	assert_not_null(parked)

func test_every_point_occupied_postpones_the_spawn() -> void:
	for i in Consts.ENEMY_SPAWN_TILES.size():
		_park_enemy(_spawn_point(i))
	_s().spawn_timer = 0
	sim.tick([0, 0])
	assert_eq(_s().enemy_tanks().size(), Consts.ENEMY_SPAWN_TILES.size(), "nowhere to appear")
	assert_eq(_s().spawn_point_index, 0, "the turn stays where it was")

## A player sitting on a spawn point used to hold the whole wave back: the
## spawner waited on that one point, and the level could not be finished.
func test_a_player_camping_a_spawn_point_does_not_hold_the_wave() -> void:
	var p := _player()
	p.pos = _spawn_point(0)
	p.shield_ticks = 1000000
	var spawned := 0
	for i in 5000:
		sim.tick([0, 0])
		for t in _s().enemy_tanks():
			t.alive = false
			spawned += 1
		p.pos = _spawn_point(0)
		if _s().enemy_queue.is_empty():
			break
	assert_eq(spawned, 20, "the whole wave came out elsewhere")

## The report of 2026-09-24: a player on the point where an enemy was blinking.
## A blinking tank does not block, so the player drives in; then the enemy
## materialises on top of the player, and each blocked the other on both axes
## for good.
func test_player_driven_onto_a_blinking_enemy_can_drive_off() -> void:
	sim.tick([0, 0])
	var e: Entities.Tank = _s().enemy_tanks()[0]
	var p := _player()
	p.pos = _spawn_point(0) + Vector2i(Consts.TANK, 0)
	p.shield_ticks = 1000000
	while not e.is_materialized():
		sim.tick([Types.IN_LEFT, 0])
	assert_true(_overlap(p, e), "the player is on the point as the enemy appears")
	# Back the way it came: the enemy leaves heading down, and a player
	# following it would only be stopped by its stern.
	var before: Vector2i = p.pos
	sim.tick([Types.IN_RIGHT, 0])
	assert_ne(p.pos, before, "the player is not locked in")
	for i in 60:
		sim.tick([Types.IN_RIGHT, 0])
	assert_false(_overlap(p, e), "the two have parted")

func test_enemy_materialised_under_a_standing_player_drives_out() -> void:
	sim.tick([0, 0])
	var e: Entities.Tank = _s().enemy_tanks()[0]
	var p := _player()
	p.pos = _spawn_point(0)
	p.shield_ticks = 1000000
	for i in 600:
		sim.tick([0, 0])
		if e.is_materialized() and not _overlap(p, e):
			break
	assert_true(e.is_materialized())
	assert_false(_overlap(p, e), "the enemy found a way out from under the player")

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
	assert_eq(spawned, 20, "a wave holds exactly twenty enemies")
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
	assert_true(flags[3], "the fourth enemy in order is marked as carrying a bonus")
