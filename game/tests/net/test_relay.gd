extends GutTest

## The client against a real server — the very binary that will travel to a
## machine. Each side is green on its own without this test; they only meet
## here, and until now every mistake at the seam was found by hand.

const PORT_BASE := 27301
const SPIN_LIMIT := 600   ## frames to wait before we call it a failure
const PLAY_TICKS := 180   ## three seconds of play: a divergence already shows here

var _pid := -1
var _url := ""
var _clock := 0

func before_each() -> void:
	_clock = 0

func after_each() -> void:
	_stop_server()

func _binary() -> String:
	# The binary lives in the repository root rather than in the Godot project:
	# it is built from server/ and has nothing to do with the game. res:// points
	# into game/, hence the step up.
	return ProjectSettings.globalize_path("res://") + "../.build/relay"

## The server takes its own port for every test: a neighbouring test may have
## left a port cooling down, and taking it again sometimes fails.
func _start_server(offset: int, extra: Array[String] = []) -> bool:
	if not FileAccess.file_exists(_binary()):
		return false
	var port := PORT_BASE + offset
	_url = "ws://127.0.0.1:%d/ws" % port
	var args: Array[String] = ["-addr=127.0.0.1:%d" % port]
	args.append_array(extra)
	_pid = OS.create_process(_binary(), args)
	if _pid <= 0:
		return false
	return _wait_until_listening(port)

## A started process does not yet mean "the port is taken": the client would
## knock at nothing and give up on the first attempt — it is one-shot precisely
## so that a person sees a refusal at once instead of a spinner.
func _wait_until_listening(port: int) -> bool:
	for i in SPIN_LIMIT:
		var probe := StreamPeerTCP.new()
		if probe.connect_to_host("127.0.0.1", port) == OK:
			for step in 20:
				probe.poll()
				if probe.get_status() == StreamPeerTCP.STATUS_CONNECTED:
					probe.disconnect_from_host()
					return true
				OS.delay_msec(5)
		probe.disconnect_from_host()
		OS.delay_msec(10)
	return false

func _stop_server() -> void:
	if _pid > 0:
		OS.kill(_pid)
		_pid = -1

func _skip_without_binary() -> bool:
	if FileAccess.file_exists(_binary()):
		return false
	pending("the server is not built: .build/relay is missing (Go required)")
	return true

## Unlike the tests around it, these two need no server at all: _open stores
## the greeting before it ever touches the socket, so the hello can be checked
## straight off a freshly built Relay.
func test_hello_carries_platform_and_version() -> void:
	var relay := Relay.new(Callable(), {"platform": "linux", "version": "1.2.3"})
	relay.create("ws://127.0.0.1:1/ws", 42)
	assert_eq(relay._greeting["platform"], "linux")
	assert_eq(relay._greeting["version"], "1.2.3")
	relay.close()

func test_client_fields_cannot_override_the_action() -> void:
	var merged := Relay.with_client({"action": "create", "game": Relay.GAME, "seed": 1},
		{"action": "evil", "platform": "linux"})
	assert_eq(merged["action"], "create",
		"a client-supplied field must never win over what the hello itself says")
	assert_eq(merged["platform"], "linux", "fields the hello does not name still pass through")

## A Relay that writes down the text it would put on the socket instead of
## putting it there, so what the server announced can be fed straight in.
class Speaker extends Relay:
	var texts: Array[String] = []
	var packets := 0
	func _send_text(text: String) -> void:
		texts.append(text)
	func send(_data: PackedByteArray) -> void:
		packets += 1

## A seated Speaker, as if the server had just answered the hello.
func _seated(answer: Dictionary) -> Speaker:
	var relay := Speaker.new(Callable(), {"platform": "linux", "version": "1.2.3"})
	# Never connected: the socket only has to exist, the way it does once seated.
	relay._socket = WebSocketPeer.new()
	relay._handle_welcome(answer)
	return relay

