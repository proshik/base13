extends GutTest

## NetMatch on its own, with a source built straight on Rollback and packets that
## arrive a set number of frames late. No sockets and no clock: what is checked is
## the stepping back, not the transport.

const TICKS := 600

class Pipe:
	var frame := 0
	var lag := 0
	var boxes := [[], []]   ## per side: [arrival_frame, tick, bits]

class PipeInput extends InputSource:
	var rollback: Rollback
	var pipe: Pipe
	var slot := 0
	var frames: Array
	var sent_through := Rollback.START - 1
	var hashes := {}
	var rollbacks := 0

	func _init(p_pipe: Pipe, p_slot: int, p_frames: Array) -> void:
		pipe = p_pipe
		slot = p_slot
		frames = p_frames
		rollback = Rollback.new(p_slot)

	func pump() -> void:
		var box: Array = pipe.boxes[slot]
		while not box.is_empty() and box[0][0] <= pipe.frame:
			var p: Array = box.pop_front()
			rollback.submit_remote(p[1], p[2])

	func capture(now: int) -> void:
		var applied := now + Rollback.INPUT_DELAY
		if applied <= sent_through:
			return
		sent_through = applied
		var bits: int = frames[now][slot]
		rollback.submit_local(applied, bits)
		pipe.boxes[1 - slot].append([pipe.frame + pipe.lag, applied, bits])

	func can_predict(tick: int) -> bool:
		return rollback.can_predict(tick)
	func inputs_for(tick: int) -> Array[int]:
		return rollback.inputs_for(tick)
	func confirmed() -> int:
		return rollback.confirmed()
	func rollback_from() -> int:
		return rollback.rollback_from()
	func clear_rollback() -> void:
		rollback.clear_rollback()
	func wants_hash(tick: int) -> bool:
		return tick % 60 == 0
	func after_confirmed(tick: int, world_hash: int) -> void:
		hashes[tick] = world_hash
	func note_rollback(_depth: int, _usec: int) -> void:
		rollbacks += 1

func _sim() -> GameSim:
	return GameSim.new(Golden.level(), Golden.SEED, SimConfig.new(),
		Golden.LEVEL_NUMBER, 2)

## Both sides, `lag` frames each way, until both have confirmed `TICKS`. Side 1
## may be left out entirely to play a partner who never comes.
func _play(frames: Array, lag: int, side_one_plays := true, shown: Array = []) -> Array[NetMatch]:
	var pipe := Pipe.new()
	pipe.lag = lag
	var sides: Array[NetMatch] = []
	for slot in 2:
		var m := NetMatch.new(_sim(), PipeInput.new(pipe, slot, frames))
		m.set_horizon(TICKS)
		sides.append(m)
	for f in TICKS * 3:
		pipe.frame = f
		for slot in 2:
			if slot == 1 and not side_one_plays:
				continue
			var frame := sides[slot].advance(1.0 / 60.0)
			if slot == 0:
				shown.append(frame)
		if sides[0].confirmed_world().tick == TICKS and sides[1].confirmed_world().tick == TICKS:
			break
	return sides

## The heart of it. Golden keys change every tick, so nearly every guess is wrong
## and nearly every frame steps back — and the confirmed world must still be the
## one a match with no network ends in.
func test_a_match_on_guesses_ends_where_one_without_a_network_does() -> void:
	var frames := Golden.frames()
	var sides := _play(frames, 6)
	var expected := ReferenceRun.hash_of(frames, TICKS)
	for slot in 2:
		assert_eq(sides[slot].confirmed_world().tick, TICKS, "side %d never confirmed the end" % slot)
		assert_eq(sides[slot].confirmed_world().hash_value(), expected, "side %d holds another world" % slot)
	assert_gt((sides[0].source() as PipeInput).rollbacks, 100, "the test never stepped back")

func test_without_lag_the_worlds_match_too() -> void:
	var frames := Golden.frames()
	var sides := _play(frames, 0)
	var expected := ReferenceRun.hash_of(frames, TICKS)
	for slot in 2:
		assert_eq(sides[slot].confirmed_world().hash_value(), expected)

func test_hashes_are_taken_of_confirmed_worlds_and_agree() -> void:
	var sides := _play(Golden.frames(), 6)
	var a: Dictionary = (sides[0].source() as PipeInput).hashes
	var b: Dictionary = (sides[1].source() as PipeInput).hashes
	assert_eq(a.keys().size(), TICKS / 60, "a hash per second of confirmed play, tick 0 included")
	assert_eq(a, b)

func test_a_silent_partner_stops_the_game_at_the_window() -> void:
	var shown: Array = []
	var sides := _play(Golden.frames(), 0, false, shown)
	var last_computable := Rollback.START - 1 + Rollback.MAX_ROLLBACK
	assert_eq(sides[0].sim().get_state().tick, last_computable + 1)
	# A frame may have no tick due at all, so look at the last few rather than one.
	var stood := false
	for f in shown.slice(-10):
		stood = stood or (f as NetMatch.Frame).waited
	assert_true(stood, "standing at the window never showed as a wait")

func test_every_event_of_the_real_match_reaches_the_screen() -> void:
	var frames := Golden.frames()
	var shown: Array = []
	_play(frames, 6, true, shown)
	var seen := {}
	for frame in shown:
		for step in frame.steps:
			for e in step.events:
				var key := "%d:%s" % [step.tick, EventFilter._key(e)]
				seen[key] = seen.get(key, 0) + 1
	var sim := _sim()
	for t in TICKS:
		var inputs: Array[int] = [0, 0]
		if t >= Rollback.START:
			inputs = [frames[t - 2][0], frames[t - 2][1]] as Array[int]
		sim.tick(inputs)
		var counts := {}
		for e in sim.drain_events():
			var key := "%d:%s" % [t, EventFilter._key(e)]
			counts[key] = counts.get(key, 0) + 1
		for key in counts:
			assert_gte(seen.get(key, 0), counts[key], "event %s never reached the screen" % key)

## Alone there is nothing to guess: no world is ever saved, and the confirmed world
## is the live one.
func test_a_game_alone_saves_nothing() -> void:
	var sim := _sim()
	var m := NetMatch.new(sim, LocalInput.new())
	for i in 60:
		m.advance(1.0 / 60.0)
	assert_gt(sim.get_state().tick, 50)
	assert_true(is_same(m.confirmed_world(), sim.get_state()))
	assert_true(m._worlds.is_empty())

func test_the_horizon_stops_the_ticks() -> void:
	var sim := _sim()
	var m := NetMatch.new(sim, LocalInput.new())
	m.set_horizon(30)
	for i in 120:
		m.advance(1.0 / 60.0)
	assert_eq(sim.get_state().tick, 30)

func test_a_tick_going_forward_is_marked_so() -> void:
	var m := NetMatch.new(_sim(), LocalInput.new())
	var frame := m.advance(1.0 / 30.0)
	assert_gt(frame.ran, 0)
	for step in frame.steps:
		assert_true(step.forward)
