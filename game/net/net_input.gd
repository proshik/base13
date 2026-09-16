class_name NetInput
extends InputSource

## Input in a network game: our press goes to the partner and into the buffer,
## theirs arrives from the socket and until then is guessed. Rollback lays both out
## by tick and says when a guess was wrong; NetMatch computes the ticks.
##
## Each player sits at their own machine, so both sides play with player one's key
## layout: everyone's own tank is "the first" to them, while who they are in the
## world is decided by the slot number, identical on both sides.

const HASH_EVERY := 60   ## compare once a second
## How often to report on how the game is going. Once every five seconds: less
## often misses a short dip, more often buries the console.
const REPORT_EVERY := 300
## How many frames in a row may stand before the screen says so: about a second.
## Any less and the caption would blink with ordinary jitter.
const STALL_BEFORE_SAYING := 60
## A stop this long is a frame loop that stood still — the partner's hidden tab, a
## dropped link — and not a network falling short. It is shown on the `[net]` line
## as `frozen` but not sent to the server as a wait, where it would turn a partner
## looking at another tab into a slow network. 0.5.0 drew the line at the same
## place, so both builds report the same stand the same way.
const FROZEN_MS := 150
## How long a tick may stand on a live link before our recent input goes out again,
## and how often after that. See `_send_again`.
const RESEND_MS := 1000
## How far back our input goes out again. The partner can be a whole window behind
## their own confirmed tick, and their confirmed tick behind ours by as much again.
const RESEND_BACK := 2 * Rollback.MAX_ROLLBACK
## How far ahead of our last computed tick the partner's packets may be. An honest
## partner is never further than a window and a delay; anything past this sits in a
## buffer for good, and a stream of it grows the buffer until the game stalls.
const FARTHEST_AHEAD := Rollback.KEEP
## How often, in computed ticks, the partner hears how far ahead of them we run.
const PACE_EVERY := 10
## How much further ahead of the partner than they are of us we may run before a
## tick is let go. Less, and ordinary jitter would make us skip.
const LEAD_TOLERATED := 2
## The fewest ticks between two let go: one in twenty cannot be seen.
const SKIP_SPACING := 20
## After a stand past FROZEN_MS, the most ticks let go one after another to fall
## back into step. A stand leaves a window's lead at most; twice that bounds a lead
## misread, which would otherwise hold the game still for good.
const RECOVERY_LIMIT := 2 * Rollback.MAX_ROLLBACK
## How many readings of the calm lead to keep. Three spans are half a second.
const CALM_READINGS := 3

var desynced := false
var desync_tick := -1

## The running figures in a form the game's font can draw: digits and capital
## Latin letters, nothing else is in the atlas — not even a minus or a percent.
var last_report := ""

var _link: Link
var _rollback: Rollback
var _bits_provider: Callable
var _fps_provider: Callable
## The last tick whose input has been sent. `capture` is called every frame a tick
## stands, and without this the same packet would go out again and again.
var _sent_through := Rollback.START - 1
var _was_linked := false
var _last_tick := 0
var _stall_run := 0
## The tick standing right now and when it began to. A stop is counted once per
## tick, not per frame: at 144 Hz one stop is six frames.
var _waiting_tick := -1
var _wait_began := 0
var _resent_at := 0
var _partner_lead := 0
var _knows_partner_lead := false
var _last_skip := -SKIP_SPACING
## Our lead while the partner kept pace, which carries the way here: what "in
## step" reads as on this path. See `_note_calm_lead`.
var _calm_lead := 0
var _knows_calm_lead := false
var _calm_samples: Array[int] = []
var _calm_edge := -1
## Set when a stand past FROZEN_MS ends, until the lead it left is shed.
var _recovering := false
var _recovery_skips := 0
var _report := Tally.new()

## What a stretch of play looked like.
class Tally:
	var began := -1
	var ticks := 0
	var stops := 0
	var longest_ms := 0
	var frozen := 0
	var frozen_longest_ms := 0
	var rollbacks := 0
	var deepest := 0
	var resim_us := 0
	var skips := 0

## bits_provider is a seam for tests, like the keyboard's: in headless a real key
## poll always yields zero. fps_provider is the same for the frame rate the report
## carries.
func _init(link: Link, local_index: int, bits_provider := Callable(),
		fps_provider := Callable()) -> void:
	_link = link
	_rollback = Rollback.new(local_index)
	_bits_provider = bits_provider
	_fps_provider = fps_provider
	_link.packet_received.connect(handle_packet)
	# Taken from the link rather than assumed: a level can be built while the relay
	# is still greeting after a drop, and only a link seen down counts as coming
	# back.
	_was_linked = _link.linked()

