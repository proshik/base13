extends GutTest

func _only(pressed: Array) -> Callable:
	return func(key: int) -> bool: return pressed.has(key)

func test_first_player_reads_the_arrows() -> void:
	assert_eq(Keyboard.bits(0, _only([KEY_UP])), Types.IN_UP)
	assert_eq(Keyboard.bits(0, _only([KEY_LEFT])), Types.IN_LEFT)
	assert_eq(Keyboard.bits(0, _only([KEY_SPACE])), Types.IN_FIRE)

func test_second_player_reads_wasd() -> void:
	assert_eq(Keyboard.bits(1, _only([KEY_W])), Types.IN_UP)
	assert_eq(Keyboard.bits(1, _only([KEY_D])), Types.IN_RIGHT)
	assert_eq(Keyboard.bits(1, _only([KEY_TAB])), Types.IN_FIRE)

func test_layouts_do_not_overlap() -> void:
	assert_eq(Keyboard.bits(1, _only([KEY_UP])), 0, "the arrows must not move player two")
	assert_eq(Keyboard.bits(0, _only([KEY_W])), 0, "WASD must not move player one")

func test_several_keys_combine_into_one_mask() -> void:
	assert_eq(Keyboard.bits(0, _only([KEY_UP, KEY_SPACE])), Types.IN_UP | Types.IN_FIRE)

func test_nothing_pressed_is_zero() -> void:
	assert_eq(Keyboard.bits(0, _only([])), 0)

func test_unknown_player_index_is_silent() -> void:
	assert_eq(Keyboard.bits(7, _only([KEY_UP])), 0,
		"there is no third player, but that must not crash anything")

func test_fire_keys_do_not_overlap() -> void:
	# A shared fire key would mean one player shooting for both.
	assert_eq(Keyboard.bits(1, _only([KEY_SPACE])), 0, "Space belongs to player one only")
	assert_eq(Keyboard.bits(0, _only([KEY_TAB])), 0, "Tab belongs to player two only")

func test_layouts_describe_themselves_for_the_legend() -> void:
	# The on-screen legend is built from the layout rather than written by hand:
	# that way it cannot drift out of step when the keys change.
	assert_eq(Keyboard.describe(0), {"move": "ARROWS", "fire": "SPACE"})
	assert_eq(Keyboard.describe(1), {"move": "WASD", "fire": "TAB"})

func test_describe_of_unknown_player_is_empty() -> void:
	assert_eq(Keyboard.describe(5), {"move": "", "fire": ""})

func test_layout_independence_is_the_point_of_physical_keys() -> void:
	# Polling goes by the physical position of a key. The contract is what is
	# checked: the mask reflects what was pressed by position, not by character.
	# On a non-Latin layout the physical W sends another letter — and without
	# this rule player two simply would not move.
	assert_eq(Keyboard.bits(1, _only([KEY_W, KEY_D])), Types.IN_UP | Types.IN_RIGHT)
	assert_eq(Keyboard.LAYOUTS[1]["up"], KEY_W, "the layout is described in position codes")
