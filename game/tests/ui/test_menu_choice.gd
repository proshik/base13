extends GutTest

## The menu once confused "item number" with "outcome": the network item
## returned 4, the root read that as five players and went straight into the
## game. These checks keep the two answers apart.

var menu

func before_each() -> void:
	menu = load("res://ui/menu.gd").new()
	add_child_autofree(menu)

func _select(index: int) -> void:
	for i in index:
		menu._move(1)

func test_first_item_is_one_player() -> void:
	assert_eq(menu.players(), 1)
	assert_false(menu._is_network())

func test_second_item_is_two_players() -> void:
	_select(1)
	assert_eq(menu.players(), 2)
	assert_false(menu._is_network())

func test_last_item_is_the_network_game() -> void:
	_select(menu.items().size() - 1)
	assert_true(menu._is_network(), "the last item leads to the network screen")

func test_player_count_never_exceeds_two() -> void:
	# A player tank exists at only two spawn points: a third player would crash
	# the game on an out-of-bounds array access.
	for i in menu.items().size():
		assert_between(menu.players(), 1, 2, "item %d yielded an impossible number" % i)
		menu._move(1)

## The legend once counted its lines by menu items: three items against two
## layouts, and "3P" hung at the bottom without a single key.
func test_legend_has_a_row_per_layout_and_no_empty_ones() -> void:
	var rows: Array[String] = menu.legend_rows()
	assert_eq(rows.size(), Keyboard.LAYOUTS.size() + 1,
		"there must be one line per layout plus the shared one")
	for i in Keyboard.LAYOUTS.size():
		var keys := Keyboard.describe(i)
		assert_ne(keys["move"], "", "player %d has no movement keys" % (i + 1))
		assert_ne(keys["fire"], "", "player %d has no fire key" % (i + 1))
	for row in rows:
		assert_lt(TextPainter.width_of(row), TextPainter.SCREEN_WIDTH,
			"the legend line '%s' does not fit on the screen" % row)

func _action(name: StringName) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = true
	return e

func test_a_phone_has_no_two_player_item() -> void:
	# Two players at one phone would need two pairs of thumbs on one screen.
	menu.touch = true
	assert_false(menu.items().has("2 PLAYERS"))
	_select(1)
	assert_true(menu._is_network(), "the item after 1 PLAYER on a phone is NETWORK")
	assert_eq(menu.players(), 1)

func test_a_phone_shows_no_keys() -> void:
	menu.touch = true
	assert_true(menu.legend_rows().is_empty())

func test_the_screen_moves_and_confirms() -> void:
	menu.touch = true
	watch_signals(menu)
	menu._unhandled_input(_action(&"touch_down"))
	assert_true(menu._is_network())
	menu._unhandled_input(_action(&"touch_fire"))
	assert_signal_emitted_with_parameters(menu, "finished", [ScreenFlow.Outcome.NET])

func test_start_begins_as_on_the_console() -> void:
	watch_signals(menu)
	menu._unhandled_input(_action(&"touch_start"))
	assert_signal_emitted_with_parameters(menu, "finished", [ScreenFlow.Outcome.CONTINUE])