func pump() -> void:
	_link.poll()
	var linked := _link.linked()
	if linked and not _was_linked:
		_send_again()
	_was_linked = linked

## Our recent input, out again. After a drop: the relay journals only what reached
## it and replays to a returning side the partner's stream, never their own. And
## once a second while a tick stands on a live link: a partner still finishing the
## last level behind a hidden tab takes our new level's first input into their old
## one. Duplicates are ignored on the other side.
func _send_again() -> void:
	for tick in range(maxi(Rollback.START, _last_tick - RESEND_BACK), _sent_through + 1):
		_link.send(Protocol.pack_input(tick, _rollback.local_input(tick)))

## `WebSocketPeer.send()` only queues; `poll()` writes. Without this a press would
## sit until the next frame.
func flush() -> void:
	_link.poll()

func capture(now: int) -> void:
	var applied := now + Rollback.INPUT_DELAY
	if applied <= _sent_through:
		return
	var bits := _read_bits(now)
	_sent_through = applied
	_rollback.submit_local(applied, bits)
	_link.send(Protocol.pack_input(applied, bits))

func _read_bits(now: int) -> int:
	if _bits_provider.is_valid():
		return _bits_provider.call(now)
	return Keyboard.bits(0) | Gamepad.bits(0)

func can_predict(tick: int) -> bool:
	if desynced:
		return false
	var now := _clock()
	if _report.began < 0:
		_report.began = now
	if _rollback.can_predict(tick):
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

## A stop shorter than a tick is no stop: at 144 Hz the tick was asked for early.
## One longer than FROZEN_MS is a stand, counted apart.
func _end_wait(ms: int) -> void:
	if ms < 1000 / 60:
		return
	if ms > FROZEN_MS:
		_report.frozen += 1
		_report.frozen_longest_ms = maxi(_report.frozen_longest_ms, ms)
		# This side went on guessing for a whole window before it stood, and the
		# partner is back from where they stopped: a window behind. The lead is
		# shed now, while the picture is still, rather than a tick in twenty over
		# the next seconds.
		_recovering = _knows_calm_lead
		_recovery_skips = 0
		return
	_report.stops += 1
	_report.longest_ms = maxi(_report.longest_ms, ms)

## The link is fine and the partner is simply not sending — a hidden tab, a
## stalled machine. The human is told the partner is missing, not why.
func waiting_for_partner() -> bool:
	return _stall_run >= STALL_BEFORE_SAYING

## Asked of the link rather than tracked here: a method's callable does not hold
## its object, a lambda capturing `self` would.
func partner_present() -> bool:
	return _link.partner_present()

func linked() -> bool:
	return _link.linked()

func dead() -> bool:
	return _link.dead()

func inputs_for(tick: int) -> Array[int]:
	return _rollback.inputs_for(tick)

func confirmed() -> int:
	return _rollback.confirmed()

func rollback_from() -> int:
	return _rollback.rollback_from()

func clear_rollback() -> void:
	_rollback.clear_rollback()

func wants_hash(tick: int) -> bool:
	return tick % HASH_EVERY == 0

func after_confirmed(tick: int, world_hash: int) -> void:
	_link.send(Protocol.pack_hash(tick, world_hash))
	if not _rollback.record_hash(tick, world_hash):
		_desync(tick)

func note_tick(tick: int) -> void:
	_last_tick = tick
	_report.ticks += 1
	if tick % PACE_EVERY == 0 and _partner_heard():
		_link.send(Protocol.pack_pace(tick, _lead()))
		_note_calm_lead()
	_rollback.forget_before(tick - Rollback.KEEP)
	if _report.ticks % 60 == 0:
		last_report = _overlay_line()
	if _report.ticks % REPORT_EVERY == 0:
		_print_report()
		_report = Tally.new()
		_report.began = _clock()

func note_rollback(depth: int, usec: int) -> void:
	_report.rollbacks += 1
	_report.deepest = maxi(_report.deepest, depth)
	_report.resim_us += usec

## How far ahead of the partner we run: our tick less theirs as their input shows
## it. Their latest input is for their tick plus the delay and took the way here to
## arrive, so this reads high by the way here — on both sides alike, which is why
## the two leads are held against each other and not against zero.
func _lead() -> int:
	return _last_tick - (_rollback.remote_edge() - Rollback.INPUT_DELAY)

