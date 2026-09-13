class_name LocalInput
extends InputSource

## Single player and co-op at one keyboard. The sources are OR-ed together, so
## keyboard and gamepad work at the same time.

func inputs_for(_tick: int) -> Array[int]:
	return [
		Keyboard.bits(0) | Gamepad.bits(0),
		Keyboard.bits(1) | Gamepad.bits(1),
	] as Array[int]
