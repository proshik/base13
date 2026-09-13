extends Node2D

## What was shot down during the level. The numbers come from the campaign: by
## this point the game screen has been destroyed along with the world state.

signal finished(outcome: int)

const SCREEN := Vector2(256, 240)
const KINDS := ["BASIC", "FAST", "POWER", "ARMOR"]
const SECONDS := 4.0
const ROW_H := 12
const BLOCK_GAP := 10
const REVEAL_SECONDS := 0.2   ## the tally lines appear one at a time, with a click
const TICK_SOUND := "res://assets/sfx/score_tick.wav"

var _font: Texture2D = preload("res://assets/font.png")
var _campaign: Campaign = null
var _best := 0
var _timer := SECONDS
var _lost := false
var _left := false
var _revealed := 0
var _reveal_timer := 0.0
var _tick: AudioStreamPlayer = null

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_tick = AudioStreamPlayer.new()
	_tick.stream = load(TICK_SOUND)
	add_child(_tick)

func configure(campaign: Campaign, _players: int, best: int) -> void:
	_campaign = campaign
	_best = best
	_lost = campaign != null and campaign.game_over
	queue_redraw()

func _process(delta: float) -> void:
	_reveal(delta)
	_timer -= delta
	if _timer <= 0.0:
		_leave()

## The tally appears line by line with a click, as in the original. The exit
## timer is held until every line is shown: an unfinished tally must not be
## swept away.
func _reveal(delta: float) -> void:
	if _revealed >= _total_rows():
		return
	_timer = SECONDS
	_reveal_timer -= delta
	if _reveal_timer > 0.0:
		return
	_reveal_timer = REVEAL_SECONDS
	_revealed += 1
	_tick.play()
	queue_redraw()

func _total_rows() -> int:
	return _campaign.slots.size() * KINDS.size() if _campaign != null else 0

func _unhandled_input(event: InputEvent) -> void:
	if SkipInput.is_skip(event):
		_leave()

func _leave() -> void:
	if _left:
		return
	_left = true
	set_process(false)
	finished.emit(ScreenFlow.Outcome.LOST if _lost else ScreenFlow.Outcome.CONTINUE)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0))
	if _campaign == null:
		return
	TextPainter.draw_centred(self, _font, "HI %d" % _best, 16)
	TextPainter.draw_centred(self, _font, "STAGE %d" % _campaign.finished_level, 32)
	var y := 60
	var shown := 0
	for i in _campaign.slots.size():
		TextPainter.draw_line(self, _font, "%dP  %d" % [i + 1, _campaign.slots[i].score],
			Vector2i(24, y))
		y += ROW_H + 2
		for k in KINDS.size():
			if shown < _revealed:
				TextPainter.draw_line(self, _font,
					"%s %d" % [KINDS[k], _campaign.last_kills[i][k]], Vector2i(40, y))
			shown += 1
			y += ROW_H
		y += BLOCK_GAP
	TextPainter.draw_centred(self, _font, "TOTAL %d" % _campaign.total_score(), 212)

