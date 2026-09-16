class_name LegacyNetInput
extends InputSource

## The client of 0.5.0, copied from commit ac65b52 with its classes renamed. Kept
## only so test_old_client.gd can seat a player who never updated. Never edit it to
## match the game: it is the other side, as it was.

## Input in a network game: our press goes to the partner and into the buffer,
## theirs arrives from the socket. A tick is computed only once both are present
## — LegacyLockstep is responsible for that.
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
## Where the first level of a match through the relay starts. Five a side covers a
## circle of about 130 ms and a path to the relay in Moscow and back is nearer
## 230, which eight a side covers; on a faster path the delay comes back down to
## five within three calm seconds.
const RELAY_START := 8
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
## How long a tick may stand on a live link before our recent input goes out
## again, and how often after that. See `_send_again`.
const RESEND_MS := 1000

## How far ahead of our last computed tick the partner's input may be. An honest
## partner is never further than both input delays together: they cannot compute
## a tick without our input for it, and ours runs at most MAX_DELAY ahead.
## LegacyLockstep.KEEP bounds the buffer's past; the same number bounds its future.
## Without it a packet for tick two billion sits in the buffer for good, and a
## stream of them stalls the game: forget_before walks every key on every tick.
const FARTHEST_AHEAD := LegacyLockstep.KEEP

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
var _resent_at := 0
## The partner's input delay, as their own packets reveal it: see handle_packet.
var _partner_delay := LegacyLockstep.DELAY
var _window := Tally.new()
var _report := Tally.new()
## The last tick whose input has already been sent. While a tick waits for the
## other side's packet, `capture` is called every frame, and without this mark
## the same packet would go out again and again: waiting would breed traffic, and
## traffic would breed more waiting.
var _sent_through := -1
## Whether the link was up at the last pump: coming back is what sends our recent
## input again.
var _was_linked := false

## The last report in a form the game's font can draw: digits and capital Latin
## letters only, nothing else is in the atlas. It exists so the numbers can be
## seen on screen instead of being dug out of a console on another machine.
var last_report := ""

var _link: Link
var _lockstep: LegacyLockstep
var _bits_provider: Callable
var _fps_provider: Callable

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
##
## `input_delay` carries the delay a previous level found. It is taken on by
## growing to it before the first tick, never by starting there. Both sides
## always fill in exactly `LegacyLockstep.DELAY` ticks of both players' input, and no
## delay ever goes below that; every later tick comes over the wire on both
## sides, whatever the two delays are. Starting one side at eleven instead left
## the other waiting for tick five from a partner who had never meant to send it,
## while that partner waited for its tick eleven — frozen for good, both of them
## present.
##
## fps_provider is the same kind of seam for the frame rate the report carries:
## the engine's own figure depends on the machine running the test.
func _init(link: Link, local_index: int, bits_provider := Callable(),
		input_delay := LegacyLockstep.DELAY, fps_provider := Callable()) -> void:
	_link = link
	_lockstep = LegacyLockstep.new(local_index)
	_bits_provider = bits_provider
	_fps_provider = fps_provider
	_link.packet_received.connect(handle_packet)
	# Taken from the link rather than assumed: a level can be built while the
	# relay is still greeting after a drop, and the band below would go nowhere.
	# The welcome then comes in with the first pump, and only a link seen down
	# first counts as coming back.
	_was_linked = _link.linked()
	# Nobody presses anything before the first tick, the same as in the ticks
	# both sides fill in.
	_raise(input_delay, 0, 0)

## The delay a level starts with: where the last one ended, or for the first
## level, what its link needs.
static func starting_delay(link: Link, carried := 0) -> int:
	if carried > 0:
		return clampi(carried, LegacyLockstep.DELAY, MAX_DELAY)
	return RELAY_START if link is Relay else LegacyLockstep.DELAY

func pump() -> void:
	_link.poll()
	var linked := _link.linked()
	if linked and not _was_linked:
		_send_again()
	_was_linked = linked

## The link is back after a drop. While it was down the game went on for a while
## on what the partner had already sent, and our input for those ticks went
## nowhere: the relay journals only what reached it, and what it replays to a
## returning side is the partner's stream, never their own. Nor is a packet
## handed to a socket that was already dying any safer. So our recent input goes
## out again, and the partner, who ignores what it already has, takes what it
## lacks.
##
## From a whole delay back rather than from our last tick: the partner needed our
## input to compute each tick, and theirs for our tick arrived when they were a
## delay behind it. They may be that far back and still need it.
##
## The same goes out once a second while a tick stands on a live link, because a
## link can lose input without ever going down: the partner, still finishing the
## last level behind a hidden tab, takes our new level's first input into their
## old one, and their new level waits for it for good. A few dozen six-byte
## packets a second of standing is not waiting breeding traffic.
func _send_again() -> void:
	for tick in range(maxi(LegacyLockstep.DELAY, _last_tick - MAX_DELAY), _sent_through + 1):
		_link.send(Protocol.pack_input(tick, _lockstep.local_input(tick)))

