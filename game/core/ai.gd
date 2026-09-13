class_name EnemyAi

## Enemy tank behaviour. Deliberately simple: in the original the AI is a bit
## dim, and that is part of the charm — making it smarter would stop the game
## from being the one people remember.

var _state: WorldState
var _config: SimConfig
var _rng: Rng
var _combat: Combat

func _init(state: WorldState, config: SimConfig, rng: Rng, combat: Combat) -> void:
	_state = state
	_config = config
	_rng = rng
	_combat = combat

func update() -> void:
	if _state.freeze_ticks > 0:
		return
	for t in _state.tanks:
		if t.player_index >= 0 or not t.is_materialized() or t.stun_ticks > 0:
			continue
		_update_enemy(t)

func _update_enemy(t) -> void:
	if t.ai_dir_timer > 0:
		t.ai_dir_timer -= 1
	if t.ai_fire_timer > 0:
		t.ai_fire_timer -= 1

	var before: Vector2i = t.pos
	Movement.drive(_state, _config, t, t.dir)
	var stuck: bool = t.pos == before

	if t.ai_dir_timer == 0 or stuck:
		_choose_direction(t)
		t.ai_dir_timer = _rng.next_range(_config.ai_dir_change_min, _config.ai_dir_change_max)

	# Instant fire only at the base: pressure on the eagle is the game.
	# At the player they fire on a timer — otherwise merely lining up with an
	# enemy is punished by an immediate bullet, and the first level cannot be
	# finished.
	if t.ai_fire_timer == 0 or _sees_base(t):
		_combat.try_fire(t)
		t.ai_fire_timer = _rng.next_range(_config.ai_fire_min, _config.ai_fire_max)

func _choose_direction(t) -> void:
	var options: Array[int] = []
	for d in 4:
		if Movement.can_occupy(_state, t, t.pos + Types.DIR_VEC[d]):
			options.append(d)
	if options.is_empty():
		return

	if _rng.chance(_config.ai_target_chance_for_level(_state.level)):
		t.ai_target_is_base = _rng.chance(_config.ai_base_target_chance)
		var toward := _direction_toward(t, _target_point(t), options)
		if toward >= 0:
			Movement.turn(_state, t, toward)
			return
	Movement.turn(_state, t, options[_rng.next_range(0, options.size())])

## Of the available directions, picks the one that shortens the Manhattan
## distance to the target the most. On a tie the lower direction index wins —
## the scan runs in order, and that makes the choice reproducible.
func _direction_toward(t, target: Vector2i, options: Array[int]) -> int:
	var best := -1
	var best_dist := 0
	var here: Vector2i = t.center()
	for d in options:
		var probe: Vector2i = here + Types.DIR_VEC[d] * Consts.CELL
		var dist: int = absi(probe.x - target.x) + absi(probe.y - target.y)
		if best < 0 or dist < best_dist:
			best = d
			best_dist = dist
	return best

func _target_point(t) -> Vector2i:
	var players := _state.player_tanks()
	if t.ai_target_is_base or players.is_empty():
		return Consts.tile_to_unit(Consts.BASE_TILE) + Vector2i(Consts.TILE / 2, Consts.TILE / 2)
	var nearest = null
	var best := 0
	for p in players:
		var d: int = absi(p.center().x - t.center().x) + absi(p.center().y - t.center().y)
		if nearest == null or d < best:
			nearest = p
			best = d
	return nearest.center()

## A ray along the barrel, cell by cell, to the first block a bullet cannot
## pass. The base only: reacting instantly to the player turned the enemies
## into snipers.
func _sees_base(t) -> bool:
	var delta: Vector2i = Types.DIR_VEC[t.dir]
	var probe: Vector2i = t.center()
	var base_pos: Vector2i = Consts.tile_to_unit(Consts.BASE_TILE)
	for i in Consts.GRID * 2:
		probe += delta * Consts.CELL
		if probe.x < 0 or probe.y < 0 or probe.x >= Consts.FIELD or probe.y >= Consts.FIELD:
			return false
		var c: Vector2i = _state.terrain.cell_at_unit(probe)
		if _state.terrain.blocks_bullet(c.x, c.y):
			return false
		if _state.base_alive and Movement.overlaps(probe, 1, base_pos, Consts.TILE):
			return true
	return false
