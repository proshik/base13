class_name Golden

## The golden run: a recorded scenario that must yield the same world always
## and everywhere. It lives in the core rather than in the tests because more
## than the tests run it: the web build uses it to check that the browser
## computes the world exactly as the desktop does — without that, cross-platform
## co-op is impossible in principle.
##
## EXPECTED was obtained by a single run and then frozen. A divergence is not a
## reason to edit the number but a reason to find out which rule drifted.

const EXPECTED := 2233634213

const SEED := 2718
const INPUT_SEED := 20260825
const TICKS := 3000
const LEVEL_NUMBER := 5
const PLAYERS := 2

## The scenario is assembled here rather than taken from a test fixture: tests
## are not packed into a build, and the golden run must be available there too.
static func level() -> LevelData:
	var lvl := LevelData.new()
	lvl.terrain = Terrain.new()
	for c in Consts.BASE_WALL_CELLS:
		lvl.terrain.set_cell(c.x, c.y, Types.Cell.BRICK)
	for cx in range(4, 22):
		lvl.terrain.set_cell(cx, 10, Types.Cell.BRICK)
	for cx in range(8, 18):
		lvl.terrain.set_cell(cx, 16, Types.Cell.STEEL)
	for i in 20:
		lvl.enemy_queue.append(Types.TankType.BASIC)
	lvl.bonus_indices = [3, 10, 17] as Array[int]
	return lvl

## The stream of key presses is built with the same generator as everything
## else: random, but reproducible.
static func frames() -> Array:
	var r := Rng.new(INPUT_SEED)
	var out: Array = []
	for i in TICKS:
		out.append([r.next_range(0, 32), r.next_range(0, 32)])
	return out

static func run() -> int:
	var sim := GameSim.new(level(), SEED, SimConfig.new(), LEVEL_NUMBER, PLAYERS)
	var script := frames()
	for i in TICKS:
		sim.tick(script[i])
	return sim.state_hash()
