extends GutTest

var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()

func _carry(lives: int, score: int, stars: int) -> Entities.Carryover:
	var c := Entities.Carryover.new()
	c.lives = lives
	c.score = score
	c.stars = stars
	return c

func test_without_carryover_nothing_changes() -> void:
	var sim := GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 1)
	assert_eq(sim.get_state().players[0].lives, cfg.start_lives)
	assert_eq(sim.get_state().players[0].score, 0)

func test_lives_and_score_are_carried() -> void:
	var sim := GameSim.new(LevelFixture.empty_level(), 1, cfg, 2, 1, [_carry(2, 4200, 0)])
	assert_eq(sim.get_state().players[0].lives, 2)
	assert_eq(sim.get_state().players[0].score, 4200)

func test_carried_stars_reach_the_tank_on_the_field() -> void:
	var sim := GameSim.new(LevelFixture.empty_level(), 1, cfg, 2, 1, [_carry(3, 0, 2)])
	assert_eq(sim.get_state().players[0].stars, 2)
	assert_eq(sim.get_state().player_tanks()[0].stars, 2,
		"a tank must roll out already upgraded rather than gain stars later")

func test_each_player_gets_its_own_row() -> void:
	var sim := GameSim.new(LevelFixture.empty_level(), 1, cfg, 2, 2,
		[_carry(1, 100, 0), _carry(3, 900, 1)])
	assert_eq(sim.get_state().players[0].lives, 1)
	assert_eq(sim.get_state().players[1].lives, 3)
	assert_eq(sim.get_state().players[1].score, 900)

func test_short_carryover_falls_back_to_defaults() -> void:
	var sim := GameSim.new(LevelFixture.empty_level(), 1, cfg, 2, 2, [_carry(1, 100, 0)])
	assert_eq(sim.get_state().players[1].lives, cfg.start_lives,
		"player two has nothing to carry over and starts as usual")

func test_carryover_does_not_disturb_determinism() -> void:
	var a := GameSim.new(LevelFixture.empty_level(), 5, cfg, 2, 1, [_carry(2, 300, 1)])
	var b := GameSim.new(LevelFixture.empty_level(), 5, cfg, 2, 1, [_carry(2, 300, 1)])
	for i in 300:
		a.tick([0, 0])
		b.tick([0, 0])
	assert_eq(a.state_hash(), b.state_hash())
