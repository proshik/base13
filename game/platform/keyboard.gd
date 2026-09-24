class_name Keyboard

## Assembles exactly the five bits that GameSim.tick() accepts.
## Direction priority when several keys are held is resolved in the core — it is
## not duplicated here, or the rule would live in two places.

## Player two fires with Tab rather than Ctrl: on macOS, Ctrl with player one's
## arrow keys switches desktops, and the system takes the press for itself.
const LAYOUTS: Array[Dictionary] = [
	{
		"up": KEY_UP, "down": KEY_DOWN, "left": KEY_LEFT, "right": KEY_RIGHT,
		"fire": KEY_SPACE,
	},
	{
		"up": KEY_W, "down": KEY_S, "left": KEY_A, "right": KEY_D,
		"fire": KEY_TAB,
	},
]

const BITS := {
	"up": Types.IN_UP, "down": Types.IN_DOWN, "left": Types.IN_LEFT,
	"right": Types.IN_RIGHT, "fire": Types.IN_FIRE,
}

## probe is a seam for tests: polling real keys in headless yields nothing.
##
## Keys are polled by physical position rather than by character: on a
## non-Latin layout W produces another letter, and a check against KEY_W would
## never fire — player two simply would not move. Arrows and Space do not depend
## on the layout, so player one kept working and the break stayed invisible.
static func bits(index: int, probe := Callable()) -> int:
	if index < 0 or index >= LAYOUTS.size():
		return 0
	var pressed := probe
	if not pressed.is_valid():
		pressed = func(key: int) -> bool: return Input.is_physical_key_pressed(key)
	var mask := 0
	for action in ["up", "down", "left", "right", "fire"]:
		if pressed.call(LAYOUTS[index][action]):
			mask |= BITS[action]
	return mask

## The bit a key going down gives this layout, for `PressLatch`: zero for a
## release, an auto-repeat or a key the layout does not use. By physical
## position, like `bits`.
static func pressed_bits(event: InputEvent, index: int) -> int:
	if index < 0 or index >= LAYOUTS.size():
		return 0
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return 0
	for action in ["up", "down", "left", "right", "fire"]:
		if LAYOUTS[index][action] == key.physical_keycode:
			return BITS[action]
	return 0

const ARROWS := [KEY_UP, KEY_LEFT, KEY_DOWN, KEY_RIGHT]

## Key names for the on-screen legend. Arrows collapse into a single word, and
## letters are joined in up-left-down-right order, which spells "WASD".
static func describe(index: int) -> Dictionary:
	if index < 0 or index >= LAYOUTS.size():
		return {"move": "", "fire": ""}
	var layout := LAYOUTS[index]
	var moves := [layout["up"], layout["left"], layout["down"], layout["right"]]
	var move := "ARROWS"
	if moves != ARROWS:
		move = ""
		for key in moves:
			move += OS.get_keycode_string(key).to_upper()
	return {"move": move, "fire": OS.get_keycode_string(layout["fire"]).to_upper()}
