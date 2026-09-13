class_name TickPump

## The core steps at exactly sixty ticks a second and knows nothing of frames.
## Here it is decided how many times to call tick() per drawn frame.
##
## Time is spent on ticks that happened, not on ticks that came due: in a network
## game a tick may fail to happen because the other side's input has not arrived
## yet. Spent for nothing, it is lost forever — the slack that lockstep rests on
## drains away, and the game drops from sixty ticks a second to one tick per
## network round trip. So the caller first asks `due()` and then reports with
## `spend()` how many ticks it actually computed.

const TICK_SECONDS := 1.0 / 60.0
## How many ticks may be caught up within one frame.
const MAX_CATCHUP := 5
## How deep the debt may get. Waiting for a partner is measured in tens of
## milliseconds and fits here with room to spare; anything larger is a dropped
## frame or a minimised window, and catching that up is not allowed: the game
## would skip across half the map.
const MAX_DEBT := 0.5

var _accumulated := 0.0

## How many ticks have come due by this frame.
func due(delta: float) -> int:
	_accumulated += delta
	if _accumulated > MAX_DEBT:
		_accumulated = MAX_DEBT
	return mini(int(_accumulated / TICK_SECONDS), MAX_CATCHUP)

## How many ticks were actually computed. The rest stays in debt.
func spend(ticks: int) -> void:
	_accumulated -= ticks * TICK_SECONDS
	if _accumulated < 0.0:
		_accumulated = 0.0

## Reset when unpausing: time passed while we stood still, but there is nothing
## to catch up.
func reset() -> void:
	_accumulated = 0.0
