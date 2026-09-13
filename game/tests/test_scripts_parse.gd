extends GutTest

## Every script in the project must at least parse.
##
## GUT loads the test scripts and, through them, everything they name. A node
## script is named by nothing: `ui/game.gd` is loaded when a person opens that
## screen and not a moment earlier. So a parse error in one of those passes the
## whole suite and ships — which is exactly what happened once, and was found by
## opening the game in a browser rather than by any test.

const SKIP := ["res://addons", "res://tests"]

func test_every_script_in_the_project_parses() -> void:
	var paths := _scripts_under("res://")
	assert_gt(paths.size(), 30, "the walk found almost nothing — it is broken, not the project")
	var broken: Array[String] = []
	for path in paths:
		# Past the cache: plain load() leaves every script and everything it
		# preloads sitting in the resource cache, and the engine reports them at
		# exit as still in use. Compiling the source by hand is not an option
		# either — a script that declares a class_name collides with the global
		# class already registered under that name.
		if ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) == null:
			broken.append(path)
	assert_eq(broken, [] as Array[String], "these scripts do not parse")

func _scripts_under(root: String) -> Array[String]:
	var out: Array[String] = []
	for skip in SKIP:
		if root.begins_with(skip):
			return out
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var path := root.path_join(entry)
		if dir.current_is_dir():
			out.append_array(_scripts_under(path))
		elif entry.ends_with(".gd"):
			out.append(path)
		entry = dir.get_next()
	dir.list_dir_end()
	return out
