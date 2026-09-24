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

## `pads` is a seam for tests, the connected pads in the order `Gamepad.bits`
## counts them: in headless there are none.
static func note(event: InputEvent, pads: Variant = null) -> void:
	for i in _seen.size():
		_seen[i] |= Keyboard.pressed_bits(event, i)
	if not (event is InputEventJoypadButton or event is InputEventJoypadMotion):
		return
	var connected: Array = Input.get_connected_joypads() if pads == null else pads
	var i := connected.find(event.device)
	if i >= 0 and i < _seen.size():
		_seen[i] |= Gamepad.pressed_bits(event)

## What was pressed for this player since the last take, and forgotten here.
static func take(index: int) -> int:
	if index < 0 or index >= _seen.size():
		return 0
	var bits := _seen[index]
	_seen[index] = 0
	return bits

static func clear() -> void:
	_seen.fill(0)
