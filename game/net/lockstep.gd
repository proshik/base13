class_name Lockstep

## A buffer of both sides' input, laid out by tick number.
##
## There is one rule: a tick is computed only once both players' input for that
## number is known. A packet is late — the game freezes and waits. Freezing
## together is right; drifting apart is not, because from there the worlds
## diverge further and further.
##
## Neither nodes nor sockets reach in here: this is a pure class, tested the same
## way the core is.

## A press made on tick N is applied on N plus the delay. In that time the
## packet must reach the partner.
##
## The value is adjustable rather than fixed: it sets the travel allowance, and a
## shortfall shows up not as lower speed but as stutter — one frame stands still
## and the next winds several ticks forward at once. The two sides may hold
## different delays: the tick number travels inside the packet, and determinism
## does not suffer.
const DELAY := 5

## How many past ticks to keep: the buffer must stay bounded, and a game runs
## for hours.
const KEEP := 240

var _local_index: int
var _local := {}      ## tick number to bits
var _remote := {}
var _hashes := {}     ## tick number to our world hash

## The furthest tick for which the other side's input is known. Needed only for
## the report: the difference from the current tick is the slack the game rests
## on. Slack at zero means every tick waits for a packet, and the game runs at
## the speed of the network rather than of the clock.
var _remote_edge := -1

var delay := DELAY

func _init(local_index: int, input_delay := DELAY) -> void:
	_local_index = local_index
	delay = input_delay
	# The first few ticks are known to carry no input: otherwise a game could
	# never start, since nobody has input for them.
	for tick in delay:
		_local[tick] = 0
		_remote[tick] = 0

## The tick number on which a press made right now will take effect.
func applied_tick(now: int) -> int:
	return now + delay

## The same computation at the default delay — for tests and for places with no
## instance at hand.
static func tick_for_press(now: int) -> int:
	return now + DELAY

## Record our own press, made on tick `now`.
func press(now: int, bits: int) -> void:
	submit_local(applied_tick(now), bits)

func submit_local(tick: int, bits: int) -> void:
	if not _local.has(tick):
		_local[tick] = bits

## A repeated packet does not overwrite what was accepted: networks duplicate,
## and changing what has already been computed is precisely a desync.
func submit_remote(tick: int, bits: int) -> void:
	_remote_edge = maxi(_remote_edge, tick)
	if not _remote.has(tick):
		_remote[tick] = bits

## How far the other side's input runs ahead of the current tick. Zero or less
## means the game is standing still, waiting on the network.
func cover(tick: int) -> int:
	return _remote_edge - tick

func can_advance(tick: int) -> bool:
	return _local.has(tick) and _remote.has(tick)

## Both players' input in slot order — identical on both sides, or the worlds
## diverge from the very first tick.
func inputs_for(tick: int) -> Array[int]:
	var mine: int = _local.get(tick, 0)
	var theirs: int = _remote.get(tick, 0)
	if _local_index == 0:
		return [mine, theirs] as Array[int]
	return [theirs, mine] as Array[int]

func forget_before(tick: int) -> void:
	for store in [_local, _remote, _hashes]:
		for key in store.keys():
			if key < tick:
				store.erase(key)

func buffered() -> int:
	return _local.size()

func record_local_hash(tick: int, value: int) -> void:
	_hashes[tick] = value

## Agreement or divergence. An unknown tick is not a divergence: the partner may
## simply have run ahead of us with the comparison, and calling that a fault
## would be wrong.
func check_remote_hash(tick: int, value: int) -> bool:
	if not _hashes.has(tick):
		return true
	return _hashes[tick] == value
