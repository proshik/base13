extends Node2D

## The splash screen. It leaves on any key or by itself: everybody hates a
## splash screen that cannot be skipped.

signal finished(outcome: int)

const SCREEN := Vector2(256, 240)
const SECONDS := 4.0

var _font: Texture2D = preload("res://assets/font.png")
var _best := 0
var _timer := SECONDS
var _left := false

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func configure(_campaign, _players: int, best: int) -> void:
	_best = best
	queue_redraw()

func _process(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_leave()

func _unhandled_input(event: InputEvent) -> void:
	if SkipInput.is_skip(event):
		_leave()

## A flag rather than merely stopping the frames: a key press and the expiring
## timer can arrive in the same frame, and the screen would change twice.
func _leave() -> void:
	if _left:
		return
	_left = true
	set_process(false)
	finished.emit(ScreenFlow.Outcome.CONTINUE)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0))
	TextPainter.draw_centred(self, _font, "BASE 13", 88)
	TextPainter.draw_centred(self, _font, "HI %d" % _best, 120)
	TextPainter.draw_centred(self, _font, "PRESS ANY KEY", 168)

