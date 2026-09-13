extends GutTest

func _event(type: int) -> SimEvent:
	return SimEvent.new(type, Vector2i.ZERO, 0)

func test_every_event_has_a_sound() -> void:
	# If a new event is added to the core, this test will remind us to give it a
	# sound as well.
	for value in Types.Event.values():
		assert_ne(Audio.sound_for(value), "",
			"event %d was left without a sound" % value)

func test_unknown_event_is_silent_but_does_not_break() -> void:
	assert_eq(Audio.sound_for(9999), "")

func test_shot_and_explosion_are_different_sounds() -> void:
	assert_ne(Audio.sound_for(Types.Event.SHOT_FIRED),
		Audio.sound_for(Types.Event.TANK_DESTROYED))

func test_repeated_events_collapse_into_one_sound() -> void:
	var events := [_event(Types.Event.BULLET_HIT_BRICK),
		_event(Types.Event.BULLET_HIT_BRICK),
		_event(Types.Event.BULLET_HIT_BRICK)]
	assert_eq(Audio.names_for(events).size(), 1,
		"four crumbled cells are one click, not four")

func test_different_events_all_sound() -> void:
	var events := [_event(Types.Event.SHOT_FIRED), _event(Types.Event.TANK_DESTROYED)]
	assert_eq(Audio.names_for(events),
		[Audio.sound_for(Types.Event.SHOT_FIRED),
		Audio.sound_for(Types.Event.TANK_DESTROYED)] as Array[String])

func test_order_follows_the_events() -> void:
	var events := [_event(Types.Event.TANK_DESTROYED), _event(Types.Event.SHOT_FIRED)]
	assert_eq(Audio.names_for(events)[0], Audio.sound_for(Types.Event.TANK_DESTROYED))

func test_empty_input_gives_nothing() -> void:
	assert_eq(Audio.names_for([]).size(), 0)

func test_every_named_sound_has_a_file() -> void:
	# A typo in the mapping table would otherwise surface only by ear.
	for value in Types.Event.values():
		var name: String = Audio.sound_for(value)
		assert_true(ResourceLoader.exists(Audio.SFX_PATH % name),
			"event %d names a sound that does not exist: %s" % [value, name])

func test_engine_changes_tone_when_moving() -> void:
	assert_ne(Audio.engine_sound(true, true), Audio.engine_sound(true, false),
		"a moving and a standing tank sound different, and that is what makes it recognisable")

func test_engine_is_silent_without_a_tank() -> void:
	assert_eq(Audio.engine_sound(false, true), "",
		"a destroyed tank's engine does not hum")
	assert_eq(Audio.engine_sound(false, false), "")

func test_engine_sounds_are_the_looped_ones() -> void:
	assert_eq(Audio.engine_sound(true, false), "engine_idle")
	assert_eq(Audio.engine_sound(true, true), "engine_move")
