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
	var host_input := NetInput.new(host_session, 0,
		func(t: int) -> int: return frames[t][0])
	var guest_input := NetInput.new(guest_session, 1,
		func(t: int) -> int: return frames[t][1])
	var host := _sim()
	var guest := _sim()

	for t in TICKS:
		host_input.capture(t)
		guest_input.capture(t)

		var ready := false
		for i in SPIN_LIMIT:
			host_input.pump()
			guest_input.pump()
			if host_input.can_advance(t) and guest_input.can_advance(t):
				ready = true
				break
			OS.delay_msec(2)
		assert_true(ready, "tick %d never got both sides' input" % t)
		if not ready:
			return

		assert_eq(host_input.inputs_for(t), guest_input.inputs_for(t),
			"on tick %d the sides saw different input" % t)
		host.tick(host_input.inputs_for(t))
		guest.tick(guest_input.inputs_for(t))
		host_input.after_tick(t, host.state_hash())
		guest_input.after_tick(t, guest.state_hash())

		if host.state_hash() != guest.state_hash():
			fail_test("the worlds diverged on tick %d" % t)
			return

	assert_eq(host.state_hash(), guest.state_hash())
	assert_false(host_input.desynced, "the hash comparison should not have fired")
	assert_false(guest_input.desynced)
