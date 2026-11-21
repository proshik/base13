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

func test_fire_that_resumed_does_not_fire_until_let_go() -> void:
	screen = _build()
	var source := LocalInput.new()
	screen.use_input(source)
	screen._unhandled_input(_action(&"touch_start"))
	Input.action_press(&"touch_fire")
	screen._unhandled_input(_action(&"touch_fire"))
	assert_false(screen._paused)
	assert_eq(source.inputs_for(0)[0] & Types.IN_FIRE, 0, "RESUME fired")
	Input.action_release(&"touch_fire")
	assert_eq(source.inputs_for(0)[0] & Types.IN_FIRE, 0)
	Input.action_press(&"touch_fire")
	assert_eq(source.inputs_for(0)[0] & Types.IN_FIRE, Types.IN_FIRE, "a fresh press was held back")
	Input.action_release(&"touch_fire")

class _Held extends LocalInput:
	var now := [0, 0]
	func _held_now(player: int) -> int:
		return now[player]

func test_the_second_player_resuming_does_not_fire_either() -> void:
	# At one keyboard either player may answer the pause; the one who did must
	# not fire with the key that answered.
	var source := _Held.new()
	source.menu_shown(true)
	source.now[1] = Types.IN_FIRE
	source.menu_shown(false)
	assert_eq(source.inputs_for(0)[1], 0, "player two's RESUME fired")
	source.now[1] = 0
	source.inputs_for(0)
	source.now[1] = Types.IN_FIRE | Types.IN_UP
	assert_eq(source.inputs_for(0)[1], Types.IN_FIRE | Types.IN_UP, "a fresh press was held back")

class _Quiet extends Link:
	pass

func test_leave_match_does_not_latch_its_presses() -> void:
	screen = _build()
	screen.use_input(NetInput.new(_Quiet.new(), 0, func(_t: int) -> int: return 0))
	screen._unhandled_input(_action(&"touch_start"))
	assert_true(screen._leaving)
	PressLatch.clear()
	for child in screen.get_children():
		if child is PressFeed:
			child._input(_action(&"touch_fire"))
			var up := _action(&"touch_fire")
			up.pressed = false
			child._input(up)
	assert_eq(PressLatch.take(0), 0, "a tap on RESUME was kept for the tank")
	PressLatch.clear()

func test_the_items_can_be_drawn() -> void:
	for text in PauseOverlay.ITEMS:
		for i in text.length():
			assert_true(TextPainter.glyph_index(text[i]) >= 0, "'%s' cannot be drawn" % text)
