extends GutTest

const ENEMIES_LINE := "enemies: BBBBBBBBBBBBBBFFFFPP"
const BONUS_LINE := "bonus: 3,10,17"

func _terrain_rows(fill: String = ".") -> String:
	var rows: Array[String] = []
	for y in Consts.GRID:
		rows.append(fill.repeat(Consts.GRID))
	return "\n".join(rows)

## Assembles a valid level text: an empty field plus the mandatory ring around
## the base.
func _valid_text() -> String:
	var grid: Array = []
	for y in Consts.GRID:
		grid.append(".".repeat(Consts.GRID).split(""))
	for c in Consts.BASE_WALL_CELLS:
		grid[c.y][c.x] = "#"
	var rows: Array[String] = []
	for y in Consts.GRID:
		rows.append("".join(grid[y]))
	return "%s\n%s\n---\n%s" % [ENEMIES_LINE, BONUS_LINE, "\n".join(rows)]

func test_parses_valid_level() -> void:
	var lvl := LevelData.parse(_valid_text())
	assert_eq(lvl.error, "", "a valid level must not produce an error")
	assert_eq(lvl.enemy_queue.size(), 20)
	assert_eq(lvl.enemy_queue[0], Types.TankType.BASIC)
	assert_eq(lvl.enemy_queue[14], Types.TankType.FAST)
	assert_eq(lvl.enemy_queue[18], Types.TankType.POWER)
	assert_eq(lvl.bonus_indices, [3, 10, 17] as Array[int])

func test_terrain_characters_map_to_cells() -> void:
	var text := _valid_text().replace("---\n.", "---\n#")
	var lvl := LevelData.parse(text)
	assert_eq(lvl.error, "")
	assert_eq(lvl.terrain.get_cell(0, 0), Types.Cell.BRICK)

func test_base_wall_is_loaded() -> void:
	var lvl := LevelData.parse(_valid_text())
	for c in Consts.BASE_WALL_CELLS:
		assert_eq(lvl.terrain.get_cell(c.x, c.y), Types.Cell.BRICK,
			"cell %s must be brick" % c)

func test_missing_separator_is_an_error() -> void:
	var lvl := LevelData.parse("%s\n%s\n%s" % [ENEMIES_LINE, BONUS_LINE, _terrain_rows()])
	assert_string_contains(lvl.error, "separator")

func test_wrong_row_count_is_an_error() -> void:
	var rows := _terrain_rows().split("\n")
	rows.remove_at(0)
	var text := "%s\n%s\n---\n%s" % [ENEMIES_LINE, BONUS_LINE, "\n".join(rows)]
	assert_string_contains(LevelData.parse(text).error, "rows")

func test_wrong_row_length_is_an_error() -> void:
	var rows := _terrain_rows().split("\n")
	rows[0] = rows[0] + "."
	var text := "%s\n%s\n---\n%s" % [ENEMIES_LINE, BONUS_LINE, "\n".join(rows)]
	assert_string_contains(LevelData.parse(text).error, "characters long")

func test_unknown_terrain_character_is_an_error() -> void:
	var text := _valid_text().replace("---\n.", "---\nZ")
	assert_string_contains(LevelData.parse(text).error, "unknown character")

func test_wrong_enemy_count_is_an_error() -> void:
	var text := _valid_text().replace(ENEMIES_LINE, "enemies: BBB")
	assert_string_contains(LevelData.parse(text).error, "20")

func test_unknown_enemy_character_is_an_error() -> void:
	var text := _valid_text().replace(ENEMIES_LINE, "enemies: ZBBBBBBBBBBBBBFFFFPP")
	assert_string_contains(LevelData.parse(text).error, "enemy type")

func test_bonus_index_out_of_range_is_an_error() -> void:
	var text := _valid_text().replace(BONUS_LINE, "bonus: 3,99")
	assert_string_contains(LevelData.parse(text).error, "bonus index")

func test_missing_base_wall_is_an_error() -> void:
	var lvl := LevelData.parse("%s\n%s\n---\n%s" % [ENEMIES_LINE, BONUS_LINE, _terrain_rows()])
	assert_string_contains(lvl.error, "base")

func test_base_cells_must_stay_empty() -> void:
	var text := _valid_text()
	var rows := text.split("---\n")[1].split("\n")
	var row: Array = rows[24].split("")
	row[12] = "#"
	rows[24] = "".join(row)
	var broken := "%s\n%s\n---\n%s" % [ENEMIES_LINE, BONUS_LINE, "\n".join(rows)]
	assert_string_contains(LevelData.parse(broken).error, "base")
