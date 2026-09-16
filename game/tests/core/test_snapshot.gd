extends GutTest

## A network game steps back to a tick and computes it again with the partner's
## real input. That is only safe if a restored world is the world that was saved —
## every field, the generator and the spawner's count included.

func _sim() -> GameSim:
	return GameSim.new(Golden.level(), Golden.SEED, SimConfig.new(),
		Golden.LEVEL_NUMBER, Golden.PLAYERS)

func _run(sim: GameSim, frames: Array, from: int, to: int) -> void:
	for t in range(from, to):
		sim.tick(frames[t])
		sim.drain_events()

func test_restoring_and_computing_again_gives_the_same_world() -> void:
	var frames := Golden.frames()
	var sim := _sim()
	_run(sim, frames, 0, 600)
	var saved := sim.save()
	_run(sim, frames, 600, 900)
	var first := sim.state_hash()
	sim.restore(saved)
	assert_eq(sim.get_state().tick, 600, "the restored world is not the saved tick")
	_run(sim, frames, 600, 900)
	assert_eq(sim.state_hash(), first, "computing the same ticks again gave another world")

func test_a_snapshot_is_not_touched_by_the_world_going_on() -> void:
	var frames := Golden.frames()
	var sim := _sim()
	_run(sim, frames, 0, 600)
	var at_600 := sim.state_hash()
	var saved := sim.save()
	_run(sim, frames, 600, 900)
	sim.restore(saved)
	assert_eq(sim.state_hash(), at_600, "the snapshot shared objects with the live world")
	_run(sim, frames, 600, 700)
	sim.restore(saved)
	assert_eq(sim.state_hash(), at_600, "a snapshot could not be restored twice")

## Steps back every hundred ticks, computes seven ticks on wrong input, and
## returns. The golden run must not notice.
func test_the_golden_run_survives_stepping_back() -> void:
	var frames := Golden.frames()
	var sim := _sim()
	for t in Golden.TICKS:
		if t % 100 == 50:
			var saved := sim.save()
			for k in 7:
				sim.tick([0, 0])
				sim.drain_events()
			sim.restore(saved)
		sim.tick(frames[t])
		sim.drain_events()
	assert_eq(sim.state_hash(), Golden.EXPECTED)

func test_restore_keeps_the_same_world_object() -> void:
	var sim := _sim()
	var live := sim.get_state()
	var saved := sim.save()
	_run(sim, Golden.frames(), 0, 10)
	sim.restore(saved)
	assert_true(is_same(sim.get_state(), live),
		"the core modules hold this object; replacing it leaves them in the old world")

## A field added to the world or an entity and forgotten in the copy would pass
## the tests above whenever its value happens to match. Every script variable is
## set to a value no default has, copied, and compared.
func test_every_field_is_copied() -> void:
	var src := WorldState.new()
	src.terrain = Terrain.new()
	src.terrain.set_cell(3, 4, Types.Cell.BRICK)
	src.tanks = [Entities.Tank.new(), Entities.Tank.new()]
	src.bullets = [Entities.Bullet.new()]
	src.bonus = Entities.Bonus.new()
	src.players = [Entities.PlayerState.new()]
	src.enemy_queue = [1, 2, 3] as Array[int]
	var n := 1000
	for obj in [src, src.tanks[0], src.tanks[1], src.bullets[0], src.bonus, src.players[0]]:
		n = _scramble(obj, n)
	var dst := WorldState.new()
	SimSnapshot.copy_world(src, dst)
	_assert_copied(src, dst, "WorldState")

func _script_vars(obj: Object) -> Array[String]:
	var out: Array[String] = []
	for p in obj.get_property_list():
		if p["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
			out.append(p["name"])
	return out

func _scramble(obj: Object, n: int) -> int:
	for name in _script_vars(obj):
		var v = obj.get(name)
		n += 1
		match typeof(v):
			TYPE_INT:
				obj.set(name, n)
			TYPE_BOOL:
				obj.set(name, not v)
			TYPE_VECTOR2I:
				obj.set(name, Vector2i(n, -n))
			TYPE_ARRAY:
				var arr: Array = v
				if arr.is_typed() and arr.get_typed_builtin() == TYPE_INT:
					arr.clear()
					arr.append_array([n, n + 1, n + 2, n + 3])
	return n

func _assert_copied(a: Object, b: Object, where: String) -> void:
	assert_false(is_same(a, b), "%s is shared, not copied" % where)
	for name in _script_vars(a):
		var va = a.get(name)
		var vb = b.get(name)
		var path := "%s.%s" % [where, name]
		if va is Object:
			_assert_copied(va, vb, path)
		elif va is Array:
			assert_false(is_same(va, vb), "%s is shared, not copied" % path)
			assert_eq((vb as Array).size(), (va as Array).size(), path)
			for i in mini((va as Array).size(), (vb as Array).size()):
				if va[i] is Object:
					_assert_copied(va[i], vb[i], "%s[%d]" % [path, i])
				else:
					assert_eq(vb[i], va[i], "%s[%d]" % [path, i])
		else:
			assert_eq(vb, va, path)