## Push out what was captured this frame. `WebSocketPeer.send()` only queues a
## packet; `poll()` is what writes the queue. Without this a press would sit
## until the next frame — eight to sixteen milliseconds each way out of a budget
## of eighty-three.
func flush() -> void:
	_link.poll()

func capture(now: int) -> void:
	var bits := _read_bits(now)
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
##
## The band carries the keys held right now. It used to go out as zero wherever
## no test seam fed the presses — in the game, that is — so a tank driven forward
## let go for a moment every time the delay grew.
func raise_to(target: int, now: int) -> void:
	_raise(target, now, _read_bits(now))

func _raise(target: int, now: int, bits: int) -> void:
	var was := _lockstep.delay
	target = mini(target, MAX_DELAY)
	if target <= was:
		return
	_lockstep.delay = target
	for tick in range(now + was, now + target + 1):
		if tick <= _sent_through:
			continue
		_sent_through = tick
		_lockstep.submit_local(tick, bits)
		_link.send(Protocol.pack_input(tick, bits))

## The keys held at tick `now`: the test seam if there is one, the keyboard and
## the gamepad otherwise.
func _read_bits(now: int) -> int:
	if _bits_provider.is_valid():
		return _bits_provider.call(now)
	return Keyboard.bits(0) | Gamepad.bits(0)

## Let the delay come back down. Stuck at the ceiling it makes the controls
## mushy forever — which is exactly what a person calls "it lags even more".
## Lowering is safe: the ticks between the old and the new horizon have already
## been submitted, so there is no gap; at most a couple of ticks keep the
## previous input.
func ease_delay() -> void:
	_lockstep.delay = maxi(LegacyLockstep.DELAY, _lockstep.delay - 1)

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
	elif now - _wait_began >= RESEND_MS and now - _resent_at >= RESEND_MS \
			and _link.linked():
		_resent_at = now
		_send_again()
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

## Asked of the link rather than tracked here: the link already knows, and a copy
## kept in step through its signals would be one more thing to go stale. A
## subscription would not keep this object alive, though — a method's callable
## does not hold its object (`test_net_input.gd` checks it); a lambda capturing
## `self` would.
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
	_lockstep.forget_before(tick - LegacyLockstep.KEEP)

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
	elif _window.waited == 0 and delay > LegacyLockstep.DELAY and _partner_slack() > SPARE:
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
##
## The same figures go to the link, which passes them to a relay that takes
## reports: the server can see the network, but only this side sees a machine
## that cannot keep up. They go here, once a line, and not with every second's
## window: the server hears a connection about once in four seconds and would
## turn most of a report a second away.
func _print_report() -> void:
	var elapsed := maxi(1, _clock() - _report.began)
	var expected := REPORT_EVERY * 1000 / 60
	var speed := expected * 100 / elapsed
	print("[net] %d ticks in %d ms (norm %d), speed %d%%, waits %d (longest %d ms), slack: worst %d, average %d, delay %d" % [
		REPORT_EVERY, elapsed, expected, speed,
		_report.waited, _report.longest_ms, _report.cover_min,
		_report.cover_sum / maxi(1, _report.samples), _lockstep.delay])
	_link.report_pace({"speed": speed, "waits": _report.waited,
		"delay": _lockstep.delay, "fps": _fps()})

## Frames drawn a second, whole. The engine measures a float, and a display at
## 59.94 Hz would make the server throw the whole report away as malformed.
func _fps() -> int:
	var fps: float = _fps_provider.call() if _fps_provider.is_valid() \
		else Engine.get_frames_per_second()
	return int(round(fps))

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
				LegacyLockstep.DELAY, MAX_DELAY)
			# Carrying on quietly is not an option: from here the worlds diverge
			# further and further, and the players cannot tell why they see
			# different things.
			if not _lockstep.check_remote_hash(packet["tick"], packet["hash"]):
				# Told once: every later hash from the partner mismatches too,
				# and the server counts a second word of it as out of turn.
				var first := not desynced
				desynced = true
				desync_tick = packet["tick"]
				if first:
					_link.report_desync()
