class_name LaggyLink
extends Link

## A link with the internet's delays, on a clock the test turns by hand.
##
## A packet crosses two legs, sender to relay and relay to partner, the way it
## does through the room server. Each leg takes its base time plus a jitter drawn
## from a seeded Rng, so a run comes out the same every time. Nothing overtakes:
## a leg is a TCP stream, and a packet that left later never arrives earlier.
## That is what makes one late packet cost a burst of waiting rather than a
## single frame — the shape a real link has and a plain delay does not.
##
## The two ends share a Wire rather than holding each other: two RefCounted
## pointing at each other are never collected.

## Milliseconds that only move when the test moves them. Kept in microseconds so
## that sixty frames a second add up to a second rather than to 960 ms.
class Clock:
	var us := 0

	func ms() -> int:
		return us / 1000

class Wire:
	var clock: Clock
	var leg_ms := 0
	var jitter_ms := 0
	var rng: Rng
	## Per direction: packets on their way to side 0 and to side 1, in order of
	## arrival, as [arrival_ms, data].
	var inbox := [[], []]
	## When the last packet towards each side reached the relay and the partner.
	## A later packet may not beat them.
	var last_at_relay := [0, 0]
	var last_arrival := [0, 0]

	func leg() -> int:
		return leg_ms + rng.next_range(-jitter_ms, jitter_ms + 1)

	func carry(to: int, data: PackedByteArray) -> void:
		var at_relay := maxi(clock.ms() + leg(), last_at_relay[to])
		last_at_relay[to] = at_relay
		var arrival := maxi(at_relay + leg(), last_arrival[to])
		last_arrival[to] = arrival
		inbox[to].append([arrival, data])

var _wire: Wire
var _side := 0

## Two ends of one link. `leg_ms ± jitter_ms` is one leg, so the full circle a
## lockstep tick depends on — A to relay to B and back — is four of them.
static func pair(clock: Clock, leg_ms: int, jitter_ms: int, seed_value: int) -> Array[LaggyLink]:
	var wire := Wire.new()
	wire.clock = clock
	wire.leg_ms = leg_ms
	wire.jitter_ms = jitter_ms
	wire.rng = Rng.new(seed_value)
	return [LaggyLink.new(wire, 0), LaggyLink.new(wire, 1)] as Array[LaggyLink]

func _init(wire: Wire, side: int) -> void:
	_wire = wire
	_side = side

func send(data: PackedByteArray) -> void:
	_wire.carry(1 - _side, data)

func poll() -> void:
	var box: Array = _wire.inbox[_side]
	while not box.is_empty() and box[0][0] <= _wire.clock.ms():
		var data: PackedByteArray = box.pop_front()[1]
		packet_received.emit(data)
