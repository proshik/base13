class_name Relay
extends Link

## A link through the relay server: a room code instead of a machine address.
##
## Both players dial outward, so there is no port to forward, no local-network
## permission to grant, and no need to share a network at all. The server never
## looks into the game: it sees a room code, the members and the order of
## packets — the clients compute the world, each on their own.
##
## Housekeeping messages arrive as text frames and game packets as binary ones.
## The frame kind is what separates the two conversations; a marker inside the
## data would have to be stepped over by every parser.

signal opened(code: String, slot: int, seed_value: int)
signal refused(reason: String)
signal lost(reason: String)

enum State { IDLE, CONNECTING, GREETING, READY, RETRYING, FAILED, CLOSED }

const GAME := "tanks"
const RETRY_MS := 1000     ## pause between attempts to come back
const POLICY_CLOSE := 1008 ## close code for "the request breaks the rules"
const GIVE_UP_MS := 30000  ## holding the game open longer is pointless

## How often the socket pings by itself. Godot leaves the heartbeat at zero, and
## a connection with no traffic is cut by whatever stands in the middle: nginx
## gives an idle connection sixty seconds by default. Waiting for a partner in a
## quick game is exactly such a connection — silent, and possibly for minutes.
##
## This covers desktop only. In a browser it does nothing: the browser's
## WebSocket has no way to send a ping, and Godot's web peer only stores the
## value. The server pings every twenty seconds for exactly that reason, and a
## browser answers by itself — so a waiting browser player is kept alive from
## the other end.
const HEARTBEAT_SECONDS := 10.0

var state := State.IDLE
var code := ""
var slot := 0
var seed_value := 0
var players := 1
var reason := ""

## How many game packets have been received. That is the mark used to catch up:
## the server never echoes our own packets back, so the count of what was
## received points unambiguously at how far we got in the other side's stream.
var received := 0

var _url := ""
var _socket: WebSocketPeer = null
var _greeting := {}
var _resuming := false
var _now: Callable
var _retry_at := 0
var _give_up_at := 0
var _client := {}
## Whether the server's last welcome said it takes reports. A server from before
## reports hands whatever follows the hello to the partner as a game packet, and a
## report arriving there would be read as input. Taken again from every welcome,
## a return after a drop included: the server on the other end may have been
## replaced by an older one in between.
var _reports := false

## now_provider is a seam for tests: otherwise the retry deadlines would have to
## be waited out for real. client is the same kind of seam for what the hello
## says about this machine; production code never passes one, and ClientInfo
## reads the real OS and project version instead.
func _init(now_provider := Callable(), client := {}) -> void:
	_now = now_provider
	_client = client if not client.is_empty() else ClientInfo.fields()

func create(url: String, new_seed: int) -> Error:
	seed_value = new_seed
	code = ""
	return _open(url, {"action": "create", "game": GAME, "seed": new_seed})

func join(url: String, room_code: String) -> Error:
	code = room_code
	return _open(url, {"action": "join", "game": GAME, "code": room_code})

## Quick game: the server seats us with whoever is waiting, or leaves us waiting
## instead. We send our own seed — it is only used if waiting fell to us;
## otherwise the welcome brings someone else's and we play by that one.
func quick(url: String, new_seed: int) -> Error:
	seed_value = new_seed
	code = ""
	return _open(url, {"action": "quick", "game": GAME, "seed": new_seed})

## Layers what the hello itself says over what the client says about itself,
## so the fixed part of a request — action, game, code, seed, since — can never
## be shadowed by a platform or version string.
static func with_client(greeting: Dictionary, client: Dictionary) -> Dictionary:
	var merged := client.duplicate()
	for key in greeting:
		merged[key] = greeting[key]
	return merged

func _open(url: String, greeting: Dictionary) -> Error:
	_url = url
	_greeting = with_client(greeting, _client)
	_socket = WebSocketPeer.new()
	_socket.heartbeat_interval = HEARTBEAT_SECONDS
	var err := _socket.connect_to_url(url)
	if err != OK:
		_socket = null
		state = State.FAILED
		reason = "NO CONNECTION"
		return err
	state = State.CONNECTING
	return OK

## Called every frame: pumps the socket, carries out the handshake and hands out
## what arrived.
func poll() -> void:
	# The deadline is checked on every frame of recovery, not only in the pause
	# between attempts: connecting to a vanished server can hang by itself, and
	# then the pause would never come.
	if (_resuming or state == State.RETRYING) and _clock() >= _give_up_at:
		_fail("CONNECTION LOST")
		return
	if state == State.RETRYING:
		_try_again()
		return
	if _socket == null:
		return
	_socket.poll()
	match _socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if state == State.CONNECTING:
				state = State.GREETING
				_socket.send_text(JSON.stringify(_greeting))
			_drain()
		WebSocketPeer.STATE_CLOSED:
			_drain()
			_closed_by_server()

