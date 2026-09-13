class_name ScoreStore

## The high score between runs. Parsing and formatting are pure functions,
## reading and writing a thin wrapper: that way the checkable part is checked by
## a test rather than by launching the game.

const PATH := "user://base13.cfg"
const KEY := "best"

static func serialise(best: int) -> String:
	return "%s=%d\n" % [KEY, maxi(0, best)]

## A corrupt file means "no high score". A damaged config is no reason to
## refuse a game, and even less of one to show a stack trace.
##
## The key is compared in full rather than by prefix: otherwise `bestiary=99`
## would pass for a high score.
static func parse(text: String) -> int:
	for raw_line in text.split("\n", false):
		var parts := raw_line.split("=", false, 1)
		if parts.size() != 2:
			continue
		if parts[0].strip_edges() != KEY:
			continue
		var value := parts[1].strip_edges()
		if not value.is_valid_int():
			continue
		return maxi(0, value.to_int())
	return 0

static func load_best() -> int:
	if not FileAccess.file_exists(PATH):
		return 0
	var handle := FileAccess.open(PATH, FileAccess.READ)
	if handle == null:
		return 0
	return parse(handle.get_as_text())

static func save_best(best: int) -> void:
	var handle := FileAccess.open(PATH, FileAccess.WRITE)
	if handle == null:
		return
	handle.store_string(serialise(best))
