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

## A bullet centred at X = 1152 (exactly the boundary of cells 8 and 9) is a
## working invariant of the core.
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
	assert_eq(s.terrain.get_cell(8, 9), Types.Cell.BRICK, "an ordinary bullet takes one cell deep")
	assert_eq(s.terrain.get_cell(9, 9), Types.Cell.BRICK)
	assert_eq(s.bullets.size(), 0, "the bullet dies against brick")
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
	assert_eq(s.bullets.size(), 0, "the bullet dies all the same")
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
	assert_eq(_state().players[0].kills[0], 1, "the killed BASIC made it into the statistics")
	assert_has(_event_types(), Types.Event.TANK_DESTROYED)

func test_armor_tank_needs_four_hits() -> void:
	var owner := _player()
	var enemy := _add_enemy(Vector2i(1024, 1280), Types.TankType.ARMOR)
	for shot in 3:
		_shoot_up(1560, true, false, owner.id)
		for i in 3:
			sim.tick([0, 0])
		assert_true(enemy.alive, "after %d hits the armoured one is still alive" % (shot + 1))
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
	assert_true(enemy.alive, "a blinking enemy does not physically exist yet")

func test_shield_protects_the_player() -> void:
	var t := _player()
	t.shield_ticks = 100
	var enemy := _add_enemy(Vector2i(t.pos.x, t.pos.y - Consts.TANK))
	var b := _shoot_up(t.pos.y - 100, false, false, enemy.id)
	b.dir = Types.Dir.DOWN
	b.pos = Vector2i(t.pos.x + Consts.TANK / 2 - Consts.BULLET / 2, t.pos.y - Consts.BULLET)
	sim.tick([0, 0])
	assert_true(t.alive, "the shield absorbs a hit")
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
	assert_true(p2.alive, "an ally cannot be killed by a bullet")
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
	assert_false(s.base_alive, "one's own bullet destroys the eagle just the same")
