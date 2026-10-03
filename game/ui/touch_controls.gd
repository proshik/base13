class_name TouchControls
extends CanvasLayer

## The stick and two buttons on a touch screen, beside the picture or below it.
## The engine's own nodes take the fingers — several at once, one sliding off a
## button — and this layer turns what they report into `touch_*` actions, the only
## thing the rest of the game reads. A direction becomes an event when it changes,
## so a menu sees a flick of the stick as one press.
##
## The engine draws neither: its stick is given empty styles and the buttons no
## texture. TouchControlArt draws the console panel and animates its surfaces;
## the hit targets stay in place.

const STICK_ACTIONS := [&"touch_stick_left", &"touch_stick_right",
	&"touch_stick_up", &"touch_stick_down"]
const DIRECTION_ACTIONS := {
	Types.IN_UP: &"touch_up", Types.IN_DOWN: &"touch_down",
	Types.IN_LEFT: &"touch_left", Types.IN_RIGHT: &"touch_right",
}
## The fixed hit area includes every arm of the drawn cross. Full strength is
## still reached 32 pixels from its centre.
const STICK_SIZE := 80.0
const BUTTON_RADIUS := 30
const START_RADIUS := 8
## Where a touch still counts: a thumb is bigger than the drawing.
const BUTTON_TOUCH := 36.0
const START_TOUCH := 22.0
const FIRE_TEXT := "FIRE"
const START_TEXT := "START"
## The pause menu caption; the physical button keeps its START label.
const PAUSE_TEXT := "PAUSE"

var _start_text := START_TEXT
var _direction := 0
var _held := {}                   ## action → true while its button is down
var _touch_ids: Array[int] = []
var _stick: VirtualJoystick
var _fire: TouchScreenButton
var _start: TouchScreenButton
var _art: TouchControlArt
var _stick_point := Vector2.ZERO
var _stick_canceled := false
var _stick_centre := Vector2.ZERO   ## where the cross stands

func _ready() -> void:
	_stick = VirtualJoystick.new()
	_stick.joystick_mode = VirtualJoystick.JOYSTICK_FIXED
	_stick.joystick_size = STICK_SIZE
	_stick.tip_size = STICK_SIZE / 2.0
	_stick.clampzone_ratio = 0.8
	# gui_input precedes the native pressed signal and supplies its local point.
	_stick.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventScreenTouch:
			_stick_point = event.position
			_stick_canceled = event.canceled)
	_stick.pressed.connect(func() -> void:
		var origin := _stick.size * _stick.initial_offset_ratio
		steer(Touch.compose((_stick_point - origin) / 32.0, _direction)))
	_stick.released.connect(func(vector: Vector2) -> void:
		# A press and a drag can both finish before _process samples them.
		if not _stick_canceled:
			steer(Touch.compose(vector, _direction))
		steer(0))
	_stick.deadzone_ratio = 0.0   # Touch.compose has its own
	_stick.action_left = STICK_ACTIONS[0]
	_stick.action_right = STICK_ACTIONS[1]
	_stick.action_up = STICK_ACTIONS[2]
	_stick.action_down = STICK_ACTIONS[3]
	for style in ["normal_joystick", "normal_tip", "pressed_joystick", "pressed_tip"]:
		_stick.add_theme_stylebox_override(style, StyleBoxEmpty.new())
	add_child(_stick)
	_fire = _button(&"touch_fire", true, BUTTON_TOUCH)
	_start = _button(&"touch_start", false, START_TOUCH)
	_art = TouchControlArt.new()
	add_child(_art)
	place(get_viewport().get_visible_rect().size)

## FIRE takes a thumb sliding onto it — from the edge of the screen, from START — as
## a press; START does not, or a thumb crossing it on the way to FIRE would pause.
func _button(action: StringName, passby: bool, reach: float) -> TouchScreenButton:
	var button := TouchScreenButton.new()
	var shape := CircleShape2D.new()
	shape.radius = reach
	button.shape = shape
	button.shape_centered = true
	button.passby_press = passby
	button.pressed.connect(func() -> void: _send(action, true))
	button.released.connect(func() -> void: _send(action, false))
	add_child(button)
	return button

