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

func test_upright_stick_start_and_fire_are_one_row() -> void:
	# As on the console's pad: the cross on the left, START in the middle, FIRE on
	# the right, all where the thumbs rest.
	var view := Vector2(256, 556)
	controls.place(view)
	var row := StageLayout.thumb_row(view)
	assert_eq(controls.stick_rest().y, row)
	assert_eq(controls.fire_centre().y, row)
	assert_lt(controls.stick_rest().x, controls.start_centre().x)
	assert_lt(controls.start_centre().x, controls.fire_centre().x)
	assert_false(controls.stick_rect().has_point(controls.start_centre()),
		"a touch on START would take the stick")

func test_upright_start_is_centred_and_the_thumbs_are_symmetric() -> void:
	for view in [Vector2(256, 556), Vector2(256, 420)]:
		controls.place(view)
		assert_eq(controls.start_centre().x, view.x / 2.0)
		assert_eq(controls.start_centre().y, controls.fire_centre().y)
		assert_almost_eq(controls.cross_centre().x + controls.fire_centre().x, view.x, 0.01)

func test_a_button_depresses_holds_and_returns_without_moving_its_hit_area() -> void:
	var fire := controls.find_child("FireSurface", true, false) as Node2D
	assert_not_null(fire, "the visible button needs its own surface")
	if fire == null:
		return
	var button := controls.find_children("*", "TouchScreenButton", true, false)[0] as TouchScreenButton
	var rest := fire.position
	var hit := button.position
	button.pressed.emit()
	await get_tree().create_timer(0.12).timeout
	assert_gt(fire.position.y, rest.y, "the surface did not go down")
	assert_eq(button.position, hit, "the touch target moved with the surface")
	assert_true(Input.is_action_pressed(&"touch_fire"))
	await get_tree().create_timer(0.12).timeout
	assert_gt(fire.position.y, rest.y, "a held button sprang back")
	button.released.emit()
	await get_tree().create_timer(0.25).timeout
	assert_almost_eq(fire.position.y, rest.y, 0.01)
	assert_false(Input.is_action_pressed(&"touch_fire"))

func test_losing_focus_releases_the_stick_fire_and_start() -> void:
	controls.steer(Types.IN_LEFT)
	for button in controls.find_children("*", "TouchScreenButton", true, false):
		button.pressed.emit()
	Input.flush_buffered_events()
	controls.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	Input.flush_buffered_events()
	assert_eq(Touch.bits(), 0, "the tank would keep moving or firing")
	assert_false(Input.is_action_pressed(&"touch_start"))

func test_the_stick_takes_its_whole_strip() -> void:
	# A thumb lands anywhere in the strip and pulls; there is no spot to hit.
	controls.place(Vector2(256, 556))
	assert_eq(controls.stick_rect(), StageLayout.stick_zone(Vector2(256, 556)))

func test_a_touch_does_not_move_the_cross() -> void:
	# The cross once jumped under the thumb; it reads as the button running away.
	controls.place(Vector2(256, 556))
	var rest := controls.cross_centre()
	var touch := InputEventScreenTouch.new()
	touch.position = controls.stick_rect().position + Vector2(10, 10)
	touch.pressed = true
	Input.parse_input_event(touch)
	Input.flush_buffered_events()
	await get_tree().process_frame
	assert_eq(controls.cross_centre(), rest)
	touch.pressed = false
	Input.parse_input_event(touch)
	Input.flush_buffered_events()

func test_start_says_what_it_does() -> void:
	controls.set_start_text(TouchControls.PAUSE_TEXT)
	assert_eq(controls.start_text(), "PAUSE")
	controls.set_start_text(TouchControls.START_TEXT)
	assert_eq(controls.start_text(), "START")

func test_the_labels_can_be_drawn() -> void:
	for text in [TouchControls.FIRE_TEXT, TouchControls.START_TEXT, TouchControls.PAUSE_TEXT,
			RotateHint.TEXT]:
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
