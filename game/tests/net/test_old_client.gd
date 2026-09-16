extends GutTest

## A player on 0.5.0 and a player on this build in one room: the desktop build a
## person installed last week meets the page the server serves today. An input
## packet means the same to both — input for tick N — so the old side waits as it
## always did, the new side guesses, and the worlds must match.

const SECONDS := 20
const FRAME_US := 1000000 / 60
const HORIZON := 600
const SEED := 7

class OldInput extends LegacyNetInput:
	var clock: LaggyLink.Clock
	func _clock() -> int:
		return clock.ms()

class NewInput extends NetInput:
	var clock: LaggyLink.Clock
	func _clock() -> int:
		return clock.ms()

## The old game screen's frame loop, as it was.
class OldPeer:
	var input: OldInput
	var sim: GameSim
	var pump := TickPump.new()
	var hashes: Array[int] = []

	func frame(delta: float) -> void:
		input.pump()
		var due := pump.due(delta)
		var ran := 0
		var waited := false
		for i in due:
			var t: int = sim.get_state().tick
			if t >= HORIZON:
				break
			input.capture(t)
			if not input.can_advance(t):
				waited = true
				break
			ran += 1
			sim.tick(input.inputs_for(t))
			var h := sim.state_hash()
			input.after_tick(t, h)
			hashes.append(h)
			sim.drain_events()
		pump.spend(ran, waited)
		input.flush()

func _sim() -> GameSim:
	return GameSim.new(Golden.level(), Golden.SEED, SimConfig.new(), Golden.LEVEL_NUMBER, 2)

func test_an_old_client_and_a_new_one_hold_the_same_world() -> void:
	var clock := LaggyLink.Clock.new()
	var links := LaggyLink.pair(clock, 30, 10, SEED)
	var frames := HeldKeys.frames(SEED, HORIZON + 600)
	var old := OldPeer.new()
	old.sim = _sim()
	old.input = OldInput.new(links[0], 0, func(t: int) -> int: return frames[t][0])
	old.input.clock = clock
	var fresh_input := NewInput.new(links[1], 1, func(t: int) -> int: return frames[t][1])
	fresh_input.clock = clock
	var fresh := NetMatch.new(_sim(), fresh_input)
	fresh.set_horizon(HORIZON)
	var delta := FRAME_US / 1000000.0
	while clock.us < SECONDS * 1000000:
		clock.us += FRAME_US
		old.frame(delta)
		fresh.advance(delta)
		if old.hashes.size() == HORIZON and fresh.confirmed_world().tick == HORIZON:
			break
	assert_eq(old.hashes.size(), HORIZON, "the old side never got there")
	assert_eq(fresh.confirmed_world().tick, HORIZON, "the new side never confirmed the end")
	if old.hashes.size() != HORIZON:
		return
	assert_eq(fresh.confirmed_world().hash_value(), old.hashes[HORIZON - 1], "the worlds parted")
	assert_false(old.input.desynced, "the old side saw a divergence")
	assert_false(fresh_input.desynced, "the new side saw a divergence")
