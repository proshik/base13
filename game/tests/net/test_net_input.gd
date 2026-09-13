extends GutTest

## Packets are fed in directly, with no socket: parsing and the reaction are
## checked here, while the transport is covered separately in test_session.gd.

var session: Session
var input: NetInput

func before_each() -> void:
	session = Session.new()
	input = NetInput.new(session, 0)

func test_remote_input_unblocks_the_tick() -> void:
	var tick := Lockstep.DELAY
	input.capture(0)   # our press goes to tick DELAY
	assert_false(input.can_advance(tick), "the other side's input has not arrived yet")
	input.handle_packet(Protocol.pack_input(tick, Types.IN_LEFT))
	assert_true(input.can_advance(tick))
	assert_eq(input.inputs_for(tick)[1], Types.IN_LEFT)

func test_matching_hashes_keep_the_game_running() -> void:
	input.after_tick(60, 12345)
	input.handle_packet(Protocol.pack_hash(60, 12345))
	assert_false(input.desynced)

func test_diverging_hashes_stop_the_game() -> void:
	input.after_tick(60, 12345)
	input.handle_packet(Protocol.pack_hash(60, 999))
	assert_true(input.desynced, "a divergence must stop the game")
	assert_eq(input.desync_tick, 60)
	assert_false(input.can_advance(Lockstep.DELAY),
		"after a desync no further ticks may be computed")

func test_input_for_a_tick_far_ahead_is_dropped() -> void:
	# An honest partner is never further ahead than both input delays: they
	# cannot compute a tick without our input for it. A packet for tick two
	# billion would sit in the buffer forever, and a stream of them grows it
	# until the game stalls — forget_before walks every key on every tick.
	var before: int = input._lockstep._remote.size()
	input.handle_packet(Protocol.pack_input(2000000000, Types.IN_FIRE))
	input.handle_packet(Protocol.pack_input(NetInput.FARTHEST_AHEAD + 1, Types.IN_FIRE))
	assert_eq(input._lockstep._remote.size(), before, "input from the far future was kept")
	assert_lt(input._lockstep.cover(0), NetInput.FARTHEST_AHEAD,
		"a dropped packet must not count as input the game can rest on")
	input.handle_packet(Protocol.pack_input(NetInput.FARTHEST_AHEAD, Types.IN_FIRE))
	assert_eq(input._lockstep._remote.size(), before + 1, "input within reach was dropped")

func test_garbage_from_the_network_is_ignored() -> void:
	# The network delivers truncated and foreign data alike. It must not crash
	# the game.
	input.handle_packet(PackedByteArray())
	input.handle_packet(PackedByteArray([99, 1, 2]))
	assert_false(input.desynced)

func test_hash_for_a_tick_we_have_not_reached_is_not_a_desync() -> void:
	# The partner ran ahead of us with the comparison — an everyday occurrence,
	# not a fault.
	input.handle_packet(Protocol.pack_hash(600, 42))
	assert_false(input.desynced)

func test_guest_sees_the_same_player_order_as_the_host() -> void:
	var guest := NetInput.new(Session.new(), 1)
	var tick := Lockstep.DELAY
	guest.capture(0)
	guest.handle_packet(Protocol.pack_input(tick, Types.IN_UP))
	# The guest's own tank is the second one: player order is identical on both
	# sides.
	assert_eq(guest.inputs_for(tick)[0], Types.IN_UP)

## A partner who switched away from the tab is not a broken link: the socket is
## fine, only nothing arrives through it. The picture freezes all the same, and a
## freeze with no caption reads as our hang — so the screen has to be able to
## tell "the link is gone" from "the partner is not sending".
func test_a_short_stall_says_nothing() -> void:
	var tick := Lockstep.DELAY
	for i in 10:
		input.can_advance(tick)
	assert_false(input.waiting_for_partner(),
		"ordinary jitter must not put a caption on the screen")

func test_a_long_stall_is_worth_saying_out_loud() -> void:
	var tick := Lockstep.DELAY
	for i in NetInput.STALL_BEFORE_SAYING:
		input.can_advance(tick)
	assert_true(input.waiting_for_partner(),
		"a second of silence is no longer jitter — the human deserves to know why")

func test_the_partner_coming_back_clears_it() -> void:
	var tick := Lockstep.DELAY
	for i in NetInput.STALL_BEFORE_SAYING:
		input.can_advance(tick)
	input.capture(0)
	input.handle_packet(Protocol.pack_input(tick, Types.IN_LEFT))
	assert_true(input.can_advance(tick))
	assert_false(input.waiting_for_partner(), "the caption must go when the input does not")
