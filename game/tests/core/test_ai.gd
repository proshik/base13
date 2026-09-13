extends GutTest

var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()

func _sim_with_enemy(pos: Vector2i, dir := Types.Dir.DOWN) -> Array:
	var sim := GameSim.new(LevelFixture.empty_level(), 5, cfg, 1, 1)
	var t := Entities.Tank.new()
	t.id = sim.get_state().next_id()
	t.type = Types.TankType.BASIC
	t.player_index = -1
	t.pos = pos
	t.dir = dir
	t.speed = cfg.enemy_speed(Types.TankType.BASIC)
	t.health = 1
	t.alive = true
	t.ai_dir_timer = 999
	t.ai_fire_timer = 999
	sim.get_state().tanks.append(t)
	return [sim, t]

func test_enemy_drives_in_its_direction() -> void:
	var pair := _sim_with_enemy(Vector2i(Consts.TILE * 3, Consts.TILE * 3))
	var sim: GameSim = pair[0]
	var t: Entities.Tank = pair[1]
	var start := t.pos
	sim.tick([0, 0])
	assert_eq(t.pos, start + Vector2i(0, cfg.enemy_speed(Types.TankType.BASIC)))

func test_frozen_enemies_do_not_move_or_shoot() -> void:
	var pair := _sim_with_enemy(Vector2i(Consts.TILE * 3, Consts.TILE * 3))
	var sim: GameSim = pair[0]
	var t: Entities.Tank = pair[1]
	sim.get_state().freeze_ticks = 100
	var start := t.pos
	sim.tick([0, 0])
	assert_eq(t.pos, start, "the clock stops the enemies")
	assert_eq(sim.get_state().bullets.size(), 0)

func test_stuck_enemy_changes_direction() -> void:
	var pair := _sim_with_enemy(Vector2i(0, 0), Types.Dir.UP)
	var sim: GameSim = pair[0]
	var t: Entities.Tank = pair[1]
	sim.tick([0, 0])
	assert_ne(t.dir, Types.Dir.UP, "on hitting the edge an enemy must turn")

func test_enemy_shoots_when_it_sees_the_base() -> void:
	# The enemy is placed directly above the base, barrel down, corridor clear.
	var sim := GameSim.new(LevelFixture.empty_level(), 5, cfg, 1, 1)
	for c in Consts.BASE_WALL_CELLS:
		sim.get_state().terrain.set_cell(c.x, c.y, Types.Cell.EMPTY)
	var t := Entities.Tank.new()
	t.id = sim.get_state().next_id()
	t.type = Types.TankType.BASIC
	t.player_index = -1
	t.pos = Consts.tile_to_unit(Vector2i(Consts.BASE_TILE.x, 6))
	t.dir = Types.Dir.DOWN
	# The speed must be real: a motionless tank looks blocked every tick, which
	# means it changes direction and the line of fire drifts away.
	t.speed = cfg.enemy_speed(Types.TankType.BASIC)
	t.health = 1
	t.alive = true
	t.ai_dir_timer = 999
	t.ai_fire_timer = 999
	sim.get_state().tanks.append(t)

	sim.tick([0, 0])
	assert_gt(sim.get_state().bullets.size(), 0, "seeing the eagle, it fires without waiting for the timer")

func test_enemy_does_not_shoot_through_steel() -> void:
	var sim := GameSim.new(LevelFixture.empty_level(), 5, cfg, 1, 1)
	for c in Consts.BASE_WALL_CELLS:
		sim.get_state().terrain.set_cell(c.x, c.y, Types.Cell.EMPTY)
	for cx in range(11, 15):
		sim.get_state().terrain.set_cell(cx, 20, Types.Cell.STEEL)
	var t := Entities.Tank.new()
	t.id = sim.get_state().next_id()
	t.type = Types.TankType.BASIC
	t.player_index = -1
	t.pos = Consts.tile_to_unit(Vector2i(Consts.BASE_TILE.x, 6))
	t.dir = Types.Dir.DOWN
	# The speed must be real: a motionless tank looks blocked every tick, which
	# means it changes direction and the line of fire drifts away.
	t.speed = cfg.enemy_speed(Types.TankType.BASIC)
	t.health = 1
	t.alive = true
	t.ai_dir_timer = 999
	t.ai_fire_timer = 999
	sim.get_state().tanks.append(t)

	sim.tick([0, 0])
	assert_eq(sim.get_state().bullets.size(), 0, "concrete blocks the line of fire")

func test_enemy_respects_the_bullet_limit() -> void:
	var pair := _sim_with_enemy(Vector2i(Consts.TILE * 3, Consts.TILE * 3))
	var sim: GameSim = pair[0]
	var t: Entities.Tank = pair[1]
	t.ai_fire_timer = 0
	for i in 5:
		sim.tick([0, 0])
	var own := 0
	for b in sim.get_state().bullets:
		if b.owner_id == t.id:
			own += 1
	assert_lte(own, 1, "an ordinary enemy has only one bullet in flight")

func test_same_seed_gives_identical_ai_behaviour() -> void:
	var a := GameSim.new(LevelFixture.empty_level(), 31337, cfg, 1, 1)
	var b := GameSim.new(LevelFixture.empty_level(), 31337, cfg, 1, 1)
	for i in 600:
		a.tick([0, 0])
		b.tick([0, 0])
	assert_eq(a.state_hash(), b.state_hash(), "the AI must be reproducible")

func test_different_seeds_diverge() -> void:
	var a := GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 1)
	var b := GameSim.new(LevelFixture.empty_level(), 2, cfg, 1, 1)
	for i in 600:
		a.tick([0, 0])
		b.tick([0, 0])
	assert_ne(a.state_hash(), b.state_hash(), "different seeds must produce different games")
