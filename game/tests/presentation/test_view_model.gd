extends GutTest

var state: WorldState
var cfg: SimConfig

func before_each() -> void:
	cfg = SimConfig.new()
	state = WorldState.new()
	state.terrain = Terrain.new()

func _tank(type: int, pos: Vector2i, player_index := -1) -> Entities.Tank:
	var t := Entities.Tank.new()
	t.id = state.next_id()
	t.type = type
	t.player_index = player_index
	t.pos = pos
	t.dir = Types.Dir.UP
	t.health = 1
	t.alive = true
	state.tanks.append(t)
	return t

func _items_at_layer(layer: int) -> Array:
	var out: Array = []
	for item in ViewModel.build(state, cfg):
		if item.layer == layer:
			out.append(item)
	return out

func _frames() -> Array:
	var out: Array = []
	for item in ViewModel.build(state, cfg):
		out.append(item.frame)
	return out

## The eagle is always drawn — for tests about tanks and bullets it is only in
## the way.
func _without_base() -> Array:
	var out: Array = []
	for item in ViewModel.build(state, cfg):
		var is_base: bool = item.atlas == ViewModel.Atlas.SPRITES \
			and (item.frame == Frames.EAGLE_ALIVE or item.frame == Frames.EAGLE_DEAD)
		if not is_base:
			out.append(item)
	return out

func test_units_convert_to_pixels() -> void:
	_tank(Types.TankType.PLAYER, Vector2i(1024, 512), 0)
	var items := _without_base()
	assert_eq(items.size(), 1)
	assert_eq(items[0].pos, Vector2i(64, 32), "1024 units is 64 pixels")

func test_player_tank_uses_its_star_level() -> void:
	var t := _tank(Types.TankType.PLAYER, Vector2i(0, 0), 0)
	t.stars = 2
	var items := _without_base()
	assert_eq(items[0].frame, Frames.tank(Types.TankType.PLAYER, 2, Types.Dir.UP,
		Frames.track_of(Vector2i(0, 0))))

func test_blinking_enemy_is_shown_as_a_flash_not_a_tank() -> void:
	var e := _tank(Types.TankType.BASIC, Vector2i(0, 0))
	e.spawn_ticks = 30
	var items := _without_base()
	assert_eq(items.size(), 1)
	assert_eq(items[0].frame, Frames.flash(30), "while an enemy blinks there is no tank yet")

func test_materialized_enemy_is_a_tank() -> void:
	_tank(Types.TankType.BASIC, Vector2i(0, 0))
	assert_eq(_without_base()[0].frame,
		Frames.tank(Types.TankType.BASIC, 0, Types.Dir.UP, Frames.track_of(Vector2i(0, 0))))

func test_armor_tank_is_tinted_by_health() -> void:
	var full := _tank(Types.TankType.ARMOR, Vector2i(0, 0))
	full.health = 4
	var white: Color = _without_base()[0].tint
	full.health = 1
	var hurt: Color = _without_base()[0].tint
	assert_ne(white, hurt, "an armoured tank's remaining health shows in its colour")

func test_shield_is_drawn_over_the_tank() -> void:
	var t := _tank(Types.TankType.PLAYER, Vector2i(0, 0), 0)
	t.shield_ticks = 100
	var items := _without_base()
	assert_eq(items.size(), 2, "the tank and the shield")
	assert_eq(items[1].layer, ViewModel.Layer.OVER, "the shield sits on top of the tank")
	assert_between(items[1].frame, Frames.SHIELD_BASE,
		Frames.SHIELD_BASE + Frames.SHIELD_FRAMES - 1)

func test_bullets_come_from_their_own_atlas() -> void:
	var b := Entities.Bullet.new()
	b.id = state.next_id()
	b.dir = Types.Dir.LEFT
	b.pos = Vector2i(256, 256)
	state.bullets.append(b)
	var items := _without_base()
	assert_eq(items[0].atlas, ViewModel.Atlas.BULLETS)
	assert_eq(items[0].frame, Types.Dir.LEFT, "the bullet frame equals its direction")
	assert_eq(items[0].pos, Vector2i(16, 16))

func test_live_base_is_drawn() -> void:
	assert_has(_frames(), Frames.EAGLE_ALIVE)
	assert_eq(_items_at_layer(ViewModel.Layer.ENTITIES)[0].pos,
		Consts.tile_to_unit(Consts.BASE_TILE) / Consts.SUBPIXEL)

func test_destroyed_base_changes_frame() -> void:
	state.base_alive = false
	assert_has(_frames(), Frames.EAGLE_DEAD)

func test_bonus_lies_under_the_tanks() -> void:
	var b := Entities.Bonus.new()
	b.type = Types.BonusType.STAR
	b.pos = Vector2i(512, 512)
	b.ticks_left = cfg.bonus_life_ticks
	b.active = true
	state.bonus = b
	var items := _items_at_layer(ViewModel.Layer.BONUS)
	assert_eq(items.size(), 1)
	assert_eq(items[0].frame, Frames.bonus(Types.BonusType.STAR))

func test_bonus_blinks_before_it_expires() -> void:
	var b := Entities.Bonus.new()
	b.type = Types.BonusType.STAR
	b.pos = Vector2i(512, 512)
	b.active = true
	state.bonus = b
	var shown := 0
	for left in cfg.bonus_blink_ticks:
		b.ticks_left = left + 1
		shown += _items_at_layer(ViewModel.Layer.BONUS).size()
	assert_gt(shown, 0, "the bonus does not vanish entirely")
	assert_lt(shown, cfg.bonus_blink_ticks, "and it is not visible every tick either: it blinks")

func test_shovel_wall_blinks_when_it_is_about_to_expire() -> void:
	for c in Consts.BASE_WALL_CELLS:
		state.terrain.set_cell(c.x, c.y, Types.Cell.STEEL)
	state.shovel_ticks = cfg.shovel_ticks
	assert_eq(_items_at_layer(ViewModel.Layer.BONUS).size(), 0,
		"while the shovel holds there is nothing to blink")
	var overlay := 0
	for left in range(1, cfg.shovel_blink_ticks + 1):
		state.shovel_ticks = left
		overlay += _items_at_layer(ViewModel.Layer.BONUS).size()
	assert_gt(overlay, 0, "as the shovel runs out the concrete blinks back to brick")
	assert_lt(overlay, Consts.BASE_WALL_CELLS.size() * cfg.shovel_blink_ticks,
		"but not every tick, or it is a swap rather than a blink")

func test_dead_entities_are_not_drawn() -> void:
	var t := _tank(Types.TankType.BASIC, Vector2i(0, 0))
	t.alive = false
	assert_eq(ViewModel.build(state, cfg).size(), 1, "only the eagle is left")

func test_order_inside_the_list_is_layer_order() -> void:
	var bonus := Entities.Bonus.new()
	bonus.pos = Vector2i(0, 0)
	bonus.ticks_left = cfg.bonus_life_ticks
	bonus.active = true
	state.bonus = bonus
	var t := _tank(Types.TankType.PLAYER, Vector2i(512, 512), 0)
	t.shield_ticks = 100
	var layers: Array[int] = []
	for item in ViewModel.build(state, cfg):
		layers.append(item.layer)
	var sorted_layers := layers.duplicate()
	sorted_layers.sort()
	assert_eq(layers, sorted_layers, "the list arrives already in drawing order")
