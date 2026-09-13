class_name Effects

## Turns core events into decorations that burn out over time. The only place in
## the presentation layer with state of its own: an explosion outlives the tick
## it was born in. Rule 6 permits exactly this exception.

const FRAME_TICKS := 4
const BIG_LIFETIME := FRAME_TICKS * Frames.BOOM_BIG_FRAMES
const SMALL_LIFETIME := FRAME_TICKS * Frames.BOOM_SMALL_FRAMES

const BIG_EVENTS := [
	Types.Event.TANK_DESTROYED,
	Types.Event.PLAYER_DESTROYED,
	Types.Event.BASE_DESTROYED,
]
const SMALL_EVENTS := [
	Types.Event.BULLET_HIT_BRICK,
	Types.Event.BULLET_HIT_STEEL,
	Types.Event.BULLET_HIT_BULLET,
]

class Burst:
	var pos := Vector2i.ZERO   ## pixels, top-left of the sprite
	var age := 0
	var big := false

var _bursts: Array = []

func absorb(events: Array) -> void:
	for e in events:
		if BIG_EVENTS.has(e.type):
			# The big explosion takes the tank's place: the event carries its
			# top-left corner.
			_add(ViewModel.to_pixels(e.pos), true)
		elif SMALL_EVENTS.has(e.type):
			# The small one goes to the point of impact, hence the half-sprite
			# offset.
			_add(ViewModel.to_pixels(e.pos) - Vector2i(Frames.SPRITE_HALF, Frames.SPRITE_HALF), false)

func advance() -> void:
	var alive: Array = []
	for b in _bursts:
		b.age += 1
		var lifetime: int = BIG_LIFETIME if b.big else SMALL_LIFETIME
		if b.age < lifetime:
			alive.append(b)
	_bursts = alive

func items() -> Array:
	var out: Array = []
	for b in _bursts:
		var step: int = b.age / FRAME_TICKS
		var frame: int = Frames.boom_big(step) if b.big else Frames.boom_small(step)
		var it := ViewModel.Item.new()
		it.atlas = ViewModel.Atlas.SPRITES
		it.frame = frame
		it.pos = b.pos
		it.layer = ViewModel.Layer.OVER
		out.append(it)
	return out

func _add(pos: Vector2i, big: bool) -> void:
	var b := Burst.new()
	b.pos = pos
	b.big = big
	_bursts.append(b)
