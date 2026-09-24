extends GutTest

## A press that begins and ends between two frames. Keys used to be read only by
## level — which are held at the moment a tick is captured — so a tap made while a
## frame hung, and released before the next one, reached no tick at all: no shot,
## no turn. The events go through the engine's own input, the way a keyboard's do,
## and the screen reads them the way it reads a real key.

const FRAME := 1.0 / 60.0

var screen: Node = null

func before_each() -> void:
	PressLatch.clear()

func after_each() -> void:
	if screen != null:
		screen.queue_free()
		screen = null
	PressLatch.clear()

## Past the STAGE caption and the tank's blinking: a tank still blinking in does
## not fire.
func _play() -> Node:
	var node: Node = load("res://ui/game.tscn").instantiate()
	add_child_autofree(node)
	node.configure(Campaign.new(1, SimConfig.new(), 4242), 1, 0)
	for i in 300:
		node._process(FRAME)
	assert_eq(node._phase, node.Phase.PLAY, "the level never began")
	assert_eq(_tank(node).spawn_ticks, 0, "the tank is still blinking in")
	return node

## Turned left by holding the key, the way that always worked: a brick stands right
## above the spawn point, and a shot up would die in the tick it was fired.
func _face_the_open_field(node: Node) -> void:
	Input.parse_input_event(_key(KEY_LEFT, true))
	Input.flush_buffered_events()
	node._process(FRAME)
	Input.parse_input_event(_key(KEY_LEFT, false))
	Input.flush_buffered_events()
	node._process(FRAME)
	assert_eq(_tank(node).dir, Types.Dir.LEFT, "the held key did not turn the tank")

func _tank(node: Node) -> Entities.Tank:
	return node._sim.get_state().player_tanks()[0]

func _key(physical: int, pressed: bool) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = physical
	e.keycode = physical
	e.pressed = pressed
	return e

## Down and up again before the next frame: the key is no longer held by the time
## the ticks are captured.
func _tap(physical: int) -> void:
	Input.parse_input_event(_key(physical, true))
	Input.parse_input_event(_key(physical, false))
	Input.flush_buffered_events()
	assert_false(Input.is_physical_key_pressed(physical), "the tap is still held")

func test_a_tap_between_frames_fires() -> void:
	screen = _play()
	_face_the_open_field(screen)
	var before: int = screen._sim.get_state().bullets.size()
	_tap(KEY_SPACE)
	screen._process(FRAME)
	assert_eq(screen._sim.get_state().bullets.size(), before + 1, "the tap fired nothing")

func test_a_tap_between_frames_turns_the_tank() -> void:
	screen = _play()
	assert_eq(_tank(screen).dir, Types.Dir.UP)
	_tap(KEY_LEFT)
	screen._process(FRAME)
	assert_eq(_tank(screen).dir, Types.Dir.LEFT, "the tap did not turn the tank")

func test_a_tap_during_a_hung_frame_fires() -> void:
	screen = _play()
	_face_the_open_field(screen)
	var before: int = screen._sim.get_state().bullets.size()
	_tap(KEY_SPACE)
	# A third of a second: the frame catches up as many ticks as it may.
	screen._process(0.3)
	assert_eq(screen._sim.get_state().bullets.size(), before + 1)

func test_player_two_taps_reach_player_two() -> void:
	var node: Node = load("res://ui/game.tscn").instantiate()
	add_child_autofree(node)
	node.configure(Campaign.new(2, SimConfig.new(), 4242), 2, 0)
	for i in 300:
		node._process(FRAME)
	screen = node
	var second: Entities.Tank = node._sim.get_state().player_tanks()[1]
	assert_eq(second.dir, Types.Dir.UP)
	_tap(KEY_A)
	node._process(FRAME)
	assert_eq(second.dir, Types.Dir.LEFT, "WASD's tap did not reach player two")
	assert_eq(_tank(node).dir, Types.Dir.UP, "player two's tap moved player one")

func test_a_tap_behind_the_pause_is_not_played_after_it() -> void:
	screen = _play()
	_face_the_open_field(screen)
	var before: int = screen._sim.get_state().bullets.size()
	screen._toggle_pause()
	_tap(KEY_SPACE)
	screen._toggle_pause()
	screen._process(FRAME)
	assert_eq(screen._sim.get_state().bullets.size(), before,
		"a press made while the world stood still fired once it moved")

func test_a_tap_behind_a_network_caption_is_not_played_after_it() -> void:
	# WAITING FOR PARTNER or RECONNECTING: the world stands still behind it, as
	# behind the pause. The caption is put up by hand — alone nothing stands.
	screen = _play()
	_face_the_open_field(screen)
	var before: int = screen._sim.get_state().bullets.size()
	screen._show_status("WAITING FOR PARTNER")
	_tap(KEY_SPACE)
	screen._show_status("")
	screen._process(FRAME)
	assert_eq(screen._sim.get_state().bullets.size(), before,
		"a press made behind WAITING FOR PARTNER fired once the world moved")

func test_a_tap_behind_the_caption_is_not_played_after_it() -> void:
	var node: Node = load("res://ui/game.tscn").instantiate()
	add_child_autofree(node)
	node.configure(Campaign.new(1, SimConfig.new(), 4242), 1, 0)
	screen = node
	node._process(FRAME)
	assert_eq(node._phase, node.Phase.INTRO)
	_tap(KEY_LEFT)
	for i in 300:
		node._process(FRAME)
	assert_eq(_tank(node).dir, Types.Dir.UP,
		"a press made behind STAGE N turned the tank once play began")