const PACE := {"speed": 97, "waits": 2, "delay": 8, "fps": 60}

## A server from before reports hands whatever follows the hello to the partner
## as a game packet. A report arriving there would be taken for input, so the
## client reports only to a server that said it takes reports.
func test_reports_are_sent_only_when_the_server_announced_them() -> void:
	var old := _seated({"ok": true, "slot": 0, "code": "ABCDEF", "seed": 1, "players": 2})
	old.report_pace(PACE)
	old.report_desync()
	assert_eq(old.texts, [] as Array[String], "a server that never announced reports was sent some")
	assert_eq(old.packets, 0)

	var current := _seated({"ok": true, "slot": 0, "code": "ABCDEF", "seed": 1, "players": 2,
		"reports": true})
	current.report_pace(PACE)
	current.report_desync()
	assert_eq(current.texts.size(), 2, "a server that announced reports heard nothing")

	# Coming back after a drop to a server that no longer takes them.
	current._resuming = true
	current._handle_welcome({"ok": true, "slot": 0, "code": "ABCDEF", "seed": 1, "players": 2})
	current.report_pace(PACE)
	assert_eq(current.texts.size(), 2, "a return to an older server kept reporting to it")

	# Nor while the link is down: there is nobody to hear it.
	var dropped := _seated({"ok": true, "slot": 0, "code": "ABCDEF", "players": 2, "reports": true})
	dropped.state = Relay.State.RETRYING
	dropped.report_pace(PACE)
	assert_eq(dropped.texts, [] as Array[String], "a report went out on a link that was not up")

## The frame kind separates the two conversations: a report goes as text, the
## way housekeeping does, and never among the game's binary packets. The server
## reads its numbers exactly, so they are whole: `97`, not `97.0`.
func test_a_report_goes_as_text_not_as_a_packet() -> void:
	var relay := _seated({"ok": true, "slot": 1, "code": "ABCDEF", "players": 2, "reports": true})
	relay.report_pace(PACE)
	relay.report_desync()
	assert_eq(relay.packets, 0, "a report went out as a game packet")
	assert_eq(relay.texts, [
		'{"report":{"speed":97,"waits":2,"delay":8,"fps":60}}',
		'{"desync":true}',
	] as Array[String])

const FULL_PACE := {"speed": 97, "waits": 2, "delay": 2, "fps": 60, "frozen": 1,
	"frozen_longest_ms": 2400, "stops_longest_ms": 120, "rollbacks": 40, "deepest": 9,
	"resim_ms": 12, "skips": 3, "lead": 4, "partner_lead": -1, "longest_frame_ms": 250}

## A server that takes reports but not notes — 0.6.4 — reads a report with more
## than its four figures, a desync with a tick and any note as malformed. It is
## told what it reads, as before; only a server whose welcome announced notes
## hears the rest, and the log that server keeps is where they go.
func test_the_current_shapes_go_only_to_a_server_that_takes_notes() -> void:
	var older := _seated({"ok": true, "slot": 0, "code": "ABCDEF", "players": 2, "reports": true})
	older.report_pace(FULL_PACE)
	older.report_desync(60)
	older.report_note("stage_begins", {"stage": 3})
	older.report_note("hidden")
	assert_eq(older.texts, [
		'{"report":{"speed":97,"waits":2,"delay":2,"fps":60}}',
		'{"desync":true}',
	] as Array[String])

	var current := _seated({"ok": true, "slot": 0, "code": "ABCDEF", "players": 2, "reports": true,
		"notes": true})
	current.report_pace(FULL_PACE)
	current.report_desync(60)
	current.report_note("stage_begins", {"stage": 3})
	current.report_note("hidden")
	assert_eq(current.texts, [
		'{"report":{"speed":97,"waits":2,"delay":2,"fps":60,"frozen":1,"frozen_longest_ms":2400,'
			+ '"stops_longest_ms":120,"rollbacks":40,"deepest":9,"resim_ms":12,"skips":3,"lead":4,'
			+ '"partner_lead":-1,"longest_frame_ms":250}}',
		'{"desync":60}',
		'{"note":{"what":"stage_begins","stage":3}}',
		'{"note":{"what":"hidden"}}',
	] as Array[String])

	# A return to a server that no longer takes notes goes back to the four.
	current._resuming = true
	current._handle_welcome({"ok": true, "slot": 0, "code": "ABCDEF", "players": 2, "reports": true})
	current.texts.clear()
	current.report_pace(FULL_PACE)
	current.report_note("visible")
	assert_eq(current.texts, ['{"report":{"speed":97,"waits":2,"delay":2,"fps":60}}'] as Array[String])

