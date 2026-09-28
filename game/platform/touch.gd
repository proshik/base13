class_name Touch

## The same five bits from the screen. `TouchControls` turns the stick and the
## buttons into the actions below, and this reads them the way `Keyboard` reads
## keys. On a machine nobody touches, nothing presses them and the OR is zero.

const ACTIONS := {
	&"touch_up": Types.IN_UP, &"touch_down": Types.IN_DOWN,
	&"touch_left": Types.IN_LEFT, &"touch_right": Types.IN_RIGHT,
	&"touch_fire": Types.IN_FIRE,
}
## Below this the stick is at rest: a thumb laid on it is not yet a move.
const DEADZONE := 0.35
## How far the other axis must pull ahead before the direction changes. Without it a
## thumb resting near the diagonal flips the tank between two ways every frame.
const HOLD := 0.2

## One direction bit or zero. The tank drives four ways; two bits at once would leave
## the choice to the core's priority rule, which a thumb cannot see.
static func compose(stick: Vector2, previous: int) -> int:
	if stick.length() < DEADZONE:
		return 0
	var across := absf(stick.x)
	var along := absf(stick.y)
	var horizontal := across > along
	if previous == Types.IN_LEFT or previous == Types.IN_RIGHT:
		horizontal = across + HOLD > along
	elif previous == Types.IN_UP or previous == Types.IN_DOWN:
		horizontal = across > along + HOLD
	if horizontal:
		return Types.IN_RIGHT if stick.x > 0.0 else Types.IN_LEFT
	return Types.IN_DOWN if stick.y > 0.0 else Types.IN_UP

static func bits() -> int:
	var mask := 0
	for action in ACTIONS:
		if Input.is_action_pressed(action):
			mask |= ACTIONS[action]
	return mask

## The bit a `touch_*` action going down gives, for `PressLatch`.
static func pressed_bits(event: InputEvent) -> int:
	var action := event as InputEventAction
	if action == null or not action.pressed:
		return 0
	return ACTIONS.get(action.action, 0)
