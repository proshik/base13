class_name TouchDevice

## Whether this machine is played by touch: the controls go on screen and the menus
## drop what a phone cannot do. Asked once — a machine does not grow a touch screen
## mid-game.

static var _known := -1   ## -1 not asked yet, 0 no, 1 yes

static func present() -> bool:
	if _known < 0:
		_known = 1 if decide(OS.get_name(), _pointer()) else 0
	return _known == 1

## `pointer` is what a browser says of its main pointer: "coarse" is a finger. The
## user agent cannot tell: an iPad asking for the desktop site calls itself a Mac. A
## laptop with a touch screen answers "fine" — its mouse comes first, and so do the
## keyboard's screens.
static func decide(os_name: String, pointer: String) -> bool:
	if os_name == "Android" or os_name == "iOS":
		return true
	return pointer == "coarse"

## For tests: what `present` answers from now on; -1 asks the machine again.
static func force(value: int) -> void:
	_known = value

static func _pointer() -> String:
	if not OS.has_feature("web"):
		return ""
	# A string rather than a boolean: see App._wants_selftest.
	var answer = JavaScriptBridge.eval(
		"window.matchMedia('(pointer: coarse)').matches ? 'coarse' : 'fine'", true)
	return answer if typeof(answer) == TYPE_STRING else ""
