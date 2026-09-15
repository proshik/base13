extends GutTest

var pump: TickPump

func before_each() -> void:
	pump = TickPump.new()

func test_one_frame_at_sixty_hertz_is_one_tick() -> void:
	assert_eq(pump.due(1.0 / 60.0), 1)

func test_short_frames_accumulate() -> void:
	assert_eq(pump.due(1.0 / 120.0), 0, "half a frame is not a tick yet")
	assert_eq(pump.due(1.0 / 120.0), 1, "two halves make a tick")

func test_long_frame_gives_several_ticks() -> void:
	assert_eq(pump.due(3.0 / 60.0), 3)

func test_catchup_is_capped_per_frame() -> void:
	assert_eq(pump.due(0.4), TickPump.MAX_CATCHUP,
		"a dropped frame must not wind twenty-four ticks forward at once")

func test_zero_delta_gives_nothing() -> void:
	assert_eq(pump.due(0.0), 0)

## A tick that came due but did not happen stays in debt: time is spent on ticks
## that happened.
func test_unspent_ticks_are_not_lost() -> void:
	assert_eq(pump.due(3.0 / 60.0), 3, "three ticks have come due")
	pump.spend(1)                                   # only one was computed
	assert_eq(pump.due(0.0), 2, "the remaining two must wait their turn")
	pump.spend(2)
	assert_eq(pump.due(0.0), 0, "and nothing else has come due")

## Half of a wait on the partner is caught up and half is let go. All of it put
## the side that waited at the very edge of the partner's input for good, where
## every late packet froze its picture and its alone; none of it made every wait
## cost the game its time while the network fell short.
func test_a_wait_on_the_partner_is_caught_up_by_half() -> void:
	for frame in 10:
		pump.due(1.0 / 60.0)
		pump.spend(0, true)                         # the partner's input is not here
	var caught := 0
	for frame in 10:
		var ticks := pump.due(0.0)
		caught += ticks
		pump.spend(ticks)
	assert_eq(caught, 5, "ten ticks of waiting must come back as five")

## Frames that end short of the tick count because the partner is late, not
## because the frame was short — only those let anything go.
func test_a_frame_that_did_not_wait_lets_nothing_go() -> void:
	pump.due(3.0 / 60.0)
	pump.spend(1)
	assert_eq(pump.due(0.0), 2)

func test_a_long_freeze_is_forgotten_rather_than_caught_up() -> void:
	# A minimised window or a hidden browser tab is not a late packet: that is
	# measured in tens of milliseconds. A minute must not be caught up, the game
	# would skip across half the map.
	pump.due(60.0)
	var total := 0
	for frame in 200:
		var ticks := pump.due(0.0)
		total += ticks
		pump.spend(ticks)
	assert_eq(total, 0, "a freeze is forgotten whole")

## The same freeze seen from the other side: the partner's tab is hidden and we
## stand waiting. Cut down to the ceiling rather than forgotten, the two sides
## came back holding different debts, and the one holding more raced to the edge
## of the other's input and stood there for the rest of the level.
func test_standing_for_a_frozen_partner_is_forgotten_too() -> void:
	for frame in 60:
		pump.due(1.0 / 60.0)
		pump.spend(0, true)
	assert_eq(pump.due(1.0 / 60.0), 1,
		"when the partner is back there is one tick due, not a backlog")

## Regression: forgetting on every frame of a long stand froze the game for good.
## A frame at sixty hertz is 16.666 ms, a hair short of a tick, so with the debt
## wiped each frame nothing was ever due again, and the partner's input sat there
## unasked for.
func test_a_long_stand_never_stops_asking() -> void:
	for frame in 60:
		pump.due(1.0 / 60.0)
		pump.spend(0, true)
	var asked := 0
	for frame in 10:
		var ticks := pump.due(0.016666)
		if ticks > 0:
			asked += 1
		pump.spend(0, ticks > 0)
	assert_gt(asked, 0, "the game must keep asking for the next tick")

func test_reset_drops_the_accumulated_debt() -> void:
	# Exactly the case of unpausing: time passed while we stood still, but there
	# is nothing to catch up.
	pump.due(0.9)
	pump.reset()
	assert_eq(pump.due(1.0 / 120.0), 0,
		"after a reset half a frame is still half a frame, not a catch-up")
	assert_eq(pump.due(1.0 / 120.0), 1)