func _process(_delta: float) -> void:
	var stick := Input.get_vector(STICK_ACTIONS[0], STICK_ACTIONS[1],
		STICK_ACTIONS[2], STICK_ACTIONS[3], 0.0)
	steer(Touch.compose(stick, _direction))

## A direction as actions, only when it changes: the old one let go, the new one
## pressed.
func steer(direction: int) -> void:
	if direction == _direction:
		return
	if _direction != 0:
		_send(DIRECTION_ACTIONS[_direction], false)
	_direction = direction
	if direction != 0:
		_send(DIRECTION_ACTIONS[direction], true)
	_art.steer(direction)

func _send(action: StringName, pressed: bool) -> void:
	if pressed:
		_held[action] = true
	else:
		_held.erase(action)
	if _art != null and (action == &"touch_fire" or action == &"touch_start"):
		_art.press(action, pressed)
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	Input.parse_input_event(event)

## A tab can lose its finger without ever seeing the release. The same clearing
## is used for engine focus changes and for the page's immediate presence events.
func release_all() -> void:
	# Release the engine's finger ownership too, or a joystick would keep its old
	# origin when the first new finger arrives after a tab switch.
	for index in _touch_ids.duplicate():
		var release := InputEventScreenTouch.new()
		release.index = index
		release.pressed = false
		release.canceled = true
		Input.parse_input_event(release)
	_touch_ids.clear()
	for action in _held.keys():
		_send(action, false)
	_direction = 0
	for action in STICK_ACTIONS:
		Input.action_release(action)
	if _art != null:
		_art.steer(0)
	PressLatch.clear()

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			if not _touch_ids.has(event.index):
				_touch_ids.append(event.index)
		else:
			_touch_ids.erase(event.index)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT \
			or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT \
			or what == NOTIFICATION_APPLICATION_PAUSED:
		release_all()

## The stick takes presses on the cross and drags from its fixed centre. On its
## side FIRE stands in the middle of the right strip and START small in its far top
## corner, well away from FIRE: a thumb brushing it would pause the game. Upright
## the three rest on one low row, as on the console's pad: the cross on the left,
## START in the middle, FIRE on the right.
func place(view: Vector2, playing := false) -> void:
	var zone := StageLayout.stick_zone(view, playing)
	var row := StageLayout.thumb_row(view, playing)
	var buttons := StageLayout.button_zone(view, playing)
	_stick.position = zone.position
	_stick.size = zone.size
	if view.y > view.x:
		_stick_centre = Vector2(view.x * 0.19, row)
		_fire.position = Vector2(view.x * 0.81, row)
		_start.position = Vector2(view.x / 2, row)
	else:
		_stick_centre = zone.get_center()
		_fire.position = Vector2(buttons.get_center().x, row)
		_start.position = buttons.end - Vector2(START_TOUCH + 2.0, buttons.size.y - START_TOUCH - 2.0)
	_stick.initial_offset_ratio = (_stick_centre - zone.position) / zone.size
	var panels: Array[Rect2] = []
	if view.y > view.x:
		panels.append(StageLayout.deck_rect(view, playing))
	else:
		panels.assign([zone, buttons])
	_art.place(_stick_centre, _fire.position, _start.position, panels)

func stick_rect() -> Rect2:
	return Rect2(_stick.position, _stick.size)

func fire_centre() -> Vector2:
	return _fire.position

func start_centre() -> Vector2:
	return _start.position

func set_start_text(text: String) -> void:
	_start_text = text
	if _art != null:
		_art.set_start_text(text)

func start_text() -> String:
	return _start_text

## Where the cross is drawn. It stands still: a thumb may land anywhere in the
## cross, but a cross jumping under it read as the button running away.
func cross_centre() -> Vector2:
	return _stick_centre

func stick_rest() -> Vector2:
	return _stick_centre
