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

## The end of a level stops the ticks at the horizon, and a side standing there
## for the partner's word on its last ticks waits just as it would at the window:
## a packet lost there held the game for good. It sends again what it sent, and
## nothing past it.
func test_standing_at_the_horizon_sends_input_again() -> void:
	var link := Flaky.new()
	var net := Clocked.new(link, 0, func(_t: int) -> int: return 0)
	var horizon := Rollback.START + 6
	for t in horizon:
		net.capture(t)
		net.note_tick(t)
	var sent := link.wire.duplicate()
	net.stand_at_horizon(horizon)
	link.wire.clear()
	net.now += NetInput.RESEND_MS - 1
	net.stand_at_horizon(horizon)
	assert_eq(link.wire, [] as Array[int], "sent again before a second had passed")
	net.now += 1
	net.stand_at_horizon(horizon)
	assert_true(link.wire.has(Rollback.START), "the stand at the horizon never sent our input again")
	for tick in link.wire:
		assert_true(sent.has(tick), "tick %d went out past what was sent before the horizon" % tick)

func test_a_confirmed_horizon_sends_nothing_again() -> void:
	var link := Flaky.new()
	var net := Clocked.new(link, 0, func(_t: int) -> int: return 0)
	var horizon := Rollback.START + 6
	for t in horizon:
		net.capture(t)
		net.note_tick(t)
		net.handle_packet(Protocol.pack_input(t, 0))
	link.wire.clear()
	for i in 3:
		net.stand_at_horizon(horizon)
		net.now += NetInput.RESEND_MS
	assert_eq(link.wire, [] as Array[int], "nothing is owed, yet input went out again")

## The same through NetMatch: the loop stops at the horizon before it would ask
## whether a tick may be computed, so the stand has to be named there.
func test_a_match_standing_at_the_horizon_sends_input_again() -> void:
	var link := Flaky.new()
	var net := Clocked.new(link, 0, func(_t: int) -> int: return 0)
	var sim := GameSim.new(Golden.level(), Golden.SEED, SimConfig.new(), Golden.LEVEL_NUMBER, 2)
	var m := NetMatch.new(sim, net)
	var horizon := Rollback.START + 6
	m.set_horizon(horizon)
	for i in 30:
		net.now += 16
		m.advance(1.0 / 60.0)
	assert_eq(sim.get_state().tick, horizon, "the match never reached the horizon")
	var sent_through: int = link.wire.max()
	link.wire.clear()
	net.now += NetInput.RESEND_MS
	m.advance(1.0 / 60.0)
	assert_true(link.wire.has(Rollback.START), "the match stood at the horizon and sent nothing again")
	assert_lte(link.wire.max() if not link.wire.is_empty() else 0, sent_through,
		"input went out past the horizon")

## The events a hang is read from, kept rather than printed.
class Logged extends Clocked:
	var lines: Array[String] = []
	func _log(line: String) -> void:
		lines.append(line)

func test_a_level_says_where_it_ends_and_that_it_is_done() -> void:
	var net := Logged.new(Flaky.new(), 1, func(_t: int) -> int: return 0)
	net.level_began(3)
	net.level_ends(1234, 1144, 1146)
	net.level_done(1234)
	assert_eq(net.lines, [
		"level 3 begins, slot 1",
		"level 3 ends on tick 1234: ended in 1144, seen at 1146",
		"level 3 done on tick 1234",
	] as Array[String])

## The same events, told to the server: its log is where a hang between two
## levels is read when nobody kept the browser's console.
func test_the_level_events_go_to_the_server() -> void:
	var link := Reporter.new()
	var net := Logged.new(link, 1, func(_t: int) -> int: return 0)
	net.level_began(3)
	net.level_ends(1234, 1144, 1146)
	net.level_done(1234)
	assert_eq(link.notes, [
		["stage_begins", {"stage": 3}],
		["stage_ends", {"stage": 3, "tick": 1234, "ended": 1144, "seen": 1146}],
		["stage_done", {"stage": 3, "tick": 1234}],
	])