func test_a_fresh_relay_reports_nothing() -> void:
	var relay := Relay.new(Callable(), {"platform": "linux", "version": "1.2.3"})
	relay.report_pace(PACE)
	relay.report_desync()
	assert_eq(relay.state, Relay.State.IDLE)

func _spin(clients: Array, check: Callable) -> bool:
	for i in SPIN_LIMIT:
		for client in clients:
			client.poll()
		if check.call():
			return true
		OS.delay_msec(5)
	return false

func _tick_clock() -> int:
	return _clock

func test_room_opens_and_partner_joins_by_code() -> void:
	if _skip_without_binary():
		return
	assert_true(_start_server(0), "the server did not start")

	var host := Relay.new()
	assert_eq(host.create(_url, 4242), OK)
	assert_true(_spin([host], func() -> bool: return host.state == Relay.State.READY),
		"the room did not open")
	assert_eq(host.code.length(), 6, "a room code is read aloud, so it is short")
	assert_eq(host.slot, 0, "the creator is player one")

	# Subscribed before the guest enters: the notice arrives in the same frame as
	# their welcome, and subscribing afterwards can miss it.
	var noticed := []
	host.peer_joined.connect(func() -> void: noticed.append(true))

	var guest := Relay.new()
	assert_eq(guest.join(_url, host.code), OK)
	assert_true(_spin([host, guest], func() -> bool: return guest.state == Relay.State.READY),
		"the guest did not get in")
	assert_eq(guest.slot, 1, "the guest is player two")
	# The creator sets the seed: every level's seed is derived from it, or the
	# sides get different enemy waves and the worlds diverge in the first second.
	assert_eq(guest.seed_value, 4242, "the guest received the wrong seed")

	# The creator sits on the waiting screen and cannot see the arrival.
	assert_true(_spin([host, guest], func() -> bool: return not noticed.is_empty()),
		"the creator never learned the partner arrived")
	host.close()
	guest.close()

func test_packets_travel_both_ways() -> void:
	if _skip_without_binary():
		return
	assert_true(_start_server(1), "the server did not start")
	var host := Relay.new()
	var guest := Relay.new()
	assert_true(_pair(host, guest), "the pair did not come together")

	# Collected into an array rather than a variable: a lambda in GDScript
	# captures local values by copy, and an assignment does not escape.
	var to_guest := []
	var to_host := []
	guest.packet_received.connect(func(data: PackedByteArray) -> void: to_guest.append(data))
	host.packet_received.connect(func(data: PackedByteArray) -> void: to_host.append(data))

	host.send(Protocol.pack_input(7, Types.IN_LEFT))
	guest.send(Protocol.pack_input(9, Types.IN_FIRE))
	assert_true(_spin([host, guest],
		func() -> bool: return to_guest.size() > 0 and to_host.size() > 0),
		"the packets never arrived")
	assert_eq(Protocol.unpack(to_guest[0])["tick"], 7)
	assert_eq(Protocol.unpack(to_host[0])["bits"], Types.IN_FIRE)
	host.close()
	guest.close()

