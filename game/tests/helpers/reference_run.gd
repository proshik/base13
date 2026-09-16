class_name ReferenceRun

## The world a network match must end in, computed with no network at all.
##
## A side's `bits_provider(now)` is read on tick `now` and takes effect on
## `now + INPUT_DELAY`; the first START ticks carry nothing. So tick `t` sees
## `frames[t - INPUT_DELAY]` from both players. Guesses, rollbacks and late packets
## may change when a side knows its world, never what that world is.

static func hash_of(frames: Array, ticks: int) -> int:
	var sim := GameSim.new(Golden.level(), Golden.SEED, SimConfig.new(),
		Golden.LEVEL_NUMBER, 2)
	for t in ticks:
		var inputs: Array[int] = [0, 0]
		if t >= Rollback.START:
			inputs = [frames[t - Rollback.INPUT_DELAY][0],
				frames[t - Rollback.INPUT_DELAY][1]] as Array[int]
		sim.tick(inputs)
		sim.drain_events()
	return sim.state_hash()
