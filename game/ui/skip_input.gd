class_name SkipInput

## "Any key" for the splash, the statistics and the game-over screens, with two
## caveats. Housekeeping keys (fullscreen, pause) do not dismiss a screen:
## otherwise F on the statistics screen would both toggle the window and sweep
## the tally away before it could be read.
## The gamepad counts the same as the keyboard — a player with only a controller
## must not be asked to wait out a timer.

## Physical position rather than character: on a non-Latin layout the letter F
## produces a different code, and fullscreen would stop working.
const RESERVED := [KEY_F, KEY_ESCAPE]

static func is_skip(event: InputEvent) -> bool:
	if event is InputEventKey:
		return event.pressed and not event.echo and not RESERVED.has(event.physical_keycode)
	if event is InputEventJoypadButton:
		return event.pressed
	return false