func test_unknown_code_is_refused_with_a_reason() -> void:
	if _skip_without_binary():
		return
	assert_true(_start_server(2), "the server did not start")
	var guest := Relay.new()
	assert_eq(guest.join(_url, "ZZZZZZ"), OK)
	assert_true(_spin([guest], func() -> bool: return guest.state == Relay.State.FAILED),
		"no refusal came for a foreign code")
	assert_ne(guest.reason, "", "a human needs an explanation, not a blank screen")
	guest.close()

func test_returning_player_gets_exactly_what_he_missed() -> void:
	if _skip_without_binary():
		return
	assert_true(_start_server(3), "the server did not start")
	var host := Relay.new()
	var guest := Relay.new()
	assert_true(_pair(host, guest), "the pair did not come together")

	var seen: Array[int] = []
	guest.packet_received.connect(func(data: PackedByteArray) -> void:
		seen.append(Protocol.unpack(data)["tick"]))

	host.send(Protocol.pack_input(1, 0))
	assert_true(_spin([host, guest], func() -> bool: return seen.size() == 1),
		"the first packet never arrived")

	# A break: the socket dies without the player asking for it. That is what a
	# departing lift or a sleeping laptop looks like.
	guest._socket.close()
	assert_true(_spin([guest], func() -> bool: return guest.state == Relay.State.RETRYING),
		"the client never noticed the break")

	# While they are away the partner keeps sending.
	host.send(Protocol.pack_input(2, 0))
	host.send(Protocol.pack_input(3, 0))
	for i in 20:
		host.poll()
		OS.delay_msec(5)

	assert_true(_spin([host, guest], func() -> bool: return seen.size() == 3),
		"what was missed never arrived, seen: %s" % [seen])
	assert_eq(seen, [1, 2, 3] as Array[int], "the order of what was missed is broken")
	assert_eq(guest.slot, 1, "one must return to one's own slot, or the worlds diverge")
	host.close()
	guest.close()

func test_gives_up_when_the_server_is_gone_for_good() -> void:
	if _skip_without_binary():
		return
	assert_true(_start_server(4), "the server did not start")
	var host := Relay.new()
	var guest := Relay.new(_tick_clock)
	assert_true(_pair(host, guest), "the pair did not come together")

	# The server was switched off for good: waiting forever is not an option, the
	# human has to be told.
	_stop_server()
	var told := []
	guest.lost.connect(func(why: String) -> void: told.append(why))

	for i in SPIN_LIMIT:
		guest.poll()
		_clock += 1000
		if not told.is_empty():
			break
		OS.delay_msec(1)
	assert_false(told.is_empty(), "the client did not give up and stays silent")
	assert_eq(guest.state, Relay.State.FAILED)
	host.close()
	guest.close()

func _pair(host: Relay, guest: Relay) -> bool:
	if host.create(_url, 1234) != OK:
		return false
	if not _spin([host], func() -> bool: return host.state == Relay.State.READY):
		return false
	if guest.join(_url, host.code) != OK:
		return false
	return _spin([host, guest], func() -> bool: return guest.state == Relay.State.READY)

