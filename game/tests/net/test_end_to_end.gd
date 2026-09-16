extends GutTest

## The strongest test of this stage: two sides play a game through a real
## socket, exchanging nothing but key presses, and the worlds must match to the
## last bit. Everything below the screens is checked here in full.

const PORT := 27213
const TICKS := 180
const SPIN_LIMIT := 200

var host_session: Session
var guest_session: Session

func before_each() -> void:
	host_session = Session.new()
	guest_session = Session.new()

func after_each() -> void:
	host_session.close()
	guest_session.close()

func _sim() -> GameSim:
	return GameSim.new(Golden.level(), Golden.SEED, SimConfig.new(),
		Golden.LEVEL_NUMBER, 2)

func test_two_peers_play_a_level_over_a_socket() -> void:
	assert_eq(host_session.host(PORT), OK)
	assert_eq(guest_session.join("ws://127.0.0.1:%d" % PORT), OK)

	var connected := false
	for i in SPIN_LIMIT:
		host_session.poll()
		guest_session.poll()
		if host_session.state == Session.State.CONNECTED \
				and guest_session.state == Session.State.CONNECTED:
			connected = true
			break
		OS.delay_msec(5)
	assert_true(connected, "the sides did not connect")

	var frames := Golden.frames()
	var sides: Array[NetMatch] = [
		NetMatch.new(_sim(), NetInput.new(host_session, 0, func(t: int) -> int: return frames[t][0])),
		NetMatch.new(_sim(), NetInput.new(guest_session, 1, func(t: int) -> int: return frames[t][1])),
	]
	for side in sides:
		side.set_horizon(TICKS)
	var done := false
	for i in SPIN_LIMIT * 4:
		for side in sides:
			side.advance(1.0 / 60.0)
		if sides[0].confirmed_world().tick == TICKS and sides[1].confirmed_world().tick == TICKS:
			done = true
			break
		OS.delay_msec(2)
	assert_true(done, "the match never confirmed tick %d: host %d, guest %d" % [
		TICKS, sides[0].confirmed_world().tick, sides[1].confirmed_world().tick])
	if not done:
		return
	var expected := ReferenceRun.hash_of(frames, TICKS)
	for side in sides:
		assert_eq(side.confirmed_world().hash_value(), expected, "the worlds are not the match's")
		assert_false((side.source() as NetInput).desynced, "the hash comparison fired")
