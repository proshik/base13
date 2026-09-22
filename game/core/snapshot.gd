class_name SimSnapshot

## A copy of everything a simulation changes as it runs, so that a network game
## can step back to a tick and compute it again with the partner's real input.
##
## Three places change: the world state, the generator and the count of enemies
## spawned. Combat, EnemyAi and Bonuses hold only references, and the event log is
## drained after every tick.
##
## Every field is copied by hand. A field added to WorldState or to an entity must
## be added here as well: test_snapshot.gd sets every script variable to an odd
## value and fails on the one that did not travel.

var state: WorldState
var rng_state := 0
var spawned := 0

## Into an existing world rather than a new one: GameSim's modules hold a
## reference to their WorldState, and restoring must reach them.
static func copy_world(src: WorldState, dst: WorldState) -> void:
	dst.tick = src.tick
	dst.level = src.level
	dst.terrain = src.terrain.clone()
	var tanks: Array = []
	for t in src.tanks:
		tanks.append(_tank(t))
	dst.tanks = tanks
	var bullets: Array = []
	for b in src.bullets:
		bullets.append(_bullet(b))
	dst.bullets = bullets
	dst.bonus = _bonus(src.bonus) if src.bonus != null else null
	dst.base_alive = src.base_alive
	dst.freeze_ticks = src.freeze_ticks
	dst.shovel_ticks = src.shovel_ticks
	dst.enemy_queue = src.enemy_queue.duplicate()
	dst.enemies_left = src.enemies_left
	dst.spawn_timer = src.spawn_timer
	dst.spawn_point_index = src.spawn_point_index
	var players: Array = []
	for p in src.players:
		players.append(_player(p))
	dst.players = players
	dst.game_over = src.game_over
	dst.level_cleared = src.level_cleared
	dst.ended_at = src.ended_at
	dst._next_id = src._next_id

static func _tank(s: Entities.Tank) -> Entities.Tank:
	var c := Entities.Tank.new()
	c.id = s.id
	c.type = s.type
	c.player_index = s.player_index
	c.pos = s.pos
	c.dir = s.dir
	c.speed = s.speed
	c.health = s.health
	c.stars = s.stars
	c.alive = s.alive
	c.spawn_ticks = s.spawn_ticks
	c.shield_ticks = s.shield_ticks
	c.stun_ticks = s.stun_ticks
	c.slide_ticks = s.slide_ticks
	c.slide_dir = s.slide_dir
	c.drops_bonus = s.drops_bonus
	c.ai_dir_timer = s.ai_dir_timer
	c.ai_fire_timer = s.ai_fire_timer
	c.ai_target_is_base = s.ai_target_is_base
	return c

static func _bullet(s: Entities.Bullet) -> Entities.Bullet:
	var c := Entities.Bullet.new()
	c.id = s.id
	c.owner_id = s.owner_id
	c.owner_is_player = s.owner_is_player
	c.pos = s.pos
	c.dir = s.dir
	c.speed = s.speed
	c.power = s.power
	c.alive = s.alive
	return c

static func _bonus(s: Entities.Bonus) -> Entities.Bonus:
	var c := Entities.Bonus.new()
	c.type = s.type
	c.pos = s.pos
	c.ticks_left = s.ticks_left
	c.active = s.active
	return c

static func _player(s: Entities.PlayerState) -> Entities.PlayerState:
	var c := Entities.PlayerState.new()
	c.index = s.index
	c.lives = s.lives
	c.stars = s.stars
	c.score = s.score
	c.kills = s.kills.duplicate()
	c.active = s.active
	c.respawn_timer = s.respawn_timer
	c.tank_id = s.tank_id
	return c
