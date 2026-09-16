class_name Combat

## Firing, bullet flight and hit resolution: terrain, tanks, the base.
## Enemy and player deaths are accounted for here too — they are outcomes of
## a hit.

var _state: WorldState
var _config: SimConfig
var _log: EventLog
var _bonuses: Bonuses

func _init(state: WorldState, config: SimConfig, log: EventLog, bonuses: Bonuses) -> void:
	_state = state
	_config = config
	_log = log
	_bonuses = bonuses

func try_fire(t: Entities.Tank) -> void:
	if _count_bullets_of(t.id) >= _bullet_limit(t):
		return
	var b := Entities.Bullet.new()
	b.id = _state.next_id()
	b.owner_id = t.id
	b.owner_is_player = t.player_index >= 0
	b.dir = t.dir
	b.speed = _bullet_speed(t)
	b.power = t.player_index >= 0 and t.stars >= 3
	# The bullet starts at the muzzle: tank centre plus half a hull minus half
	# a bullet.
	var muzzle: Vector2i = t.center() + Types.DIR_VEC[t.dir] * (Consts.TANK / 2 - Consts.BULLET / 2)
	b.pos = muzzle - Vector2i(Consts.BULLET / 2, Consts.BULLET / 2)
	_state.bullets.append(b)
	_log.add(Types.Event.SHOT_FIRED, b.pos, b.dir)

func _bullet_limit(t: Entities.Tank) -> int:
	if t.player_index >= 0 and t.stars >= 2:
		return 2
	return 1

func _bullet_speed(t: Entities.Tank) -> int:
	if t.player_index >= 0:
		return _config.bullet_speed_fast if t.stars >= 1 else _config.bullet_speed
	return _config.enemy_bullet_speed(t.type)

func _count_bullets_of(owner_id: int) -> int:
	var n := 0
	for item in _state.bullets:
		var b: Entities.Bullet = item
		if b.alive and b.owner_id == owner_id:
			n += 1
	return n

func update_bullets() -> void:
	for item in _state.bullets:
		var b: Entities.Bullet = item
		if not b.alive:
			continue
		if not _advance_bullet(b):
			b.alive = false
	_resolve_bullet_pair_collisions()

## The bullet moves one unit at a time, so a hit registers in exactly the cell
## it entered, with no snapping arithmetic. Returns false if the bullet died.
##
## This is the hottest loop in the game — thirty-two steps per bullet per tick —
## so whatever cannot change while the bullet walks is settled before it sets
## off: the tanks it could possibly meet, whether the base lies on its line at
## all, and the cells it covers, which only change at a cell boundary. Nothing
## here answers differently from the plain checks; it only stops asking
## questions whose answer is already known.
func _advance_bullet(b: Entities.Bullet) -> bool:
	var delta: Vector2i = Types.DIR_VEC[b.dir]
	# A bullet keeps one coordinate the whole way, and nothing else on the field
	# moves until it stops: the base, the tanks and the terrain all stand still.
	var vertical: bool = delta.x == 0
	var base_pos: Vector2i = Consts.tile_to_unit(Consts.BASE_TILE)
	var base_on_line: bool = _state.base_alive and (
		Movement.bands_meet(b.pos.x, Consts.BULLET, base_pos.x, Consts.TILE) if vertical
		else Movement.bands_meet(b.pos.y, Consts.BULLET, base_pos.y, Consts.TILE))
	var targets := _targets_on_line(b, vertical)
	# No cell can have these indices, so the first step always looks at the
	# terrain.
	var cx0 := Consts.GRID + 1
	var cy0 := Consts.GRID + 1
	var cx1 := cx0
	var cy1 := cy0
	for i in b.speed:
		var next: Vector2i = b.pos + delta
		if _bullet_out_of_field(next):
			_log.add(Types.Event.BULLET_HIT_STEEL, b.pos, b.dir)
			return false
		b.pos = next
		var along: int = b.pos.y if vertical else b.pos.x
		if base_on_line and Movement.bands_meet(along, Consts.BULLET,
				base_pos.y if vertical else base_pos.x, Consts.TILE):
			_destroy_base(b)
			return false
		for item in targets:
			var t: Entities.Tank = item
			if Movement.bands_meet(along, Consts.BULLET,
					t.pos.y if vertical else t.pos.x, Consts.TANK):
				_apply_bullet_to_tank(b, t)
				return false
		var nx0 := Terrain.cell_index(b.pos.x)
		var ny0 := Terrain.cell_index(b.pos.y)
		var nx1 := Terrain.cell_index(b.pos.x + Consts.BULLET - 1)
		var ny1 := Terrain.cell_index(b.pos.y + Consts.BULLET - 1)
		if nx0 != cx0 or ny0 != cy0 or nx1 != cx1 or ny1 != cy1:
			cx0 = nx0
			cy0 = ny0
			cx1 = nx1
			cy1 = ny1
			if _state.terrain.blocks_bullet_rect(cx0, cy0, cx1, cy1):
				_destroy_band(b)
				return false
	return true