## The strongest test of this stage: two sides play a level through a real
## server, exchanging nothing but key presses, and the worlds must match to the
## last bit. Everything below the screens is checked here in full.
func test_two_sides_play_a_level_through_the_relay() -> void:
	if _skip_without_binary():
		return
	assert_true(_start_server(5), "the server did not start")
	var host_link := Relay.new()
	var guest_link := Relay.new()
	assert_true(_pair(host_link, guest_link), "the pair did not come together")

	var frames := Golden.frames()
	var sides: Array[NetMatch] = [
		NetMatch.new(_sim(), NetInput.new(host_link, host_link.slot, func(t: int) -> int: return frames[t][0])),
		NetMatch.new(_sim(), NetInput.new(guest_link, guest_link.slot, func(t: int) -> int: return frames[t][1])),
	]
	for side in sides:
		side.set_horizon(PLAY_TICKS)
	var done := false
	for i in SPIN_LIMIT * 4:
		for side in sides:
			side.advance(1.0 / 60.0)
		if sides[0].confirmed_world().tick == PLAY_TICKS and sides[1].confirmed_world().tick == PLAY_TICKS:
			done = true
			break
		OS.delay_msec(2)
	assert_true(done, "the match never confirmed tick %d: host %d, guest %d" % [
		PLAY_TICKS, sides[0].confirmed_world().tick, sides[1].confirmed_world().tick])
	if not done:
		host_link.close()
		guest_link.close()
		return
	var expected := ReferenceRun.hash_of(frames, PLAY_TICKS)
	for side in sides:
		assert_eq(side.confirmed_world().hash_value(), expected, "the worlds are not the match's")
		assert_false((side.source() as NetInput).desynced, "the hash comparison fired")
	host_link.close()
	guest_link.close()

func _sim() -> GameSim:
	return GameSim.new(Golden.level(), Golden.SEED, SimConfig.new(),
		Golden.LEVEL_NUMBER, 2)

## The same match with a drop in the middle of it. While the guest is away each
## side goes on on guesses as far as the window allows, and the guest's presses
## for those ticks go nowhere — the relay journals only what reached it, and
## replays the partner's stream to whoever returns, never their own. Unless the
## returning side sends them again, the partner waits for them forever.
func test_play_goes_on_after_a_drop_mid_game() -> void:
	if _skip_without_binary():
		return
	assert_true(_start_server(11), "the server did not start")
	var host_link := Relay.new()
	var guest_link := Relay.new()
	assert_true(_pair(host_link, guest_link), "the pair did not come together")

	var frames := Golden.frames()
	var sides: Array[NetMatch] = [
		NetMatch.new(_sim(), NetInput.new(host_link, host_link.slot, func(t: int) -> int: return frames[t][0])),
		NetMatch.new(_sim(), NetInput.new(guest_link, guest_link.slot, func(t: int) -> int: return frames[t][1])),
	]
	for side in sides:
		side.set_horizon(PLAY_TICKS)
	var dropped_at := -1
	for i in SPIN_LIMIT * 4:
		for side in sides:
			side.advance(1.0 / 60.0)
		var guest_tick: int = sides[1].sim().get_state().tick
		if dropped_at < 0 and guest_tick >= 60:
			# A lift, a sleeping laptop: the socket dies with nobody asking.
			guest_link._socket.close()
			dropped_at = guest_tick
		if sides[0].confirmed_world().tick == PLAY_TICKS and sides[1].confirmed_world().tick == PLAY_TICKS:
			break
		OS.delay_msec(2)

	assert_gt(dropped_at, 0, "the drop never happened")
	assert_eq(guest_link.state, Relay.State.READY, "the guest never came back")
	for side in sides:
		assert_eq(side.confirmed_world().tick, PLAY_TICKS, "the match froze after the drop")
	var expected := ReferenceRun.hash_of(frames, PLAY_TICKS)
	for side in sides:
		assert_eq(side.confirmed_world().hash_value(), expected, "the worlds diverged")
	host_link.close()
	guest_link.close()

## Two people press one button and end up in the same game without exchanging
## anything: no code, no address.
func test_quick_game_brings_two_strangers_together() -> void:
	if _skip_without_binary():
		return
	assert_true(_start_server(6), "the server did not start")

	var first := Relay.new()
	assert_eq(first.quick(_url, 4321), OK)
	assert_true(_spin([first], func() -> bool: return first.state == Relay.State.READY),
		"the first one did not start waiting")
	assert_eq(first.slot, 0, "whoever waits first is player one")
	assert_eq(first.players, 1, "it must wait alone")

	# Subscribed before the second one arrives: the notice comes in the same
	# frame.
	var noticed := []
	first.peer_joined.connect(func() -> void: noticed.append(true))

	var second := Relay.new()
	assert_eq(second.quick(_url, 8765), OK)
	assert_true(_spin([first, second], func() -> bool: return second.state == Relay.State.READY),
		"the second one was not matched")
	assert_eq(second.slot, 1, "the matched one is player two")
	assert_eq(second.code, first.code, "they ended up in different rooms")
	# Whoever waits first sets the seed, or the sides get different enemy waves.
	assert_eq(second.seed_value, 4321, "the matched one received the wrong seed")
	assert_true(_spin([first, second], func() -> bool: return not noticed.is_empty()),
		"the waiter never learned the partner arrived")

	first.close()
	second.close()

