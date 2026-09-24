extends GutTest

## Which events a press is, whose it is, and that a capture takes it once.

func before_each() -> void:
	PressLatch.clear()

func after_each() -> void:
	PressLatch.clear()

func _key(physical: int, pressed := true, echo := false) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = physical
	e.pressed = pressed
	e.echo = echo
	return e

func _button(button: int, device := 0, pressed := true) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = button
	e.device = device
	e.pressed = pressed
	return e

func _stick(axis: int, value: float, device := 0) -> InputEventJoypadMotion:
	var e := InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = value
	e.device = device
	return e

func test_a_press_is_taken_once() -> void:
	PressLatch.note(_key(KEY_SPACE))
	assert_eq(PressLatch.take(0), Types.IN_FIRE)
	assert_eq(PressLatch.take(0), 0, "the same press was taken twice")

func test_presses_add_up_until_taken() -> void:
	PressLatch.note(_key(KEY_UP))
	PressLatch.note(_key(KEY_UP, false))
	PressLatch.note(_key(KEY_SPACE))
	assert_eq(PressLatch.take(0), Types.IN_UP | Types.IN_FIRE)

func test_a_release_or_a_repeat_is_not_a_press() -> void:
	PressLatch.note(_key(KEY_SPACE, false))
	PressLatch.note(_key(KEY_SPACE, true, true))
	assert_eq(PressLatch.take(0), 0)

func test_each_layout_is_its_own_player() -> void:
	PressLatch.note(_key(KEY_LEFT))
	PressLatch.note(_key(KEY_TAB))
	assert_eq(PressLatch.take(0), Types.IN_LEFT)
	assert_eq(PressLatch.take(1), Types.IN_FIRE)

func test_a_key_no_layout_uses_is_nobody_s() -> void:
	PressLatch.note(_key(KEY_ESCAPE))
	PressLatch.note(_key(KEY_L))
	assert_eq(PressLatch.take(0), 0)
	assert_eq(PressLatch.take(1), 0)

func test_an_unknown_player_takes_nothing() -> void:
	PressLatch.note(_key(KEY_SPACE))
	assert_eq(PressLatch.take(7), 0)
	assert_eq(PressLatch.take(0), Types.IN_FIRE, "an unknown player took player one's press")

func test_clear_forgets() -> void:
	PressLatch.note(_key(KEY_SPACE))
	PressLatch.note(_key(KEY_W))
	PressLatch.clear()
	assert_eq(PressLatch.take(0), 0)
	assert_eq(PressLatch.take(1), 0)

func test_a_pad_plays_for_its_place_among_the_connected() -> void:
	# Pad 5 is the second connected, so it is player two's, as `Gamepad.bits`
	# counts it.
	PressLatch.note(_button(JOY_BUTTON_A, 5), true, [2, 5])
	assert_eq(PressLatch.take(0), 0)
	assert_eq(PressLatch.take(1), Types.IN_FIRE)

func test_a_pad_not_connected_is_nobody_s() -> void:
	PressLatch.note(_button(JOY_BUTTON_A, 9), true, [2, 5])
	assert_eq(PressLatch.take(0), 0)
	assert_eq(PressLatch.take(1), 0)

func test_pad_buttons_give_the_keyboard_s_bits() -> void:
	assert_eq(Gamepad.pressed_bits(_button(JOY_BUTTON_DPAD_UP)), Types.IN_UP)
	assert_eq(Gamepad.pressed_bits(_button(JOY_BUTTON_DPAD_DOWN)), Types.IN_DOWN)
	assert_eq(Gamepad.pressed_bits(_button(JOY_BUTTON_DPAD_LEFT)), Types.IN_LEFT)
	assert_eq(Gamepad.pressed_bits(_button(JOY_BUTTON_DPAD_RIGHT)), Types.IN_RIGHT)
	assert_eq(Gamepad.pressed_bits(_button(JOY_BUTTON_A)), Types.IN_FIRE)
	assert_eq(Gamepad.pressed_bits(_button(JOY_BUTTON_B)), Types.IN_FIRE)

func test_a_pad_release_or_another_button_is_not_a_press() -> void:
	assert_eq(Gamepad.pressed_bits(_button(JOY_BUTTON_A, 0, false)), 0)
	assert_eq(Gamepad.pressed_bits(_button(JOY_BUTTON_START)), 0)

func test_a_stick_flick_past_the_dead_zone_is_a_press() -> void:
	var far := Gamepad.DEADZONE + 0.2
	assert_eq(Gamepad.pressed_bits(_stick(JOY_AXIS_LEFT_X, -far)), Types.IN_LEFT)
	assert_eq(Gamepad.pressed_bits(_stick(JOY_AXIS_LEFT_Y, far)), Types.IN_DOWN)
	assert_eq(Gamepad.pressed_bits(_stick(JOY_AXIS_LEFT_X, Gamepad.DEADZONE - 0.1)), 0)
	assert_eq(Gamepad.pressed_bits(_stick(JOY_AXIS_RIGHT_X, -far)), 0,
		"the right stick does not drive")

func test_a_stick_springing_back_is_not_a_press() -> void:
	# On the way back to the centre the axis still reads past the dead zone.
	assert_eq(Gamepad.pressed_bits(_stick(JOY_AXIS_LEFT_X, -0.7), -0.9), 0)
	assert_eq(Gamepad.pressed_bits(_stick(JOY_AXIS_LEFT_X, -0.55), -0.7), 0)
	assert_eq(Gamepad.pressed_bits(_stick(JOY_AXIS_LEFT_X, 0.0), -0.55), 0)

