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
