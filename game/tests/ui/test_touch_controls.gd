extends GutTest

## The layer that turns the engine's stick and buttons into `touch_*` actions: one
## event a change, so a menu sees one flick as one press, and nothing is left held.

var controls: TouchControls

func before_each() -> void:
	controls = TouchControls.new()
	add_child_autofree(controls)

func after_each() -> void:
	controls.steer(0)
	for action in Touch.ACTIONS:
		Input.action_release(action)
	Input.action_release(&"touch_start")
	Input.flush_buffered_events()

func test_a_direction_is_held_until_it_changes() -> void:
	controls.steer(Types.IN_UP)
	Input.flush_buffered_events()
	assert_eq(Touch.bits(), Types.IN_UP)
	controls.steer(Types.IN_LEFT)
	Input.flush_buffered_events()
	assert_eq(Touch.bits(), Types.IN_LEFT, "the old direction was left held")
	controls.steer(0)
	Input.flush_buffered_events()
	assert_eq(Touch.bits(), 0)

func test_the_same_direction_sends_nothing_new() -> void:
	var seen: Array = []
	var spy := _Spy.new(seen)
	add_child_autofree(spy)
	controls.steer(Types.IN_DOWN)
	controls.steer(Types.IN_DOWN)
	Input.flush_buffered_events()
	await get_tree().process_frame
	assert_eq(seen.count("touch_down"), 1, "a menu would move twice")

func test_the_controls_stay_off_the_picture() -> void:
	# An iPhone in landscape: 633 across, the picture from 188 to 444.
	controls.place(Vector2(633, 240))
	var stick := controls.stick_rect()
	assert_lte(stick.end.x, 188.0, "the stick covers the field")
	assert_gte(controls.fire_centre().x - TouchControls.BUTTON_RADIUS, 444.0,
		"FIRE covers the panel")

func test_upright_the_controls_stay_below_the_picture() -> void:
	var view := Vector2(256, 556)
	controls.place(view)
	var bottom := StageLayout.picture_at(view).y + StageLayout.BASE.y
	assert_gte(controls.stick_rect().position.y, float(bottom), "the stick covers the field")
	assert_gte(controls.fire_centre().y - TouchControls.BUTTON_RADIUS, float(bottom),
		"FIRE covers the field")
	assert_gte(controls.start_centre().y - TouchControls.START_RADIUS, float(bottom),
		"START covers the field")

func test_start_is_well_away_from_fire() -> void:
	# A thumb on FIRE must not pause the game by brushing START.
	for view in [Vector2(256, 556), Vector2(256, 420), Vector2(633, 240), Vector2(560, 240)]:
		controls.place(view)
		var gap := controls.fire_centre().distance_to(controls.start_centre())
		assert_gt(gap, TouchControls.BUTTON_TOUCH + TouchControls.START_TOUCH + 8.0,
			"FIRE and START too close at %s" % view)

func test_the_stick_takes_its_whole_strip() -> void:
	# A thumb lands anywhere in the strip and pulls; there is no spot to hit.
	controls.place(Vector2(256, 556))
	assert_eq(controls.stick_rect(), StageLayout.stick_zone(Vector2(256, 556)))

func test_the_labels_can_be_drawn() -> void:
	for text in [TouchControls.FIRE_TEXT, TouchControls.START_TEXT, RotateHint.TEXT]:
		for i in text.length():
			if text[i] == " ":
				continue
			assert_true(TextPainter.glyph_index(text[i]) >= 0, "'%s' cannot be drawn" % text)

class _Spy extends Node:
	var _seen: Array
	func _init(seen: Array) -> void:
		_seen = seen
	func _input(event: InputEvent) -> void:
		if event is InputEventAction and event.pressed:
			_seen.append(String(event.action))
