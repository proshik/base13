extends GutTest

var r: Rollback

func before_each() -> void:
	r = Rollback.new(0)

func _local_through(tick: int) -> void:
	for t in range(Rollback.START, tick + 1):
		r.submit_local(t, 0)

func test_the_first_ticks_are_known_on_both_sides() -> void:
	assert_eq(r.confirmed(), Rollback.START - 1)
	for t in Rollback.START:
		assert_true(r.can_predict(t))
		assert_eq(r.inputs_for(t), [0, 0] as Array[int])

func test_with_nothing_from_the_partner_the_guess_is_no_keys() -> void:
	_local_through(8)
	assert_true(r.can_predict(8))
	assert_eq(r.inputs_for(8)[1], 0)

func test_the_guess_is_what_the_partner_held_last() -> void:
	_local_through(9)
	r.submit_remote(5, Types.IN_LEFT)
	assert_eq(r.inputs_for(9)[1], Types.IN_LEFT)

func test_a_guess_that_came_true_asks_for_nothing() -> void:
	_local_through(8)
	for t in range(5, 9):
		r.inputs_for(t)
	for t in range(5, 9):
		r.submit_remote(t, 0)
	assert_eq(r.rollback_from(), -1)
	assert_eq(r.confirmed(), 8)

func test_the_earliest_wrong_guess_is_where_to_step_back_to() -> void:
	_local_through(9)
	for t in range(5, 10):
		r.inputs_for(t)
	r.submit_remote(5, 0)
	r.submit_remote(6, Types.IN_FIRE)
	r.submit_remote(7, 0)
	assert_eq(r.rollback_from(), 6)
	r.clear_rollback()
	assert_eq(r.rollback_from(), -1)

func test_computing_again_on_real_input_is_not_a_new_mistake() -> void:
	_local_through(7)
	for t in range(5, 8):
		r.inputs_for(t)
	r.submit_remote(5, Types.IN_UP)
	assert_eq(r.rollback_from(), 5)
	r.clear_rollback()
	for t in range(5, 8):
		r.inputs_for(t)
	r.submit_remote(6, Types.IN_UP)
	assert_eq(r.rollback_from(), -1, "tick 6 was computed again on the right guess")

func test_a_repeated_packet_does_not_change_what_was_accepted() -> void:
	_local_through(5)
	r.submit_remote(5, Types.IN_UP)
	r.inputs_for(5)
	r.submit_remote(5, Types.IN_DOWN)
	assert_eq(r.inputs_for(5)[1], Types.IN_UP)
	assert_eq(r.rollback_from(), -1)

func test_the_confirmed_tick_stops_at_a_gap() -> void:
	r.submit_remote(5, 0)
	r.submit_remote(6, 0)
	r.submit_remote(8, 0)
	assert_eq(r.confirmed(), 6)
	assert_eq(r.remote_edge(), 8)

func test_past_the_window_the_game_stands() -> void:
	_local_through(40)
	var last := Rollback.START - 1 + Rollback.MAX_ROLLBACK
	assert_true(r.can_predict(last))
	assert_false(r.can_predict(last + 1))

func test_our_own_input_must_be_there() -> void:
	for t in range(5, 20):
		r.submit_remote(t, 0)
	assert_false(r.can_predict(6), "a tick is never computed on a guess about ourselves")

func test_the_guest_sees_the_same_player_order() -> void:
	var guest := Rollback.new(1)
	guest.submit_local(5, Types.IN_FIRE)
	guest.submit_remote(5, Types.IN_UP)
	assert_eq(guest.inputs_for(5), [Types.IN_UP, Types.IN_FIRE] as Array[int])

func test_hashes_that_agree() -> void:
	assert_true(r.record_hash(60, 1))
	assert_true(r.submit_remote_hash(60, 1))

func test_hashes_that_differ() -> void:
	assert_true(r.record_hash(60, 1))
	assert_false(r.submit_remote_hash(60, 2))

## The partner's hash often arrives before our tick is confirmed. Dropped as
## "unknown", a divergence would pass unseen; it waits instead.
func test_a_partner_hash_waits_for_ours() -> void:
	assert_true(r.submit_remote_hash(60, 2), "not knowing ours yet is not a desync")
	assert_false(r.record_hash(60, 1), "the waiting hash was never compared")

func test_old_ticks_are_forgotten() -> void:
	for t in range(5, 300):
		r.submit_local(t, 0)
		r.submit_remote(t, 0)
		r.inputs_for(t)
	r.forget_before(200)
	assert_lt(r._local.size(), 101)
	assert_lt(r._remote.size(), 101)
	assert_lt(r._used.size(), 101)
	assert_eq(r.inputs_for(299)[1], 0)
