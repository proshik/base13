class_name TouchControls
extends CanvasLayer

## The stick and two buttons on a touch screen, beside the picture or below it.
## The engine's own nodes take the fingers — several at once, one sliding off a
## button — and this layer turns what they report into `touch_*` actions, the only
## thing the rest of the game reads. A direction becomes an event when it changes,
## so a menu sees a flick of the stick as one press.
##
## The engine draws neither: its stick is given empty styles and the buttons no
## texture, and the pixels are drawn here — a cross like the console's pad and two
## round buttons — so the controls look like the rest of the game.

const STICK_ACTIONS := [&"touch_stick_left", &"touch_stick_right",
	&"touch_stick_up", &"touch_stick_down"]
const DIRECTION_ACTIONS := {
	Types.IN_UP: &"touch_up", Types.IN_DOWN: &"touch_down",
	Types.IN_LEFT: &"touch_left", Types.IN_RIGHT: &"touch_right",
}
## How far a thumb pulls for a full push, in base pixels, twice over. The stick
## follows a thumb pulled past it, so a long pull never sticks at the edge.
const STICK_SIZE := 64.0
const CELL := 18                  ## one arm of the drawn cross
const BUTTON_RADIUS := 26
const START_RADIUS := 12
## Where a touch still counts: a thumb is bigger than the drawing.
const BUTTON_TOUCH := 34.0
const START_TOUCH := 20.0
const FIRE_TEXT := "FIRE"
const START_TEXT := "START"
## In a level the same button pauses it, and says so.
const PAUSE_TEXT := "PAUSE"
const IDLE := Color(1, 1, 1, 0.35)
const LIT := Color(1.0, 0.85, 0.2, 0.8)

var _font: Texture2D = preload("res://assets/font.png")
var _start_text := START_TEXT
var _direction := 0
var _held := {}                   ## action → true while its button is down
var _stick: VirtualJoystick
var _fire: TouchScreenButton
var _start: TouchScreenButton
var _art: Node2D
var _stick_centre := Vector2.ZERO   ## where the cross stands

func _ready() -> void:
	_stick = VirtualJoystick.new()
	_stick.joystick_mode = VirtualJoystick.JOYSTICK_FOLLOWING
	_stick.joystick_size = STICK_SIZE
	_stick.tip_size = STICK_SIZE / 2.0
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
	_art = Node2D.new()
	_art.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_art.draw.connect(_paint)
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

func _send(action: StringName, pressed: bool) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	Input.parse_input_event(event)
	if pressed:
		_held[action] = true
	else:
		_held.erase(action)
	if _art != null:
		_art.queue_redraw()

## The stick takes its whole zone: a thumb lands anywhere in it and pulls. On its
## side FIRE stands in the middle of the right strip and START small in its far top
## corner, well away from FIRE: a thumb brushing it would pause the game. Upright
## the three rest on one low row, as on the console's pad: the cross on the left,
## START in the middle, FIRE on the right.
func place(view: Vector2) -> void:
	var zone := StageLayout.stick_zone(view)
	var row := StageLayout.thumb_row(view)
	var buttons := StageLayout.button_zone(view)
	_stick.position = zone.position
	_stick.size = zone.size
	if view.y > view.x:
		_stick_centre = Vector2(zone.get_center().x, row)
		_fire.position = Vector2(buttons.end.x - BUTTON_TOUCH - 6.0, row)
		_start.position = Vector2(buttons.position.x + START_TOUCH + 4.0, row + 10.0)
	else:
		_stick_centre = zone.get_center()
		_fire.position = Vector2(buttons.get_center().x, row)
		_start.position = buttons.end - Vector2(START_TOUCH + 2.0, buttons.size.y - START_TOUCH - 2.0)
	_art.queue_redraw()

func stick_rect() -> Rect2:
	return Rect2(_stick.position, _stick.size)

func fire_centre() -> Vector2:
	return _fire.position

func start_centre() -> Vector2:
	return _start.position

func set_start_text(text: String) -> void:
	_start_text = text
	if _art != null:
		_art.queue_redraw()

func start_text() -> String:
	return _start_text

## Where the cross is drawn. It stands still: a thumb may land anywhere in the
## stick's zone, but a cross jumping under it read as the button running away.
func cross_centre() -> Vector2:
	return _stick_centre

func stick_rest() -> Vector2:
	return _stick_centre

func _paint() -> void:
	_cross(_stick_centre)
	_disc(_fire.position, BUTTON_RADIUS, LIT if _held.has(&"touch_fire") else IDLE)
	_disc(_start.position, START_RADIUS, LIT if _held.has(&"touch_start") else IDLE)
	_label(FIRE_TEXT, _fire.position + Vector2(0, BUTTON_RADIUS + 4))
	_label(_start_text, _start.position + Vector2(0, START_RADIUS + 4))

## The console's cross: a centre and four arms, the one held lit.
func _cross(centre: Vector2) -> void:
	var half := CELL / 2.0
	_art.draw_rect(Rect2(centre - Vector2(half, half), Vector2(CELL, CELL)), IDLE)
	for bit in DIRECTION_ACTIONS:
		var way := Vector2.ZERO
		match bit:
			Types.IN_UP:
				way = Vector2(0, -1)
			Types.IN_DOWN:
				way = Vector2(0, 1)
			Types.IN_LEFT:
				way = Vector2(-1, 0)
			Types.IN_RIGHT:
				way = Vector2(1, 0)
		var at := centre + way * CELL - Vector2(half, half)
		_art.draw_rect(Rect2(at, Vector2(CELL, CELL)), LIT if bit == _direction else IDLE)

## A smooth circle: on a phone the layer is drawn at the screen's own resolution,
## and a circle built of the picture's pixels showed its steps.
func _disc(centre: Vector2, radius: int, color: Color) -> void:
	_art.draw_circle(centre, radius, color, true, -1.0, true)

func _label(text: String, top_centre: Vector2) -> void:
	var at := Vector2i(int(top_centre.x) - TextPainter.width_of(text) / 2, int(top_centre.y))
	TextPainter.draw_line(_art, _font, text, at, IDLE)
