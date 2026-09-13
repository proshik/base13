class_name LevelData

## Parser for the level's text format. It works on a string rather than a file:
## reading from disk is platform/'s job, so that the core knows nothing about a
## file system.
##
## Format:
##   enemies: BBBBBBBBBBBBBBFFFFPP
##   bonus: 3,10,17
##   ---
##   26 rows of 26 characters: . empty  # brick  @ concrete  ~ water  % forest  - ice

const SEPARATOR := "---"
const ENEMY_COUNT := 20

const CHAR_TO_CELL := {
	".": Types.Cell.EMPTY,
	"#": Types.Cell.BRICK,
	"@": Types.Cell.STEEL,
	"~": Types.Cell.WATER,
	"%": Types.Cell.TREES,
	"-": Types.Cell.ICE,
}

const CHAR_TO_TANK := {
	"B": Types.TankType.BASIC,
	"F": Types.TankType.FAST,
	"P": Types.TankType.POWER,
	"A": Types.TankType.ARMOR,
}

var terrain: Terrain
var enemy_queue: Array[int] = []
var bonus_indices: Array[int] = []
var error := ""

static func parse(text: String) -> LevelData:
	var lvl := LevelData.new()
	lvl.terrain = Terrain.new()

	var parts := text.split(SEPARATOR + "\n", false)
	if parts.size() < 2:
		lvl.error = "no '---' separator between the header and the field"
		return lvl

	var header_error := lvl._parse_header(parts[0])
	if header_error != "":
		lvl.error = header_error
		return lvl

	var body_error := lvl._parse_terrain(parts[1])
	if body_error != "":
		lvl.error = body_error
		return lvl

	lvl.error = lvl._validate_base()
	return lvl

func _parse_header(header: String) -> String:
	var enemies := ""
	var bonus := ""
	for raw_line in header.split("\n", false):
		var line := raw_line.strip_edges()
		if line.begins_with("enemies:"):
			enemies = line.substr(8).strip_edges()
		elif line.begins_with("bonus:"):
			bonus = line.substr(6).strip_edges()

	if enemies.length() != ENEMY_COUNT:
		return "the enemies line must hold exactly %d characters, found %d" % [ENEMY_COUNT, enemies.length()]
	for i in enemies.length():
		var ch := enemies[i]
		if not CHAR_TO_TANK.has(ch):
			return "unknown enemy type '%s' at position %d" % [ch, i]
		enemy_queue.append(CHAR_TO_TANK[ch])

	if bonus != "":
		for piece in bonus.split(",", false):
			var value := piece.strip_edges()
			if not value.is_valid_int():
				return "bonus index '%s' is not a number" % value
			var index := value.to_int()
			if index < 0 or index >= ENEMY_COUNT:
				return "bonus index %d is out of the range 0..%d" % [index, ENEMY_COUNT - 1]
			bonus_indices.append(index)
	return ""

func _parse_terrain(body: String) -> String:
	var rows := body.split("\n", false)
	if rows.size() != Consts.GRID:
		return "the field must span exactly %d rows, found %d" % [Consts.GRID, rows.size()]
	for y in Consts.GRID:
		var row: String = rows[y]
		if row.length() != Consts.GRID:
			return "row %d is %d characters long, expected %d" % [y, row.length(), Consts.GRID]
		for x in Consts.GRID:
			var ch := row[x]
			if not CHAR_TO_CELL.has(ch):
				return "unknown character '%s' in row %d at position %d" % [ch, y, x]
			terrain.set_cell(x, y, CHAR_TO_CELL[ch])
	return ""

func _validate_base() -> String:
	for c in Consts.BASE_WALL_CELLS:
		if terrain.get_cell(c.x, c.y) != Types.Cell.BRICK:
			return "the base is uncovered: cell %s must be brick" % c
	for c in Consts.BASE_CELLS:
		if terrain.get_cell(c.x, c.y) != Types.Cell.EMPTY:
			return "the base stands on a non-empty cell %s" % c
	return ""
