extends GutTest

## The character and the physical position are given separately: on a non-Latin
## layout the physical F key sends another character, and telling them apart is
## mandatory.
func _key(physical: int, pressed := true, echo := false, symbol := -1) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = physical
	e.keycode = physical if symbol < 0 else symbol
	e.pressed = pressed
	e.echo = echo
	return e

func _pad(button: int, pressed := true) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = button
	e.pressed = pressed
	return e

func test_ordinary_key_skips() -> void:
	assert_true(SkipInput.is_skip(_key(KEY_SPACE)))
	assert_true(SkipInput.is_skip(_key(KEY_ENTER)))

func test_release_and_repeat_do_not_skip() -> void:
	assert_false(SkipInput.is_skip(_key(KEY_SPACE, false)))
	assert_false(SkipInput.is_skip(_key(KEY_SPACE, true, true)), "auto-repeat is not a press")

func test_reserved_keys_do_not_skip() -> void:
	# F toggles fullscreen and Esc pauses; neither may also sweep the statistics
	# away before they have been read.
	assert_false(SkipInput.is_skip(_key(KEY_F)))
	assert_false(SkipInput.is_skip(_key(KEY_ESCAPE)))

func test_gamepad_button_skips() -> void:
	assert_true(SkipInput.is_skip(_pad(JOY_BUTTON_A)))
	assert_true(SkipInput.is_skip(_pad(JOY_BUTTON_START)))
	assert_false(SkipInput.is_skip(_pad(JOY_BUTTON_A, false)))

func test_mouse_motion_is_not_a_skip() -> void:
	assert_false(SkipInput.is_skip(InputEventMouseMotion.new()))

func test_reserved_keys_are_matched_by_position_not_symbol() -> void:
	# On a non-Latin layout the same physical key sends a different character.
	# Comparing characters would make fullscreen stop working when the language
	# changes.
	assert_false(SkipInput.is_skip(_key(KEY_F, true, false, KEY_A)),
		"F stays F whatever character the layout calls it")

func test_letter_key_in_another_layout_still_skips() -> void:
	assert_true(SkipInput.is_skip(_key(KEY_W, true, false, KEY_SEMICOLON)))
