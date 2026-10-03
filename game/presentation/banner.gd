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
var text_scale := 1
var _text := ""
var _bounds := Rect2(Vector2.ZERO, SCREEN)

func show_text(text: String) -> void:
	_text = text
	visible = true
	queue_redraw()

func hide_banner() -> void:
	visible = false

func set_bounds(bounds: Rect2) -> void:
	_bounds = bounds
	queue_redraw()

func _draw() -> void:
	draw_rect(_bounds, BACKGROUND)
	# A line break starts a new line, each centred; the block stays in the middle.
	var lines := _text.split("\n")
	var top := int(_bounds.get_center().y) - TextPainter.GLYPH_PX * text_scale * lines.size()
	for i in lines.size():
		var width := TextPainter.width_of(lines[i], text_scale)
		var at := Vector2i(int(_bounds.get_center().x) - width / 2,
			top + i * TextPainter.GLYPH_PX * text_scale * 2)
		TextPainter.draw_line(self, _font, lines[i], at, Color.WHITE, text_scale)
