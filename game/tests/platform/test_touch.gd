extends GutTest

## The screen's stick and buttons as the same five bits: one direction at a time,
## steady near the diagonal, and a tap that is not lost between two ticks.

func after_each() -> void:
	for action in Touch.ACTIONS:
		Input.action_release(action)
	PressLatch.clear()

func _action(name: StringName, pressed := true) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = pressed
	return e

func test_a_resting_thumb_is_no_move() -> void:
	assert_eq(Touch.compose(Vector2(0.2, -0.1), 0), 0)
	assert_eq(Touch.compose(Vector2.ZERO, Types.IN_UP), 0, "letting go stops the tank")

func test_each_way() -> void:
	assert_eq(Touch.compose(Vector2(0, -1), 0), Types.IN_UP)
	assert_eq(Touch.compose(Vector2(0, 1), 0), Types.IN_DOWN)
	assert_eq(Touch.compose(Vector2(-1, 0), 0), Types.IN_LEFT)
	assert_eq(Touch.compose(Vector2(1, 0), 0), Types.IN_RIGHT)

func test_one_direction_at_a_time() -> void:
	# Two bits would leave the choice to the core's priority rule, which the
	# thumb cannot see.
	assert_eq(Touch.compose(Vector2(0.7, -0.6), 0), Types.IN_RIGHT)
	assert_eq(Touch.compose(Vector2(0.6, -0.7), 0), Types.IN_UP)

func test_near_diagonal_keeps_the_direction() -> void:
	# The same thumb, a hair past the diagonal: whichever way the tank was going,
	# it keeps going. Without this it flips frame by frame.
	assert_eq(Touch.compose(Vector2(0.62, -0.72), Types.IN_RIGHT), Types.IN_RIGHT)
	assert_eq(Touch.compose(Vector2(0.72, -0.62), Types.IN_UP), Types.IN_UP)

func test_a_clear_lead_turns() -> void:
	assert_eq(Touch.compose(Vector2(0.4, -0.9), Types.IN_RIGHT), Types.IN_UP)
	assert_eq(Touch.compose(Vector2(-0.9, -0.4), Types.IN_UP), Types.IN_LEFT)

func test_bits_read_the_actions() -> void:
	Input.action_press(&"touch_up")
	Input.action_press(&"touch_fire")
	assert_eq(Touch.bits(), Types.IN_UP | Types.IN_FIRE)

func test_start_is_not_a_game_bit() -> void:
	Input.action_press(&"touch_start")
	assert_eq(Touch.bits(), 0, "START pauses; it must not reach the simulation")

func test_a_fire_tap_is_latched_for_player_one() -> void:
	PressLatch.note(_action(&"touch_fire"))
	PressLatch.note(_action(&"touch_fire", false))
	assert_eq(PressLatch.take(0), Types.IN_FIRE, "a tap between two ticks was lost")
	assert_eq(PressLatch.take(1), 0, "the screen belongs to player one")

func test_a_release_is_not_a_press() -> void:
	assert_eq(Touch.pressed_bits(_action(&"touch_fire", false)), 0)

func test_a_closed_latch_notes_no_tap() -> void:
	PressLatch.note(_action(&"touch_fire"), false)
	assert_eq(PressLatch.take(0), 0)

func test_local_input_hears_the_screen() -> void:
	Input.action_press(&"touch_left")
	var bits: Array[int] = LocalInput.new().inputs_for(0)
	assert_eq(bits[0] & Types.IN_LEFT, Types.IN_LEFT)
	assert_eq(bits[1], 0)
