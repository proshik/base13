extends GutTest

## Two sides play through a link with the internet's delays, frame by frame, on a
## clock the test turns by hand. Everything below the screen is the production
## code; the frame loop is `game.gd`'s, step for step.
##
## A lockstep tick needs the partner's input, and that input left the partner
## when they computed an earlier tick, which needed ours. So the two input delays
## together must cover the whole circle, A to relay to B and back:
## `(D_A + D_B) × 16.7 ms ≥ circle + two frames`. A path to Moscow and back is
## four legs of about sixty milliseconds, and the starting 5 + 5 covers a circle
## of about 130.

const SEED := 13
const SECONDS := 30
const FRAME_US := 16667
## How long the delay is given to find its value. Past this, a waiting tick is
## stutter a human sees.
const SETTLE_SECONDS := 3
const WAITS_PER_SECOND := 1
## Until the delay adapts within a second, these profiles stutter: 60 ± 20 waits
## on 25–30 ticks a second for twelve seconds while the delay creeps 5 → 8 → 11,
## 120 ± 40 waits all thirty, and after a partner's tab switch the side that
## came back waits on every tick for good.
const ADAPTS := false

class ClockedInput extends NetInput:
	var clock: LaggyLink.Clock
	func _clock() -> int:
		return clock.ms()

## One side of the match: the production input, the core and the frame loop of
## the game screen.
class Peer:
	var input: ClockedInput
	var sim: GameSim
	var pump := TickPump.new()
	var hashes: Array[int] = []
	## When each tick that had to wait first waited. A tick waiting over several
	## frames is one stutter, not several.
	var waits: Array[int] = []
	## The input delay at the end of every second.
	var delays: Array[int] = []
	var skipped := 0.0
	var _clock: LaggyLink.Clock
	var _last_waited := -1
	var _caption := false

	func _init(link: LaggyLink, slot: int, clock: LaggyLink.Clock, frames: Array) -> void:
		_clock = clock
		input = ClockedInput.new(link, slot, func(t: int) -> int: return frames[t][slot])
		input.clock = clock
		sim = GameSim.new(Golden.level(), Golden.SEED, SimConfig.new(),
			Golden.LEVEL_NUMBER, 2)

	## `game.gd` `_advance`, in the same order: `_sent_through` depends on it.
	func frame(delta: float) -> void:
		input.pump()
		var due := pump.due(delta)
		var ran := 0
		for i in due:
			var t: int = sim.get_state().tick
			input.capture(t)
			if not input.can_advance(t):
				if t != _last_waited:
					_last_waited = t
					waits.append(_clock.ms())
				break
			ran += 1
			sim.tick(input.inputs_for(t))
			var h := sim.state_hash()
			input.after_tick(t, h)
			hashes.append(h)
			sim.drain_events()
		pump.spend(ran)
		input.flush()
		# `game.gd` `_show_status`: the debt is dropped when the caption goes.
		var caption := input.waiting_for_partner()
		if _caption and not caption:
			pump.reset()
		_caption = caption

	func waits_in_second(second: int) -> int:
		var count := 0
		for ms in waits:
			if ms / 1000 == second:
				count += 1
		return count

## One leg is `leg_ms ± jitter_ms`. Side 1 may go silent for a while, the way a
## browser tab stops its frame loop when the player switches away: no frames,
## and on return a single frame carrying all the time that passed.
func _play(leg_ms: int, jitter_ms: int, silent_from_ms := -1, silent_ms := 0) -> Array[Peer]:
	var clock := LaggyLink.Clock.new()
	var links := LaggyLink.pair(clock, leg_ms, jitter_ms, SEED)
	var frames := Golden.frames()
	var peers: Array[Peer] = [Peer.new(links[0], 0, clock, frames),
		Peer.new(links[1], 1, clock, frames)]
	var delta := FRAME_US / 1000000.0
	var second := 0
	while clock.us < SECONDS * 1000000:
		clock.us += FRAME_US
		for i in 2:
			var peer := peers[i]
			var ms := clock.ms()
			if i == 1 and ms >= silent_from_ms and ms < silent_from_ms + silent_ms:
				peer.skipped += delta
				continue
			peer.frame(delta + peer.skipped)
			peer.skipped = 0.0
		if clock.ms() / 1000 > second:
			second = clock.ms() / 1000
			for peer in peers:
				peer.delays.append(peer.input.delay())
	return peers

func _describe(peers: Array[Peer]) -> String:
	var lines := ""
	for i in 2:
		var per_second: Array[int] = []
		for s in SECONDS:
			per_second.append(peers[i].waits_in_second(s))
		lines += "\n  side %d: waits per second %s, delay %s" % [i, per_second, peers[i].delays]
	return lines

func _assert_same_worlds(peers: Array[Peer]) -> void:
	var common := mini(peers[0].hashes.size(), peers[1].hashes.size())
	for t in common:
		if peers[0].hashes[t] != peers[1].hashes[t]:
			fail_test("the worlds diverged on tick %d" % t)
			return
	assert_false(peers[0].input.desynced or peers[1].input.desynced,
		"the hash comparison fired")

func _assert_calm_after(peers: Array[Peer], from_second: int) -> void:
	for i in 2:
		for s in range(from_second, SECONDS):
			if peers[i].waits_in_second(s) > WAITS_PER_SECOND:
				fail_test("side %d waited on %d ticks in second %d — that is stutter%s" % [
					i, peers[i].waits_in_second(s), s, _describe(peers)])
				return
	pass_test("calm")

func test_a_quarter_second_circle_stops_stuttering_within_seconds() -> void:
	if not ADAPTS:
		pending("the input delay does not adapt yet")
		return
	var peers := _play(60, 20)
	_assert_same_worlds(peers)
	_assert_calm_after(peers, SETTLE_SECONDS)

func test_a_half_second_circle_settles_under_the_ceiling() -> void:
	if not ADAPTS:
		pending("the input delay does not adapt yet")
		return
	var peers := _play(120, 40)
	_assert_same_worlds(peers)
	_assert_calm_after(peers, SETTLE_SECONDS)
	for i in 2:
		assert_lte(peers[i].delays.max(), NetInput.MAX_DELAY)

## Responsiveness must not pay for all of this: on a local network the delay has
## nothing to grow for.
func test_a_local_network_keeps_the_smallest_delay() -> void:
	var peers := _play(5, 3)
	_assert_same_worlds(peers)
	for i in 2:
		for d in peers[i].delays:
			if d != Lockstep.DELAY:
				fail_test("side %d left the smallest delay on a local network%s" % [
					i, _describe(peers)])
				return
	pass_test("stayed at the smallest delay")

## A partner switching tabs for two seconds is one long wait, not a network that
## cannot keep up. The game must settle again afterwards, not climb to the
## ceiling and stay there.
func test_a_partner_switching_tabs_is_not_a_slow_network() -> void:
	if not ADAPTS:
		pending("the input delay does not adapt yet")
		return
	var peers := _play(5, 3, 10000, 2000)
	_assert_same_worlds(peers)
	for i in 2:
		assert_lt(peers[i].delays.max(), NetInput.MAX_DELAY,
			"side %d went to the ceiling over one wait%s" % [i, _describe(peers)])
	_assert_calm_after(peers, 15)