func _drain() -> void:
	while _socket != null and _socket.get_available_packet_count() > 0:
		var data := _socket.get_packet()
		if _socket.was_string_packet():
			_handle_notice(data.get_string_from_utf8())
		else:
			received += 1
			packet_received.emit(data)

func _handle_notice(text: String) -> void:
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var notice: Dictionary = parsed
	if notice.has("event"):
		players = int(notice.get("players", players))
		if notice["event"] == "joined":
			peer_joined.emit()
		else:
			peer_left.emit()
		return
	_handle_welcome(notice)

func _handle_welcome(answer: Dictionary) -> void:
	if not bool(answer.get("ok", false)):
		# Take the short marker rather than the human explanation: the game's
		# font can draw only capital Latin letters and digits, and an arbitrary
		# sentence would not render.
		reason = str(answer.get("reason", "refused"))
		state = State.FAILED
		_shut()
		refused.emit(reason)
		return
	var given: int = int(answer.get("slot", 0))
	# The slot decides the order of players, and that must match on both sides.
	# Taking somebody else's slot after a break means diverged worlds a minute
	# later.
	if _resuming and given != slot:
		_fail("SLOT TAKEN")
		return
	slot = given
	_reports = bool(answer.get("reports", false))
	code = str(answer.get("code", code))
	seed_value = int(answer.get("seed", seed_value))
	players = int(answer.get("players", 1))
	state = State.READY
	if _resuming:
		_resuming = false
		peer_joined.emit()
	else:
		opened.emit(code, slot, seed_value)

## The refusal arrives in the close frame rather than as a message: while
## parsing the farewell, WebSocketPeer discards anything we did not manage to
## read, and the refusal text never reaches us. The reason inside the farewell
## always does — the server puts the short marker there for exactly this.
func _closed_by_server() -> void:
	if state == State.FAILED or state == State.CLOSED:
		return
	if _socket != null and _socket.get_close_code() == POLICY_CLOSE:
		var why := _socket.get_close_reason()
		if why != "":
			reason = why
			state = State.FAILED
			_resuming = false
			_shut()
			refused.emit(why)
			return
	_dropped()

## A break mid-game is not the end: the room on the server lives on for a few
## minutes, the journal is intact, and whoever returns is sent what they missed.
## The game would not move on by itself anyway — a tick will not advance while
## the other side's input is missing.
func _dropped() -> void:
	if state == State.READY:
		_shut()
		state = State.RETRYING
		_retry_at = _clock()
		_give_up_at = _clock() + GIVE_UP_MS
		return
	if _resuming:
		_shut()
		state = State.RETRYING
		_retry_at = _clock() + RETRY_MS
		return
	_fail("NO CONNECTION")

func _try_again() -> void:
	var now := _clock()
	if now < _retry_at:
		return
	_retry_at = now + RETRY_MS
	_resuming = true
	if _open(_url, {"action": "join", "game": GAME, "code": code,
			"since": received}) != OK:
		state = State.RETRYING

func _fail(why: String) -> void:
	reason = why
	state = State.FAILED
	_resuming = false
	_shut()
	lost.emit(why)

func send(data: PackedByteArray) -> void:
	if state != State.READY or _socket == null:
		return
	_socket.send(data)

## Reports travel as text, beside the room's housekeeping, and never among the
## game's binary packets: the frame kind is what keeps them out of the partner's
## stream. The server reads each figure as a whole number, so the caller hands
## over ints — `JSON.stringify` writes an int as `97` and a float as `97.0`, and a
## fractional frame rate would make the whole report malformed.
func report_pace(pace: Dictionary) -> void:
	_report({"report": pace})

func report_desync() -> void:
	_report({"desync": true})

## Nothing goes to a server that did not announce reports, and nothing goes while
## the link is not up: a report queued on a dying socket is lost anyway, and one
## sent before the welcome would reach the server as a malformed hello.
func _report(message: Dictionary) -> void:
	if not _reports or state != State.READY or _socket == null:
		return
	# Keys in the order they were written rather than sorted: the server does
	# not mind either, but a report read in a capture should read like the
	# `[net]` line it came from.
	_send_text(JSON.stringify(message, "", false))

## A seam for tests: what goes onto the socket as text can be caught here without
## standing a server up.
func _send_text(text: String) -> void:
	_socket.send_text(text)

## While the link is being restored, the game waits. The game screen shows this
## to the human; otherwise a frozen screen looks like a hang.
## The room reports its occupancy in every housekeeping message, and a welcome
## after a reconnect brings it too, so this repairs itself without being told.
func partner_present() -> bool:
	return players >= 2

func linked() -> bool:
	return state == State.READY

func dead() -> bool:
	return state == State.FAILED or state == State.CLOSED

func close() -> void:
	_shut()
	state = State.CLOSED

func _shut() -> void:
	if _socket != null:
		_socket.close()
		_socket = null

func _clock() -> int:
	return int(_now.call()) if _now.is_valid() else Time.get_ticks_msec()