## A stand says once why input went out again, not once a second.
func test_a_stand_at_the_horizon_is_told_once() -> void:
	var link := Flaky.new()
	var net := Logged.new(link, 0, func(_t: int) -> int: return 0)
	net.level_began(3)
	var horizon := Rollback.START + 6
	for t in horizon:
		net.capture(t)
		net.note_tick(t)
	net.lines.clear()
	for i in 4:
		net.stand_at_horizon(horizon)
		net.now += NetInput.RESEND_MS
	assert_eq(net.lines, [
		"level 3: standing at the horizon %d for 1000 ms, confirmed through %d, input sent again for %d..%d"
			% [horizon, Rollback.START - 1, Rollback.START, horizon - 1 + Rollback.INPUT_DELAY],
	] as Array[String])

func test_a_stand_at_the_window_is_told_once() -> void:
	var net := Logged.new(Flaky.new(), 0, func(_t: int) -> int: return 0)
	net.level_began(2)
	_capture_through(net, 20)
	var tick := Rollback.START + Rollback.MAX_ROLLBACK
	for i in 4:
		net.can_predict(tick)
		net.now += NetInput.RESEND_MS
	assert_eq(net.lines.size(), 2, "%s" % [net.lines])
	assert_eq(net.lines[1], "level 2: tick %d stood 1000 ms, confirmed through %d, input sent again for %d..%d"
		% [tick, Rollback.START - 1, Rollback.START, 20 + Rollback.INPUT_DELAY])

## And the server hears it the same once, with the figures of the line.
func test_a_stand_tells_the_server_once() -> void:
	var link := Reporter.new()
	var net := Logged.new(link, 0, func(_t: int) -> int: return 0)
	net.level_began(2)
	_capture_through(net, 20)
	var tick := Rollback.START + Rollback.MAX_ROLLBACK
	for i in 4:
		net.can_predict(tick)
		net.now += NetInput.RESEND_MS
	assert_eq(link.notes, [
		["stage_begins", {"stage": 2}],
		["stood", {"stage": 2, "tick": tick, "ms": 1000, "confirmed": Rollback.START - 1,
			"from": Rollback.START, "through": 20 + Rollback.INPUT_DELAY}],
	])

func test_a_stand_at_the_horizon_tells_the_server() -> void:
	var link := Reporter.new()
	var net := Logged.new(link, 0, func(_t: int) -> int: return 0)
	net.level_began(3)
	var horizon := Rollback.START + 6
	for t in horizon:
		net.capture(t)
		net.note_tick(t)
	for i in 3:
		net.stand_at_horizon(horizon)
		net.now += NetInput.RESEND_MS
	assert_eq(link.notes.size(), 2, "%s" % [link.notes])
	assert_eq(link.notes[-1], ["horizon", {"stage": 3, "tick": horizon, "ms": 1000,
		"confirmed": Rollback.START - 1, "from": Rollback.START,
		"through": horizon - 1 + Rollback.INPUT_DELAY}])

## A link that comes back lets the server hear why input came again, which in
## its window line otherwise reads as a burst held by the network.
func test_a_link_back_tells_the_server() -> void:
	var link := FlakyReporter.new()
	var net := Logged.new(link, 0, func(_t: int) -> int: return 0)
	net.level_began(1)
	_capture_through(net, 8)
	link.up = false
	net.pump()
	link.up = true
	net.pump()
	assert_eq(link.notes[-1], ["link_back", {"stage": 1, "from": Rollback.START,
		"through": 8 + Rollback.INPUT_DELAY}])

func test_a_link_back_is_told() -> void:
	var link := Flaky.new()
	var net := Logged.new(link, 0, func(_t: int) -> int: return 0)
	net.level_began(1)
	_capture_through(net, 8)
	link.up = false
	net.pump()
	link.up = true
	net.pump()
	assert_eq(net.lines[-1], "level 1: link back, input sent again for %d..%d"
		% [Rollback.START, 8 + Rollback.INPUT_DELAY])

func test_without_word_from_the_partner_nothing_is_skipped() -> void:
	for t in 60:
		input.note_tick(t)
		assert_false(input.should_skip(t + 1))

## Our lead is our tick less theirs as their input shows it; theirs arrives in a
## pace packet. Steadily well ahead of them — let a tick go, but not two in a row.
func test_running_ahead_of_the_partner_lets_a_tick_go() -> void:
	for t in 41:
		if t - 18 >= Rollback.START:
			input.handle_packet(Protocol.pack_input(t - 18, 0))
		input.note_tick(t)
	input.handle_packet(Protocol.pack_pace(18, 0))
	assert_true(input.should_skip(41), "20 ticks ahead of a partner who is not ahead of us")
	assert_false(input.should_skip(42), "two ticks let go one after another")
	assert_true(input.should_skip(41 + NetInput.SKIP_SPACING))

