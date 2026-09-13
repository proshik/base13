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

## How far the input delay may grow, and in what steps.
##
## It grows rather than being a fixed number, because the value needed depends on
## the network and not on the game: on an even link five ticks suffice and the
## controls stay responsive, while on a jittery Wi-Fi every late packet is a
## frozen frame. Sixteen ticks is 266 ms: beyond that the game turns into
## correspondence, and it is more honest to stop at the ceiling.
const MAX_DELAY := 16
const DELAY_STEP := 3
## How many ticks in a row may go uncomputed before the screen says so. A tick is
## 1/60 s, so this is about a second: any less and the caption would blink on and
## off with ordinary jitter, which is worse than no caption at all.
const STALL_BEFORE_SAYING := 60

## How many waits within a report window justify taking on more slack. Isolated
## late packets are unavoidable and not worth growing for.
const STALLS_BEFORE_GROWING := 30

## How far ahead of our last computed tick the partner's input may be. An honest
## partner is never further than both input delays together: they cannot compute
## a tick without our input for it, and ours runs at most MAX_DELAY ahead.
## Lockstep.KEEP bounds the buffer's past; the same number bounds its future.
## Without it a packet for tick two billion sits in the buffer for good, and a
## stream of them stalls the game: forget_before walks every key on every tick.
const FARTHEST_AHEAD := Lockstep.KEEP

var desynced := false
var desync_tick := -1

## Counters for the report. Without them "it lags" stays a word: the line shows
## whether the game falls behind the clock and whose fault that is — its own or
## the network's.
var _advanced := 0
var _stalls := 0
var _stall_run := 0
var _worst_stall := 0
var _cover_min := 0
var _cover_sum := 0
var _samples := 0
var _window_began := 0
var _last_tick := 0
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

## Take on more travel allowance.
##
## The band between the old horizon and the new one is the dangerous part: our
## input for those ticks will no longer be submitted in the ordinary course,
## while the partner waits for it. Leave the band unfilled and the result is not
## stutter but a game frozen for good.
func grow_delay(now: int) -> void:
	var was := _lockstep.delay
	if was >= MAX_DELAY:
		return
	_lockstep.delay = mini(was + DELAY_STEP, MAX_DELAY)
	var bits: int = _bits_provider.call(now) if _bits_provider.is_valid() else 0
	for tick in range(now + was, now + _lockstep.delay + 1):
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
	var cover := _lockstep.cover(tick)
	if _samples == 0:
		_cover_min = cover
		_window_began = _clock()
	_cover_sum += cover
	_samples += 1
	_cover_min = mini(_cover_min, cover)
	if ready:
		_stall_run = 0
	else:
		_stalls += 1
		_stall_run += 1
		_worst_stall = maxi(_worst_stall, _stall_run)
	return ready

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
	_report(tick)
	_lockstep.record_local_hash(tick, world_hash)
	if tick % HASH_EVERY == 0:
		_link.send(Protocol.pack_hash(tick, world_hash))
	_lockstep.forget_before(tick - Lockstep.KEEP)

## A line about how the game is going. It goes to standard output: a terminal on
## desktop, the developer console in a browser. Without it a complaint of "it
## lags" cannot be checked against anything.
##
## What to read: `slack` is how many ticks the other side's input runs ahead of
## ours. While it stays near the input delay, the game runs off the clock.
## Sagging to zero means every tick waits for a packet, and the network is at
## fault rather than the game.
func _report(_tick: int) -> void:
	if _advanced % REPORT_EVERY != 0:
		return
	# There is one measure: how much real time these ticks took. Three hundred
	# ticks must take five seconds. If they took fifteen, the game runs three
	# times slower than the clock, and that is what "lagging" means.
	var elapsed := maxi(1, _clock() - _window_began)
	var expected := REPORT_EVERY * 1000 / 60
	print("[net] %d ticks in %d ms (norm %d), speed %d%%, waits %d (up to %d in a row), slack: worst %d, average %d" % [
		REPORT_EVERY, elapsed, expected, expected * 100 / elapsed,
		_stalls, _worst_stall, _cover_min, _cover_sum / maxi(1, _samples)])
	# The network cannot keep up — take on more slack. Control responsiveness
	# suffers, but stutter suffers more: a frozen frame is visible, while another
	# fifty milliseconds before a shot is barely noticeable.
	if _stalls >= STALLS_BEFORE_GROWING and _lockstep.delay < MAX_DELAY:
		grow_delay(_last_tick)
		print("[net] many waits — input delay raised to %d ticks (%d ms)" % [
			_lockstep.delay, _lockstep.delay * 1000 / 60])
	elif _stalls == 0 and _cover_min > 1 and _lockstep.delay > Lockstep.DELAY:
		# The network has calmed down: give the responsiveness back. One tick per
		# window — the descent is slower than the climb, so we do not start
		# another round trip of growing.
		ease_delay()
	last_report = "SPD %d%% WAIT %d DLY %d COV %d" % [
		expected * 100 / elapsed, _stalls, _lockstep.delay, _cover_min]
	_stalls = 0
	_worst_stall = 0
	_cover_sum = 0
	_samples = 0
	_advanced = 0

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
			# Carrying on quietly is not an option: from here the worlds diverge
			# further and further, and the players cannot tell why they see
			# different things.
			if not _lockstep.check_remote_hash(packet["tick"], packet["hash"]):
				desynced = true
				desync_tick = packet["tick"]
