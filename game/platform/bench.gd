class_name Bench

## What stepping back would cost on this machine: one tick, one save, and the worst
## frame of a network game — restoring a world and computing twelve ticks again,
## saving before each. It runs with the self-test, because the browser is the
## machine that matters and it has no terminal.

const TICKS := 600
const REPEATS := 20
## Rollback.MAX_ROLLBACK; spelled out because this runs before that class exists.
const DEPTH := 12

static func measure() -> Dictionary:
	var frames := Golden.frames()
	var sim := GameSim.new(Golden.level(), Golden.SEED, SimConfig.new(),
		Golden.LEVEL_NUMBER, Golden.PLAYERS)
	var began := Time.get_ticks_usec()
	for t in TICKS:
		sim.tick(frames[t])
		sim.drain_events()
	var tick_us := (Time.get_ticks_usec() - began) / TICKS
	var saved: SimSnapshot = null
	began = Time.get_ticks_usec()
	for i in REPEATS:
		saved = sim.save()
	var save_us := (Time.get_ticks_usec() - began) / REPEATS
	began = Time.get_ticks_usec()
	for i in REPEATS:
		sim.restore(saved)
		for d in DEPTH:
			sim.save()
			sim.tick(frames[TICKS + d])
			sim.drain_events()
	var resim_us := (Time.get_ticks_usec() - began) / REPEATS
	return {"tick_us": maxi(1, tick_us), "save_us": maxi(1, save_us), "resim_us": maxi(1, resim_us)}
