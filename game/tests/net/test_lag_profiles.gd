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
##
## Where each profile settles, both sides starting from the smallest delay:
##
##   leg 5 ± 3, a local network    5 / 5, not a single wait
##   leg 60 ± 20                   10 / 10 within three seconds, then at most one
##                                 waiting tick a second; 98 % of the clock
##   leg 120 ± 40                  16 / 16 by the fourth second and still five to
##                                 seven waiting ticks a second: the circle,
##                                 480 ± 160 ms, is longer than the ceiling's
##                                 533 ms can cover; 87 % of the clock
##   2 s tab switch, leg 5 ± 3     6 on the side that waited, 5 on the one that
##                                 came back, calm at once
##   2 s tab switch, leg 60 ± 20   11 / 10, calm at once
##
## Before the delay was reconsidered every second, 60 ± 20 waited on 25–30 ticks
## a second for twelve seconds while the delay crept 5 → 8 → 11; 120 ± 40 waited
## on 10–20 a second for all thirty; and after a tab switch the side that came
## back waited on every tick until the level ended, its delay climbing to the
## ceiling.

const SEED := 13
const SECONDS := 30
const FRAME_US := 1000000 / 60
## The two machines do not draw in step.
const OFFSET_US := 5000
## How long the delay is given to find its value. Past this, a waiting tick is
## stutter a human sees.
const SETTLE_SECONDS := 3
## Read as a rate: a late packet a second on average, and never a second with
## more than two — three is a visible stumble.
const WAITS_PER_SECOND := 1
const WAITS_IN_ANY_SECOND := 2

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
		var waited := false
		for i in due:
			var t: int = sim.get_state().tick
			input.capture(t)
			if not input.can_advance(t):
				waited = true
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
		pump.spend(ran, waited)
		input.flush()

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
	var next: Array[int] = [FRAME_US, FRAME_US + OFFSET_US]
	var delta := FRAME_US / 1000000.0
	var second := 0
	while clock.us < SECONDS * 1000000:
		var i := 0 if next[0] <= next[1] else 1
		clock.us = next[i]
		next[i] += FRAME_US
		var peer := peers[i]
		var ms := clock.ms()
		if i == 1 and ms >= silent_from_ms and ms < silent_from_ms + silent_ms:
			peer.skipped += delta
		else:
			peer.frame(delta + peer.skipped)
			peer.skipped = 0.0
		if clock.ms() / 1000 > second:
			second = clock.ms() / 1000
			for p in peers:
				p.delays.append(p.input.delay())
	return peers

func _describe(peers: Array[Peer]) -> String:
	var lines := ""
	for i in 2:
		var per_second: Array[int] = []
		for s in SECONDS:
			per_second.append(peers[i].waits_in_second(s))
		lines += "\n  side %d: %d ticks, waits per second %s, delay %s" % [
			i, peers[i].hashes.size(), per_second, peers[i].delays]
	return lines

func _assert_same_worlds(peers: Array[Peer]) -> void:
	var common := mini(peers[0].hashes.size(), peers[1].hashes.size())
	for t in common:
		if peers[0].hashes[t] != peers[1].hashes[t]:
			fail_test("the worlds diverged on tick %d" % t)
			return
	assert_false(peers[0].input.desynced or peers[1].input.desynced,
		"the hash comparison fired")

## No waits is also what a game frozen for good looks like.
func _assert_keeps_pace(peers: Array[Peer], percent: int, silent_ms := 0) -> void:
	var expected := (SECONDS * 1000 - silent_ms) * 60 / 1000
	for i in 2:
		assert_gte(peers[i].hashes.size() * 100, expected * percent,
			"side %d fell behind the clock%s" % [i, _describe(peers)])

func _assert_calm_after(peers: Array[Peer], from_second: int) -> void:
	for i in 2:
		var total := 0
		for s in range(from_second, SECONDS):
			var waits := peers[i].waits_in_second(s)
			total += waits
			if waits > WAITS_IN_ANY_SECOND:
				fail_test("side %d waited on %d ticks in second %d — that is stutter%s" % [
					i, waits, s, _describe(peers)])
				return
		if total > (SECONDS - from_second) * WAITS_PER_SECOND:
			fail_test("side %d waited on %d ticks after second %d — that is stutter%s" % [
				i, total, from_second, _describe(peers)])
			return
	pass_test("calm")

func test_a_quarter_second_circle_stops_stuttering_within_seconds() -> void:
	var peers := _play(60, 20)
	_assert_same_worlds(peers)
	_assert_keeps_pace(peers, 95)
	_assert_calm_after(peers, SETTLE_SECONDS)

## Past the ceiling nothing covers the circle, and the waits stay: sixteen ticks a
## side is where the game would turn into correspondence, and raising it waits
## for players who need it. What must hold is that the delay goes to the ceiling
## and no further, and the game carries on in step.
func test_a_half_second_circle_goes_to_the_ceiling_and_plays_on() -> void:
	var peers := _play(120, 40)
	_assert_same_worlds(peers)
	_assert_keeps_pace(peers, 80)
	for i in 2:
		assert_eq(peers[i].delays.max(), NetInput.MAX_DELAY,
			"side %d did not take the slack there was%s" % [i, _describe(peers)])
		assert_eq(peers[i].delays[-1], NetInput.MAX_DELAY,
			"side %d gave slack back while still waiting%s" % [i, _describe(peers)])

## Responsiveness must not pay for all of this: on a local network the delay has
## nothing to grow for.
func test_a_local_network_keeps_the_smallest_delay() -> void:
	var peers := _play(5, 3)
	_assert_same_worlds(peers)
	_assert_keeps_pace(peers, 99)
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
	var peers := _play(5, 3, 10000, 2000)
	_assert_same_worlds(peers)
	_assert_keeps_pace(peers, 95, 2000)
	for i in 2:
		assert_lt(peers[i].delays.max(), NetInput.MAX_DELAY,
			"side %d went to the ceiling over one wait%s" % [i, _describe(peers)])
	_assert_calm_after(peers, 15)

func test_a_tab_switch_on_a_slow_path_settles_as_quickly() -> void:
	var peers := _play(60, 20, 10000, 2000)
	_assert_same_worlds(peers)
	_assert_keeps_pace(peers, 95, 2000)
	for i in 2:
		assert_lt(peers[i].delays.max(), NetInput.MAX_DELAY,
			"side %d went to the ceiling over one wait%s" % [i, _describe(peers)])
	_assert_calm_after(peers, 15)
