class_name WorldState

var tick := 0
var level := 1
var terrain: Terrain
var tanks: Array = []          ## Entities.Tank; array order is traversal order
var bullets: Array = []        ## Entities.Bullet
var bonus: Entities.Bonus = null
var base_alive := true
var freeze_ticks := 0
var shovel_ticks := 0
var enemy_queue: Array[int] = []
var enemies_left := 0
var spawn_timer := 0
var spawn_point_index := 0
var players: Array = []        ## Entities.PlayerState
var game_over := false
var level_cleared := false

var _next_id := 1

func next_id() -> int:
	var id := _next_id
	_next_id += 1
	return id

func find_tank(id: int) -> Entities.Tank:
	for t in tanks:
		if t.id == id:
			return t
	return null

func player_tanks() -> Array:
	var out: Array = []
	for t in tanks:
		if t.player_index >= 0 and t.alive:
			out.append(t)
	return out

func enemy_tanks() -> Array:
	var out: Array = []
	for t in tanks:
		if t.player_index < 0 and t.alive:
			out.append(t)
	return out

func alive_enemy_count() -> int:
	return enemy_tanks().size()

## Removes the dead while preserving the relative order of the living:
## traversal order is part of determinism.
func compact() -> void:
	var live_tanks: Array = []
	for t in tanks:
		if t.alive:
			live_tanks.append(t)
	tanks = live_tanks

	var live_bullets: Array = []
	for b in bullets:
		if b.alive:
			live_bullets.append(b)
	bullets = live_bullets

func hash_value() -> int:
	var h := 2166136261
	h = _mix(h, tick)
	h = _mix(h, level)
	h = _mix(h, terrain.cells_checksum())
	h = _mix(h, 1 if base_alive else 0)
	h = _mix(h, freeze_ticks)
	h = _mix(h, shovel_ticks)
	h = _mix(h, enemies_left)
	h = _mix(h, spawn_timer)
	h = _mix(h, spawn_point_index)
	h = _mix(h, 1 if game_over else 0)
	h = _mix(h, 1 if level_cleared else 0)
	for t in tanks:
		h = _mix(h, t.id)
		h = _mix(h, t.type)
		h = _mix(h, t.pos.x)
		h = _mix(h, t.pos.y)
		h = _mix(h, t.dir)
		h = _mix(h, t.health)
		h = _mix(h, t.stars)
		h = _mix(h, t.spawn_ticks)
		h = _mix(h, t.shield_ticks)
		h = _mix(h, t.stun_ticks)
		h = _mix(h, t.slide_ticks)
	for b in bullets:
		h = _mix(h, b.id)
		h = _mix(h, b.pos.x)
		h = _mix(h, b.pos.y)
		h = _mix(h, b.dir)
	if bonus != null and bonus.active:
		h = _mix(h, bonus.type)
		h = _mix(h, bonus.pos.x)
		h = _mix(h, bonus.pos.y)
		h = _mix(h, bonus.ticks_left)
	for p in players:
		h = _mix(h, p.lives)
		h = _mix(h, p.stars)
		h = _mix(h, p.score)
		h = _mix(h, p.respawn_timer)
	return h

static func _mix(h: int, v: int) -> int:
	var x := (h ^ (v & 0xFFFFFFFF)) & 0xFFFFFFFF
	return (x * 16777619) & 0xFFFFFFFF
