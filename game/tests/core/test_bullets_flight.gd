extends GutTest

var sim: GameSim
var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()
	sim = GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 1)

func _player() -> Entities.Tank:
	return sim.get_state().player_tanks()[0]

func _bullets() -> Array:
	return sim.get_state().bullets

## Counts one particular tank's bullets: from task 13 onwards enemy bullets
## appear on the field too, and a test counting everything would start failing
## for no reason.
func _own_bullets(owner_id: int) -> int:
	var n := 0
	for b in sim.get_state().bullets:
		if b.owner_id == owner_id:
			n += 1
	return n

func test_fire_creates_one_bullet_in_front_of_the_tank() -> void:
	var t := _player()
	sim.tick([Types.IN_FIRE, 0])
	assert_eq(_bullets().size(), 1)
	var b: Entities.Bullet = _bullets()[0]
	assert_eq(b.dir, Types.Dir.UP)
	assert_eq(b.owner_id, t.id)
	assert_true(b.owner_is_player)
	assert_lt(b.center().y, t.center().y, "the bullet leaves forward in the tank's direction")
	assert_eq(b.center().x, t.center().x, "and centred on the barrel")

func test_shot_fired_event_is_emitted() -> void:
	sim.tick([Types.IN_FIRE, 0])
	var types: Array[int] = []
	for e in sim.drain_events():
		types.append(e.type)
	assert_has(types, Types.Event.SHOT_FIRED)

func test_one_bullet_at_a_time_without_stars() -> void:
	var id := _player().id
	sim.tick([Types.IN_FIRE, 0])
	sim.tick([Types.IN_FIRE, 0])
	assert_eq(_own_bullets(id), 1, "with no stars only one bullet is in flight")

func test_two_stars_allow_two_bullets() -> void:
	var id := _player().id
	_player().stars = 2
	sim.tick([Types.IN_FIRE, 0])
	sim.tick([Types.IN_FIRE, 0])
	assert_eq(_own_bullets(id), 2)
	sim.tick([Types.IN_FIRE, 0])
	assert_eq(_own_bullets(id), 2, "a third one does not leave the barrel")

func test_first_star_makes_the_bullet_faster() -> void:
	sim.tick([Types.IN_FIRE, 0])
	assert_eq(_bullets()[0].speed, cfg.bullet_speed)

	var fast := GameSim.new(LevelFixture.empty_level(), 1, cfg, 1, 1)
	fast.get_state().player_tanks()[0].stars = 1
	fast.tick([Types.IN_FIRE, 0])
	assert_eq(fast.get_state().bullets[0].speed, cfg.bullet_speed_fast)

func test_third_star_makes_the_bullet_powerful() -> void:
	_player().stars = 3
	sim.tick([Types.IN_FIRE, 0])
	assert_true(_bullets()[0].power, "with the third star the bullet punches through concrete")

func test_bullet_travels_at_its_speed() -> void:
	sim.tick([Types.IN_FIRE, 0])
	var b: Entities.Bullet = _bullets()[0]
	var y := b.pos.y
	sim.tick([0, 0])
	assert_eq(b.pos.y, y - cfg.bullet_speed)

func test_bullet_dies_at_the_field_edge() -> void:
	sim.tick([Types.IN_FIRE, 0])
	var b: Entities.Bullet = _bullets()[0]
	for i in 300:
		sim.tick([0, 0])
		if not b.alive:
			break
	assert_false(b.alive, "a bullet must vanish on reaching the edge of the field")

func test_opposing_bullets_cancel_each_other() -> void:
	var s := sim.get_state()
	var a := Entities.Bullet.new()
	a.id = s.next_id()
	a.owner_id = 100
	a.owner_is_player = true
	a.dir = Types.Dir.RIGHT
	a.speed = cfg.bullet_speed
	a.pos = Vector2i(1600, 1600)
	var b := Entities.Bullet.new()
	b.id = s.next_id()
	b.owner_id = 200
	b.owner_is_player = false
	b.dir = Types.Dir.LEFT
	b.speed = cfg.bullet_speed
	b.pos = Vector2i(1600 + Consts.BULLET, 1600)
	s.bullets.append(a)
	s.bullets.append(b)

	sim.tick([0, 0])
	assert_eq(s.bullets.size(), 0, "bullets flying at each other cancel out")

func test_bullets_of_the_same_tank_do_not_cancel() -> void:
	var s := sim.get_state()
	for i in 2:
		var b := Entities.Bullet.new()
		b.id = s.next_id()
		b.owner_id = 42
		b.owner_is_player = true
		b.dir = Types.Dir.UP
		b.speed = 0
		b.pos = Vector2i(1600, 1600)
		s.bullets.append(b)
	sim.tick([0, 0])
	assert_eq(s.bullets.size(), 2, "two of one's own bullets in the same spot must not cancel out")
