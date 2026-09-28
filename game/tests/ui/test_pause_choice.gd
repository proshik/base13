extends GutTest

## The pause and the leave question are a choice of two, driven like a menu: a
## phone and a pad have no Q, and a pad could pause but never quit.

const FRAME := 1.0 / 60.0

var screen: Node = null

func after_each() -> void:
	if screen != null:
		screen.queue_free()
		screen = null

func _build() -> Node:
	var node: Node = load("res://ui/game.tscn").instantiate()
	add_child_autofree(node)
	node.configure(Campaign.new(1, SimConfig.new(), 4242), 1, 0)
	for i in 200:
		node._process(FRAME)
	return node

func _action(name: StringName) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = name
	e.pressed = true
	return e

func test_start_pauses_and_resumes() -> void:
	screen = _build()
	screen._unhandled_input(_action(&"touch_start"))
	assert_true(screen._paused)
	screen._unhandled_input(_action(&"touch_start"))
	assert_false(screen._paused)

func test_fire_on_resume_resumes() -> void:
	screen = _build()
	screen._unhandled_input(_action(&"touch_start"))
	screen._unhandled_input(_action(&"touch_fire"))
	assert_false(screen._paused)

func test_down_and_fire_quit() -> void:
	screen = _build()
	watch_signals(screen)
	screen._unhandled_input(_action(&"touch_start"))
	screen._unhandled_input(_action(&"touch_down"))
	screen._unhandled_input(_action(&"touch_fire"))
	assert_signal_emitted_with_parameters(screen, "finished", [ScreenFlow.Outcome.QUIT])

func test_a_new_pause_starts_on_resume() -> void:
	# Quit left chosen from the last pause would make the next FIRE end the game.
	screen = _build()
	screen._unhandled_input(_action(&"touch_start"))
	screen._unhandled_input(_action(&"touch_down"))
	screen._unhandled_input(_action(&"touch_start"))
	screen._unhandled_input(_action(&"touch_start"))
	screen._unhandled_input(_action(&"touch_fire"))
	assert_false(screen._paused)

func test_fire_in_play_is_not_a_choice() -> void:
	screen = _build()
	watch_signals(screen)
	screen._unhandled_input(_action(&"touch_down"))
	screen._unhandled_input(_action(&"touch_fire"))
	assert_signal_not_emitted(screen, "finished")
	assert_false(screen._paused)

func test_the_items_can_be_drawn() -> void:
	for text in PauseOverlay.ITEMS:
		for i in text.length():
			assert_true(TextPainter.glyph_index(text[i]) >= 0, "'%s' cannot be drawn" % text)
