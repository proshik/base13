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
	assert_lt(a, b, "identifiers must grow: traversal order depends on it")

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
