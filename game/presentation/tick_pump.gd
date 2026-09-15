class_name TickPump

## The core steps at exactly sixty ticks a second and knows nothing of frames.
## Here it is decided how many times to call tick() per drawn frame.
##
## Time is spent on ticks that happened, not on ticks that came due: in a network
## game a tick may fail to happen because the other side's input has not arrived
## yet. So the caller first asks `due()` and then reports with `spend()` how many
## ticks it actually computed, and whether it stopped for the partner.

const TICK_SECONDS := 1.0 / 60.0
## How many ticks may be caught up within one frame.
const MAX_CATCHUP := 5
## How deep the debt may get. A dropped frame or a partner's late packet is tens
## of milliseconds and fits here with room to spare. Standing still for longer —
## a minimised window, a hidden browser tab, or a partner who has one — is a
## freeze, and a freeze is forgotten whole rather than caught up: the game would
## skip across half the map.
##
## Whole, and on both sides alike. Cutting the debt down to this ceiling instead
## left the two sides of a network game holding different debts after one
## partner's tab switch, and a side holding more debt than its partner cannot pay
## it — see WAIT_CAUGHT_UP.
const MAX_DEBT := 0.5
## How much of a wait on the partner is caught up afterwards: half. The other
## half is let go, and the side that waited stays that much behind.
##
## Catching up all of it breaks two sides apart. A lockstep pair has one pace,
## the slower side's. A side carrying more debt than its partner races to the
## very edge of the partner's input and stands there, and every late packet
## becomes a frozen frame on that side alone; the debt is never paid, because the
## partner is not behind. Growing the delay does not help it either: our delay is
## the partner's slack, not ours. Letting half of each wait go moves the side
## that waits back from the edge and hands it the slack the other side has spare.
##
## Letting all of it go is too much the other way: while the network falls short,
## every wait costs the game its time and the pair runs slower than the clock.
## Half costs two to three percent of speed while the delay is still finding its
## value; `test_lag_profiles.gd` has the numbers.
const WAIT_CAUGHT_UP := 0.5

var _accumulated := 0.0
var _last_delta := 0.0
## How long the partner has kept us standing, frame after frame.
var _stood := 0.0

## How many ticks have come due by this frame.
func due(delta: float) -> int:
	_last_delta = delta
	if delta > MAX_DEBT:
		_accumulated = 0.0
		return 0
	_accumulated += delta
	if _accumulated > MAX_DEBT:
		_accumulated = MAX_DEBT
	return mini(int(_accumulated / TICK_SECONDS), MAX_CATCHUP)

## How many ticks were actually computed, and whether the frame stopped because
## the partner's input was not there. The rest stays in debt, less the part of a
## wait that is let go.
func spend(ticks: int, waited := false) -> void:
	_accumulated -= ticks * TICK_SECONDS
	if waited:
		_accumulated -= _last_delta * (1.0 - WAIT_CAUGHT_UP)
	# A frame with no tick due does not end a stand: at sixty frames a second of
	# 16.66 ms against ticks of 16.67, one comes along every so often, and ending
	# the stand there meant a long wait was never forgotten.
	if ticks > 0:
		_stood = 0.0
	elif waited or _stood > 0.0:
		_stood += _last_delta
	# Only a frame that actually stood for the partner forgets. Forgetting on
	# every frame of a long stand froze the game for good: a frame's own time is
	# a hair short of a tick, so nothing was ever due again.
	if waited and _stood > MAX_DEBT:
		_accumulated = 0.0
	if _accumulated < 0.0:
		_accumulated = 0.0

## Reset when unpausing: time passed while we stood still, but there is nothing
## to catch up.
func reset() -> void:
	_accumulated = 0.0
