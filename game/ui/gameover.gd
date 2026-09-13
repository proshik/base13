extends Node2D

## The outcome of a game. The high score is updated here rather than during
## play: writing to disk for every tank destroyed is pointless, and until the
## very end a game can still finish differently.

signal finished(outcome: int)

const SCREEN := Vector2(256, 240)
const SECONDS := 6.0

var _font: Texture2D = preload("res://assets/font.png")
var _score := 0
var _best := 0
var _new_record := false
var _timer := SECONDS
var _left := false

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func configure(campaign: Campaign, _players: int, best: int) -> void:
	_score = campaign.total_score() if campaign != null else 0
	_new_record = _score > best
	_best = maxi(best, _score)
	queue_redraw()

func score() -> int:
	return _score

func best() -> int:
	return _best

func _process(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_leave()

func _unhandled_input(event: InputEvent) -> void:
	if SkipInput.is_skip(event):
		_leave()

func _leave() -> void:
	if _left:
		return
	_left = true
	set_process(false)
	finished.emit(ScreenFlow.Outcome.CONTINUE)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0))
	TextPainter.draw_centred(self, _font, "GAME OVER", 96)
	TextPainter.draw_centred(self, _font, "SCORE %d" % _score, 128)
	if _new_record:
		TextPainter.draw_centred(self, _font, "NEW RECORD", 152)
	else:
		TextPainter.draw_centred(self, _font, "HI %d" % _best, 152)

