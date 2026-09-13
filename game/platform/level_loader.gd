class_name LevelLoader

## Reading levels from disk lives outside the core: core/ must not know about
## the file system.

const LEVEL_DIR := "res://levels"
const LEVEL_COUNT := 35

static func level_count() -> int:
	return LEVEL_COUNT

static func load_level(number: int) -> LevelData:
	var path := "%s/%02d.lvl" % [LEVEL_DIR, number]
	if not FileAccess.file_exists(path):
		var missing := LevelData.new()
		missing.terrain = Terrain.new()
		missing.error = "level file not found: %s" % path
		return missing
	return LevelData.parse(FileAccess.get_file_as_string(path))
