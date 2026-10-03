class_name PauseOverlay
extends Node2D

## An overlay rather than a screen: the field shows through, so a person does not
## lose track of where they stopped.
##
## Two shapes, because Esc means two different things. Alone it stops the world.
## On the network there is no world to stop: the partner keeps playing, and our
## pause would only freeze their screen. So there Esc asks a question instead,
## and the game goes on behind it — hence the thinner veil, the field still
## matters while the question is up.

enum Kind { PAUSE, LEAVE }

const SCREEN := Vector2(256, 240)
const VEIL := Color(0, 0, 0, 0.55)
const ASKING_VEIL := Color(0, 0, 0, 0.35)
const HINT_TINT := Color(0.62, 0.62, 0.62)
## A choice of two, driven like the title menu: a pad and a phone have no Q. Esc and
## Q still work on a keyboard; the items say what they do.
const ITEMS := ["RESUME", "QUIT"]
const TEXT_X := 110
const FIRST_Y := 124
const STEP_Y := 16

var _font: Texture2D = preload("res://assets/font.png")
var _sprites: Texture2D = preload("res://assets/sprites.png")
var _kind := Kind.PAUSE
var _choice := 0
var _bounds := Rect2(Vector2.ZERO, SCREEN)

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	visible = false

func set_shown(value: bool, kind: int = Kind.PAUSE) -> void:
	visible = value
	_kind = kind
	_choice = 0
	queue_redraw()

func set_choice(index: int) -> void:
	_choice = index
	queue_redraw()

func set_bounds(bounds: Rect2) -> void:
	_bounds = bounds
	queue_redraw()

func _draw() -> void:
	var asking := _kind == Kind.LEAVE
	var offset := Vector2i(_bounds.get_center() - SCREEN / 2.0)
	draw_rect(_bounds, ASKING_VEIL if asking else VEIL)
	TextPainter.draw_centred(self, _font, "LEAVE MATCH" if asking else "PAUSE", 100 + offset.y)
	for i in ITEMS.size():
		TextPainter.draw_line(self, _font, ITEMS[i], Vector2i(TEXT_X, FIRST_Y + i * STEP_Y) + offset,
			Color.WHITE if i == _choice else HINT_TINT)
	# The cursor is a tank, as on the title menu.
	var frame := Frames.tank(Types.TankType.PLAYER, 0, Types.Dir.RIGHT, 0)
	var src := Rect2i((frame % 16) * 16, (frame / 16) * 16, 16, 16)
	var at := Vector2(TEXT_X - 22, FIRST_Y + _choice * STEP_Y - 4) + Vector2(offset)
	draw_texture_rect_region(_sprites, Rect2(at, Vector2(16, 16)), src)
