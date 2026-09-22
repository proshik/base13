class_name GameSim

## The entry point into the simulation. The core knows nothing of the keyboard,
## the screen or the network: the only input is five bits per player per tick.
##
## Only orchestration lives here: the order of operations in a tick, the players
## and the end conditions. Combat, AI, the spawner and bonuses live in their own
## files. None of the modules holds a reference back to GameSim — reference
## cycles between RefCounted objects are never collected in Godot and leak.

var _state: WorldState
var _config: SimConfig
var _rng: Rng
var _log := EventLog.new()
var _bonuses: Bonuses
var _combat: Combat
var _ai: EnemyAi
var _spawner: Spawner

func _init(level: LevelData, seed_value: int, config: SimConfig = null,
		level_number: int = 1, player_count: int = 1, carryover: Array = []) -> void:
	_config = config if config != null else SimConfig.new()
	_rng = Rng.new(seed_value)

	_state = WorldState.new()
	_state.level = level_number
	_state.terrain = level.terrain.clone()
	_state.enemy_queue = level.enemy_queue.duplicate()
	_state.enemies_left = level.enemy_queue.size()

	_bonuses = Bonuses.new(_state, _config, _rng, _log)
	_combat = Combat.new(_state, _config, _log, _bonuses)
	_ai = EnemyAi.new(_state, _config, _rng, _combat)
	_spawner = Spawner.new(_state, _config, _rng, _log, level.bonus_indices)

	for i in player_count:
		var p := Entities.PlayerState.new()
		p.index = i
		p.lives = _config.start_lives
		p.active = true
		if i < carryover.size():
			var c: Entities.Carryover = carryover[i]
			p.lives = c.lives
			p.score = c.score
			p.stars = c.stars
		_state.players.append(p)
		_spawn_player(i)

## The order of operations is fixed: reproducibility depends on it, which makes
## it part of the contract rather than an implementation detail.
func tick(inputs: Array) -> void:
	_state.tick += 1
	_update_timers()
	_update_players(inputs)
	_ai.update()
	_combat.update_bullets()
	_bonuses.update()
	_spawner.update()
	_check_end_conditions()
	_state.compact()

func get_state() -> WorldState:
	return _state

func get_config() -> SimConfig:
	return _config

func drain_events() -> Array:
	return _log.drain()

func state_hash() -> int:
	return _state.hash_value()

## A copy of the simulation as it stands, for stepping back to later.
func save() -> SimSnapshot:
	var s := SimSnapshot.new()
	s.state = WorldState.new()
	SimSnapshot.copy_world(_state, s.state)
	s.rng_state = _rng.get_state()
	s.spawned = _spawner.spawned_count()
	return s

## Back to a saved moment. The snapshot is copied from, never taken over, so it
## can be restored again.
func restore(s: SimSnapshot) -> void:
	SimSnapshot.copy_world(s.state, _state)
	_rng.set_state(s.rng_state)
	_spawner.set_spawned_count(s.spawned)
	# Events of ticks that are about to be computed again belong to nobody.
	_log.drain()

# --- internals ---

func _spawn_player(index: int) -> void:
	var p: Entities.PlayerState = _state.players[index]
	var t := Entities.Tank.new()
	t.id = _state.next_id()
	t.type = Types.TankType.PLAYER
	t.player_index = index
	t.pos = Consts.tile_to_unit(Consts.PLAYER_SPAWN_TILES[index])
	t.dir = Types.Dir.UP
	t.speed = _config.player_speed
	t.health = 1
	t.stars = p.stars
	t.shield_ticks = _config.respawn_shield_ticks
	_state.tanks.append(t)
	p.tank_id = t.id

func _update_timers() -> void:
	if _state.freeze_ticks > 0:
		_state.freeze_ticks -= 1
	if _state.shovel_ticks > 0:
		_state.shovel_ticks -= 1
		if _state.shovel_ticks == 0:
			_restore_base_wall()
	for t in _state.tanks:
		if t.spawn_ticks > 0:
			t.spawn_ticks -= 1
		if t.shield_ticks > 0:
			t.shield_ticks -= 1
		if t.stun_ticks > 0:
			t.stun_ticks -= 1
	# slide_ticks is deliberately left alone here: it is spent at the moment of
	# sliding, or the inertia would come out one tick shorter than declared.

## Restores brick only where the shovel's concrete now stands: a hole already
## punched through is not repaired, exactly as in the original.
func _restore_base_wall() -> void:
	for c in Consts.BASE_WALL_CELLS:
		if _state.terrain.get_cell(c.x, c.y) == Types.Cell.STEEL:
			_state.terrain.set_cell(c.x, c.y, Types.Cell.BRICK)

func _update_players(inputs: Array) -> void:
	_update_respawns()
	for p in _state.players:
		if p.tank_id == -1:
			continue
		var t := _state.find_tank(p.tank_id)
		if t == null or not t.alive or t.stun_ticks > 0:
			continue
		var bits: int = inputs[p.index] if p.index < inputs.size() else 0
		_control_tank(t, bits)

func _control_tank(t, bits: int) -> void:
	var dir := _dir_from_bits(bits)
	if dir >= 0:
		Movement.drive(_state, _config, t, dir)
	elif t.slide_ticks > 0:
		# Inertia on ice: exactly one tick is spent per slide.
		t.slide_ticks -= 1
		Movement.step(_state, t, t.slide_dir, t.speed)
	if bits & Types.IN_FIRE:
		_combat.try_fire(t)

## The order in which the bits are read is fixed — it is part of determinism.
func _dir_from_bits(bits: int) -> int:
	if bits & Types.IN_UP:
		return Types.Dir.UP
	if bits & Types.IN_DOWN:
		return Types.Dir.DOWN
	if bits & Types.IN_LEFT:
		return Types.Dir.LEFT
	if bits & Types.IN_RIGHT:
		return Types.Dir.RIGHT
	return -1

func _update_respawns() -> void:
	for p in _state.players:
		if not p.active or p.tank_id != -1 or p.respawn_timer <= 0:
			continue
		p.respawn_timer -= 1
		if p.respawn_timer == 0:
			_spawn_player(p.index)

## Thin delegates: combat accounts for a tank's death, but tests and outside
## scenarios address the simulation without knowing its internal split.
func _on_enemy_destroyed(t, b) -> void:
	_combat.on_enemy_destroyed(t, b)

func _on_player_destroyed(t) -> void:
	_combat.on_player_destroyed(t)

func _check_end_conditions() -> void:
	if _state.game_over or _state.level_cleared:
		return
	if not _state.base_alive:
		_state.game_over = true
		_state.ended_at = _state.tick
		_log.add(Types.Event.GAME_OVER, Consts.tile_to_unit(Consts.BASE_TILE))
		return
	if _state.enemies_left <= 0:
		_state.level_cleared = true
		_state.ended_at = _state.tick
		_log.add(Types.Event.LEVEL_CLEARED)
		return
	var anyone_left := false
	for p in _state.players:
		if p.active and (p.lives > 0 or p.tank_id != -1):
			anyone_left = true
	if not anyone_left:
		_state.game_over = true
		_state.ended_at = _state.tick
		_log.add(Types.Event.GAME_OVER)
