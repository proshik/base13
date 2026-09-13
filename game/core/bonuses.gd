class_name Bonuses

## Bonus spawning, pickup and effects. Never more than one on the field.

var _state: WorldState
var _config: SimConfig
var _rng: Rng
var _log: EventLog

func _init(state: WorldState, config: SimConfig, rng: Rng, log: EventLog) -> void:
	_state = state
	_config = config
	_rng = rng
	_log = log

func spawn_bonus() -> void:
	var b := Entities.Bonus.new()
	b.type = _rng.next_range(0, Types.BonusType.size())
	b.pos = Consts.tile_to_unit(_random_bonus_tile())
	b.ticks_left = _config.bonus_life_ticks
	b.active = true
	_state.bonus = b     # never more than one bonus on the field
	_log.add(Types.Event.BONUS_SPAWNED, b.pos, b.type)

func _random_bonus_tile() -> Vector2i:
	var tiles_per_side := Consts.GRID / 2
	for attempt in 32:
		var tile := Vector2i(_rng.next_range(0, tiles_per_side), _rng.next_range(0, tiles_per_side))
		if tile != Consts.BASE_TILE:
			return tile
	return Vector2i(0, 0)

func update() -> void:
	var b = _state.bonus
	if b == null or not b.active:
		return
	b.ticks_left -= 1
	if b.ticks_left <= 0:
		b.active = false
		_state.bonus = null
		return
	for t in _state.player_tanks():
		if not t.is_materialized():
			continue
		if Movement.overlaps(t.pos, Consts.TANK, b.pos, Consts.TILE):
			_apply(b, t)
			b.active = false
			_state.bonus = null
			return

func _apply(b, t) -> void:
	var p: Entities.PlayerState = _state.players[t.player_index]
	p.score += _config.bonus_score
	_log.add(Types.Event.BONUS_TAKEN, b.pos, b.type)
	match b.type:
		Types.BonusType.HELMET:
			t.shield_ticks = _config.shield_ticks
		Types.BonusType.CLOCK:
			_state.freeze_ticks = _config.freeze_ticks
		Types.BonusType.SHOVEL:
			for c in Consts.BASE_WALL_CELLS:
				_state.terrain.set_cell(c.x, c.y, Types.Cell.STEEL)
			_state.shovel_ticks = _config.shovel_ticks
		Types.BonusType.STAR:
			p.stars = mini(p.stars + 1, 3)
			t.stars = p.stars
		Types.BonusType.GRENADE:
			_destroy_all_enemies()
		Types.BonusType.TANK:
			p.lives += 1

## The grenade leaves still-blinking tanks alone: physically they are not on
## the field yet. No points are given for what the grenade takes out — this is
## only the write-off and the bonus, the same branch as an enemy dying without
## a bullet.
func _destroy_all_enemies() -> void:
	for t in _state.tanks:
		if t.player_index >= 0 or not t.is_materialized():
			continue
		t.alive = false
		_log.add(Types.Event.TANK_DESTROYED, t.pos, t.type)
		_state.enemies_left -= 1
		if t.drops_bonus:
			spawn_bonus()
