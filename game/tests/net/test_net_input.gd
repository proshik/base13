extends GutTest

## Packets are fed in directly, with no socket: parsing and the reaction are
## checked here, while the transport is covered in test_session.gd.

var session: Session
var input: NetInput

func before_each() -> void:
	session = Session.new()
	input = NetInput.new(session, 0, func(_t: int) -> int: return 0)

## A link that goes down and comes back, the way the relay does: whatever is sent
## while it is down goes nowhere.
class Flaky extends Link:
	var up := true
	var wire: Array[int] = []    ## ticks of the input packets that got out
	var paces: Array[int] = []   ## leads sent
	func send(data: PackedByteArray) -> void:
		if not up:
			return
		var packet := Protocol.unpack(data)
		match packet.get("kind", Protocol.Kind.INVALID):
			Protocol.Kind.INPUT:
				wire.append(packet["tick"])
			Protocol.Kind.PACE:
				paces.append(packet["lead"])
	func linked() -> bool:
		return up

func _capture_through(net: NetInput, now: int) -> void:
	for t in now + 1:
		net.capture(t)

func test_our_press_takes_effect_two_ticks_later() -> void:
	var link := Flaky.new()
	var net := NetInput.new(link, 0, func(t: int) -> int: return Types.IN_UP if t == 3 else 0)
	_capture_through(net, 3)
	assert_eq(link.wire, [Rollback.START] as Array[int], "the first press goes to tick five")
	assert_eq(net.inputs_for(Rollback.START)[0], Types.IN_UP)

func test_a_tick_is_computed_on_a_guess() -> void:
	_capture_through(input, 3)
	assert_true(input.can_predict(Rollback.START), "the game waited for a packet")
	assert_eq(input.inputs_for(Rollback.START)[1], 0)

func test_a_wrong_guess_asks_to_step_back() -> void:
	_capture_through(input, 6)
	for t in range(5, 9):
		input.inputs_for(t)
	input.handle_packet(Protocol.pack_input(5, 0))
	input.handle_packet(Protocol.pack_input(6, Types.IN_LEFT))
	assert_eq(input.rollback_from(), 6)

func test_past_the_window_the_game_stands() -> void:
	_capture_through(input, 20)
	var stands := Rollback.START + Rollback.MAX_ROLLBACK
	assert_true(input.can_predict(stands - 1))
	assert_false(input.can_predict(stands))

func test_matching_hashes_keep_the_game_running() -> void:
	input.after_confirmed(60, 12345)
	input.handle_packet(Protocol.pack_hash(60, 12345))
	assert_false(input.desynced)

func test_diverging_hashes_stop_the_game() -> void:
	input.after_confirmed(60, 12345)
	input.handle_packet(Protocol.pack_hash(60, 999))
	assert_true(input.desynced, "a divergence must stop the game")
	assert_eq(input.desync_tick, 60)
	_capture_through(input, 3)
	assert_false(input.can_predict(Rollback.START), "after a desync no further ticks may be computed")

func test_a_partner_hash_ahead_of_us_is_compared_when_we_get_there() -> void:
	input.handle_packet(Protocol.pack_hash(60, 999))
	assert_false(input.desynced, "not having got there is not a divergence")
	input.after_confirmed(60, 12345)
	assert_true(input.desynced, "the hash that waited was never compared")

func test_input_for_a_tick_far_ahead_is_dropped() -> void:
	var before: int = input._rollback._remote.size()
	input.handle_packet(Protocol.pack_input(2000000000, Types.IN_FIRE))
	input.handle_packet(Protocol.pack_input(NetInput.FARTHEST_AHEAD + 1, Types.IN_FIRE))
	assert_eq(input._rollback._remote.size(), before, "input from the far future was kept")
	input.handle_packet(Protocol.pack_input(NetInput.FARTHEST_AHEAD, Types.IN_FIRE))
	assert_eq(input._rollback._remote.size(), before + 1, "input within reach was dropped")

func test_a_hash_far_ahead_is_dropped() -> void:
	input.handle_packet(Protocol.pack_hash(2000000000, 1))
	assert_eq(input._rollback._remote_hashes.size(), 0, "a waiting hash from the far future was kept")

func test_garbage_from_the_network_is_ignored() -> void:
	input.handle_packet(PackedByteArray())
	input.handle_packet(PackedByteArray([99, 1, 2]))
	assert_false(input.desynced)

func test_guest_sees_the_same_player_order_as_the_host() -> void:
	var guest := NetInput.new(Session.new(), 1, func(_t: int) -> int: return 0)
	_capture_through(guest, 3)
	guest.handle_packet(Protocol.pack_input(Rollback.START, Types.IN_UP))
	assert_eq(guest.inputs_for(Rollback.START)[0], Types.IN_UP)