## The tanks a bullet could meet, settled before it sets off. It keeps one
## coordinate the whole way, so a tank off that band is not a candidate, and
## array order — which decides who is hit first — is kept.
func _targets_on_line(b: Entities.Bullet, vertical: bool) -> Array:
	var out: Array = []
	var owner_id: int = b.owner_id
	var from_player: bool = b.owner_is_player
	for item in _state.tanks:
		var t: Entities.Tank = item
		if not t.alive or t.spawn_ticks != 0 or t.id == owner_id:
			continue
		# An enemy does not harm an enemy — the bullet passes straight through.
		if not from_player and t.player_index < 0:
			continue
		if vertical:
			if not Movement.bands_meet(b.pos.x, Consts.BULLET, t.pos.x, Consts.TANK):
				continue
		elif not Movement.bands_meet(b.pos.y, Consts.BULLET, t.pos.y, Consts.TANK):
			continue
		out.append(t)
	return out

## The point on the bullet's leading edge. It is what picks the hit cell:
## taken from the bullet's centre it would resolve one cell later than it
## should.
func _bullet_leading_point(b: Entities.Bullet) -> Vector2i:
	var c: Vector2i = b.center()
	match b.dir:
		Types.Dir.UP:
			return Vector2i(c.x, b.pos.y)
		Types.Dir.DOWN:
			return Vector2i(c.x, b.pos.y + Consts.BULLET - 1)
		Types.Dir.LEFT:
			return Vector2i(b.pos.x, c.y)
		_:
			return Vector2i(b.pos.x + Consts.BULLET - 1, c.y)

## A strip as wide as a tank (two cells) and one cell deep — two cells for a
## bullet from a third-star tank.
func _destroy_band(b: Entities.Bullet) -> void:
	var horizontal: bool = b.dir == Types.Dir.LEFT or b.dir == Types.Dir.RIGHT
	var impact: Vector2i = _state.terrain.cell_at_unit(_bullet_leading_point(b))
	var centre: Vector2i = b.center()
	var perp_base: int = (centre.y / Consts.CELL - 1) if horizontal else (centre.x / Consts.CELL - 1)
	var forward: int = 1 if (b.dir == Types.Dir.RIGHT or b.dir == Types.Dir.DOWN) else -1
	var depth: int = 2 if b.power else 1

	var broke_brick := false
	var touched_steel := false
	for d in depth:
		for k in 2:
			var cx: int = (impact.x + forward * d) if horizontal else (perp_base + k)
			var cy: int = (perp_base + k) if horizontal else (impact.y + forward * d)
			var before := _state.terrain.get_cell(cx, cy)
			var destroyed := _state.terrain.destroy_cell(cx, cy, b.power)
			if destroyed == Types.Cell.BRICK:
				broke_brick = true
			elif before == Types.Cell.STEEL:
				touched_steel = true

	if broke_brick:
		_log.add(Types.Event.BULLET_HIT_BRICK, b.center(), b.dir)
	elif touched_steel:
		_log.add(Types.Event.BULLET_HIT_STEEL, b.center(), b.dir)

func _apply_bullet_to_tank(b: Entities.Bullet, t: Entities.Tank) -> void:
	if b.owner_is_player and t.player_index >= 0:
		t.stun_ticks = _config.ally_stun_ticks
		return
	if t.shield_ticks > 0:
		return
	t.health -= 1
	if t.health > 0:
		return
	t.alive = false
	if t.player_index >= 0:
		_log.add(Types.Event.PLAYER_DESTROYED, t.pos, t.player_index)
		on_player_destroyed(t)
	else:
		_log.add(Types.Event.TANK_DESTROYED, t.pos, t.type)
		on_enemy_destroyed(t, b)

func _destroy_base(_b: Entities.Bullet) -> void:
	_state.base_alive = false
	_log.add(Types.Event.BASE_DESTROYED, Consts.tile_to_unit(Consts.BASE_TILE))

func on_enemy_destroyed(t: Entities.Tank, b: Entities.Bullet) -> void:
	_state.enemies_left -= 1
	if t.drops_bonus:
		_bonuses.spawn_bonus()
	if b == null or not b.owner_is_player:
		return
	var owner := _state.find_tank(b.owner_id)
	if owner == null or owner.player_index < 0:
		return
	var p: Entities.PlayerState = _state.players[owner.player_index]
	p.score += _config.enemy_score(t.type)
	p.kills[t.type - Types.TankType.BASIC] += 1

func on_player_destroyed(t: Entities.Tank) -> void:
	var p: Entities.PlayerState = _state.players[t.player_index]
	p.tank_id = -1
	p.stars = 0
	p.lives -= 1
	if p.lives > 0:
		p.respawn_timer = _config.respawn_delay_ticks

func _bullet_out_of_field(pos: Vector2i) -> bool:
	return pos.x < 0 or pos.y < 0 \
		or pos.x + Consts.BULLET > Consts.FIELD \
		or pos.y + Consts.BULLET > Consts.FIELD

func _resolve_bullet_pair_collisions() -> void:
	for i in _state.bullets.size():
		var a: Entities.Bullet = _state.bullets[i]
		if not a.alive:
			continue
		for j in range(i + 1, _state.bullets.size()):
			var b: Entities.Bullet = _state.bullets[j]
			if not b.alive or a.owner_id == b.owner_id:
				continue
			if Movement.overlaps(a.pos, Consts.BULLET, b.pos, Consts.BULLET):
				a.alive = false
				b.alive = false
				_log.add(Types.Event.BULLET_HIT_BULLET, a.pos)
				break
