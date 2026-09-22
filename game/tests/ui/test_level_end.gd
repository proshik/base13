extends GutTest

## A level alone still ends the way it did: the last explosion burns out over a
## second and a half, and then the screen hands the world to the campaign.
##
## The outro used to be counted in seconds off the clock and is now counted in
## ticks, so that both sides of a network game end on the same one. At sixty ticks
## a second the two are the same length, and alone every tick is confirmed the
## moment it is computed — this test stands guard over that.

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
	return node

## The index of the frame `finished` fired on, or -1. An array holds the outcome:
## a lambda captures a local by copy and the assignment would never escape.
func _run_until_finished(node: Node, limit: int) -> int:
	var seen: Array = []
	node.finished.connect(func(outcome: int) -> void: seen.append(outcome))
	for i in limit:
		node._process(FRAME)
		if not seen.is_empty():
			return i
	return -1

func test_a_cleared_level_ends_ninety_ticks_later() -> void:
	screen = _build()
	# Past the STAGE caption and into play.
	for i in 200:
		screen._process(FRAME)
	assert_eq(screen._phase, screen.Phase.PLAY, "the level never began")
	# Cleared by the core, not by setting the flag: the outro is counted from the
	# tick the core records with it.
	screen._sim.get_state().enemies_left = 0
	# Alone the world the clear happened in is the one it is seen in, a frame
	# later: the outro is ninety ticks from either.
	var seen_at := -1
	for i in 10:
		screen._process(FRAME)
		if screen._phase == screen.Phase.OUTRO:
			seen_at = screen._sim.get_state().tick
			break
	assert_gt(seen_at, 0, "the clear was never noticed")
	assert_eq(screen._sim.get_state().ended_at, seen_at,
		"alone the clear is seen in the world it happened in")
	var frames := _run_until_finished(screen, 600)
	assert_gt(frames, 0, "the level never finished")
	assert_eq(screen._sim.get_state().tick, seen_at + screen.OUTRO_TICKS,
		"the outro is not ninety ticks long")
	# At sixty frames a second that is the second and a half it always was.
	assert_between(frames + 1, screen.OUTRO_TICKS, screen.OUTRO_TICKS + 2,
		"the outro no longer lasts a second and a half")

func test_the_campaign_gets_the_world_of_the_last_tick() -> void:
	screen = _build()
	for i in 200:
		screen._process(FRAME)
	var state: WorldState = screen._sim.get_state()
	state.enemies_left = 0
	state.players[0].score = 4000
	_run_until_finished(screen, 600)
	assert_eq(screen._campaign.carryover()[0].score, 4000,
		"the score of the world the level ended on was not carried over")
