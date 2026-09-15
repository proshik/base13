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
	input.raise_to(before + 3, 0)
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
		input.raise_to(input.delay() + NetInput.MAX_STEP, i)
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
			input.raise_to(input.delay() + 3, now)
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
		input.raise_to(input.delay() + NetInput.MAX_STEP, i)
	var grown := input.delay()
	assert_eq(grown, NetInput.MAX_DELAY, "first it grew to the ceiling")

	for i in 40:
		input.ease_delay()
	assert_lt(input.delay(), grown, "on a calm network it must come back down")
	assert_gte(input.delay(), Lockstep.DELAY, "there is no reason to go below the starting value")

## The delay is reconsidered once a second, on a clock the test turns by hand.
class Clocked extends NetInput:
	var now := 0
	func _clock() -> int:
		return now

## One window of play. The partner's input runs `ahead` ticks in advance of the
## last tick, except for the ticks in `waits`: each stands for its milliseconds,
## split over `frames` frames, before the partner's input for it arrives. When
## `partner_delay` is given, the partner's hash reveals it before the window.
func _window(net: Clocked, from: int, ahead: int, waits := {}, frames := 1,
		partner_delay := -1) -> void:
	var edge := from + NetInput.WINDOW + ahead - 1
	for t in range(from, edge + 1):
		if not waits.has(t):
			net.handle_packet(Protocol.pack_input(t, 0))
	if partner_delay >= 0:
		net.handle_packet(Protocol.pack_hash(edge - partner_delay, 0))
	for t in range(from, from + NetInput.WINDOW):
		net.capture(t)
		if waits.has(t):
			for f in frames:
				assert_false(net.can_advance(t), "tick %d was meant to wait" % t)
				net.now += waits[t] / frames
			net.handle_packet(Protocol.pack_input(t, 0))
		assert_true(net.can_advance(t), "tick %d is not computed" % t)
		net.after_tick(t, 0)
		net.now += 1000 / 60

func test_the_delay_is_reconsidered_every_second() -> void:
	var net := Clocked.new(link, 0)
	_window(net, 0, 0, {10: 20, 20: 100, 30: 20})
	assert_gt(net.delay(), Lockstep.DELAY,
		"a second of waiting must be answered within that second, not five later")
	assert_ne(net.last_report, "", "the numbers on screen must be as fresh as the decision")

func test_one_late_packet_a_second_is_not_worth_growing() -> void:
	var net := Clocked.new(link, 0)
	_window(net, 0, 0, {20: 50})
	assert_eq(net.delay(), Lockstep.DELAY,
		"an isolated late packet is unavoidable, and mushier controls do not pay for it")

func test_repeated_hundred_millisecond_waits_grow_by_what_they_lack() -> void:
	# A hundred milliseconds is six ticks the two delays together fell short by.
	# Both sides grow at once, so each takes half.
	var net := Clocked.new(link, 0)
	_window(net, 0, 0, {10: 100, 20: 100, 30: 100})
	assert_eq(net.delay(), Lockstep.DELAY + 3,
		"growing a tick at a time is ten seconds of stutter on a slow path")

func test_one_long_wait_is_a_hitch_not_the_network() -> void:
	# Judged by its longest wait, a partner's single slow frame put six ticks on
	# the delay. What the network lacks is what repeats.
	var net := Clocked.new(link, 0)
	_window(net, 0, 0, {10: 20, 20: 120, 30: 20})
	assert_eq(net.delay(), Lockstep.DELAY + 1)

func test_a_partner_standing_still_is_not_a_slow_network() -> void:
	# Two seconds on another browser tab, waited out frame by frame.
	var net := Clocked.new(link, 0)
	_window(net, 0, 0, {20: 2000, 40: 2000}, 120)
	assert_eq(net.delay(), Lockstep.DELAY, "a tab switch drove the delay up")

func test_a_wait_shorter_than_a_tick_is_no_stutter() -> void:
	# At 144 Hz the tick is asked for a few milliseconds before its input comes,
	# and would not have been drawn any sooner.
	var net := Clocked.new(link, 0)
	_window(net, 0, 0, {10: 7, 20: 7, 30: 7})
	assert_eq(net.delay(), Lockstep.DELAY)

func test_one_second_adds_no_more_than_the_step() -> void:
	var waits := {}
	for t in range(Lockstep.DELAY, NetInput.WINDOW, 2):
		waits[t] = 100
	var net := Clocked.new(link, 0)
	_window(net, 0, 0, waits)
	assert_eq(net.delay(), Lockstep.DELAY + NetInput.MAX_STEP)

func test_a_wait_counts_once_however_many_frames_it_spans() -> void:
	# At 144 Hz a forty-millisecond wait is six frames; counted by frames, it
	# would look like six waits.
	var fast := Clocked.new(link, 0)
	_window(fast, 0, 0, {10: 42}, 6)
	var slow := Clocked.new(Recorder.new(), 0)
	_window(slow, 0, 0, {10: 42}, 1)
	assert_eq(fast.delay(), slow.delay(), "the frame rate changed the decision")
	assert_eq(fast.delay(), Lockstep.DELAY, "one wait a second is tolerated")

func test_the_partner_delay_is_read_from_their_packets() -> void:
	# They send the input for `tick + delay` just before computing `tick`, and
	# the hash of `tick` just after.
	var net := Clocked.new(link, 0)
	for t in range(Lockstep.DELAY, 50):
		net.handle_packet(Protocol.pack_input(t, 0))
	net.handle_packet(Protocol.pack_hash(40, 0))
	assert_eq(net._partner_delay, 9)

func test_the_delay_comes_down_only_with_ticks_to_spare() -> void:
	var net := Clocked.new(link, 0)
	net.raise_to(10, 0)
	_window(net, 0, NetInput.SPARE, {}, 1, 10)
	assert_eq(net.delay(), 10,
		"with only the spare ticks left the next wait is one jitter away")
	_window(net, NetInput.WINDOW, NetInput.SPARE + 1)
	assert_eq(net.delay(), 9, "a calm second with room to spare gives a tick back")

## Our slack is the partner's delay, so the side with the smaller delay has the
## bigger slack. Judged by its own slack, that side came down first and kept
## coming down while the other waited and climbed — five against sixteen.
func test_the_larger_delay_gives_back_first() -> void:
	var net := Clocked.new(link, 0)
	net.raise_to(10, 0)
	_window(net, 0, 0, {}, 1, 5)
	assert_eq(net.delay(), 9, "the partner is resting on our ten ticks")

func test_the_smaller_delay_holds_despite_its_slack() -> void:
	var net := Clocked.new(link, 0)
	net.raise_to(8, 0)
	_window(net, 0, 5, {}, 1, 12)
	assert_eq(net.delay(), 8, "our slack is the partner's twelve, not our eight")