## A partner in step whose packets stall for a quarter of a second each second
## and then arrive together, as on the Wi-Fi of 2026-09-24. While they stall our
## lead reads high — "lead 7 against 1" — but it is the path, not the pace, and
## letting a tick go for it dropped up to nine a stretch for nothing.
func test_a_burst_of_late_packets_lets_no_tick_go() -> void:
	var skipped := 0
	var delivered := Rollback.START - 1
	for t in 600:
		var stalled := t % 60 >= 45 and t % 60 < 59
		if not stalled:
			while delivered < t + 1:
				delivered += 1
				if delivered >= Rollback.START:
					input.handle_packet(Protocol.pack_input(delivered, 0))
		if input.should_skip(t):
			skipped += 1
		input.note_tick(t)
		if t % NetInput.PACE_EVERY == 0:
			input.handle_packet(Protocol.pack_pace(t, 1))
	assert_eq(skipped, 0, "ticks were let go for late packets")

func test_being_as_far_ahead_as_the_partner_is_in_step() -> void:
	for t in range(Rollback.START, 21):
		input.handle_packet(Protocol.pack_input(t, 0))
	for t in 41:
		input.note_tick(t)
	input.handle_packet(Protocol.pack_pace(18, 21))
	assert_false(input.should_skip(41))

## A partner in step on a local network: their input for tick `t + 2` arrives as
## we compute `t`. Up to `through`, then they stop, the way a hidden tab stops.
func _calm_then_silent(net: Clocked, through: int) -> void:
	for t in through + 1:
		net.capture(t)
		net.handle_packet(Protocol.pack_input(t + Rollback.INPUT_DELAY, 0))
		assert_true(net.can_predict(t))
		assert_false(net.should_skip(t), "tick %d was let go in calm play" % t)
		net.note_tick(t)
		net.now += 1000 / 60

## Guesses to the window's edge, then a stand of two seconds. Returns the tick
## that stands.
func _stand_for_two_seconds(net: Clocked, from: int) -> int:
	var t := from
	while true:
		net.capture(t)
		if not net.can_predict(t):
			break
		net.note_tick(t)
		net.now += 1000 / 60
		t += 1
	for i in 120:
		assert_false(net.can_predict(t))
		net.now += 1000 / 60
	return t

## The partner is back from the tick they stopped on, `lag` ticks further off than
## before. Each call is one of their frames and one of ours on the standing tick.
func _partner_back(net: Clocked, partner_tick: int, lag: int) -> int:
	net.handle_packet(Protocol.pack_input(partner_tick + Rollback.INPUT_DELAY - lag, 0))
	net.now += 1000 / 60
	return partner_tick + 1

## A stand leaves this side a whole window ahead of a partner back from a hidden
## tab. It lets ticks go one after another while the game is still standing, until
## its lead is what it was before the partner left — not one in twenty for seconds.
func test_after_a_long_stand_the_lead_is_shed_at_once() -> void:
	var net := Clocked.new(Flaky.new(), 0, func(_t: int) -> int: return 0)
	_calm_then_silent(net, 60)
	var standing := _stand_for_two_seconds(net, 61)
	var partner := 61
	var shed := 0
	var resumed := false
	for i in 40:
		partner = _partner_back(net, partner, 0)
		net.capture(standing)
		if not net.can_predict(standing):
			continue
		if net.should_skip(standing):
			assert_false(resumed, "a tick was let go after the game had moved again")
			shed += 1
			continue
		resumed = true
		net.note_tick(standing)
		standing += 1
	assert_true(resumed, "the game never moved again")
	assert_gt(shed, 5, "the lead the stand left was not shed")
	assert_lte(net._lead(), net._calm_lead + NetInput.LEAD_TOLERATED + 1,
		"the game moved again still ahead of the partner")

