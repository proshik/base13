extends GutTest

var ls: Lockstep

func before_each() -> void:
	# The local player is slot zero, the partner slot one.
	ls = Lockstep.new(0)

func test_first_ticks_are_playable_because_the_buffer_starts_filled() -> void:
	# The input delay means that for the first few ticks neither side pressed
	# anything at all: otherwise a game could never begin.
	for i in Lockstep.DELAY:
		assert_true(ls.can_advance(i), "tick %d must be ready at once" % i)
		assert_eq(ls.inputs_for(i), [0, 0] as Array[int])

func test_a_tick_waits_for_both_sides() -> void:
	var tick := Lockstep.DELAY
	assert_false(ls.can_advance(tick), "a tick cannot be computed without both sides' input")
	ls.submit_local(tick, Types.IN_UP)
	assert_false(ls.can_advance(tick), "one's own input is not enough")
	ls.submit_remote(tick, Types.IN_LEFT)
	assert_true(ls.can_advance(tick))

func test_inputs_arrive_in_the_order_of_players() -> void:
	var tick := Lockstep.DELAY
	ls.submit_local(tick, Types.IN_UP)
	ls.submit_remote(tick, Types.IN_LEFT)
	assert_eq(ls.inputs_for(tick), [Types.IN_UP, Types.IN_LEFT] as Array[int])

func test_the_second_player_sees_the_mirror_order() -> void:
	# The guest's own input is their own too, but it must sit second in the
	# array: player order is identical on both sides, or the worlds diverge.
	var guest := Lockstep.new(1)
	var tick := Lockstep.DELAY
	guest.submit_local(tick, Types.IN_UP)
	guest.submit_remote(tick, Types.IN_LEFT)
	assert_eq(guest.inputs_for(tick), [Types.IN_LEFT, Types.IN_UP] as Array[int])

func test_local_press_applies_after_the_delay() -> void:
	# A press on tick 0 applies on tick DELAY: in that time the packet reaches
	# the partner.
	assert_eq(ls.tick_for_press(0), Lockstep.DELAY)
	ls.press(0, Types.IN_FIRE)
	assert_eq(ls.inputs_for(0)[0], 0, "on the current tick the press does not apply yet")
	ls.submit_remote(Lockstep.DELAY, 0)
	assert_eq(ls.inputs_for(Lockstep.DELAY)[0], Types.IN_FIRE)

func test_out_of_order_arrival_is_fine() -> void:
	var a := Lockstep.DELAY
	var b := Lockstep.DELAY + 1
	ls.submit_remote(b, Types.IN_DOWN)
	ls.submit_remote(a, Types.IN_UP)
	ls.submit_local(a, 0)
	ls.submit_local(b, 0)
	assert_eq(ls.inputs_for(a)[1], Types.IN_UP)
	assert_eq(ls.inputs_for(b)[1], Types.IN_DOWN)

func test_duplicate_packet_does_not_change_anything() -> void:
	var tick := Lockstep.DELAY
	ls.submit_remote(tick, Types.IN_UP)
	ls.submit_remote(tick, Types.IN_DOWN)
	assert_eq(ls.inputs_for(tick)[1], Types.IN_UP,
		"a repeated packet must not overwrite input already accepted")

func test_unknown_tick_reads_as_no_input() -> void:
	assert_eq(ls.inputs_for(9999), [0, 0] as Array[int],
		"reading an unknown tick must not crash the game")

func test_forgetting_the_past_keeps_the_buffer_bounded() -> void:
	# A game runs for hours; there is no reason to keep all the input.
	for tick in range(Lockstep.DELAY, Lockstep.DELAY + 1000):
		ls.submit_local(tick, 0)
		ls.submit_remote(tick, 0)
		ls.forget_before(tick - Lockstep.KEEP)
	assert_lte(ls.buffered(), Lockstep.KEEP + Lockstep.DELAY + 2,
		"the buffer must stay bounded")

func test_hash_agreement() -> void:
	ls.record_local_hash(60, 12345)
	assert_true(ls.check_remote_hash(60, 12345), "identical hashes mean agreement")

func test_hash_disagreement_is_reported() -> void:
	ls.record_local_hash(60, 12345)
	assert_false(ls.check_remote_hash(60, 999), "a divergence must be noticed")

func test_hash_for_an_unknown_tick_is_not_a_disagreement() -> void:
	# The partner ran ahead of us with the comparison — that is not a desync but
	# an everyday occurrence.
	assert_true(ls.check_remote_hash(600, 42))
