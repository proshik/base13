class_name Gamepad

## The same five bits as from the keyboard. The sources are OR-ed together, so
## there is nothing to switch between: both work at once.

const DEADZONE := 0.5

## The pure part: a mask out of the d-pad, stick and button state.
## A dead zone is mandatory: a stick rarely rests at exact zero, and without one
## the tank drives off on its own, which looks like broken physics.
static func compose(up: bool, down: bool, left: bool, right: bool, fire: bool,
		stick: Vector2) -> int:
	var mask := 0
	if up or stick.y < -DEADZONE:
		mask |= Types.IN_UP
	if down or stick.y > DEADZONE:
		mask |= Types.IN_DOWN
	if left or stick.x < -DEADZONE:
		mask |= Types.IN_LEFT
	if right or stick.x > DEADZONE:
		mask |= Types.IN_RIGHT
	if fire:
		mask |= Types.IN_FIRE
	return mask

static func bits(device: int) -> int:
	var pads := Input.get_connected_joypads()
	if device < 0 or device >= pads.size():
		return 0
	var pad: int = pads[device]
	var stick := Vector2(
		Input.get_joy_axis(pad, JOY_AXIS_LEFT_X),
		Input.get_joy_axis(pad, JOY_AXIS_LEFT_Y))
	return compose(
		Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_UP),
		Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_DOWN),
		Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_LEFT),
		Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_RIGHT),
		Input.is_joy_button_pressed(pad, JOY_BUTTON_A)
			or Input.is_joy_button_pressed(pad, JOY_BUTTON_B),
		stick)

const BUTTON_BITS := {
	JOY_BUTTON_DPAD_UP: Types.IN_UP, JOY_BUTTON_DPAD_DOWN: Types.IN_DOWN,
	JOY_BUTTON_DPAD_LEFT: Types.IN_LEFT, JOY_BUTTON_DPAD_RIGHT: Types.IN_RIGHT,
	JOY_BUTTON_A: Types.IN_FIRE, JOY_BUTTON_B: Types.IN_FIRE,
}

## The bits a pad event presses, for `PressLatch`, whichever pad it came from: a
## button going down, or the stick pushed past the dead zone. Zero for anything
## else — a release included.
static func pressed_bits(event: InputEvent) -> int:
	var button := event as InputEventJoypadButton
	if button != null:
		return BUTTON_BITS.get(button.button_index, 0) if button.pressed else 0
	var motion := event as InputEventJoypadMotion
	if motion == null:
		return 0
	var stick := Vector2.ZERO
	if motion.axis == JOY_AXIS_LEFT_X:
		stick.x = motion.axis_value
	elif motion.axis == JOY_AXIS_LEFT_Y:
		stick.y = motion.axis_value
	return compose(false, false, false, false, false, stick)
