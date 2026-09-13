extends GutTest

func test_player_stages_occupy_their_own_blocks() -> void:
	assert_eq(Frames.tank(Types.TankType.PLAYER, 0, Types.Dir.UP, 0), 0)
	assert_eq(Frames.tank(Types.TankType.PLAYER, 1, Types.Dir.UP, 0), 8)
	assert_eq(Frames.tank(Types.TankType.PLAYER, 3, Types.Dir.UP, 0), 24)

func test_stars_above_three_do_not_run_off_the_atlas() -> void:
	assert_eq(Frames.tank(Types.TankType.PLAYER, 9, Types.Dir.UP, 0), 24,
		"there is no fourth upgrade stage")

func test_direction_and_track_inside_a_block() -> void:
	assert_eq(Frames.tank(Types.TankType.PLAYER, 0, Types.Dir.RIGHT, 0), 2)
	assert_eq(Frames.tank(Types.TankType.PLAYER, 0, Types.Dir.RIGHT, 1), 3)
	assert_eq(Frames.tank(Types.TankType.PLAYER, 0, Types.Dir.LEFT, 1), 7)

func test_enemies_start_after_the_player_block() -> void:
	assert_eq(Frames.tank(Types.TankType.BASIC, 0, Types.Dir.UP, 0), 32)
	assert_eq(Frames.tank(Types.TankType.FAST, 0, Types.Dir.UP, 0), 40)
	assert_eq(Frames.tank(Types.TankType.ARMOR, 0, Types.Dir.UP, 0), 56)

func test_bonus_frames_follow_the_enum() -> void:
	assert_eq(Frames.bonus(Types.BonusType.HELMET), 78)
	assert_eq(Frames.bonus(Types.BonusType.TANK), 83)

func test_terrain_frames() -> void:
	assert_eq(Frames.terrain(Types.Cell.BRICK, 0), 0)
	assert_eq(Frames.terrain(Types.Cell.STEEL, 0), 1)
	assert_eq(Frames.terrain(Types.Cell.TREES, 0), 4)
	assert_eq(Frames.terrain(Types.Cell.ICE, 0), 5)
	assert_eq(Frames.terrain(Types.Cell.EMPTY, 0), -1, "an empty cell is not drawn")

func test_water_animates_with_time() -> void:
	assert_eq(Frames.terrain(Types.Cell.WATER, 0), 2)
	assert_eq(Frames.terrain(Types.Cell.WATER, Frames.WATER_PERIOD), 3)
	assert_eq(Frames.terrain(Types.Cell.WATER, Frames.WATER_PERIOD * 2), 2)

func test_tracks_follow_position_not_time() -> void:
	var still := Vector2i(1024, 1024)
	assert_eq(Frames.track_of(still), Frames.track_of(still),
		"a standing tank does not shuffle its tracks")
	assert_ne(Frames.track_of(still), Frames.track_of(still + Vector2i(Frames.TRACK_STEP, 0)),
		"after TRACK_STEP of travel the tank changes its track frame")

func test_spawn_flash_cycles_through_four_frames() -> void:
	var seen := {}
	for ticks in 60:
		seen[Frames.flash(ticks)] = true
	assert_eq(seen.size(), 4, "the spawn flash is four frames")
	for frame in seen:
		assert_between(frame, 66, 69, "the flash lives in frames 66..69")

func test_explosion_frames_are_clamped_at_the_last_one() -> void:
	assert_eq(Frames.boom_big(0), 73)
	assert_eq(Frames.boom_big(Frames.BOOM_BIG_FRAMES - 1), 77)
	assert_eq(Frames.boom_big(999), 77, "walking through the age never leaves the atlas")
	assert_eq(Frames.boom_small(0), 70)
	assert_eq(Frames.boom_small(999), 72)
