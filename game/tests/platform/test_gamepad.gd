extends GutTest

func test_dpad_gives_bits() -> void:
	assert_eq(Gamepad.compose(true, false, false, false, false, Vector2.ZERO), Types.IN_UP)
	assert_eq(Gamepad.compose(false, false, false, true, false, Vector2.ZERO), Types.IN_RIGHT)

func test_fire_button() -> void:
	assert_eq(Gamepad.compose(false, false, false, false, true, Vector2.ZERO), Types.IN_FIRE)

func test_stick_beyond_the_deadzone_counts() -> void:
	var far := Gamepad.DEADZONE + 0.2
	assert_eq(Gamepad.compose(false, false, false, false, false, Vector2(0, -far)), Types.IN_UP)
	assert_eq(Gamepad.compose(false, false, false, false, false, Vector2(far, 0)), Types.IN_RIGHT)

func test_stick_inside_the_deadzone_is_ignored() -> void:
	# Without a dead zone the tank drives off on its own, and that looks like
	# broken physics.
	var near := Gamepad.DEADZONE - 0.1
	assert_eq(Gamepad.compose(false, false, false, false, false, Vector2(near, -near)), 0)

func test_dpad_and_stick_add_up() -> void:
	var far := Gamepad.DEADZONE + 0.2
	assert_eq(Gamepad.compose(true, false, false, false, false, Vector2(far, 0)),
		Types.IN_UP | Types.IN_RIGHT)

func test_nothing_pressed_is_zero() -> void:
	assert_eq(Gamepad.compose(false, false, false, false, false, Vector2.ZERO), 0)

func test_diagonal_stick_gives_both_axes() -> void:
	var far := Gamepad.DEADZONE + 0.2
	assert_eq(Gamepad.compose(false, false, false, false, false, Vector2(-far, far)),
		Types.IN_LEFT | Types.IN_DOWN)

func test_bits_match_the_keyboard_contract() -> void:
	# Both sources must speak the same language, or they cannot be OR-ed.
	assert_eq(Gamepad.compose(true, false, false, false, true, Vector2.ZERO),
		Keyboard.bits(0, func(key: int) -> bool: return key == KEY_UP or key == KEY_SPACE))
