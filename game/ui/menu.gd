extends Node2D

## Choosing the number of players. The cursor is a tank, as in the original:
## cheaper than a highlight and it says at once what we are playing.
##
## What goes up is the selection index rather than an outcome: 0 for one player,
## 1 for two. The root node adds one.

signal finished(outcome: int)

const SCREEN := Vector2(256, 240)
const ITEMS := ["1 PLAYER", "2 PLAYERS", "NETWORK"]
const FIRST_Y := 112
const STEP_Y := 24
const TEXT_X := 96
const CURSOR_DX := -24
const CURSOR_DY := -4
const LEGEND_Y := 190
const LEGEND_X := 46
const LEGEND_STEP := 12
const LEGEND_TINT := Color(0.62, 0.62, 0.62)

var _font: Texture2D = preload("res://assets/font.png")
var _sprites: Texture2D = preload("res://assets/sprites.png")
var _best := 0
var _choice := 0
var _left := false

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func configure(_campaign, _players: int, best: int) -> void:
	_best = best
	queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventJoypadButton and event.pressed:
		match event.button_index:
			JOY_BUTTON_DPAD_UP:
				_move(-1)
			JOY_BUTTON_DPAD_DOWN:
				_move(1)
			JOY_BUTTON_A, JOY_BUTTON_START:
				_confirm()
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.physical_keycode:
		KEY_UP, KEY_W:
			_move(-1)
		KEY_DOWN, KEY_S:
			_move(1)
		KEY_ENTER, KEY_SPACE:
			_confirm()

## A latch: Enter and a gamepad button can arrive in the same frame while the
## screen changes only later — the second confirmation would land on the game
## screen.
func _confirm() -> void:
	if _left:
		return
	_left = true
	finished.emit(ScreenFlow.Outcome.NET if _is_network() \
		else ScreenFlow.Outcome.CONTINUE)

func _is_network() -> bool:
	return _choice == ITEMS.size() - 1

## How many players were chosen. A separate question rather than mixed into the
## outcome: the network item once returned 4, the root read that as "five
## players" and went straight into the game, past the network screen.
func players() -> int:
	return 1 if _is_network() else _choice + 1

func _move(step: int) -> void:
	_choice = (_choice + ITEMS.size() + step) % ITEMS.size()
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0))
	TextPainter.draw_centred(self, _font, "BASE 13", 56)
	TextPainter.draw_centred(self, _font, "HI %d" % _best, 80)
	for i in ITEMS.size():
		TextPainter.draw_line(self, _font, ITEMS[i], Vector2i(TEXT_X, FIRST_Y + i * STEP_Y))
	_draw_cursor()
	_draw_legend()

## Who does what. Built from the key layout rather than written by hand: change
## the keys and the legend changes with them. In a muted colour so it does not
## argue with the menu items.
func _draw_legend() -> void:
	var rows := legend_rows()
	for i in rows.size():
		TextPainter.draw_line(self, _font, rows[i],
			Vector2i(LEGEND_X, LEGEND_Y + i * LEGEND_STEP), LEGEND_TINT)

## The legend's lines are kept apart from drawing: they used to drift out of
## step with the layouts unnoticed — three menu items against two layouts, and
## the third line came out empty with nothing but a player number.
func legend_rows() -> Array[String]:
	var rows: Array[String] = []
	for i in Keyboard.LAYOUTS.size():
		var keys := Keyboard.describe(i)
		rows.append("%dP  %-7s %s" % [i + 1, keys["move"], keys["fire"]])
	rows.append("ESC PAUSE   F SCREEN")
	return rows

func _draw_cursor() -> void:
	var frame := Frames.tank(Types.TankType.PLAYER, 0, Types.Dir.RIGHT, 0)
	var src := Rect2i((frame % 16) * 16, (frame / 16) * 16, 16, 16)
	var at := Vector2(TEXT_X + CURSOR_DX, FIRST_Y + _choice * STEP_Y + CURSOR_DY)
	draw_texture_rect_region(_sprites, Rect2(at, Vector2(16, 16)), src)

