class_name RotateHint
extends CanvasLayer

## Held upright, a phone has no strips beside the picture for the thumbs, and the
## picture itself would be a third of the screen. The game asks to be turned instead.

const TEXT := "ROTATE PHONE"

var _font: Texture2D = preload("res://assets/font.png")
var _art: Node2D

func _ready() -> void:
	layer = 10
	_art = Node2D.new()
	_art.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_art.draw.connect(_paint)
	add_child(_art)

func refresh() -> void:
	_art.queue_redraw()

func _paint() -> void:
	var view := _art.get_viewport().get_visible_rect().size
	_art.draw_rect(Rect2(Vector2.ZERO, view), Color.BLACK)
	var at := Vector2i(int(view.x) / 2 - TextPainter.width_of(TEXT) / 2, int(view.y) / 2 - 4)
	TextPainter.draw_line(_art, _font, TEXT, at)
