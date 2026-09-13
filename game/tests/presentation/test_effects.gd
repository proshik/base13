extends GutTest

var fx: Effects

func before_each() -> void:
	fx = Effects.new()

func _event(type: int, pos := Vector2i(1024, 1024)) -> SimEvent:
	return SimEvent.new(type, pos, 0)

func test_no_events_no_effects() -> void:
	fx.absorb([])
	assert_eq(fx.items().size(), 0)

func test_destroyed_tank_makes_a_big_burst() -> void:
	fx.absorb([_event(Types.Event.TANK_DESTROYED)])
	var items := fx.items()
	assert_eq(items.size(), 1)
	assert_eq(items[0].frame, Frames.boom_big(0))
	assert_eq(items[0].pos, Vector2i(64, 64), "the big explosion takes the tank's place")

func test_brick_hit_makes_a_small_burst() -> void:
	fx.absorb([_event(Types.Event.BULLET_HIT_BRICK)])
	assert_eq(fx.items()[0].frame, Frames.boom_small(0))

func test_small_burst_is_centred_on_the_point() -> void:
	fx.absorb([_event(Types.Event.BULLET_HIT_BRICK, Vector2i(1024, 1024))])
	assert_eq(fx.items()[0].pos, Vector2i(64 - 8, 64 - 8),
		"a hit is a point, while the explosion sprite is sixteen pixels")

func test_frames_advance_with_age() -> void:
	fx.absorb([_event(Types.Event.TANK_DESTROYED)])
	for i in Effects.FRAME_TICKS:
		fx.advance()
	assert_eq(fx.items()[0].frame, Frames.boom_big(1))

func test_big_burst_dies_out() -> void:
	fx.absorb([_event(Types.Event.TANK_DESTROYED)])
	for i in Effects.BIG_LIFETIME:
		fx.advance()
	assert_eq(fx.items().size(), 0, "an explosion must burn out, or hundreds of them pile up")

func test_small_burst_dies_out_sooner() -> void:
	assert_lt(Effects.SMALL_LIFETIME, Effects.BIG_LIFETIME)
	fx.absorb([_event(Types.Event.BULLET_HIT_BRICK)])
	for i in Effects.SMALL_LIFETIME:
		fx.advance()
	assert_eq(fx.items().size(), 0)

func test_ignored_events_make_nothing() -> void:
	fx.absorb([_event(Types.Event.SHOT_FIRED), _event(Types.Event.BONUS_SPAWNED),
		_event(Types.Event.ENEMY_SPAWNED), _event(Types.Event.LEVEL_CLEARED)])
	assert_eq(fx.items().size(), 0, "not every event is an explosion")

func test_several_bursts_live_side_by_side() -> void:
	fx.absorb([_event(Types.Event.TANK_DESTROYED, Vector2i(0, 0)),
		_event(Types.Event.PLAYER_DESTROYED, Vector2i(512, 0)),
		_event(Types.Event.BASE_DESTROYED, Vector2i(0, 512))])
	assert_eq(fx.items().size(), 3)

func test_effects_are_drawn_over_everything() -> void:
	fx.absorb([_event(Types.Event.TANK_DESTROYED)])
	assert_eq(fx.items()[0].layer, ViewModel.Layer.OVER)
