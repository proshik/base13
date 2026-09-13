extends GutTest

var sim: GameSim
var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()
	sim = GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 1)

func _player() -> Entities.Tank:
	return sim.get_state().player_tanks()[0]

func test_moving_right_turns_and_advances() -> void:
	var start := _player().pos
	sim.tick([Types.IN_RIGHT, 0])
	assert_eq(_player().dir, Types.Dir.RIGHT)
	assert_eq(_player().pos, start + Vector2i(cfg.player_speed, 0))

func test_holding_the_key_keeps_moving() -> void:
	var start := _player().pos
	for i in 3:
		sim.tick([Types.IN_UP, 0])
	assert_eq(_player().pos, start - Vector2i(0, cfg.player_speed * 3))

func test_releasing_the_key_stops_the_tank() -> void:
	sim.tick([Types.IN_UP, 0])
	var after := _player().pos
	sim.tick([0, 0])
	assert_eq(_player().pos, after)

func test_input_priority_is_fixed() -> void:
	# The order in which the bits are read is part of determinism: up, down,
	# left, right.
	sim.tick([Types.IN_UP | Types.IN_RIGHT, 0])
	assert_eq(_player().dir, Types.Dir.UP)

func test_turning_snaps_to_the_half_tile_grid() -> void:
	for i in 5:
		sim.tick([Types.IN_UP, 0])       # moved 60 units up: Y is not a multiple of a cell
	assert_ne(_player().pos.y % Consts.CELL, 0)
	sim.tick([Types.IN_RIGHT, 0])
	assert_eq(_player().pos.y % Consts.CELL, 0, "turning sideways snaps Y")

func test_stunned_player_does_not_move() -> void:
	var t := _player()
	t.stun_ticks = 5
	var start := t.pos
	sim.tick([Types.IN_UP, 0])
	assert_eq(t.pos, start)

func test_second_player_reads_its_own_bits() -> void:
	var two := GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 2)
	var p1: Entities.Tank = two.get_state().player_tanks()[0]
	var p2: Entities.Tank = two.get_state().player_tanks()[1]
	var start1 := p1.pos
	var start2 := p2.pos
	two.tick([0, Types.IN_UP])
	assert_eq(p1.pos, start1, "player one received no input")
	assert_eq(p2.pos, start2 - Vector2i(0, cfg.player_speed))

func test_ice_keeps_the_tank_sliding_after_release() -> void:
	var cells := {}
	for cy in range(18, 26):
		cells[Vector2i(9, cy)] = Types.Cell.ICE
	var iced := GameSim.new(LevelFixture.level_with(cells), 1, cfg, 1, 1)
	var t: Entities.Tank = iced.get_state().player_tanks()[0]

	iced.tick([Types.IN_UP, 0])
	assert_eq(t.slide_ticks, cfg.ice_slide_ticks, "sliding over ice arms the inertia")
	var after_release := t.pos

	for i in cfg.ice_slide_ticks:
		iced.tick([0, 0])
	assert_eq(t.pos, after_release - Vector2i(0, cfg.player_speed * cfg.ice_slide_ticks),
		"after the key is released the tank slides exactly ice_slide_ticks ticks")

	var settled := t.pos
	iced.tick([0, 0])
	assert_eq(t.pos, settled, "the inertia ran out and the tank stands still")

func test_no_ice_means_no_sliding() -> void:
	sim.tick([Types.IN_UP, 0])
	assert_eq(_player().slide_ticks, 0)
