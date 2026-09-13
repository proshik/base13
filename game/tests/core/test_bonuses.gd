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

## Places a bonus of the given type right under the player's tracks.
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
	b.pos = Vector2i(Consts.TILE * 2, Consts.TILE * 2)   # well away from the player
	for i in cfg.bonus_life_ticks:
		sim.tick([0, 0])
	assert_null(_s().bonus, "a bonus disappears by itself")

func test_new_bonus_replaces_the_old_one() -> void:
	_put_bonus_under_player(Types.BonusType.STAR)
	var enemy := _add_enemy(Vector2i(Consts.TILE * 3, Consts.TILE * 3))
	enemy.drops_bonus = true
	enemy.alive = false
	sim._on_enemy_destroyed(enemy, null)
	assert_eq(_s().bonus.ticks_left, cfg.bonus_life_ticks, "only one bonus lies on the field")

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
		assert_eq(_player().stars, expected, "a tank on the field is upgraded immediately")

func test_grenade_wipes_the_field_but_spares_blinking_enemies() -> void:
	var solid := _add_enemy(Vector2i(Consts.TILE * 3, Consts.TILE * 3))
	var blinking := _add_enemy(Vector2i(Consts.TILE * 6, Consts.TILE * 3), false)
	_put_bonus_under_player(Types.BonusType.GRENADE)
	sim.tick([0, 0])
	assert_false(solid.alive, "a materialised enemy dies")
	assert_true(blinking.alive, "the grenade leaves a still-blinking tank alone")

func test_grenade_gives_no_score_for_the_wiped_enemies() -> void:
	_add_enemy(Vector2i(Consts.TILE * 3, Consts.TILE * 3))
	_put_bonus_under_player(Types.BonusType.GRENADE)
	sim.tick([0, 0])
	assert_eq(_s().players[0].score, cfg.bonus_score, "only 500 for the bonus itself")

func test_tank_bonus_adds_a_life() -> void:
	var before: int = _s().players[0].lives
	_put_bonus_under_player(Types.BonusType.TANK)
	sim.tick([0, 0])
	assert_eq(_s().players[0].lives, before + 1)