func _stand() -> int:
	_capture_through(input, 20)
	return Rollback.START + Rollback.MAX_ROLLBACK

func test_a_short_stall_says_nothing() -> void:
	var tick := _stand()
	for i in 10:
		input.can_predict(tick)
	assert_false(input.waiting_for_partner(), "ordinary jitter must not put a caption on the screen")

func test_a_long_stall_is_worth_saying_out_loud() -> void:
	var tick := _stand()
	for i in NetInput.STALL_BEFORE_SAYING:
		input.can_predict(tick)
	assert_true(input.waiting_for_partner())

func test_the_partner_coming_back_clears_it() -> void:
	var tick := _stand()
	for i in NetInput.STALL_BEFORE_SAYING:
		input.can_predict(tick)
	for t in range(Rollback.START, tick):
		input.handle_packet(Protocol.pack_input(t, 0))
	assert_true(input.can_predict(tick))
	assert_false(input.waiting_for_partner(), "the caption must go when the stall does")

func test_a_finished_input_leaves_the_link_alone() -> void:
	var link := Session.new()
	var old := NetInput.new(link, 0)
	var gone: WeakRef = weakref(old)
	assert_eq(link.packet_received.get_connections().size(), 1)
	old = null
	assert_null(gone.get_ref(), "the link kept the old input alive")
	assert_eq(link.packet_received.get_connections().size(), 0)

## While the link is down the game carries on on guesses, and our input for those
## ticks is lost: the relay journals only what reached it. Unless it goes out again
## once the link is back, the partner stands at the window for good.
func test_input_lost_while_the_link_was_down_goes_out_again() -> void:
	var link := Flaky.new()
	var net := NetInput.new(link, 0, func(_t: int) -> int: return 0)
	for t in 10:
		net.capture(t)
		net.note_tick(t)
	link.up = false
	net.pump()
	for t in range(10, 20):
		net.capture(t)
		net.note_tick(t)
	link.up = true
	link.wire.clear()
	net.pump()
	for tick in range(10 + Rollback.INPUT_DELAY, 20 + Rollback.INPUT_DELAY):
		assert_true(link.wire.has(tick), "our input for tick %d was never sent again" % tick)

func test_a_link_that_stays_up_sends_nothing_again() -> void:
	var link := Flaky.new()
	var net := NetInput.new(link, 0, func(_t: int) -> int: return 0)
	_capture_through(net, 3)
	link.wire.clear()
	for i in 5:
		net.pump()
	assert_eq(link.wire, [] as Array[int], "a healthy link must not breed traffic")

## A level built while the relay is still greeting: our first input goes nowhere,
## and the welcome comes in with the first pump.
func test_input_sent_before_the_link_was_up_goes_out_when_it_is() -> void:
	var link := Flaky.new()
	link.up = false
	var net := NetInput.new(link, 0, func(_t: int) -> int: return 0)
	_capture_through(net, 8)
	link.up = true
	net.pump()
	for tick in range(Rollback.START, 11):
		assert_true(link.wire.has(tick), "tick %d never went out" % tick)

class Clocked extends NetInput:
	var now := 0
	func _clock() -> int:
		return now

## A partner still finishing the last level can swallow our first input with the
## link up the whole time. A tick standing a second sends it again.
func test_a_tick_standing_a_second_on_a_live_link_sends_input_again() -> void:
	var link := Flaky.new()
	var net := Clocked.new(link, 0, func(_t: int) -> int: return 0)
	_capture_through(net, 20)
	var tick := Rollback.START + Rollback.MAX_ROLLBACK
	net.can_predict(tick)
	link.wire.clear()
	net.now += NetInput.RESEND_MS
	net.can_predict(tick)
	assert_true(link.wire.has(Rollback.START), "the stand never sent our input again")

func test_without_word_from_the_partner_nothing_is_skipped() -> void:
	for t in 60:
		input.note_tick(t)
		assert_false(input.should_skip(t + 1))

## Our lead is our tick less theirs as their input shows it; theirs arrives in a
## pace packet. Well ahead of them — let a tick go, but not two in a row.
func test_running_ahead_of_the_partner_lets_a_tick_go() -> void:
	for t in range(Rollback.START, 21):
		input.handle_packet(Protocol.pack_input(t, 0))
	for t in 41:
		input.note_tick(t)
	input.handle_packet(Protocol.pack_pace(18, 0))
	assert_true(input.should_skip(41), "22 ticks ahead of a partner who is not ahead of us")
	assert_false(input.should_skip(42), "two ticks let go one after another")
	assert_true(input.should_skip(41 + NetInput.SKIP_SPACING))