## A player waiting alone must not conclude the game has started.
func test_a_lone_quick_player_keeps_waiting() -> void:
	if _skip_without_binary():
		return
	assert_true(_start_server(7), "the server did not start")

	var alone := Relay.new()
	assert_eq(alone.quick(_url, 1), OK)
	assert_true(_spin([alone], func() -> bool: return alone.state == Relay.State.READY),
		"the room was not opened")
	for i in 40:
		alone.poll()
		OS.delay_msec(5)
	assert_eq(alone.players, 1, "a partner appeared out of nowhere")
	alone.close()

## A person waiting for a partner sends nothing and receives nothing, and an
## intermediary counts that silence: nginx cuts an idle connection at sixty
## seconds by default. Godot leaves the heartbeat off unless it is switched on,
## so on the local network this is invisible and behind a proxy it is certain.
func test_the_socket_pings_on_its_own() -> void:
	if _skip_without_binary():
		return
	assert_true(_start_server(8), "the server did not start")

	var waiting := Relay.new()
	assert_eq(waiting.quick(_url, 4242), OK)
	assert_gt(waiting._socket.heartbeat_interval, 0.0,
		"without a heartbeat the connection dies while waiting for a partner")
	assert_lt(waiting._socket.heartbeat_interval, 60.0,
		"a heartbeat rarer than the usual proxy timeout protects nothing")
	waiting.close()

## An intermediary that closes a connection nothing has travelled through for a
## while — that is all a proxy's idle timeout is. Nginx gives sixty seconds by
## default, Cloudflare about a hundred; here it is a couple of seconds so the
## test costs seconds and not minutes.
class IdleProxy:
	var cut := false

	var _server := TCPServer.new()
	var _near: StreamPeerTCP = null      ## the client's side
	var _far: StreamPeerTCP = null       ## the relay's side
	var _target := 0
	var _idle_ms := 0
	var _last := 0

	func listen(port: int, target: int, idle_ms: int) -> bool:
		_target = target
		_idle_ms = idle_ms
		_last = Time.get_ticks_msec()
		return _server.listen(port, "127.0.0.1") == OK

	func pump() -> void:
		if cut:
			return
		if _near == null and _server.is_connection_available():
			_near = _server.take_connection()
			_far = StreamPeerTCP.new()
			if _far.connect_to_host("127.0.0.1", _target) != OK:
				_far = null
				return
			_last = Time.get_ticks_msec()
		if _near == null or _far == null:
			return
		_near.poll()
		_far.poll()
		if _far.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return
		if _forward(_near, _far) or _forward(_far, _near):
			_last = Time.get_ticks_msec()
		if Time.get_ticks_msec() - _last >= _idle_ms:
			cut = true
			_near.disconnect_from_host()
			_far.disconnect_from_host()

	## Returns true if anything at all travelled: that is what "not idle" means.
	func _forward(from: StreamPeerTCP, to: StreamPeerTCP) -> bool:
		var waiting := from.get_available_bytes()
		if waiting <= 0:
			return false
		var got: Array = from.get_data(waiting)
		if got[0] != OK:
			return false
		to.put_data(got[1])
		return true

	func stop() -> void:
		_server.stop()
		if _near != null:
			_near.disconnect_from_host()
		if _far != null:
			_far.disconnect_from_host()

