extends GutTest

var state: WorldState

func before_each() -> void:
	state = WorldState.new()
	state.terrain = Terrain.new()
	state.level = 4

func _player(lives: int) -> void:
	var p := Entities.PlayerState.new()
	p.index = state.players.size()
	p.lives = lives
	p.active = true
	state.players.append(p)

func _enemy(spawning: bool) -> void:
	var t := Entities.Tank.new()
	t.id = state.next_id()
	t.type = Types.TankType.BASIC
	t.player_index = -1
	t.alive = true
	t.spawn_ticks = 30 if spawning else 0
	state.tanks.append(t)

func test_level_and_lives_are_taken_from_the_state() -> void:
	_player(2)
	_player(3)
	var hud := ViewModel.hud(state)
	assert_eq(hud.level, 4)
	assert_eq(hud.lives, [2, 3] as Array[int])

func test_remaining_enemies_include_those_not_yet_spawned() -> void:
	state.enemy_queue = [Types.TankType.BASIC, Types.TankType.FAST] as Array[int]
	_enemy(false)
	_enemy(true)
	assert_eq(ViewModel.hud(state).enemies_left, 4,
		"two in the queue and two on the field, counting the one still blinking")

func test_empty_wave_shows_zero() -> void:
	assert_eq(ViewModel.hud(state).enemies_left, 0)

func test_dead_enemies_are_not_counted() -> void:
	_enemy(false)
	state.tanks[0].alive = false
	assert_eq(ViewModel.hud(state).enemies_left, 0)
