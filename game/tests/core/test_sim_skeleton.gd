extends GutTest

var sim: GameSim

func before_each() -> void:
	sim = GameSim.new(LevelFixture.empty_level(), 1, SimConfig.new(), 1, 1)

func test_tick_advances_counter() -> void:
	assert_eq(sim.get_state().tick, 0)
	sim.tick([0, 0])
	sim.tick([0, 0])
	assert_eq(sim.get_state().tick, 2)

func test_player_is_placed_at_spawn_tile_with_shield() -> void:
	var s := sim.get_state()
	assert_eq(s.player_tanks().size(), 1)
	var t: Entities.Tank = s.player_tanks()[0]
	assert_eq(t.pos, Consts.tile_to_unit(Consts.PLAYER_SPAWN_TILES[0]))
	assert_eq(t.dir, Types.Dir.UP)
	assert_eq(t.shield_ticks, sim.get_config().respawn_shield_ticks)
	assert_eq(s.players[0].lives, sim.get_config().start_lives)

func test_two_players_get_separate_spawns() -> void:
	var two := GameSim.new(LevelFixture.empty_level(), 1, SimConfig.new(), 1, 2)
	var tanks := two.get_state().player_tanks()
	assert_eq(tanks.size(), 2)
	assert_eq(tanks[0].pos, Consts.tile_to_unit(Consts.PLAYER_SPAWN_TILES[0]))
	assert_eq(tanks[1].pos, Consts.tile_to_unit(Consts.PLAYER_SPAWN_TILES[1]))

func test_timers_count_down_and_stop_at_zero() -> void:
	var s := sim.get_state()
	s.freeze_ticks = 2
	sim.tick([0, 0])
	assert_eq(s.freeze_ticks, 1)
	sim.tick([0, 0])
	assert_eq(s.freeze_ticks, 0)
	sim.tick([0, 0])
	assert_eq(s.freeze_ticks, 0, "the timer must not go negative")

func test_shovel_expiry_returns_steel_walls_to_brick() -> void:
	var s := sim.get_state()
	for c in Consts.BASE_WALL_CELLS:
		s.terrain.set_cell(c.x, c.y, Types.Cell.STEEL)
	s.shovel_ticks = 1
	sim.tick([0, 0])
	for c in Consts.BASE_WALL_CELLS:
		assert_eq(s.terrain.get_cell(c.x, c.y), Types.Cell.BRICK,
			"once the shovel expires the concrete returns as brick")

func test_shovel_expiry_leaves_holes_alone() -> void:
	var s := sim.get_state()
	var hole: Vector2i = Consts.BASE_WALL_CELLS[0]
	s.terrain.set_cell(hole.x, hole.y, Types.Cell.EMPTY)
	s.shovel_ticks = 1
	sim.tick([0, 0])
	assert_eq(s.terrain.get_cell(hole.x, hole.y), Types.Cell.EMPTY,
		"the shovel does not repair a hole already punched")

func test_destroyed_base_ends_the_game() -> void:
	sim.get_state().base_alive = false
	sim.tick([0, 0])
	assert_true(sim.get_state().game_over)

func test_game_over_event_is_emitted_once() -> void:
	sim.get_state().base_alive = false
	sim.tick([0, 0])
	var first := _count(sim.drain_events(), Types.Event.GAME_OVER)
	sim.tick([0, 0])
	var second := _count(sim.drain_events(), Types.Event.GAME_OVER)
	assert_eq(first, 1)
	assert_eq(second, 0, "the end of the game is announced once")

func test_level_cleared_when_no_enemies_left() -> void:
	sim.get_state().enemies_left = 0
	sim.tick([0, 0])
	assert_true(sim.get_state().level_cleared)
	assert_eq(_count(sim.drain_events(), Types.Event.LEVEL_CLEARED), 1)

func test_drain_events_empties_the_queue() -> void:
	sim.get_state().enemies_left = 0
	sim.tick([0, 0])
	assert_gt(sim.drain_events().size(), 0)
	assert_eq(sim.drain_events().size(), 0)

func test_hash_matches_between_two_identical_sims() -> void:
	var a := GameSim.new(LevelFixture.empty_level(), 77, SimConfig.new(), 1, 1)
	var b := GameSim.new(LevelFixture.empty_level(), 77, SimConfig.new(), 1, 1)
	for i in 20:
		a.tick([0, 0])
		b.tick([0, 0])
	assert_eq(a.state_hash(), b.state_hash())

func _count(events: Array, type: int) -> int:
	var n := 0
	for e in events:
		if e.type == type:
			n += 1
	return n