func _partner_heard() -> bool:
	return _rollback.remote_edge() >= Rollback.START

## Our lead, taken only while the partner keeps pace: their input moved on nearly a
## whole span since the last look. A partner going quiet sends their last packets
## in a trickle, and a lead read then would count the silence as the path.
##
## The least of the last few readings, not the last one: a late packet only ever
## makes the lead read high, so the lowest reading is the one nearest to in step.
## A single reading on a local network came out three where in step is one, and
## the game stopped shedding with four ticks still to go.
func _note_calm_lead() -> void:
	var edge := _rollback.remote_edge()
	if _calm_edge >= 0 and edge - _calm_edge >= PACE_EVERY - LEAD_TOLERATED:
		_calm_samples.append(_lead())
		if _calm_samples.size() > CALM_READINGS:
			_calm_samples.remove_at(0)
		_calm_lead = _calm_samples.min()
		_knows_calm_lead = true
	_calm_edge = edge

func should_skip(tick: int) -> bool:
	if not _partner_heard():
		return false
	if _recovering:
		# Judged by our own lead against our own calm one, not against the
		# partner's word: that is from before the stand, and up to a span stale.
		# Down to a tick ahead — the rule below holds two leads apart by
		# LEAD_TOLERATED, which is a tick each; stopping short of that left the
		# rest to be shed one tick in twenty after all.
		if _lead() > _calm_lead + LEAD_TOLERATED / 2 and _recovery_skips < RECOVERY_LIMIT:
			_recovery_skips += 1
			_report.skips += 1
			return true
		_recovering = false
		# The spaced rule below waits a span, for the partner's word to be fresh.
		_last_skip = tick
		return false
	if not _knows_partner_lead:
		return false
	if tick - _last_skip < SKIP_SPACING:
		return false
	if _lead() - _partner_lead <= LEAD_TOLERATED:
		return false
	_last_skip = tick
	_report.skips += 1
	return true

func _desync(tick: int) -> void:
	if desynced:
		return
	desynced = true
	desync_tick = tick
	_link.report_desync()

## What to read: `stops` are times the game stood past the window for a moment —
## the path is longer than 200 ms; `frozen` are stands longer than FROZEN_MS — the
## partner went quiet. `rollbacks` and `deepest` say how often
## and how far guesses were wrong; `resim` is the time that cost this machine. Speed
## below 100 with no stops and a large resim means the machine, not the network.
func _print_report() -> void:
	var elapsed := maxi(1, _clock() - _report.began)
	var expected := REPORT_EVERY * 1000 / 60
	var speed := expected * 100 / elapsed
	print("[net] %d ticks in %d ms (norm %d), speed %d%%, stops %d (longest %d ms), frozen %d (longest %d ms), rollbacks %d (deepest %d), resim %d ms, skips %d, lead %d against %d" % [
		REPORT_EVERY, elapsed, expected, speed, _report.stops, _report.longest_ms,
		_report.frozen, _report.frozen_longest_ms, _report.rollbacks, _report.deepest, _report.resim_us / 1000, _report.skips,
		_lead() if _partner_heard() else 0, _partner_lead])
	_link.report_pace({"speed": speed, "waits": _report.stops,
		"delay": Rollback.INPUT_DELAY, "fps": _fps()})

func _overlay_line() -> String:
	var elapsed := maxi(1, _clock() - _report.began)
	var lead := _lead() if _partner_heard() else 0
	return "SPD %d STOP %d FRZ %d RB %d DEEP %d RESIM %d %s %d" % [
		_report.ticks * 100000 / 60 / elapsed, _report.stops, _report.frozen, _report.rollbacks,
		_report.deepest, _report.resim_us / 1000, "LEAD" if lead >= 0 else "BACK", absi(lead)]

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
			_rollback.submit_remote(packet["tick"], packet["bits"])
		Protocol.Kind.HASH:
			# A waiting hash is kept until our tick is confirmed; one from the far
			# future would be kept for good.
			if packet["tick"] > _last_tick + FARTHEST_AHEAD:
				return
			if not _rollback.submit_remote_hash(packet["tick"], packet["hash"]):
				_desync(packet["tick"])
		Protocol.Kind.PACE:
			_partner_lead = clampi(packet["lead"], -FARTHEST_AHEAD, FARTHEST_AHEAD)
			_knows_partner_lead = true
