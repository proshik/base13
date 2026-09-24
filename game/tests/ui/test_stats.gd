extends GutTest

## The tally between two levels. Alone a key sweeps it away. In a network game
## each side shows its own, and a key swept away only that side's: on 2026-09-24
## the side that skipped began levels 3, 4 and 5 up to five seconds before its
## partner and stood frozen on their twelfth tick until the partner came.

func _key(code: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = true
	return event

func _stats(players: int) -> Node:
	var stats: Node = load("res://ui/stats.tscn").instantiate()
	add_child_autofree(stats)
	stats.configure(Campaign.new(players, SimConfig.new(), 1), players, 0)
	return stats

func _left(stats: Node) -> Array:
	var outcomes := []
	stats.finished.connect(func(outcome: int) -> void: outcomes.append(outcome))
	return outcomes

func test_alone_a_key_skips_the_tally() -> void:
	var stats := _stats(2)
	var outcomes := _left(stats)
	stats._unhandled_input(_key(KEY_SPACE))
	assert_eq(outcomes.size(), 1, "a key did not skip the tally")

func test_in_a_network_game_a_key_does_not_skip_the_tally() -> void:
	var stats := _stats(2)
	stats.skippable = false
	var outcomes := _left(stats)
	stats._unhandled_input(_key(KEY_SPACE))
	stats._unhandled_input(_key(KEY_ENTER))
	assert_eq(outcomes.size(), 0, "a key swept one side's tally away")
	# The timer still ends it, the same on both sides.
	for i in 60 * 10:
		stats._process(1.0 / 60.0)
	assert_eq(outcomes.size(), 1, "the tally never ended by itself")

## The wiring: the root makes the tally unskippable exactly when there is a link.
func test_the_root_holds_the_tally_only_in_a_network_game() -> void:
	for networked in [false, true]:
		var app: Node = load("res://ui/app.gd").new()
		app._campaign = Campaign.new(2, SimConfig.new(), 1)
		app._players = 2
		if networked:
			app._link = Link.new()
		app._show(ScreenFlow.Screen.STATS)
		assert_eq(app._current.skippable, not networked,
			"networked %s: the tally skippable is %s" % [networked, app._current.skippable])
		app.free()
