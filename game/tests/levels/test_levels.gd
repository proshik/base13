extends GutTest

func _count_type(lvl: LevelData, type: int) -> int:
	var n := 0
	for t in lvl.enemy_queue:
		if t == type:
			n += 1
	return n

func test_all_levels_parse() -> void:
	for n in range(1, LevelLoader.level_count() + 1):
		var lvl := LevelLoader.load_level(n)
		assert_eq(lvl.error, "", "level %d: %s" % [n, lvl.error])

func test_spawn_points_are_clear() -> void:
	var tiles: Array[Vector2i] = []
	tiles.append_array(Consts.ENEMY_SPAWN_TILES)
	tiles.append_array(Consts.PLAYER_SPAWN_TILES)
	for n in range(1, LevelLoader.level_count() + 1):
		var lvl := LevelLoader.load_level(n)
		for tile in tiles:
			for dy in 2:
				for dx in 2:
					assert_eq(lvl.terrain.get_cell(tile.x * 2 + dx, tile.y * 2 + dy),
						Types.Cell.EMPTY,
						"level %d: spawn point %s is occupied by something" % [n, tile])

func test_levels_are_not_overcrowded() -> void:
	for n in range(1, LevelLoader.level_count() + 1):
		var lvl := LevelLoader.load_level(n)
		var empty := 0
		for cy in Consts.GRID:
			for cx in Consts.GRID:
				if lvl.terrain.get_cell(cx, cy) == Types.Cell.EMPTY:
					empty += 1
		assert_gt(empty, Consts.GRID * Consts.GRID * 2 / 5,
			"level %d is too crowded, there would be nowhere to play" % n)

func test_wave_gets_heavier() -> void:
	var first := LevelLoader.load_level(1)
	var last := LevelLoader.load_level(35)
	assert_eq(_count_type(first, Types.TankType.BASIC), 20,
		"the first level holds only basic tanks")
	assert_lt(_count_type(last, Types.TankType.BASIC), 20,
		"towards the end of the game fast and heavy tanks appear in the wave")

func test_every_level_survives_ten_seconds_of_simulation() -> void:
	for n in range(1, LevelLoader.level_count() + 1):
		var sim := GameSim.new(LevelLoader.load_level(n), 100 + n, SimConfig.new(), n, 1)
		for i in 600:
			sim.tick([0, 0])
		assert_eq(sim.get_state().tick, 600, "level %d did not finish its ticks" % n)
