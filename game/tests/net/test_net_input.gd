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

## A new NetInput for every level subscribes to the same link. If the
## subscription kept the old one alive, every finished level would stay behind
## listening, and a reference cycle between two RefCounted is never collected.
## It does not: a method's callable does not hold its object, and the connection
## goes when the object does.
func test_a_finished_input_leaves_the_link_alone() -> void:
	var link := Session.new()
	var old := NetInput.new(link, 0)
	var gone: WeakRef = weakref(old)
	assert_eq(link.packet_received.get_connections().size(), 1)
	old = null
	assert_null(gone.get_ref(), "the link kept the old input alive")
	assert_eq(link.packet_received.get_connections().size(), 0,
		"the old input is still subscribed")

## The first level through the relay starts where a path to the relay and back
## needs to be: five a side covers a circle of 130 ms, eight covers 230. A local
## network starts at the smallest delay. After that a level starts where the
## last one ended.
func test_the_first_level_starts_at_the_delay_its_link_needs() -> void:
	assert_eq(NetInput.starting_delay(Session.new()), Lockstep.DELAY)
	assert_eq(NetInput.starting_delay(Relay.new()), NetInput.RELAY_START)

func test_a_later_level_starts_where_the_last_one_ended() -> void:
	assert_eq(NetInput.starting_delay(Relay.new(), 12), 12)
	assert_eq(NetInput.starting_delay(Session.new(), 7), 7)
	assert_eq(NetInput.starting_delay(Relay.new(), 99), NetInput.MAX_DELAY)

## A link that goes down and comes back, the way the relay does: whatever is sent
## while it is down goes nowhere.
class Flaky extends Link:
	var up := true
	var wire: Array[int] = []    ## ticks of the input packets that got out
	func send(data: PackedByteArray) -> void:
		if not up:
			return
		var packet := Protocol.unpack(data)
		if packet.get("kind", Protocol.Kind.INVALID) == Protocol.Kind.INPUT:
			wire.append(packet["tick"])
	func linked() -> bool:
		return up

## While the link is down the game carries on for a while on what the partner
## already sent, and our input for those ticks is lost: the relay journals only
## what reached it. Unless it goes out again once the link is back, the partner
## waits for it forever.
##
## Again from a whole delay back, not just past our last tick: the partner may
## hold a larger delay than ours and be that far behind, still needing input for
## ticks we have already computed.
func test_input_lost_while_the_link_was_down_goes_out_again() -> void:
	var link := Flaky.new()
	var net := NetInput.new(link, 0, func(_t: int) -> int: return 0)
	for t in range(Lockstep.DELAY, 40):
		net.handle_packet(Protocol.pack_input(t, 0))
	for t in 10:
		net.capture(t)
		assert_true(net.can_advance(t))
		net.after_tick(t, 0)
	link.up = false
	net.pump()
	for t in range(10, 20):
		net.capture(t)
		assert_true(net.can_advance(t))
		net.after_tick(t, 0)
	link.up = true
	link.wire.clear()
	net.pump()
	for tick in range(10 + Lockstep.DELAY, 20 + Lockstep.DELAY):
		assert_true(link.wire.has(tick),
			"our input for tick %d was lost with the link and never sent again" % tick)

func test_a_link_that_stays_up_sends_nothing_again() -> void:
	var link := Flaky.new()
	var net := NetInput.new(link, 0, func(_t: int) -> int: return 0)
	net.capture(0)
	link.wire.clear()
	for i in 5:
		net.pump()
	assert_eq(link.wire, [] as Array[int], "a healthy link must not breed traffic")
