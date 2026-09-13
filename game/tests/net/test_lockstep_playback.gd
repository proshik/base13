extends GutTest

## The central property of the whole networking effort: two sides exchanging
## nothing but key presses hold a bit-for-bit identical world. There is no
## network here — packets are handed over directly, so the test is fast and
## catches mistakes in laying input out by tick rather than in the transport.

const TICKS := 900
const CHECK_EVERY := 60

func _sim() -> GameSim:
	return GameSim.new(Golden.level(), Golden.SEED, SimConfig.new(),
		Golden.LEVEL_NUMBER, 2)

func test_two_peers_stay_in_lockstep() -> void:
	var host_ls := Lockstep.new(0)
	var guest_ls := Lockstep.new(1)
	var host := _sim()
	var guest := _sim()
	var frames := Golden.frames()

	for t in TICKS:
		# Each captures their own press and sends it to the partner; it applies
		# on tick t + DELAY for both.
		var applied := Lockstep.tick_for_press(t)
		host_ls.submit_local(applied, frames[t][0])
		guest_ls.submit_remote(applied, frames[t][0])
		guest_ls.submit_local(applied, frames[t][1])
		host_ls.submit_remote(applied, frames[t][1])

		assert_true(host_ls.can_advance(t), "the host could not compute tick %d" % t)
		assert_true(guest_ls.can_advance(t), "the guest could not compute tick %d" % t)
		assert_eq(host_ls.inputs_for(t), guest_ls.inputs_for(t),
			"on tick %d the sides saw different input" % t)

		host.tick(host_ls.inputs_for(t))
		guest.tick(guest_ls.inputs_for(t))

		if t % CHECK_EVERY == 0 and host.state_hash() != guest.state_hash():
			fail_test("the worlds diverged on tick %d" % t)
			return

	assert_eq(host.state_hash(), guest.state_hash(),
		"nine hundred ticks of exchanging input without a single divergence")

func test_delayed_input_differs_from_immediate() -> void:
	# The input delay is not free: a game with it runs differently from one
	# without. This test keeps that honest, so nobody mistakes the delay for
	# cosmetics.
	var delayed := _sim()
	var immediate := _sim()
	var ls := Lockstep.new(0)
	var frames := Golden.frames()
	for t in 300:
		var applied := Lockstep.tick_for_press(t)
		ls.submit_local(applied, frames[t][0])
		ls.submit_remote(applied, frames[t][1])
		delayed.tick(ls.inputs_for(t))
		immediate.tick(frames[t])
	assert_ne(delayed.state_hash(), immediate.state_hash())

func test_a_missing_packet_stalls_instead_of_diverging() -> void:
	# The partner's packet has not arrived — computing is not allowed. That is
	# the protection against divergence: the game freezes rather than inventing
	# the other side's input.
	var ls := Lockstep.new(0)
	var stall := Lockstep.DELAY
	ls.submit_local(stall, Types.IN_UP)
	assert_false(ls.can_advance(stall))
	ls.submit_remote(stall, Types.IN_DOWN)
	assert_true(ls.can_advance(stall))