func test_being_as_far_ahead_as_the_partner_is_in_step() -> void:
	for t in range(Rollback.START, 21):
		input.handle_packet(Protocol.pack_input(t, 0))
	for t in 41:
		input.note_tick(t)
	input.handle_packet(Protocol.pack_pace(18, 21))
	assert_false(input.should_skip(41))

func test_the_lead_goes_out_every_few_ticks() -> void:
	var link := Flaky.new()
	var net := NetInput.new(link, 0, func(_t: int) -> int: return 0)
	net.handle_packet(Protocol.pack_input(Rollback.START, 0))
	for t in 30:
		net.note_tick(t)
	assert_eq(link.paces.size(), 3, "a pace packet every %d ticks" % NetInput.PACE_EVERY)

class Reporter extends Link:
	var paces: Array[Dictionary] = []
	var desyncs := 0
	func report_pace(pace: Dictionary) -> void:
		paces.append(pace)
	func report_desync() -> void:
		desyncs += 1

## Three hundred ticks, the partner's input twelve ticks behind; every sixtieth
## tick from the thirtieth it is thirteen behind for fifty milliseconds — a stop.
## On `frozen_at` the stand lasts longer than FROZEN_MS instead.
func _play(net: Clocked, from: int, to: int, frozen_at := -1) -> void:
	for t in range(from, to):
		net.capture(t)
		if t >= 17 and t % 60 == 30:
			assert_false(net.can_predict(t), "tick %d was meant to stand" % t)
			net.now += NetInput.FROZEN_MS + 50 if t == frozen_at else 50
		if t - 12 >= Rollback.START:
			net.handle_packet(Protocol.pack_input(t - 12, 0))
		assert_true(net.can_predict(t), "tick %d is not computed" % t)
		net.note_tick(t)
		net.now += 1000 / 60

## The server hears the figures the `[net]` line prints, once a line.
func test_each_line_sends_one_report() -> void:
	var link := Reporter.new()
	var net := Clocked.new(link, 0, func(_t: int) -> int: return 0, func() -> float: return 59.94)
	_play(net, 0, NetInput.REPORT_EVERY - 1)
	assert_eq(link.paces.size(), 0)
	_play(net, NetInput.REPORT_EVERY - 1, NetInput.REPORT_EVERY)
	assert_eq(link.paces.size(), 1)
	if link.paces.size() != 1:
		return
	# 299 ticks of 16 ms and five stops of 50 took 5034 ms against 5000 due: 99 %.
	assert_eq(link.paces[0], {"speed": 99, "waits": 5, "delay": Rollback.INPUT_DELAY, "fps": 60})
	for key in link.paces[0]:
		assert_eq(typeof(link.paces[0][key]), TYPE_INT, "%s is not a whole number" % key)

## A stand longer than FROZEN_MS is somebody's frame loop standing still — the
## partner's hidden tab, a dropped link — and not a network falling short. The
## server hears only the short stops as waits, the way 0.5.0 reported them; told
## otherwise, it would count a partner looking at another tab as a slow network.
## The stand still shows on the line a human reads.
func test_a_long_stand_is_not_reported_as_a_wait() -> void:
	var link := Reporter.new()
	var net := Clocked.new(link, 0, func(_t: int) -> int: return 0, func() -> float: return 60.0)
	_play(net, 0, NetInput.REPORT_EVERY, 90)
	assert_eq(link.paces.size(), 1)
	if link.paces.size() != 1:
		return
	# 299 ticks of 16 ms, four stops of 50 and a stand of 200: 5184 ms, 96 %.
	assert_eq(link.paces[0], {"speed": 96, "waits": 4, "delay": Rollback.INPUT_DELAY, "fps": 60})
	assert_string_contains(net.last_report, "STOP 4 FRZ 1")

func test_a_desync_is_reported_once() -> void:
	var link := Reporter.new()
	var net := NetInput.new(link, 0)
	net.after_confirmed(60, 12345)
	net.after_confirmed(120, 12345)
	net.handle_packet(Protocol.pack_hash(60, 999))
	assert_eq(link.desyncs, 1)
	net.handle_packet(Protocol.pack_hash(120, 999))
	assert_true(net.desynced)
	assert_eq(link.desyncs, 1, "the same desync was reported twice")
	assert_eq(net.desync_tick, 60, "the first divergence is the one to show")

func test_matching_hashes_report_no_desync() -> void:
	var link := Reporter.new()
	var net := NetInput.new(link, 0)
	net.after_confirmed(60, 12345)
	net.handle_packet(Protocol.pack_hash(60, 12345))
	assert_eq(link.desyncs, 0)
