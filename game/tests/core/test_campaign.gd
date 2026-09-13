extends GutTest

var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()

func _finished(cleared: bool, lives: Array, scores: Array,
		base_alive := true) -> WorldState:
	var s := WorldState.new()
	s.terrain = Terrain.new()
	s.level_cleared = cleared
	s.game_over = not cleared
	s.base_alive = base_alive
	for i in lives.size():
		var p := Entities.PlayerState.new()
		p.index = i
		p.lives = lives[i]
		p.score = scores[i]
		p.stars = 3
		s.players.append(p)
	return s

func test_starts_at_the_first_level_with_full_lives() -> void:
	var c := Campaign.new(1, cfg, 7)
	assert_eq(c.level_number, 1)
	assert_eq(c.level_file(), 1)
	assert_eq(c.carryover()[0].lives, cfg.start_lives)
	assert_eq(c.carryover()[0].score, 0)
	assert_false(c.game_over)

func test_clearing_a_level_advances_it() -> void:
	var c := Campaign.new(1, cfg, 7)
	c.finish_level(_finished(true, [2], [1500]))
	assert_eq(c.level_number, 2)
	assert_false(c.game_over)

func test_lives_and_score_travel_but_stars_do_not() -> void:
	var c := Campaign.new(1, cfg, 7)
	c.finish_level(_finished(true, [2], [1500]))
	assert_eq(c.carryover()[0].lives, 2)
	assert_eq(c.carryover()[0].score, 1500)
	assert_eq(c.carryover()[0].stars, 0,
		"upgrades reset between levels, as in the original")

func test_level_files_wrap_after_thirty_five() -> void:
	var c := Campaign.new(1, cfg, 7)
	for i in 35:
		c.finish_level(_finished(true, [3], [0]))
	assert_eq(c.level_number, 36)
	assert_eq(c.level_file(), 1, "after the thirty-fifth we play the first again")

func test_level_number_keeps_growing_after_the_wrap() -> void:
	# The level number drives the AI's aggression: on the second lap the enemies
	# are meaner.
	var c := Campaign.new(1, cfg, 7)
	for i in 40:
		c.finish_level(_finished(true, [3], [0]))
	assert_eq(c.level_number, 41)
	assert_gt(c.level_number, cfg.ai_late_level)

func test_losing_the_base_ends_the_campaign() -> void:
	var c := Campaign.new(1, cfg, 7)
	c.finish_level(_finished(false, [2], [800], false))
	assert_true(c.game_over)
	assert_eq(c.level_number, 1, "a lost level does not count")

func test_running_out_of_lives_ends_the_campaign() -> void:
	var c := Campaign.new(1, cfg, 7)
	c.finish_level(_finished(false, [0], [800]))
	assert_true(c.game_over)

func test_seed_is_reproducible_and_differs_per_level() -> void:
	var a := Campaign.new(1, cfg, 12345)
	var b := Campaign.new(1, cfg, 12345)
	assert_eq(a.level_seed(), b.level_seed(), "one base means one seed")
	var first := a.level_seed()
	a.finish_level(_finished(true, [3], [0]))
	assert_ne(a.level_seed(), first, "every level has its own seed")

func test_different_base_seeds_give_different_games() -> void:
	assert_ne(Campaign.new(1, cfg, 1).level_seed(), Campaign.new(1, cfg, 2).level_seed())

func test_two_players_keep_separate_rows() -> void:
	var c := Campaign.new(2, cfg, 7)
	c.finish_level(_finished(true, [1, 3], [100, 900]))
	assert_eq(c.carryover()[0].lives, 1)
	assert_eq(c.carryover()[1].lives, 3)
	assert_eq(c.total_score(), 1000)

func test_second_player_out_of_lives_does_not_end_the_game() -> void:
	var c := Campaign.new(2, cfg, 7)
	c.finish_level(_finished(true, [2, 0], [100, 900]))
	assert_false(c.game_over, "while player one is alive the campaign continues")

func test_kills_of_the_finished_level_are_remembered() -> void:
	var c := Campaign.new(1, cfg, 7)
	var s := _finished(true, [3], [400])
	s.players[0].kills = [2, 1, 0, 1] as Array[int]
	c.finish_level(s)
	assert_eq(c.last_kills[0], [2, 1, 0, 1] as Array[int],
		"the statistics screen is built from these numbers")

func test_kills_accumulate_across_levels() -> void:
	var c := Campaign.new(1, cfg, 7)
	var first := _finished(true, [3], [400])
	first.players[0].kills = [2, 0, 0, 0] as Array[int]
	c.finish_level(first)
	var second := _finished(true, [3], [800])
	second.players[0].kills = [1, 3, 0, 0] as Array[int]
	c.finish_level(second)
	assert_eq(c.carryover()[0].kills, [3, 3, 0, 0] as Array[int],
		"the game total is the sum over the levels")
	assert_eq(c.last_kills[0], [1, 3, 0, 0] as Array[int],
		"while the last level stays on its own")

func test_kills_start_empty() -> void:
	var c := Campaign.new(2, cfg, 7)
	assert_eq(c.carryover()[0].kills, [0, 0, 0, 0] as Array[int])
	assert_eq(c.last_kills.size(), 2, "a row per player from the very start")

func test_finished_level_number_is_kept_for_the_statistics_screen() -> void:
	# The statistics screen is shown after the number has already moved on:
	# without a separate field it would label the first level's tally "STAGE 2".
	var c := Campaign.new(1, cfg, 7)
	c.finish_level(_finished(true, [3], [0]))
	assert_eq(c.finished_level, 1)
	assert_eq(c.level_number, 2)
	c.finish_level(_finished(false, [0], [0]))
	assert_eq(c.finished_level, 2, "a lost level still counts as finished for the tally")
