class_name NetInput
extends InputSource

## Input in a network game: our press goes to the partner and into the buffer,
## theirs arrives from the socket. A tick is computed only once both are present
## — Lockstep is responsible for that.
##
## Each player sits at their own machine, so both sides play with player one's
## key layout: everyone's own tank is "the first" to them, while who they are in
## the world is decided by the slot number, identical on both sides.

const HASH_EVERY := 60   ## compare once a second
## How often to report on how the game is going. Once every five seconds: less
## often misses a short dip, more often buries the console.
const REPORT_EVERY := 300
## How often the delay is reconsidered, in computed ticks: once a second. It used
## to be the report's five seconds, stretched further while the game stood
## waiting, and a slow path stuttered for ten to twenty seconds before the delay
## caught up with it.
const WINDOW := 60

## How far the input delay may grow.
##
## It grows rather than being a fixed number, because the value needed depends on
## the network and not on the game. The two delays together must cover the whole
## circle a tick depends on — our press to the partner, their press back to us:
## `(ours + theirs) × 16.7 ms ≥ circle + two frames`. On a local network five
## ticks a side is plenty and the controls stay responsive; through a relay in
## Moscow the circle is a quarter of a second and five is not nearly enough.
## Sixteen ticks is 266 ms: beyond that the game turns into correspondence, and
## it is more honest to stop at the ceiling.
const MAX_DELAY := 16
## The most one window may add: a burst of bad luck must not drive the delay to
## the ceiling at a stroke.
const MAX_STEP := 6
## How many ticks in a row may go uncomputed before the screen says so. A tick is
## 1/60 s, so this is about a second: any less and the caption would blink on and
## off with ordinary jitter, which is worse than no caption at all.
const STALL_BEFORE_SAYING := 60

## How many ticks may wait within a window before the delay grows. A late packet
## a second is unavoidable and not worth mushier controls; two already are.
const STALLS_TOLERATED := 1
## Ticks of the partner's slack to spare before the delay comes down. Without
## them it would step down, wait, grow back and step down again — a jolt every
## two seconds.
const SPARE := 2
## A wait this long is a frame loop that stopped — a hidden browser tab, a
## dragged window, a slow first frame, on either side — and not a network falling
## short. It says nothing about the delay, and counted, one tab switch would drive
## the delay to the ceiling. A network spike this long is rare enough to ignore
## too.
const FROZEN_MS := 150

## How far ahead of our last computed tick the partner's input may be. An honest
## partner is never further than both input delays together: they cannot compute
## a tick without our input for it, and ours runs at most MAX_DELAY ahead.
## Lockstep.KEEP bounds the buffer's past; the same number bounds its future.
## Without it a packet for tick two billion sits in the buffer for good, and a
## stream of them stalls the game: forget_before walks every key on every tick.
const FARTHEST_AHEAD := Lockstep.KEEP

var desynced := false
var desync_tick := -1

## Counters for the window and the report. Without them "it lags" stays a word:
## the numbers show whether the game falls behind the clock and whose fault that
## is — its own or the network's.
var _advanced := 0
var _last_tick := 0
var _stall_run := 0
## The tick that is waiting right now and when it began to. A wait is counted
## once per tick rather than once per frame: at 144 Hz a single forty-millisecond
## wait is six frames, and the frame rate must not decide the delay.
var _waiting_tick := -1
var _wait_began := 0
## The partner's input delay, as their own packets reveal it: see handle_packet.
var _partner_delay := Lockstep.DELAY
var _window := Tally.new()
var _report := Tally.new()
## The last tick whose input has already been sent. While a tick waits for the
## other side's packet, `capture` is called every frame, and without this mark
## the same packet would go out again and again: waiting would breed traffic, and
## traffic would breed more waiting.
var _sent_through := -1

## The last report in a form the game's font can draw: digits and capital Latin
## letters only, nothing else is in the atlas. It exists so the numbers can be
## seen on screen instead of being dug out of a console on another machine.
var last_report := ""

var _link: Link
var _lockstep: Lockstep
var _bits_provider: Callable

## What a stretch of play looked like: how many ticks waited, the longest wait,
## and how much of the partner's input there was to rest on.
class Tally:
	var began := 0
	var waited := 0
	var waited_ms := 0
	var longest_ms := 0
	var second_ms := 0
	var cover_min := 0
	var cover_sum := 0
	var samples := 0

	func note(ms: int) -> void:
		if ms > longest_ms:
			second_ms = longest_ms
			longest_ms = ms
		elif ms > second_ms:
			second_ms = ms

	func sample(cover: int, now: int) -> void:
		if samples == 0:
			began = now
			cover_min = cover
		cover_min = mini(cover_min, cover)
		cover_sum += cover
		samples += 1

	func absorb(other: Tally) -> void:
		if samples == 0:
			began = other.began
			cover_min = other.cover_min
		cover_min = mini(cover_min, other.cover_min)
		waited += other.waited
		waited_ms += other.waited_ms
		for ms in [other.longest_ms, other.second_ms]:
			note(ms)
		cover_sum += other.cover_sum
		samples += other.samples

