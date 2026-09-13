extends Node2D

## Desync: the two sides' worlds have diverged. We say so honestly and return to
## the menu.
##
## Carrying on quietly is not an option — the divergence only grows, and the
## players see different things without understanding why one of them watched a
## tank explode and the other did not.

signal finished(outcome: int)

const SCREEN := Vector2(256, 240)
const HINT_TINT := Color(0.62, 0.62, 0.62)

var _font: Texture2D = preload("res://assets/font.png")
var _tick := -1
var _left := false

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func show_tick(tick: int) -> void:
	_tick = tick
	queue_redraw()

func configure(_campaign, _players: int, _best: int) -> void:
	queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	if SkipInput.is_skip(event):
		_leave()

func _leave() -> void:
	if _left:
		return
	_left = true
	finished.emit(ScreenFlow.Outcome.CONTINUE)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0))
	TextPainter.draw_centred(self, _font, "DESYNC", 96)
	if _tick >= 0:
		TextPainter.draw_centred(self, _font, "AT TICK %d" % _tick, 120, HINT_TINT)
	TextPainter.draw_centred(self, _font, "PRESS ANY KEY", 168, HINT_TINT)