## Drives the proxy alongside the clients: without pumping it the bytes never
## reach the server, and the test would be measuring its own harness.
func _spin_through(proxy: IdleProxy, clients: Array, check: Callable, ms: int) -> bool:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		proxy.pump()
		for client in clients:
			client.poll()
		if check.call():
			return true
		OS.delay_msec(5)
	return false

## What a cut connection actually costs a player, checked end to end rather than
## reasoned about. A person presses QUICK GAME, waits behind an intermediary that
## drops idle links, and someone else presses the same button later.
##
## Without a heartbeat the wait is not merely interrupted: the room is emptied,
## the client is left retrying through the same cutting proxy, and the partner
## who arrives is seated in a room of their own. Two people staring at a
## stopwatch in separate rooms, forever.
func _wait_then_partner(heartbeat: float, offset: int) -> Dictionary:
	var relay_port := PORT_BASE + offset
	var idle_ms := 800

	var waiting := Relay.new()
	var proxy := IdleProxy.new()
	assert_true(proxy.listen(relay_port + 40, relay_port, idle_ms), "the proxy did not start")
	assert_eq(waiting.quick("ws://127.0.0.1:%d/ws" % (relay_port + 40), 7), OK)
	assert_true(_spin_through(proxy, [waiting], func() -> bool:
		return waiting.state == Relay.State.READY, 5000), "the waiting player was never seated")
	waiting._socket.heartbeat_interval = heartbeat

	_spin_through(proxy, [waiting], func() -> bool: return false, idle_ms * 3)

	var partner := Relay.new()
	assert_eq(partner.quick("ws://127.0.0.1:%d/ws" % relay_port, 8), OK)
	var met := _spin_through(proxy, [waiting, partner], func() -> bool:
		return waiting.players == 2 and partner.players == 2, 3000)

	var outcome := {"cut": proxy.cut, "met": met, "room": waiting.code, "partner": partner.code}
	waiting.close()
	partner.close()
	proxy.stop()
	return outcome

func test_a_heartbeat_is_what_lets_a_waiting_player_be_found() -> void:
	if _skip_without_binary():
		return
	assert_true(_start_server(9), "the server did not start")

	var mute := _wait_then_partner(0.0, 9)      # what Godot gives us by default
	assert_true(mute["cut"], "the link outlived the idle timeout — the proxy is not being modelled")
	assert_false(mute["met"],
		"a silent wait survived a cutting intermediary — then the heartbeat guards nothing")
	assert_ne(mute["room"], mute["partner"],
		"the two ended up in one room anyway — the failure is not the one described")

	var beating := _wait_then_partner(0.4, 9)   # production shape, scaled to the test
	assert_false(beating["cut"], "a heartbeat did not keep the link alive")
	assert_true(beating["met"], "the partner did not find the waiting player")
	assert_eq(beating["room"], beating["partner"], "they met in different rooms")

## Reads the server's metrics page. Empty if it could not be read.
func _scrape(port: int) -> String:
	var http := HTTPClient.new()
	if http.connect_to_host("127.0.0.1", port) != OK:
		return ""
	for i in SPIN_LIMIT:
		http.poll()
		var status := http.get_status()
		if status == HTTPClient.STATUS_CONNECTED:
			break
		if status != HTTPClient.STATUS_CONNECTING and status != HTTPClient.STATUS_RESOLVING:
			return ""
		OS.delay_msec(5)
	if http.request(HTTPClient.METHOD_GET, "/metrics", []) != OK:
		return ""
	for i in SPIN_LIMIT:
		http.poll()
		if http.get_status() != HTTPClient.STATUS_REQUESTING:
			break
		OS.delay_msec(5)
	if not http.has_response():
		return ""
	var body := PackedByteArray()
	for i in SPIN_LIMIT:
		if http.get_status() != HTTPClient.STATUS_BODY:
			break
		http.poll()
		var chunk := http.read_response_body_chunk()
		if chunk.is_empty():
			OS.delay_msec(5)
		else:
			body.append_array(chunk)
	http.close()
	return body.get_string_from_utf8()