## bits_provider is a seam for tests, like the keyboard's: in headless a real
## key poll always yields zero, and there is no other way to feed a scripted
## sequence of presses.
func _init(link: Link, local_index: int, bits_provider := Callable(),
		input_delay := Lockstep.DELAY) -> void:
	_link = link
	_lockstep = Lockstep.new(local_index, input_delay)
	_bits_provider = bits_provider
	_link.packet_received.connect(handle_packet)

func pump() -> void:
	_link.poll()

## Push out what was captured this frame. `WebSocketPeer.send()` only queues a
## packet; `poll()` is what writes the queue. Without this a press would sit
## until the next frame — eight to sixteen milliseconds each way out of a budget
## of eighty-three.
func flush() -> void:
	_link.poll()

func capture(now: int) -> void:
	var bits: int = _bits_provider.call(now) if _bits_provider.is_valid() \
		else Keyboard.bits(0) | Gamepad.bits(0)
	var applied := _lockstep.applied_tick(now)
	if applied <= _sent_through:
		return
	_sent_through = applied
	_lockstep.submit_local(applied, bits)
	_link.send(Protocol.pack_input(applied, bits))

## The current input delay in ticks.
func delay() -> int:
	return _lockstep.delay

## Take on more travel allowance, up to `target` ticks, from tick `now`.
##
## The band between the old horizon and the new one is the dangerous part: our
## input for those ticks will no longer be submitted in the ordinary course,
## while the partner waits for it. Leave the band unfilled and the result is not
## stutter but a game frozen for good.
func raise_to(target: int, now: int) -> void:
	var was := _lockstep.delay
	target = mini(target, MAX_DELAY)
	if target <= was:
		return
	_lockstep.delay = target
	var bits: int = _bits_provider.call(now) if _bits_provider.is_valid() else 0
	for tick in range(now + was, now + target + 1):
		if tick <= _sent_through:
			continue
		_sent_through = tick
		_lockstep.submit_local(tick, bits)
		_link.send(Protocol.pack_input(tick, bits))

## Let the delay come back down. Stuck at the ceiling it makes the controls
## mushy forever — which is exactly what a person calls "it lags even more".
## Lowering is safe: the ticks between the old and the new horizon have already
## been submitted, so there is no gap; at most a couple of ticks keep the
## previous input.
func ease_delay() -> void:
	_lockstep.delay = maxi(Lockstep.DELAY, _lockstep.delay - 1)

func can_advance(tick: int) -> bool:
	if desynced:
		return false
	var ready := _lockstep.can_advance(tick)
	var now := _clock()
	_window.sample(_lockstep.cover(tick), now)
	if ready:
		if tick == _waiting_tick:
			_end_wait(now - _wait_began)
		_stall_run = 0
		_waiting_tick = -1
		return true
	_stall_run += 1
	if tick != _waiting_tick:
		_waiting_tick = tick
		_wait_began = now
	return false

## A wait that ended. One shorter than a tick is no stutter at all: at 144 Hz the
## tick is asked for sooner and waits a few milliseconds it would have waited
## anyway before being drawn. One longer than FROZEN_MS is somebody's frame loop
## standing still.
func _end_wait(ms: int) -> void:
	if ms < 1000 / 60 or ms > FROZEN_MS:
		return
	_window.waited += 1
	_window.waited_ms += ms
	_window.note(ms)

## The link is fine and the partner is simply not sending. That happens when they
## switch away from the browser tab: the browser stops driving the frame loop, so
## their game neither computes ticks nor sends input, while the socket stays open.
## Indistinguishable from a stalled machine, and the same on screen either way —
## which is the point: the human is told the partner is missing, not why.
func waiting_for_partner() -> bool:
	return _stall_run >= STALL_BEFORE_SAYING

## Asked of the link rather than tracked here: subscribing to its signals would
## hand the link a callable holding this object while this object holds the
## link, and a reference cycle between two RefCounted is never collected.
func partner_present() -> bool:
	return _link.partner_present()

## No link — the game waits. The game screen shows this to the human: a frozen
## screen with no explanation looks like a hang.
func linked() -> bool:
	return _link.linked()

func dead() -> bool:
	return _link.dead()

func inputs_for(tick: int) -> Array[int]:
	return _lockstep.inputs_for(tick)

func after_tick(tick: int, world_hash: int) -> void:
	_advanced += 1
	_last_tick = tick
	if _advanced % WINDOW == 0:
		_close_window()
	_lockstep.record_local_hash(tick, world_hash)
	if tick % HASH_EVERY == 0:
		_link.send(Protocol.pack_hash(tick, world_hash))
	_lockstep.forget_before(tick - Lockstep.KEEP)

