class_name PressLatch

## Presses since the last tick was captured, per player. Keys and buttons are
## read by level — which are down at the moment a tick is captured — and a press
## that goes down and comes up between two captures reached no tick at all: a
## frame that hung for a third of a second swallowed a tap of fire or a turn, and
## a tick standing for the partner swallowed every tap made while it stood. The
## engine still delivers every event, in order, so a press is noted here as it
## comes, the next capture takes it along with what is held, and the capture after
## that no longer sees it.
##
## Static, like the `Input` it stands beside: there is one keyboard whichever
## source reads it, and the source is built far from the screen that sees the
## events.

static var _seen: Array[int] = [0, 0]
## Where each pad's axes last stood, by `Vector2i(device, axis)`: a stick counts as
## pressed only when it crosses out of the dead zone. Only a game screen sees the
## events, so a new one cannot know where a stick carried in from the menu stands;
## an axis not seen since `clear` is taken to have stood where its first event
## puts it. What is held is still read by level, so that loses nothing but a flick
## whose first sample is already past the dead zone, where guessing the centre
## drove the tank a tick after a held stick was let go.
static var _axes := {}

## `open` false follows the stick without noting a press: a stick let go behind the
## pause would otherwise still read as pushed after it. `pads` is a seam for
## tests, the connected pads in the order `Gamepad.bits` counts them: in headless
## there are none.
static func note(event: InputEvent, open := true, pads: Variant = null) -> void:
	var was := 0.0
	var motion := event as InputEventJoypadMotion
	if motion != null:
		var axis := Vector2i(motion.device, motion.axis)
		was = _axes.get(axis, motion.axis_value)
		_axes[axis] = motion.axis_value
	if not open:
		return
	for i in _seen.size():
		_seen[i] |= Keyboard.pressed_bits(event, i)
	if not (event is InputEventJoypadButton or motion != null):
		return
	var connected: Array = Input.get_connected_joypads() if pads == null else pads
	var i := connected.find(event.device)
	if i >= 0 and i < _seen.size():
		_seen[i] |= Gamepad.pressed_bits(event, was)

## What was pressed for this player since the last take, and forgotten here.
static func take(index: int) -> int:
	if index < 0 or index >= _seen.size():
		return 0
	var bits := _seen[index]
	_seen[index] = 0
	return bits

static func clear() -> void:
	_seen.fill(0)
	_axes.clear()
