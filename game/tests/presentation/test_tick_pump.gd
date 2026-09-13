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
	assert_eq(pump.due(1.0), TickPump.MAX_CATCHUP,
		"a one-second stall must not wind sixty ticks forward at once")

func test_zero_delta_gives_nothing() -> void:
	assert_eq(pump.due(0.0), 0)

## The central property. A tick that came due but did not happen — on the
## network that is at every step, until the other side's input arrives — must
## stay in debt. Spent for nothing, it is lost forever: the slack that lockstep
## rests on drains away, and the game drops from sixty ticks a second to one
## tick per network round trip.
func test_unspent_ticks_are_not_lost() -> void:
	assert_eq(pump.due(3.0 / 60.0), 3, "three ticks have come due")
	pump.spend(1)                                   # only one was computed
	assert_eq(pump.due(0.0), 2, "the remaining two must wait their turn")
	pump.spend(2)
	assert_eq(pump.due(0.0), 0, "and nothing else has come due")

func test_waiting_for_a_partner_does_not_slow_the_game_down() -> void:
	# Ten frames waited for the other side's input, then it arrived. The game
	# must catch up exactly what it stood still for rather than fall behind
	# forever.
	for frame in 10:
		pump.due(1.0 / 60.0)
		pump.spend(0)                               # not a single tick happened
	# Time does not move on — we work off one accumulated debt.
	var caught := 0
	for frame in 10:
		var ticks := pump.due(0.0)
		caught += ticks
		pump.spend(ticks)
	assert_eq(caught, 10, "the game must catch up exactly what it stood still for")

func test_a_long_freeze_is_forgotten_rather_than_caught_up() -> void:
	# A minimised window or a minute-long stall is not the same as waiting for a
	# partner: that is measured in tens of milliseconds. A minute must not be
	# caught up, the game would skip across half the map.
	pump.due(60.0)
	var total := 0
	for frame in 200:
		var ticks := pump.due(0.0)
		total += ticks
		pump.spend(ticks)
	assert_lt(total, int(TickPump.MAX_DEBT * 60.0) + 2,
		"the debt must be bounded, or the game spends a minute catching up")

func test_reset_drops_the_accumulated_debt() -> void:
	# Exactly the case of unpausing: time passed while we stood still, but there
	# is nothing to catch up.
	pump.due(0.9)
	pump.reset()
	assert_eq(pump.due(1.0 / 120.0), 0,
		"after a reset half a frame is still half a frame, not a catch-up")
	assert_eq(pump.due(1.0 / 120.0), 1)