## A second of play is over: decide the delay, and every fifth time say how the
## game is going.
func _close_window() -> void:
	# There is one measure of lag: how much real time these ticks took. Sixty
	# ticks must take a second. If they took three, the game runs three times
	# slower than the clock, and that is what "lagging" means.
	var elapsed := maxi(1, _clock() - _window.began)
	var expected := WINDOW * 1000 / 60
	_adapt(expected)
	last_report = "SPD %d%% WAIT %d DLY %d COV %d" % [
		expected * 100 / elapsed, _window.waited, _lockstep.delay, _window.cover_min]
	_report.absorb(_window)
	_window = Tally.new()
	if _advanced % REPORT_EVERY == 0:
		_print_report()
		_report = Tally.new()

## The network cannot keep up — take on more slack, by as much as it lacked.
## Control responsiveness suffers, but stutter suffers more: a frozen frame is
## visible, while another fifty milliseconds before a shot is barely noticeable.
##
## Two estimates of the shortfall, both for the two delays together. When the
## circle is steadily longer than they cover, many ticks wait a little, and the
## share of the second spent waiting is the share the delays fall short by. When
## the circle is covered on average and jitter is what hurts, a wait is itself
## the shortfall. Both sides sit in the same circle and grow in the same second,
## so each takes half.
##
## Both leave out the longest wait: one wait is a hitch, and what the network
## lacks is what repeats. Judged by the longest, a partner's single slow frame
## put six ticks on the delay.
func _adapt(expected: int) -> void:
	var delay := _lockstep.delay
	if _window.waited > STALLS_TOLERATED:
		var behind := 2 * delay * (_window.waited_ms - _window.longest_ms) / expected
		var burst := (_window.second_ms * 60 + 999) / 1000
		var step := clampi((maxi(behind, burst) + 1) / 2, 1, MAX_STEP)
		if delay < MAX_DELAY:
			raise_to(delay + step, _last_tick)
			print("[net] many waits — input delay raised to %d ticks (%d ms)" % [
				_lockstep.delay, _lockstep.delay * 1000 / 60])
	elif _window.waited == 0 and delay > Lockstep.DELAY and _partner_slack() > SPARE:
		# The network has calmed down: give the responsiveness back, one tick a
		# second.
		ease_delay()

## How much of our input the partner has to rest on — the thing lowering our
## delay takes away. They cannot tell us, so it is reckoned from what we can see:
## our own slack is their delay less the way here, theirs is our delay less the
## way there. The two ways are the same road, so theirs is ours plus the
## difference in delays.
##
## Judging by our own slack alone was the old rule, and it split the delays
## apart: the side with the smaller delay has the bigger slack, because its slack
## is the partner's delay, so it came down first and kept coming down while the
## other side waited and climbed — five against sixteen, for the rest of the
## match.
func _partner_slack() -> int:
	return _window.cover_min + _lockstep.delay - _partner_delay

## A line about how the game is going. It goes to standard output: a terminal on
## desktop, the developer console in a browser. Without it a complaint of "it
## lags" cannot be checked against anything.
##
## What to read: `slack` is how many ticks the other side's input runs ahead of
## ours. While it stays near the input delay, the game runs off the clock.
## Sagging to zero means every tick waits for a packet, and the network is at
## fault rather than the game.
func _print_report() -> void:
	var elapsed := maxi(1, _clock() - _report.began)
	var expected := REPORT_EVERY * 1000 / 60
	print("[net] %d ticks in %d ms (norm %d), speed %d%%, waits %d (longest %d ms), slack: worst %d, average %d, delay %d" % [
		REPORT_EVERY, elapsed, expected, expected * 100 / elapsed,
		_report.waited, _report.longest_ms, _report.cover_min,
		_report.cover_sum / maxi(1, _report.samples), _lockstep.delay])

func _clock() -> int:
	return Time.get_ticks_msec()

## Public so that tests can feed a packet without standing a socket up.
func handle_packet(data: PackedByteArray) -> void:
	var packet := Protocol.unpack(data)
	match packet.get("kind", Protocol.Kind.INVALID):
		Protocol.Kind.INPUT:
			if packet["tick"] > _last_tick + FARTHEST_AHEAD:
				return
			_lockstep.submit_remote(packet["tick"], packet["bits"])
		Protocol.Kind.HASH:
			# The partner sends the input for `tick + their delay` just before
			# computing `tick`, and the hash of `tick` just after, over the same
			# ordered stream. So when the hash arrives, the input furthest ahead
			# is exactly their delay beyond it — known without a packet of its
			# own.
			_partner_delay = clampi(_lockstep.cover(packet["tick"]),
				Lockstep.DELAY, MAX_DELAY)
			# Carrying on quietly is not an option: from here the worlds diverge
			# further and further, and the players cannot tell why they see
			# different things.
			if not _lockstep.check_remote_hash(packet["tick"], packet["hash"]):
				desynced = true
				desync_tick = packet["tick"]