func test_a_stick_swung_across_is_a_press_the_other_way() -> void:
	assert_eq(Gamepad.pressed_bits(_stick(JOY_AXIS_LEFT_X, -0.9), 0.9), Types.IN_LEFT)

func test_the_latch_takes_a_stick_let_go_as_no_press() -> void:
	# Pushed left and let go between two captures: the push is a press, the way
	# back is not, and the capture after the first sees nothing.
	for value in [0.0, -0.9, -0.7, -0.55, 0.0]:
		PressLatch.note(_stick(JOY_AXIS_LEFT_X, value, 11), true, [11])
	assert_eq(PressLatch.take(0), Types.IN_LEFT)
	PressLatch.note(_stick(JOY_AXIS_LEFT_X, -0.9, 11), true, [11])
	PressLatch.take(0)
	for value in [-0.7, -0.55, 0.0]:
		PressLatch.note(_stick(JOY_AXIS_LEFT_X, value, 11), true, [11])
	assert_eq(PressLatch.take(0), 0, "a stick springing back drove the tank on")

func test_a_stick_turned_from_up_to_left_presses_left_only() -> void:
	PressLatch.note(_stick(JOY_AXIS_LEFT_X, 0.0, 12), true, [12])
	PressLatch.note(_stick(JOY_AXIS_LEFT_Y, 0.0, 12), true, [12])
	PressLatch.note(_stick(JOY_AXIS_LEFT_Y, -0.9, 12), true, [12])
	PressLatch.take(0)
	# Up comes back towards the centre as left goes out.
	PressLatch.note(_stick(JOY_AXIS_LEFT_Y, -0.7, 12), true, [12])
	PressLatch.note(_stick(JOY_AXIS_LEFT_X, -0.8, 12), true, [12])
	PressLatch.note(_stick(JOY_AXIS_LEFT_Y, -0.1, 12), true, [12])
	assert_eq(PressLatch.take(0), Types.IN_LEFT,
		"up is where the stick came from, not a press; it outranks left in the core")

func test_the_stick_is_followed_while_presses_are_not_wanted() -> void:
	# Pushed before the pause, let go behind it, pushed again after: the last is
	# a press, which only a latch that kept following the stick can tell.
	PressLatch.note(_stick(JOY_AXIS_LEFT_X, 0.0, 13), true, [13])
	PressLatch.note(_stick(JOY_AXIS_LEFT_X, -0.9, 13), true, [13])
	PressLatch.take(0)
	PressLatch.note(_stick(JOY_AXIS_LEFT_X, 0.0, 13), false, [13])
	PressLatch.note(_stick(JOY_AXIS_LEFT_X, -0.9, 13), true, [13])
	assert_eq(PressLatch.take(0), Types.IN_LEFT)

func test_a_stick_held_in_from_another_screen_is_not_a_press() -> void:
	# Held since the menu, where no game screen saw it: its first event here is the
	# way back to the centre, and guessing the centre for where it stood made that
	# a press.
	PressLatch.note(_stick(JOY_AXIS_LEFT_X, -0.9, 15), true, [15])
	PressLatch.note(_stick(JOY_AXIS_LEFT_X, -0.6, 15), true, [15])
	PressLatch.note(_stick(JOY_AXIS_LEFT_X, 0.0, 15), true, [15])
	assert_eq(PressLatch.take(0), 0)

func test_a_new_level_forgets_where_the_stick_stood() -> void:
	# The last level saw the stick at the centre; it was pushed and held through
	# the stats, where no game screen saw it. Its first event here is the way
	# back, and read against the old centre it was a press.
	PressLatch.note(_stick(JOY_AXIS_LEFT_X, 0.0, 16), true, [16])
	PressLatch.clear()
	PressLatch.note(_stick(JOY_AXIS_LEFT_X, -0.9, 16), true, [16])
	assert_eq(PressLatch.take(0), 0, "the last level's centre made the way back a press")
	PressLatch.note(_stick(JOY_AXIS_LEFT_X, 0.0, 16), true, [16])
	PressLatch.note(_stick(JOY_AXIS_LEFT_X, -0.9, 16), true, [16])
	assert_eq(PressLatch.take(0), Types.IN_LEFT, "once seen, the stick is followed again")

func test_a_press_while_not_wanted_is_not_noted() -> void:
	PressLatch.note(_key(KEY_SPACE), false)
	PressLatch.note(_button(JOY_BUTTON_A, 14), false, [14])
	assert_eq(PressLatch.take(0), 0)

func test_a_key_press_gives_its_layout_s_bit() -> void:
	assert_eq(Keyboard.pressed_bits(_key(KEY_DOWN), 0), Types.IN_DOWN)
	assert_eq(Keyboard.pressed_bits(_key(KEY_D), 1), Types.IN_RIGHT)
	assert_eq(Keyboard.pressed_bits(_key(KEY_D), 0), 0, "WASD must not move player one")
	assert_eq(Keyboard.pressed_bits(_key(KEY_UP), 3), 0)
	assert_eq(Keyboard.pressed_bits(_button(JOY_BUTTON_A), 0), 0)
