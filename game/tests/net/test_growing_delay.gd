extends GutTest

## The input delay grows when the network cannot keep up. What is checked here
## is the part that is easy to break: as it grows, a band of ticks is left
## between the old horizon and the new one for which nobody submitted our input.
## The partner would wait for them forever — the game would freeze for good.

class Recorder extends Link:
	var sent: Array[PackedByteArray] = []
	func send(data: PackedByteArray) -> void:
		sent.append(data)

var link: Recorder
var input: NetInput

func before_each() -> void:
	link = Recorder.new()
	input = NetInput.new(link, 0, func(_t: int) -> int: return Types.IN_LEFT)

func _sent_ticks() -> Array[int]:
	var ticks: Array[int] = []
	for packet in link.sent:
		var parsed := Protocol.unpack(packet)
		if parsed.get("kind", Protocol.Kind.INVALID) == Protocol.Kind.INPUT:
			ticks.append(parsed["tick"])
	return ticks

func test_delay_starts_small_so_controls_stay_responsive() -> void:
	assert_eq(input.delay(), Lockstep.DELAY)

func test_growing_leaves_no_gap_in_our_input() -> void:
	input.capture(0)
	var before := input.delay()
	input.grow_delay(0)
	assert_gt(input.delay(), before, "the delay must grow")

	# Every tick from the old horizon to the new one must be submitted, or the
	# partner stalls on the first missing one.
	var ticks := _sent_ticks()
	for tick in range(before, input.delay() + 1):
		assert_true(ticks.has(tick),
			"there is no input of ours for tick %d, and the partner would wait for it forever" % tick)

func test_growing_never_goes_past_the_ceiling() -> void:
	for i in 50:
		input.capture(i)
		input.grow_delay(i)
	assert_lte(input.delay(), NetInput.MAX_DELAY,
		"unbounded growth would turn the game into correspondence")
	assert_eq(input.delay(), NetInput.MAX_DELAY, "it must reach the ceiling")

func test_a_partner_with_another_delay_is_understood() -> void:
	# The sides are free to hold different delays: the tick number travels in the
	# packet. Otherwise growth on one machine would desync the game.
	var tick := 40
	input.handle_packet(Protocol.pack_input(tick, Types.IN_FIRE))
	input.capture(tick - Lockstep.DELAY)
	assert_true(input.can_advance(tick), "the other side's input for this tick is known")
	assert_eq(input.inputs_for(tick)[1], Types.IN_FIRE)

func test_growth_keeps_the_game_playable_afterwards() -> void:
	# After the growth the game must keep computing rather than stall.
	for now in 30:
		input.capture(now)
		if now == 10:
			input.grow_delay(now)
		# The other side's input arrives on time, so nothing prevents computing.
		input.handle_packet(Protocol.pack_input(now, 0))
		assert_true(input.can_advance(now),
			"tick %d is not computed after the delay grew" % now)

## Packets must leave for the socket in the same frame they were captured.
## `WebSocketPeer.send()` only queues; `poll()` is what writes the queue. While
## sending happened after the single poll of a frame, every press lay there an
## extra frame — eight to sixteen milliseconds each way out of a budget of
## eighty-three.
class Counter extends Link:
	var polls := 0
	var sends := 0
	var polled_after_last_send := false
	func send(_data: PackedByteArray) -> void:
		sends += 1
		polled_after_last_send = false
	func poll() -> void:
		polls += 1
		if sends > 0:
			polled_after_last_send = true

func test_captured_input_is_flushed_within_the_same_frame() -> void:
	var counter := Counter.new()
	var net := NetInput.new(counter, 0, func(_t: int) -> int: return Types.IN_UP)
	net.capture(0)
	assert_gt(counter.sends, 0, "the press must be sent")
	net.flush()
	assert_true(counter.polled_after_last_send,
		"a poll is needed after sending, or the packet sits until the next frame")

## Waiting must not breed traffic. While a tick waits for the other side's
## input, `capture` is called every frame — and it used to send the same packet
## again. The result was a closed circle: waiting adds traffic, traffic clogs
## the channel, the channel adds waiting.
func test_the_same_input_is_not_sent_twice() -> void:
	input.capture(7)
	var after_first := link.sent.size()
	input.capture(7)
	input.capture(7)
	assert_eq(link.sent.size(), after_first,
		"a repeated call for the same tick must stay silent")

func test_a_new_tick_is_still_sent() -> void:
	input.capture(7)
	var after_first := link.sent.size()
	input.capture(8)
	assert_gt(link.sent.size(), after_first, "a new tick must go out")

## The delay must come back down: stuck at the ceiling it makes the controls
## mushy forever — which is exactly what a person calls "it lags even more".
func test_delay_comes_back_down_when_the_network_calms() -> void:
	for i in 20:
		input.capture(i)
		input.grow_delay(i)
	var grown := input.delay()
	assert_eq(grown, NetInput.MAX_DELAY, "first it grew to the ceiling")

	for i in 40:
		input.ease_delay()
	assert_lt(input.delay(), grown, "on a calm network it must come back down")
	assert_gte(input.delay(), Lockstep.DELAY, "there is no reason to go below the starting value")
