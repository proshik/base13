extends GutTest

var filter: EventFilter

func before_each() -> void:
	filter = EventFilter.new()

func _e(type: int, x: int, data := 0) -> SimEvent:
	return SimEvent.new(type, Vector2i(x, 0), data)

func test_the_first_time_everything_is_new() -> void:
	var events := [_e(Types.Event.SHOT_FIRED, 1), _e(Types.Event.BULLET_HIT_BRICK, 2)]
	assert_eq(filter.fresh(10, events).size(), 2)

func test_computing_a_tick_again_shows_nothing_twice() -> void:
	filter.fresh(10, [_e(Types.Event.SHOT_FIRED, 1)])
	assert_eq(filter.fresh(10, [_e(Types.Event.SHOT_FIRED, 1)]), [])

func test_what_is_new_on_the_second_pass_is_shown() -> void:
	filter.fresh(10, [_e(Types.Event.SHOT_FIRED, 1)])
	var out := filter.fresh(10, [_e(Types.Event.TANK_DESTROYED, 5)])
	assert_eq(out.size(), 1)
	assert_eq(out[0].type, Types.Event.TANK_DESTROYED)

func test_what_vanished_is_not_shown_again_when_it_returns() -> void:
	filter.fresh(10, [_e(Types.Event.SHOT_FIRED, 1)])
	filter.fresh(10, [])
	assert_eq(filter.fresh(10, [_e(Types.Event.SHOT_FIRED, 1)]), [],
		"a sound once played stays played for its tick")

func test_identical_events_on_one_tick_are_counted() -> void:
	var hit := func() -> SimEvent: return _e(Types.Event.BULLET_HIT_BRICK, 3)
	filter.fresh(10, [hit.call(), hit.call()])
	assert_eq(filter.fresh(10, [hit.call(), hit.call(), hit.call()]).size(), 1)

func test_the_same_event_on_another_tick_is_another_event() -> void:
	filter.fresh(10, [_e(Types.Event.SHOT_FIRED, 1)])
	assert_eq(filter.fresh(11, [_e(Types.Event.SHOT_FIRED, 1)]).size(), 1)

func test_payload_tells_events_apart() -> void:
	filter.fresh(10, [_e(Types.Event.SHOT_FIRED, 1, 0)])
	assert_eq(filter.fresh(10, [_e(Types.Event.SHOT_FIRED, 1, 2)]).size(), 1)

func test_old_ticks_are_forgotten() -> void:
	for t in 100:
		filter.fresh(t, [_e(Types.Event.SHOT_FIRED, 1)])
	filter.forget_before(90)
	assert_eq(filter._shown.size(), 10)
