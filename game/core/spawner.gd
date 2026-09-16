class_name Spawner

## The enemy wave queue: the interval, the cap on the field, cycling through
## the three spawn points, and marking the ones that carry a bonus.

var _state: WorldState
var _config: SimConfig
var _rng: Rng
var _log: EventLog
var _bonus_indices: Array[int] = []
var _spawned_count := 0

func _init(state: WorldState, config: SimConfig, rng: Rng, log: EventLog,
		bonus_indices: Array[int]) -> void:
	_state = state
	_config = config
	_rng = rng
	_log = log
	_bonus_indices = bonus_indices.duplicate()

## How many enemies have come out so far — it decides which one carries a bonus,
## so stepping back must bring it back too.
func spawned_count() -> int:
	return _spawned_count

func set_spawned_count(n: int) -> void:
	_spawned_count = n

func update() -> void:
	if _state.enemy_queue.is_empty():
		return
	if _state.spawn_timer > 0:
		_state.spawn_timer -= 1
		return
	if _state.alive_enemy_count() >= _config.max_enemies_alive:
		return

	var pos: Vector2i = Consts.tile_to_unit(Consts.ENEMY_SPAWN_TILES[_state.spawn_point_index])
	if _blocked(pos):
		return

	var type: int = _state.enemy_queue.pop_front()
	_spawn_enemy(type, pos)
	_state.spawn_point_index = (_state.spawn_point_index + 1) % Consts.ENEMY_SPAWN_TILES.size()
	_state.spawn_timer = _config.spawn_interval_ticks

func _blocked(pos: Vector2i) -> bool:
	for t in _state.tanks:
		if t.is_materialized() and Movement.overlaps(pos, Consts.TANK, t.pos, Consts.TANK):
			return true
	return false

func _spawn_enemy(type: int, pos: Vector2i) -> Entities.Tank:
	var t := Entities.Tank.new()
	t.id = _state.next_id()
	t.type = type
	t.player_index = -1
	t.pos = pos
	t.dir = Types.Dir.DOWN
	t.speed = _config.enemy_speed(type)
	t.health = _config.enemy_health(type)
	t.spawn_ticks = _config.spawn_blink_ticks
	t.drops_bonus = _bonus_indices.has(_spawned_count)
	# The AI timers come from the shared generator — otherwise the behaviour
	# would stop being reproducible.
	t.ai_dir_timer = _rng.next_range(_config.ai_dir_change_min, _config.ai_dir_change_max)
	t.ai_fire_timer = _rng.next_range(_config.ai_fire_min, _config.ai_fire_max)
	t.ai_target_is_base = _rng.chance(_config.ai_base_target_chance)
	_state.tanks.append(t)
	_spawned_count += 1
	_log.add(Types.Event.ENEMY_SPAWNED, pos, type)
	return t
