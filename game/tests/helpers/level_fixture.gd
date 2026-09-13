class_name LevelFixture

## Builds a LevelData in code, bypassing the text format: tests almost always
## need an empty field with two or three cells in given places.

static func empty_level() -> LevelData:
	return level_with({})

## cells is a dictionary of Vector2i to Types.Cell; the ring around the base is
## added automatically.
static func level_with(cells: Dictionary) -> LevelData:
	var lvl := LevelData.new()
	lvl.terrain = Terrain.new()
	for c in Consts.BASE_WALL_CELLS:
		lvl.terrain.set_cell(c.x, c.y, Types.Cell.BRICK)
	for key in cells:
		lvl.terrain.set_cell(key.x, key.y, cells[key])
	for i in 20:
		lvl.enemy_queue.append(Types.TankType.BASIC)
	lvl.bonus_indices = [3, 10, 17] as Array[int]
	return lvl
