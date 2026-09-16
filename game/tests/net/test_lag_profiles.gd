extends GutTest

## Two sides play through a link with the internet's delays, frame by frame, on a
## clock the test turns by hand. Below the screen everything is production code:
## NetInput, NetMatch and the core.
##
## A packet takes two legs, side to relay to side, so the partner's input for a
## tick reaches us two legs after they sent it. Past a window of twelve ticks the
## game stands.
##
## Where each profile settles over thirty seconds, keys held as people hold them.
## `stops` are frames that stood past the window, `deepest` the furthest a frame
## ever had to step back, `pace` the share of the clock's ticks the side computed.
##
##   one leg          stops   deepest   pace     counted from
##   5 +- 3 ms            0         0   99 %     the start
##   60 +- 20 ms          0         8   99 %     second 1
##   120 +- 40 ms       520        12   84 %     second 1
##   tab switch, 5 ms     0       0-1   93 %     second 13
##   tab switch, 60 ms    0         8   92 %     second 15
##   half a second early  0       2-3   98 %     second 10
##
## The second line is the path of the complaint — a relay about 110 ms away — and
## it never stands: guesses cover it, eight ticks deep at the worst. The third is
## twice that path, past what twelve ticks can cover, and there the game does stand
## — but both sides stand together and the worlds stay the same.
##
## A tab switch leaves the side that stood a window ahead of its partner. Shed one
## tick in twenty, that lead dropped nine frames and stepped back five ticks deep
## after second 13 on a local network; it is shed inside the stand now, and the
## line above reads as a calm local network does.

const SEED := 13
const SECONDS := 30
const FRAME_US := 1000000 / 60
## The two machines do not draw in step.
const OFFSET_US := 5000

class ClockedInput extends NetInput:
	var clock: LaggyLink.Clock
	func _clock() -> int:
		return clock.ms()

class Peer:
	var input: ClockedInput
	var net_match: NetMatch
	## When a frame stood for the partner, in ms.
	var stops: Array[int] = []
	## The deepest rollback of every second.
	var deepest: Array[int] = []
	## Every frame as [ms, ticks computed going forward, rollback depth]. A frame
	## that computed nothing — stood, or let a tick go — left the picture still.
	var frames_log: Array = []
	var skipped := 0.0
	var _clock: LaggyLink.Clock
	var _deepest_now := 0

	func _init(link: LaggyLink, slot: int, clock: LaggyLink.Clock, frames: Array) -> void:
		_clock = clock
		input = ClockedInput.new(link, slot, func(t: int) -> int: return frames[t][slot])
		input.clock = clock
		net_match = NetMatch.new(GameSim.new(Golden.level(), Golden.SEED, SimConfig.new(),
			Golden.LEVEL_NUMBER, 2), input)

	func frame(delta: float) -> void:
		var f := net_match.advance(delta)
		if f.waited:
			stops.append(_clock.ms())
		frames_log.append([_clock.ms(), f.ran, f.rollback_depth])
		_deepest_now = maxi(_deepest_now, f.rollback_depth)

	func close_second() -> void:
		deepest.append(_deepest_now)
		_deepest_now = 0

	func ticks() -> int:
		return net_match.sim().get_state().tick

	func stops_from(second: int) -> int:
		var n := 0
		for ms in stops:
			if ms / 1000 >= second:
				n += 1
		return n

	func deepest_from(second: int) -> int:
		return deepest_between(second, deepest.size())

	func deepest_between(from: int, to: int) -> int:
		var d := 0
		for s in range(from, mini(to, deepest.size())):
			d = maxi(d, deepest[s])
		return d

	## The first frame after `ms` that computed a tick.
	func moved_after(ms: int) -> int:
		for f in frames_log:
			if f[0] > ms and f[1] > 0:
				return f[0]
		return -1

	func stills_between(from_ms: int, to_ms: int) -> int:
		var n := 0
		for f in frames_log:
			if f[0] >= from_ms and f[0] < to_ms and f[1] == 0:
				n += 1
		return n

	func depth_between(from_ms: int, to_ms: int) -> int:
		var d := 0
		for f in frames_log:
			if f[0] >= from_ms and f[0] < to_ms:
				d = maxi(d, f[2])
		return d

## One leg is `leg_ms ± jitter_ms`. Side 1 may go silent for a while, the way a
## browser tab stops its frame loop, and may start late.
func _play(leg_ms: int, jitter_ms: int, silent_from_ms := -1, silent_ms := 0,
		late_start_ms := 0) -> Array[Peer]:
	var clock := LaggyLink.Clock.new()
	var links := LaggyLink.pair(clock, leg_ms, jitter_ms, SEED)
	var frames := HeldKeys.frames(SEED, SECONDS * 60 + 600)
	var peers: Array[Peer] = [Peer.new(links[0], 0, clock, frames),
		Peer.new(links[1], 1, clock, frames)]
	var next: Array[int] = [FRAME_US, FRAME_US + OFFSET_US + late_start_ms * 1000]
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
				p.close_second()
	return peers

