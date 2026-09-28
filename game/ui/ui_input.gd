class_name UiInput

## What a press means to a menu, whichever device made it. The screens used to take
## keys apart each on its own, and the network screen knew only the keyboard.
##
## BACK and START are kept apart: Esc does nothing on the title menu, while START
## there begins the game, as it did on the console.

enum Act { NONE, UP, DOWN, CONFIRM, BACK, START }

static func of(event: InputEvent) -> int:
	var key := event as InputEventKey
	if key != null:
		if not key.pressed or key.echo:
			return Act.NONE
		match key.physical_keycode:
			KEY_UP, KEY_W:
				return Act.UP
			KEY_DOWN, KEY_S:
				return Act.DOWN
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				return Act.CONFIRM
			KEY_ESCAPE:
				return Act.BACK
		return Act.NONE
	var button := event as InputEventJoypadButton
	if button != null:
		if not button.pressed:
			return Act.NONE
		match button.button_index:
			JOY_BUTTON_DPAD_UP:
				return Act.UP
			JOY_BUTTON_DPAD_DOWN:
				return Act.DOWN
			JOY_BUTTON_A:
				return Act.CONFIRM
			JOY_BUTTON_START:
				return Act.START
		return Act.NONE
	var action := event as InputEventAction
	if action == null or not action.pressed:
		return Act.NONE
	match action.action:
		&"touch_up":
			return Act.UP
		&"touch_down":
			return Act.DOWN
		&"touch_fire":
			return Act.CONFIRM
		&"touch_start":
			return Act.START
	return Act.NONE
