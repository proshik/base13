class_name HudPanel
extends Node2D

func _ready() -> void:
	# Explicit rather than inherited from the project: pixel art must not be
	# smoothed.
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

## The right-hand panel. Not tied to the field's position: in subproject 2 it
## moves below for portrait orientation, and the field's drawing will never know.

const BACKGROUND := Color(0.36, 0.34, 0.32)
const PANEL_SIZE := Vector2(40, 208)
const TEXT_LEFT := 4

var _font: Texture2D = preload("res://assets/font.png")
var _model: ViewModel.Hud = null
var _horizontal := false

func show_model(model: ViewModel.Hud) -> void:
	_model = model
	queue_redraw()

func set_horizontal(value: bool) -> void:
	_horizontal = value
	queue_redraw()

func _draw() -> void:
	if _model == null:
		return
	if _horizontal:
		_draw_row()
		return
	draw_rect(Rect2(Vector2.ZERO, PANEL_SIZE), BACKGROUND)
	TextPainter.draw_line(self, _font, "ENEMY", Vector2i(TEXT_LEFT, 8))
	TextPainter.draw_line(self, _font, str(_model.enemies_left), Vector2i(TEXT_LEFT, 18))
	var row := 40
	for i in _model.lives.size():
		TextPainter.draw_line(self, _font, "%dP" % (i + 1), Vector2i(TEXT_LEFT, row))
		TextPainter.draw_line(self, _font, str(_model.lives[i]), Vector2i(TEXT_LEFT, row + 10))
		row += 32
	TextPainter.draw_line(self, _font, "STAGE", Vector2i(TEXT_LEFT, row + 8))
	TextPainter.draw_line(self, _font, str(_model.level), Vector2i(TEXT_LEFT, row + 18))

## Keep both lives in co-op. The row has three groups with a measured gap, rather
## than a fixed column that clips a large stage number or a second player.
func _draw_row() -> void:
	draw_rect(Rect2(0, 0, 256, 32), BACKGROUND)
	var enemies := "ENEMY %d" % _model.enemies_left
	var lives: Array[String] = []
	for i in _model.lives.size():
		lives.append("%dP %d" % [i + 1, _model.lives[i]])
	var players := "  ".join(lives)
	var stage := "STAGE %d" % _model.level
	var right := 248 - TextPainter.width_of(stage)
	var middle := (256 - TextPainter.width_of(players)) / 2
	TextPainter.draw_line(self, _font, enemies, Vector2i(8, 8))
	TextPainter.draw_line(self, _font, players, Vector2i(middle, 8))
	TextPainter.draw_line(self, _font, stage, Vector2i(right, 8))
