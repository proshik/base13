extends GutTest

## A press that came and went between two captures, in a network game. The tick
## captured next carries it to the partner; nothing captured, nothing lost — a
## tick standing for the partner keeps the press until the game moves again.

class Wire extends Link:
	var sent := {}    ## tick → bits, of the input packets that went out
	func send(data: PackedByteArray) -> void:
		var packet := Protocol.unpack(data)
		if packet.get("kind", Protocol.Kind.INVALID) == Protocol.Kind.INPUT:
			sent[packet["tick"]] = packet["bits"]

var wire: Wire
var held := [0]

func before_each() -> void:
	PressLatch.clear()
	wire = Wire.new()
	held[0] = 0

func after_each() -> void:
	PressLatch.clear()

## The first tick captured whose input goes out: earlier ones apply before the
## game begins.
const FIRST := Rollback.START - Rollback.INPUT_DELAY

func _net() -> NetInput:
	return NetInput.new(wire, 0, func(_t: int) -> int: return held[0])

func _tap(physical: int) -> void:
	var down := InputEventKey.new()
	down.physical_keycode = physical
	down.pressed = true
	var up := InputEventKey.new()
	up.physical_keycode = physical
	PressLatch.note(down)
	PressLatch.note(up)

func test_a_tap_between_captures_goes_out_with_the_next_one() -> void:
	var net := _net()
	net.capture(FIRST)
	_tap(KEY_SPACE)
	net.capture(FIRST + 1)
	net.capture(FIRST + 2)
	var first := FIRST + 1 + Rollback.INPUT_DELAY
	assert_eq(wire.sent[first], Types.IN_FIRE, "the tap never went out")
	assert_eq(wire.sent[first + 1], 0, "one tap went out as two ticks of fire")
	assert_eq(net.inputs_for(first)[0], Types.IN_FIRE, "our own buffer lost the tap")

func test_a_tap_while_a_tick_stands_waits_for_the_next_capture() -> void:
	var net := _net()
	var stands := Rollback.START + Rollback.MAX_ROLLBACK
	for t in stands + 1:
		net.capture(t)
	assert_false(net.can_predict(stands), "the game did not stand")
	_tap(KEY_LEFT)
	# Frames go by with the tick still standing: it is captured again, and nothing
	# new is read.
	net.capture(stands)
	net.capture(stands)
	net.capture(stands + 1)
	assert_eq(wire.sent[stands + 1 + Rollback.INPUT_DELAY], Types.IN_LEFT,
		"the tap made while the game stood was lost")

func test_a_tap_adds_to_what_is_held() -> void:
	var net := _net()
	held[0] = Types.IN_UP
	_tap(KEY_SPACE)
	net.capture(FIRST)
	assert_eq(wire.sent[Rollback.START], Types.IN_UP | Types.IN_FIRE)

func test_a_network_game_reads_the_first_layout_only() -> void:
	# Both sides play with player one's keys: WASD is nobody's here.
	var net := _net()
	_tap(KEY_W)
	net.capture(FIRST)
	assert_eq(wire.sent[Rollback.START], 0)
