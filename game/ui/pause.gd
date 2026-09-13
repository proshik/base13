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

var _font: Texture2D = preload("res://assets/font.png")
var _kind := Kind.PAUSE

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	visible = false

func set_shown(value: bool, kind: int = Kind.PAUSE) -> void:
	visible = value
	_kind = kind
	queue_redraw()

func _draw() -> void:
	if _kind == Kind.LEAVE:
		draw_rect(Rect2(Vector2.ZERO, SCREEN), ASKING_VEIL)
		TextPainter.draw_centred(self, _font, "LEAVE MATCH", 104)
		TextPainter.draw_centred(self, _font, "Q QUIT", 128, HINT_TINT)
		TextPainter.draw_centred(self, _font, "ESC BACK", 140, HINT_TINT)
		return
	draw_rect(Rect2(Vector2.ZERO, SCREEN), VEIL)
	TextPainter.draw_centred(self, _font, "PAUSE", 104)
	TextPainter.draw_centred(self, _font, "ESC RESUME", 128, HINT_TINT)
	TextPainter.draw_centred(self, _font, "Q QUIT", 140, HINT_TINT)

