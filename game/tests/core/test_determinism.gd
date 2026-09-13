extends GutTest

const TICKS := 10000

## The input scenario is built with the same generator as everything else:
## a random but reproducible stream of presses for both players.
func _script(seed_value: int, count: int) -> Array:
	var r := Rng.new(seed_value)
	var frames: Array = []
	for i in count:
		frames.append([r.next_range(0, 32), r.next_range(0, 32)])
	return frames

func _level() -> LevelData:
	var cells := {}
	for cx in range(4, 22):
		cells[Vector2i(cx, 8)] = Types.Cell.BRICK
	for cx in range(6, 20):
		cells[Vector2i(cx, 14)] = Types.Cell.STEEL
	for cx in range(2, 8):
		cells[Vector2i(cx, 18)] = Types.Cell.WATER
	for cx in range(18, 24):
		cells[Vector2i(cx, 18)] = Types.Cell.ICE
	return LevelFixture.level_with(cells)

func test_two_sims_stay_in_lockstep_for_ten_thousand_ticks() -> void:
	var frames := _script(4242, TICKS)
	var a := GameSim.new(_level(), 777, SimConfig.new(), 3, 2)
	var b := GameSim.new(_level(), 777, SimConfig.new(), 3, 2)
	for i in frames.size():
		a.tick(frames[i])
		b.tick(frames[i])
		if a.state_hash() != b.state_hash():
			fail_test("desync on tick %d" % i)
			return
	assert_eq(a.state_hash(), b.state_hash(), "ten thousand ticks without a single divergence")

func test_different_input_gives_different_outcome() -> void:
	var a := GameSim.new(_level(), 777, SimConfig.new(), 3, 2)
	var b := GameSim.new(_level(), 777, SimConfig.new(), 3, 2)
	var fa := _script(1, 600)
	var fb := _script(2, 600)
	for i in 600:
		a.tick(fa[i])
		b.tick(fb[i])
	assert_ne(a.state_hash(), b.state_hash(), "different input must produce a different outcome")
