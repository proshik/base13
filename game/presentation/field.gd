class_name Field
extends Node2D

func _ready() -> void:
	# Explicit rather than inherited from the project: pixel art must not be
	# smoothed.
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

## A thin node: it decides nothing and draws the ready-made list from the
## ViewModel. Its only concern is not to rebuild the terrain every frame.

const SPRITE_PX := 16
const SPRITE_COLUMNS := 16
const BULLET_COLUMNS := 4
const TERRAIN_COLUMNS := 8

## In the original the playfield is black and the frame around it is grey.
## Without this backdrop the field merges into the window and the picture stops
## being recognisable.
const BACKGROUND := Color(0, 0, 0)

var _sprites: Texture2D = preload("res://assets/sprites.png")
var _bullets: Texture2D = preload("res://assets/bullets.png")
var _terrain_atlas: Texture2D = preload("res://assets/terrain.png")

var _state: WorldState = null
var _items: Array = []
var _under: ImageTexture = null
var _trees: ImageTexture = null
var _terrain_checksum := -1
var _water_frame := -1

func sync(state: WorldState, items: Array) -> void:
	_state = state
	_items = items
	var checksum: int = state.terrain.cells_checksum()
	var water: int = Frames.terrain(Types.Cell.WATER, state.tick)
	if checksum != _terrain_checksum or water != _water_frame:
		_terrain_checksum = checksum
		_water_frame = water
		_rebuild_terrain()
	queue_redraw()

func _rebuild_terrain() -> void:
	var atlas: Image = _terrain_atlas.get_image()
	var under := Image.create_empty(Consts.FIELD_PX, Consts.FIELD_PX, false, Image.FORMAT_RGBA8)
	var trees := Image.create_empty(Consts.FIELD_PX, Consts.FIELD_PX, false, Image.FORMAT_RGBA8)
	for cy in Consts.GRID:
		for cx in Consts.GRID:
			var cell: int = _state.terrain.get_cell(cx, cy)
			var frame: int = Frames.terrain(cell, _state.tick)
			if frame < 0:
				continue
			var src := Rect2i(frame * Consts.CELL_PX, 0, Consts.CELL_PX, Consts.CELL_PX)
			var at := Vector2i(cx * Consts.CELL_PX, cy * Consts.CELL_PX)
			if cell == Types.Cell.TREES:
				trees.blit_rect(atlas, src, at)
			else:
				under.blit_rect(atlas, src, at)
	_under = ImageTexture.create_from_image(under)
	_trees = ImageTexture.create_from_image(trees)

func _draw() -> void:
	if _state == null:
		return
	draw_rect(Rect2(Vector2.ZERO, Vector2(Consts.FIELD_PX, Consts.FIELD_PX)), BACKGROUND)
	draw_texture(_under, Vector2.ZERO)
	for item in _items:
		_draw_item(item)
	# The forest is drawn last: tanks hide under it, and that is its whole
	# point.
	draw_texture(_trees, Vector2.ZERO)

func _draw_item(item) -> void:
	var texture := _sprites
	var size := SPRITE_PX
	var columns := SPRITE_COLUMNS
	if item.atlas == ViewModel.Atlas.BULLETS:
		texture = _bullets
		size = Consts.BULLET / Consts.SUBPIXEL
		columns = BULLET_COLUMNS
	elif item.atlas == ViewModel.Atlas.TERRAIN:
		texture = _terrain_atlas
		size = Consts.CELL_PX
		columns = TERRAIN_COLUMNS
	var src := Rect2i((item.frame % columns) * size, (item.frame / columns) * size, size, size)
	draw_texture_rect_region(texture, Rect2(item.pos, Vector2(size, size)), src, item.tint)
