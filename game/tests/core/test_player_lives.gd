extends GutTest

var sim: GameSim
var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()
	sim = GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 1)

func _kill_player() -> void:
	var t: Entities.Tank = sim.get_state().player_tanks()[0]
	t.shield_ticks = 0
	t.health = 0
	t.alive = false
	sim._on_player_destroyed(t)

func test_death_costs_a_life_and_resets_stars() -> void:
	var s := sim.get_state()
	s.players[0].stars = 3
	_kill_player()
	sim.tick([0, 0])
	assert_eq(s.players[0].lives, cfg.start_lives - 1)
	assert_eq(s.players[0].stars, 0, "upgrades reset, as in the original")

func test_player_respawns_after_the_delay() -> void:
	var s := sim.get_state()
	_kill_player()
	sim.tick([0, 0])
	assert_eq(s.player_tanks().size(), 0, "right after death there is no tank on the field")
	# The tick above has already spent one unit of the delay.
	for i in cfg.respawn_delay_ticks - 1:
		sim.tick([0, 0])
	assert_eq(s.player_tanks().size(), 1, "after respawn_delay_ticks the player returns")
	var t: Entities.Tank = s.player_tanks()[0]
	assert_eq(t.pos, Consts.tile_to_unit(Consts.PLAYER_SPAWN_TILES[0]))
	assert_eq(t.shield_ticks, cfg.respawn_shield_ticks, "respawning grants a short shield")
	assert_eq(t.stars, 0)

func test_last_life_ends_the_game() -> void:
	var s := sim.get_state()
	s.players[0].lives = 1
	_kill_player()
	sim.tick([0, 0])
	assert_eq(s.players[0].lives, 0)
	for i in cfg.respawn_delay_ticks + 2:
		sim.tick([0, 0])
	assert_eq(s.player_tanks().size(), 0, "there is nothing left to respawn with")
	assert_true(s.game_over)

func test_second_player_keeps_playing_while_the_first_is_out() -> void:
	var two := GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 2)
	var s := two.get_state()
	s.players[0].lives = 1
	var t: Entities.Tank = s.player_tanks()[0]
	t.alive = false
	two._on_player_destroyed(t)
	for i in cfg.respawn_delay_ticks + 2:
		two.tick([0, 0])
	assert_false(s.game_over, "while player two is alive the game continues")
	assert_eq(s.player_tanks().size(), 1)

func test_respawned_tank_carries_the_current_star_level() -> void:
	var s := sim.get_state()
	_kill_player()
	sim.tick([0, 0])
	s.players[0].stars = 2      # a star was picked up, say, while waiting to respawn
	for i in cfg.respawn_delay_ticks:
		sim.tick([0, 0])
	assert_eq(s.player_tanks()[0].stars, 2)
