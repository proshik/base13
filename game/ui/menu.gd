extends Node2D

## Choosing the number of players. The cursor is a tank, as in the original:
## cheaper than a highlight and it says at once what we are playing.
##
## What goes up is the selection index rather than an outcome: 0 for one player,
## 1 for two. The root node adds one.

signal finished(outcome: int)

const SCREEN := Vector2(256, 240)
const ITEMS := ["1 PLAYER", "2 PLAYERS", "NETWORK"]
## A phone has one pair of thumbs on one screen: two players there would need two.
const TOUCH_ITEMS := ["1 PLAYER", "NETWORK"]
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
## Set once, from the machine; a field so that a test can say "phone".
var touch := TouchDevice.present()

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func configure(_campaign, _players: int, best: int) -> void:
	_best = best
	queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	match UiInput.of(event):
		UiInput.Act.UP:
			_move(-1)
		UiInput.Act.DOWN:
			_move(1)
		UiInput.Act.CONFIRM, UiInput.Act.START:
			_confirm()

func items() -> Array:
	return TOUCH_ITEMS if touch else ITEMS

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
	return items()[_choice] == "NETWORK"

## How many players were chosen. A separate question rather than mixed into the
## outcome: the network item once returned 4, the root read that as "five
## players" and went straight into the game, past the network screen.
func players() -> int:
	return 2 if items()[_choice] == "2 PLAYERS" else 1

func _move(step: int) -> void:
	var count := items().size()
	_choice = (_choice + count + step) % count
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0))
	var text_scale := 2 if touch else 1
	TextPainter.draw_centred(self, _font, "BASE 13", 56, Color.WHITE, text_scale)
	TextPainter.draw_centred(self, _font, "HI %d" % _best, 80, Color.WHITE, text_scale)
	var shown := items()
	for i in shown.size():
		TextPainter.draw_line(self, _font, shown[i], Vector2i(80 if touch else TEXT_X,
			FIRST_Y + i * (32 if touch else STEP_Y)),
			Color.WHITE, text_scale)
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
	if touch:
		# The keys are not there to name.
		return [] as Array[String]
	var rows: Array[String] = []
	for i in Keyboard.LAYOUTS.size():
		var keys := Keyboard.describe(i)
		rows.append("%dP  %-7s %s" % [i + 1, keys["move"], keys["fire"]])
	rows.append("ESC PAUSE   F SCREEN")
	return rows

func _draw_cursor() -> void:
	var frame := Frames.tank(Types.TankType.PLAYER, 0, Types.Dir.RIGHT, 0)
	var src := Rect2i((frame % 16) * 16, (frame / 16) * 16, 16, 16)
	var at := Vector2((80 if touch else TEXT_X) + CURSOR_DX,
		FIRST_Y + _choice * (32 if touch else STEP_Y) + (0 if touch else CURSOR_DY))
	draw_texture_rect_region(_sprites, Rect2(at, Vector2(16, 16)), src)

