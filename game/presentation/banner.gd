class_name Banner
extends Node2D

func _ready() -> void:
	# Explicit rather than inherited from the project: pixel art must not be
	# smoothed.
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

## A black screen with a single caption in the middle: STAGE 7, GAME OVER.

const SCREEN := Vector2(256, 240)
const BACKGROUND := Color(0, 0, 0)

var _font: Texture2D = preload("res://assets/font.png")
var _text := ""

func show_text(text: String) -> void:
	_text = text
	visible = true
	queue_redraw()

func hide_banner() -> void:
	visible = false

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), BACKGROUND)
	var width := TextPainter.width_of(_text)
	var at := Vector2i((int(SCREEN.x) - width) / 2, int(SCREEN.y) / 2 - TextPainter.GLYPH_PX)
	TextPainter.draw_line(self, _font, _text, at)