## The report a real client writes, read by the real server: counted as a window
## and a desync, never as malformed, and never handed to the partner. Each side's
## tests pin its half of the wire; only here do the halves meet.
func test_the_server_counts_what_the_client_reports() -> void:
	if _skip_without_binary():
		return
	var metrics_port := PORT_BASE + 12 + 100
	assert_true(_start_server(12, ["-metrics-addr=127.0.0.1:%d" % metrics_port]),
		"the server did not start")
	var host := Relay.new(Callable(), {"platform": "linux", "version": "1.2.3"})
	var guest := Relay.new(Callable(), {"platform": "web", "version": "1.2.3"})
	assert_true(_pair(host, guest), "the pair did not come together")
	assert_true(host._reports, "the server's welcome did not announce reports")
	assert_true(host._notes, "the server's welcome did not announce notes")
	var to_guest := []
	guest.packet_received.connect(func(data: PackedByteArray) -> void: to_guest.append(data))

	# The shapes test_net_input.gd sees NetInput hand to its link: none of them
	# may read as malformed. The notes go first: the server reads in order, so
	# once the window and the desync behind them are counted, so are they.
	host.report_note("stage_ends", {"stage": 3, "tick": 1234, "ended": 1144, "seen": 1146})
	host.report_note("stood", {"stage": 3, "tick": 17, "ms": 1000, "confirmed": 4, "from": 5, "through": 19})
	host.report_note("blur")
	var pace := FULL_PACE.duplicate()
	pace.merge({"speed": 99, "waits": 5, "delay": 8}, true)
	host.report_pace(pace)
	host.report_desync(60)
	var page := [""]
	var counted := _spin([host, guest], func() -> bool:
		page[0] = _scrape(metrics_port)
		return page[0].contains('relay_client_windows_total{platform="linux",verdict="smooth"} 1') \
			and page[0].contains('relay_desynced_matches_total{kind="code"} 1'))
	assert_true(counted, "the server never counted the report:\n%s" % _lines_about(page[0],
		["relay_client_windows_total", "relay_client_reports_rejected_total", "relay_desynced_matches_total"]))
	assert_string_contains(page[0], 'relay_client_reports_rejected_total{why="malformed"} 0')
	assert_string_contains(page[0], 'relay_client_reports_rejected_total{why="early"} 0')
	assert_string_contains(page[0], "relay_client_input_delay_ticks_sum 8")
	assert_string_contains(page[0], "relay_client_waits_total 5")
	for i in 20:
		host.poll()
		guest.poll()
		OS.delay_msec(5)
	assert_eq(to_guest.size(), 0, "a report reached the partner as a game packet")
	host.close()
	guest.close()

func _lines_about(page: String, prefixes: Array[String]) -> String:
	var kept: PackedStringArray = []
	for line in page.split("\n"):
		for prefix in prefixes:
			if line.begins_with(prefix):
				kept.append(line)
	return "\n".join(kept)

## A partner who shut their window is silent in exactly the way one who merely
## looked away is. Only the room can tell them apart, and it does: occupancy
## travels in every housekeeping message. Without this the game screen waits for
## a person who is never coming back, for as long as the window stays open.
func test_a_partner_who_leaves_stops_being_present() -> void:
	if _skip_without_binary():
		return
	assert_true(_start_server(10), "the server did not start")
	var host := Relay.new()
	var guest := Relay.new()
	assert_true(_pair(host, guest), "the pair did not come together")
	assert_true(host.partner_present(), "two in the room and nobody notices")
	assert_true(guest.partner_present())

	guest.close()
	assert_true(_spin([host], func() -> bool: return not host.partner_present()),
		"the room never said the other one had gone")
	host.close()