## A lead that cannot be shed must not freeze the game. A partner who comes back
## just far enough for the standing tick to be guessed, and stalls again, leaves
## the lead where it is; shedding gives up after a bounded number of ticks and the
## tick is computed.
func test_shedding_a_lead_is_bounded() -> void:
	var net := Clocked.new(Flaky.new(), 0, func(_t: int) -> int: return 0)
	_calm_then_silent(net, 60)
	var standing := _stand_for_two_seconds(net, 61)
	var last_heard := 60 + Rollback.INPUT_DELAY
	for t in range(last_heard + 1, standing - Rollback.MAX_ROLLBACK + 1):
		net.handle_packet(Protocol.pack_input(t, 0))
	var shed := 0
	for i in 200:
		net.capture(standing)
		assert_true(net.can_predict(standing), "the standing tick cannot be guessed")
		if not net.should_skip(standing):
			break
		shed += 1
		net.now += 1000 / 60
	assert_eq(shed, NetInput.RECOVERY_LIMIT)

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
	var desync_ticks: Array[int] = []
	var notes: Array = []   ## [what, figures] pairs
	func report_pace(pace: Dictionary) -> void:
		paces.append(pace)
	func report_desync(tick := -1) -> void:
		desyncs += 1
		desync_ticks.append(tick)
	func report_note(what: String, figures := {}) -> void:
		notes.append([what, figures])

## A Reporter that goes down and comes back, the way Flaky does.
class FlakyReporter extends Reporter:
	var up := true
	func linked() -> bool:
		return up

## The four figures every server reads, out of a report of the current shape.
func _four(pace: Dictionary) -> Dictionary:
	return {"speed": pace.get("speed"), "waits": pace.get("waits"), "delay": pace.get("delay"),
		"fps": pace.get("fps")}

## Every figure of the `[net]` line, under the names the server reads them by.
const PACE_KEYS := ["speed", "waits", "delay", "fps", "frozen", "frozen_longest_ms",
	"stops_longest_ms", "rollbacks", "deepest", "resim_ms", "skips", "lead", "partner_lead",
	"longest_frame_ms"]

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
	assert_eq(_four(link.paces[0]), {"speed": 99, "waits": 5, "delay": Rollback.INPUT_DELAY, "fps": 60})
	assert_eq(link.paces[0].keys(), PACE_KEYS, "the report is not every figure of the line")
	assert_eq(link.paces[0]["stops_longest_ms"], 50)
	assert_eq(link.paces[0]["frozen"], 0)
	# Twelve ticks behind as their input shows it, which is the delay less.
	assert_eq(link.paces[0]["lead"], 12 + Rollback.INPUT_DELAY)
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
	assert_eq(_four(link.paces[0]), {"speed": 96, "waits": 4, "delay": Rollback.INPUT_DELAY, "fps": 60})
	# The stand itself goes to the server's log, apart.
	assert_eq(link.paces[0]["frozen"], 1)
	assert_eq(link.paces[0]["frozen_longest_ms"], NetInput.FROZEN_MS + 50)
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
	assert_eq(link.desync_ticks, [60] as Array[int], "the server was not told the tick")

func test_matching_hashes_report_no_desync() -> void:
	var link := Reporter.new()
	var net := NetInput.new(link, 0)
	net.after_confirmed(60, 12345)
	net.handle_packet(Protocol.pack_hash(60, 12345))
	assert_eq(link.desyncs, 0)

## A frame far longer than a tick is this machine standing still. It sends
## nothing meanwhile, and the server's window line cannot tell that from a
## network holding our packets: on 2026-09-24 one side's stream stood for
## 100-460 ms nearly every five seconds, and nobody could say which. The line
## says how long the longest frame of its stretch took, and starts over after.
func test_the_line_says_how_long_the_longest_frame_took() -> void:
	var net := Logged.new(Reporter.new(), 0, func(_t: int) -> int: return 0)
	for t in NetInput.REPORT_EVERY * 2:
		net.pump()
		net.capture(t)
		if t - 12 >= Rollback.START:
			net.handle_packet(Protocol.pack_input(t - 12, 0))
		assert_true(net.can_predict(t), "tick %d is not computed" % t)
		net.note_tick(t)
		net.now += 240 if t == 100 else 1000 / 60
	var lines := net.lines.filter(func(l: String) -> bool: return l.contains("ticks in"))
	assert_eq(lines.size(), 2, "one line a stretch: %s" % [net.lines])
	if lines.size() != 2:
		return
	assert_string_contains(lines[0], "longest frame 240 ms")
	assert_string_contains(lines[1], "longest frame 16 ms")