func _describe(peers: Array[Peer]) -> String:
	var out := ""
	for i in 2:
		out += "\n  side %d: %d ticks, stops %d, deepest per second %s" % [
			i, peers[i].ticks(), peers[i].stops.size(), peers[i].deepest]
	return out

func _assert_same_worlds(peers: Array[Peer]) -> void:
	for p in peers:
		assert_false(p.input.desynced, "the hash comparison fired%s" % _describe(peers))
	var a := peers[0].net_match.confirmed_world()
	var b := peers[1].net_match.confirmed_world()
	if a.tick == b.tick:
		assert_eq(a.hash_value(), b.hash_value(), "the confirmed worlds differ%s" % _describe(peers))

func _assert_keeps_pace(peers: Array[Peer], percent: int, silent_ms := 0) -> void:
	var expected := (SECONDS * 1000 - silent_ms) * 60 / 1000
	for i in 2:
		assert_gte(peers[i].ticks() * 100, expected * percent,
			"side %d fell behind the clock%s" % [i, _describe(peers)])

func test_a_local_network_barely_steps_back() -> void:
	var peers := _play(5, 3)
	_assert_same_worlds(peers)
	_assert_keeps_pace(peers, 99)
	for i in 2:
		assert_eq(peers[i].stops.size(), 0, "side %d stood%s" % [i, _describe(peers)])
		assert_lte(peers[i].deepest_from(0), 2, "side %d stepped back too far%s" % [i, _describe(peers)])

## The path of the complaint: about 110 ms each way through the relay.
func test_a_path_to_the_relay_and_back_never_stands() -> void:
	var peers := _play(60, 20)
	_assert_same_worlds(peers)
	_assert_keeps_pace(peers, 98)
	for i in 2:
		assert_eq(peers[i].stops_from(1), 0, "side %d stood%s" % [i, _describe(peers)])
		assert_lte(peers[i].deepest_from(1), 10, "side %d near the window%s" % [i, _describe(peers)])

## Past the window nothing can be guessed, and the game stands — but in step.
func test_a_path_longer_than_the_window_stands_and_plays_on() -> void:
	var peers := _play(120, 40)
	_assert_same_worlds(peers)
	_assert_keeps_pace(peers, 80)

func test_a_partner_switching_tabs_stands_the_game_and_lets_it_go() -> void:
	var peers := _play(5, 3, 10000, 2000)
	_assert_same_worlds(peers)
	_assert_keeps_pace(peers, 95, 2000)
	for i in 2:
		assert_eq(peers[i].stops_from(13), 0, "side %d kept standing after the partner came back%s" % [i, _describe(peers)])

func test_a_tab_switch_on_a_slow_path_settles_as_quickly() -> void:
	var peers := _play(60, 20, 10000, 2000)
	_assert_same_worlds(peers)
	_assert_keeps_pace(peers, 95, 2000)
	for i in 2:
		assert_eq(peers[i].stops_from(15), 0, "side %d kept standing%s" % [i, _describe(peers)])

## A partner back from a hidden tab finds the side that stood twelve ticks ahead:
## it went on guessing for a whole window before it stood. Shed one tick in twenty,
## that lead cost three and a half seconds of dropped frames and rollbacks ten deep
## on a link that otherwise never steps back. From the moment the side that stood
## moves again, five seconds of play look as they did before the partner left.
##
## The limits are what each path shows with no tab switch at all: a local network
## drops no frame and never steps back; the path to the relay drops about one
## frame in three seconds and steps back up to eight ticks.
func test_after_a_tab_switch_the_game_runs_as_before_at_once() -> void:
	for profile in [[5, 3, 0, 1], [60, 20, 2, 9]]:
		var peers := _play(profile[0], profile[1], 10000, 2000)
		_assert_same_worlds(peers)
		for i in 2:
			var from := peers[i].moved_after(12000)
			assert_gt(from, 0, "side %d never moved again" % i)
			var stills := peers[i].stills_between(from, from + 5000)
			var depth := peers[i].depth_between(from, from + 5000)
			assert_lte(stills, profile[2],
				"legs of %d ms: side %d dropped %d frames in the five seconds after it moved again%s" % [
					profile[0], i, stills, _describe(peers)])
			assert_lte(depth, profile[3],
				"legs of %d ms: side %d stepped back %d ticks after it moved again%s" % [
					profile[0], i, depth, _describe(peers)])

## A side that started half a second earlier runs thirty ticks ahead and would
## guess at the very edge of the window for the whole match. It lets ticks go
## until the two are in step.
func test_a_side_that_started_early_falls_back_into_step() -> void:
	var peers := _play(30, 5, -1, 0, 500)
	_assert_same_worlds(peers)
	assert_lte(absi(peers[0].ticks() - peers[1].ticks()), 3,
		"the sides are still apart%s" % _describe(peers))
	for i in 2:
		assert_eq(peers[i].stops_from(10), 0, "side %d stood%s" % [i, _describe(peers)])
		assert_lte(peers[i].deepest_from(10), 8, "side %d guessing at the edge%s" % [i, _describe(peers)])
