class_name ViewModel

## The only place where what to draw and where is decided. The nodes decide
## nothing: they take this list and draw it layer by layer.
##
## Nothing invisible is in the list at all: a bonus in the dark half of its blink
## simply does not make it into the result. That way "not visible right now" is
## checked by the absence of an entry.

enum Atlas { SPRITES, BULLETS, TERRAIN }
enum Layer { BONUS, ENTITIES, OVER }

const ARMOR_TINTS: Array[Color] = [
	Color(1.0, 0.55, 0.55),   ## one hit from death
	Color(1.0, 0.75, 0.55),
	Color(0.75, 0.9, 1.0),
	Color(1.0, 1.0, 1.0),     ## untouched
]

class Hud:
	var enemies_left := 0
	var lives: Array[int] = []
	var level := 1

class Item:
	var atlas := Atlas.SPRITES
	var frame := 0
	var pos := Vector2i.ZERO     ## pixels, measured from the field's top-left
	var layer := Layer.ENTITIES
	var tint := Color.WHITE

static func build(state: WorldState, config: SimConfig) -> Array:
	var items: Array = []
	_add_bonus(items, state, config)
	_add_shovel_blink(items, state, config)
	_add_base(items, state)
	_add_tanks(items, state)
	_add_bullets(items, state)
	_add_shields(items, state)
	return items

## What the panel shows. Computed here so that the node decides nothing.
static func hud(state: WorldState) -> Hud:
	var h := Hud.new()
	h.level = state.level
	h.enemies_left = state.enemy_queue.size()
	for t in state.tanks:
		if t.alive and t.player_index < 0:
			h.enemies_left += 1
	for p in state.players:
		h.lives.append(p.lives)
	return h

static func to_pixels(units: Vector2i) -> Vector2i:
	return units / Consts.SUBPIXEL

static func _item(atlas: int, frame: int, pos: Vector2i, layer: int,
		tint := Color.WHITE) -> Item:
	var it := Item.new()
	it.atlas = atlas
	it.frame = frame
	it.pos = pos
	it.layer = layer
	it.tint = tint
	return it

static func _add_bonus(items: Array, state: WorldState, config: SimConfig) -> void:
	var bonus: Entities.Bonus = state.bonus
	if bonus == null or not bonus.active:
		return
	if bonus.ticks_left <= config.bonus_blink_ticks and not _blink_on(bonus.ticks_left):
		return
	items.append(_item(Atlas.SPRITES, Frames.bonus(bonus.type),
		to_pixels(bonus.pos), Layer.BONUS))

## As the shovel runs out, the concrete around the base blinks back to brick, so
## the player can see the protection ending. Done as an overlay on top of the
## baked terrain: there is no reason to rebuild the field's picture every four
## ticks for eight cells.
static func _add_shovel_blink(items: Array, state: WorldState, config: SimConfig) -> void:
	if state.shovel_ticks <= 0 or state.shovel_ticks > config.shovel_blink_ticks:
		return
	if _blink_on(state.shovel_ticks):
		return
	for c in Consts.BASE_WALL_CELLS:
		if state.terrain.get_cell(c.x, c.y) != Types.Cell.STEEL:
			continue
		items.append(_item(Atlas.TERRAIN, Frames.terrain(Types.Cell.BRICK, state.tick),
			Vector2i(c.x * Consts.CELL_PX, c.y * Consts.CELL_PX), Layer.BONUS))

static func _add_base(items: Array, state: WorldState) -> void:
	var frame := Frames.EAGLE_ALIVE if state.base_alive else Frames.EAGLE_DEAD
	items.append(_item(Atlas.SPRITES, frame,
		to_pixels(Consts.tile_to_unit(Consts.BASE_TILE)), Layer.ENTITIES))

static func _add_tanks(items: Array, state: WorldState) -> void:
	for t in state.tanks:
		if not t.alive:
			continue
		var pos: Vector2i = to_pixels(t.pos)
		if t.spawn_ticks > 0:
			# While an enemy materialises there is no tank yet — only a flash.
			items.append(_item(Atlas.SPRITES, Frames.flash(t.spawn_ticks), pos, Layer.ENTITIES))
			continue
		var frame: int = Frames.tank(t.type, t.stars, t.dir, Frames.track_of(t.pos))
		items.append(_item(Atlas.SPRITES, frame, pos, Layer.ENTITIES, _tint_of(t)))

static func _add_bullets(items: Array, state: WorldState) -> void:
	for b in state.bullets:
		if not b.alive:
			continue
		items.append(_item(Atlas.BULLETS, b.dir, to_pixels(b.pos), Layer.ENTITIES))

static func _add_shields(items: Array, state: WorldState) -> void:
	for t in state.tanks:
		if not t.alive or t.spawn_ticks > 0 or t.shield_ticks <= 0:
			continue
		items.append(_item(Atlas.SPRITES, Frames.shield(t.shield_ticks),
			to_pixels(t.pos), Layer.OVER))

## An armoured tank's remaining health is shown by colour: separate frames for
## every hit would double the amount of art for the same meaning.
static func _tint_of(t) -> Color:
	if t.type != Types.TankType.ARMOR:
		return Color.WHITE
	return ARMOR_TINTS[clampi(t.health - 1, 0, ARMOR_TINTS.size() - 1)]

static func _blink_on(ticks: int) -> bool:
	return (ticks / Frames.SHIELD_PERIOD) % 2 == 0
