extends GutTest

## What a press means to a menu, from each device. The network screen once knew
## only the keyboard, and a player with a pad or a phone could not leave it.

func _key(physical: int, pressed := true, echo := false) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = physical
	e.pressed = pressed
	e.echo = echo
	return e

func _pad(button: int, pressed := true) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = button
	e.pressed = pressed
	return e

func _action(name: StringName, pressed := true) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = pressed
	return e

func test_keys() -> void:
	assert_eq(UiInput.of(_key(KEY_UP)), UiInput.Act.UP)
	assert_eq(UiInput.of(_key(KEY_W)), UiInput.Act.UP)
	assert_eq(UiInput.of(_key(KEY_DOWN)), UiInput.Act.DOWN)
	assert_eq(UiInput.of(_key(KEY_S)), UiInput.Act.DOWN)
	assert_eq(UiInput.of(_key(KEY_ENTER)), UiInput.Act.CONFIRM)
	assert_eq(UiInput.of(_key(KEY_SPACE)), UiInput.Act.CONFIRM)
	assert_eq(UiInput.of(_key(KEY_ESCAPE)), UiInput.Act.BACK)
	assert_eq(UiInput.of(_key(KEY_F)), UiInput.Act.NONE)

func test_a_release_or_repeat_is_nothing() -> void:
	assert_eq(UiInput.of(_key(KEY_UP, false)), UiInput.Act.NONE)
	assert_eq(UiInput.of(_key(KEY_UP, true, true)), UiInput.Act.NONE)
	assert_eq(UiInput.of(_pad(JOY_BUTTON_A, false)), UiInput.Act.NONE)
	assert_eq(UiInput.of(_action(&"touch_fire", false)), UiInput.Act.NONE)

func test_pad() -> void:
	assert_eq(UiInput.of(_pad(JOY_BUTTON_DPAD_UP)), UiInput.Act.UP)
	assert_eq(UiInput.of(_pad(JOY_BUTTON_DPAD_DOWN)), UiInput.Act.DOWN)
	assert_eq(UiInput.of(_pad(JOY_BUTTON_A)), UiInput.Act.CONFIRM)
	assert_eq(UiInput.of(_pad(JOY_BUTTON_START)), UiInput.Act.START)

func test_screen() -> void:
	assert_eq(UiInput.of(_action(&"touch_up")), UiInput.Act.UP)
	assert_eq(UiInput.of(_action(&"touch_down")), UiInput.Act.DOWN)
	assert_eq(UiInput.of(_action(&"touch_fire")), UiInput.Act.CONFIRM)
	assert_eq(UiInput.of(_action(&"touch_start")), UiInput.Act.START)
	assert_eq(UiInput.of(_action(&"touch_left")), UiInput.Act.NONE)

func test_anything_else_is_nothing() -> void:
	assert_eq(UiInput.of(InputEventMouseMotion.new()), UiInput.Act.NONE)
	assert_eq(UiInput.of(InputEventScreenTouch.new()), UiInput.Act.NONE)
