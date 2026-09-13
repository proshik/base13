class_name NetStats
extends Node2D

## Numbers about how a network game is going, drawn over the field. Toggled
## with the L key.
##
## It exists for one reason: so that a person on another machine can send a
## screenshot instead of hunting for the developer console and copying text out
## of it. Hence the line is built only from what the atlas font can draw —
## digits and capital Latin letters.

const TINT := Color(0.35, 1.0, 0.45)
const AT := Vector2i(4, 4)

var _font: Texture2D = preload("res://assets/font.png")
var _line := ""

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	z_index = 100
	visible = false

func show_line(line: String) -> void:
	if line == _line:
		return
	_line = line
	queue_redraw()

func _draw() -> void:
	if _line == "":
		TextPainter.draw_line(self, _font, "NET NO DATA YET", AT, TINT)
		return
	TextPainter.draw_line(self, _font, _line, AT, TINT)
