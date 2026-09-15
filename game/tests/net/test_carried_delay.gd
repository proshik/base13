extends GutTest

## A delay learnt on one level is carried into the next, so a slow path does not
## stutter through the first seconds of every level again. The danger is the
## start: if one side began a level at eleven and the other at five, the first
## packet from the first side is for tick eleven, while the second side has only
## ticks up to four filled in. It waits for tick five forever, and the first side
## waits forever for its tick eleven — "WAITING FOR PARTNER" with the partner
## right there, and no timer ends it.

const TICKS := 900

func _sim() -> GameSim:
	return GameSim.new(Golden.level(), Golden.SEED, SimConfig.new(),
		Golden.LEVEL_NUMBER, 2)

func test_sides_starting_with_different_delays_do_not_wait_for_each_other() -> void:
	var clock := LaggyLink.Clock.new()
	var links := LaggyLink.pair(clock, 0, 0, 1)
	var frames := Golden.frames()
	var host_input := NetInput.new(links[0], 0,
		func(t: int) -> int: return frames[t][0], 11)
	var guest_input := NetInput.new(links[1], 1,
		func(t: int) -> int: return frames[t][1], Lockstep.DELAY)
	assert_eq(host_input.delay(), 11, "the carried delay was not taken")
	var host := _sim()
	var guest := _sim()

	for t in TICKS:
		host_input.capture(t)
		guest_input.capture(t)
		host_input.pump()
		guest_input.pump()
		if not (host_input.can_advance(t) and guest_input.can_advance(t)):
			fail_test("tick %d waits on both sides for good" % t)
			return
		host.tick(host_input.inputs_for(t))
		guest.tick(guest_input.inputs_for(t))
		host_input.after_tick(t, host.state_hash())
		guest_input.after_tick(t, guest.state_hash())
		if host.state_hash() != guest.state_hash():
			fail_test("the worlds diverged on tick %d" % t)
			return
	assert_false(host_input.desynced or guest_input.desynced)

class ClockedInput extends NetInput:
	var clock: LaggyLink.Clock
	func _clock() -> int:
		return clock.ms()

## The partner can still be finishing the last level when ours begins — a tab
## hidden at the level clear, a slow frame. Their old input takes in our new band,
## the packets are gone from the socket, and their new level waits for tick five
## from us for good, though we sent it. Only sending it again gets them moving:
## once a tick has stood a second on a live link, the recent input goes out again.
func test_a_band_eaten_by_the_partners_last_level_is_sent_again() -> void:
	var clock := LaggyLink.Clock.new()
	var links := LaggyLink.pair(clock, 30, 5, 3)
	var frames := Golden.frames()
	var old := ClockedInput.new(links[1], 1)
	old.clock = clock
	var inputs: Array[ClockedInput] = []
	inputs.append(ClockedInput.new(links[0], 0, func(t: int) -> int: return frames[t][0], 10))
	inputs[0].clock = clock
	clock.us += 200000
	old.pump()
	old = null
	inputs.append(ClockedInput.new(links[1], 1, func(t: int) -> int: return frames[t][1]))
	inputs[1].clock = clock

	var sims: Array[GameSim] = [_sim(), _sim()]
	var next: Array[int] = [0, 0]
	for frame in 60 * 20:
		clock.us += 16667
		for side in 2:
			inputs[side].pump()
			if next[side] < TICKS:
				inputs[side].capture(next[side])
				if inputs[side].can_advance(next[side]):
					sims[side].tick(inputs[side].inputs_for(next[side]))
					inputs[side].after_tick(next[side], sims[side].state_hash())
					next[side] += 1
			inputs[side].flush()
		if next[0] >= TICKS and next[1] >= TICKS:
			break
	assert_eq(next, [TICKS, TICKS] as Array[int],
		"the match froze at the start of the level: %s" % [next])
	assert_eq(sims[0].state_hash(), sims[1].state_hash(), "the worlds diverged")
