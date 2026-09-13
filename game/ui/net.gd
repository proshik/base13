extends Node2D

## The network game screen. Two ways to meet: a room by code through the relay,
## and a direct connection on the local network.
##
## A room works from anywhere — both sides dial outward, so there is no port to
## forward and no local-network permission to grant. The direct connection stays
## for playing with no internet at all.
##
## The campaign seed is set by whoever started: every level's seed is derived
## from it, so both sides get identical enemy waves.

signal finished(outcome: int)

enum Mode { CHOOSE, QUICK_WAIT, ROOM_WAIT, CODE_TYPING, LAN_WAIT, LAN_TYPING, CONNECTING, FAILED }

const SCREEN := Vector2(256, 240)
const HINT_TINT := Color(0.62, 0.62, 0.62)
const CODE_TINT := Color(1.0, 0.85, 0.2)
const ITEMS := ["QUICK GAME", "CREATE ROOM", "JOIN ROOM", "LAN HOST", "LAN JOIN"]
const FIRST_Y := 88
const STEP_Y := 18
const TEXT_X := 72
const CODE_LEN := 6
const CODE_SCALE := 3   ## a code gets dictated over the phone — it must read without squinting
const ADDRESS_MAX := 21

## Refusals arrive as a short marker: the server's explanation is prose, and the
## font knows only capital letters and digits.
const REFUSALS := {
	"no_room": "NO SUCH ROOM",
	"full": "ROOM IS FULL",
	"busy": "SERVER IS BUSY",
	"bad_hello": "SERVER REFUSED",
	"refused": "SERVER REFUSED",
	"NO CONNECTION": "NO CONNECTION",
	"CONNECTION LOST": "CONNECTION LOST",
	"SLOT TAKEN": "ROOM IS FULL",
}

var link: Link = null
var local_index := 0
var seed_value := 0

## The room server's address. A field rather than a call at the point of use: a
## test substitutes it without touching the process environment. Empty means the
## usual lookup.
var relay_url := ""

var _font: Texture2D = preload("res://assets/font.png")
var _sprites: Texture2D = preload("res://assets/sprites.png")
var _mode := Mode.CHOOSE
var _choice := 0
var _typed := ""
var _address := ""
var _trouble := ""
## Which way the last attempt went. The hint depends on it: a room and a direct
## connection fail for different reasons, and one piece of advice for both sends
## people to fix the wrong thing.
var _via_room := false
## There are two ways to wait, and they must show different things: whoever
## opened a room dictates the code, while whoever pressed quick game has nobody
## to dictate it to.
var _via_quick := false
var _waited := 0.0
var _left := false

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func configure(_campaign, _players: int, _best: int) -> void:
	queue_redraw()

func _process(delta: float) -> void:
	if _mode == Mode.QUICK_WAIT:
		var before := int(_waited)
		_waited += delta
		if int(_waited) != before:
			queue_redraw()
	if link == null:
		return
	link.poll()
	if link is Session and _mode == Mode.CONNECTING \
			and link.state == Session.State.FAILED:
		_failed("NO CONNECTION")

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match _mode:
		Mode.CHOOSE:
			_choose(event)
		Mode.CODE_TYPING:
			_type_code(event)
		Mode.LAN_TYPING:
			_type_address(event)
		_:
			if event.physical_keycode == KEY_ESCAPE:
				_leave(ScreenFlow.Outcome.QUIT)

func _choose(event: InputEventKey) -> void:
	match event.physical_keycode:
		KEY_UP, KEY_W:
			_choice = (_choice + ITEMS.size() - 1) % ITEMS.size()
			queue_redraw()
		KEY_DOWN, KEY_S:
			_choice = (_choice + 1) % ITEMS.size()
			queue_redraw()
		KEY_ESCAPE:
			_leave(ScreenFlow.Outcome.QUIT)
		KEY_ENTER, KEY_SPACE:
			_act()

func _act() -> void:
	match _choice:
		0:
			_quick_game()
		1:
			_create_room()
		2:
			_typed = ""
			_mode = Mode.CODE_TYPING
		3:
			_lan_host()
		4:
			_address = ""
			_mode = Mode.LAN_TYPING
	queue_redraw()

## The code is typed by character rather than by key position: what matters is
## what the person typed, not which button they pressed. The same for the
## address.
func _type_code(event: InputEventKey) -> void:
	if event.physical_keycode == KEY_ESCAPE:
		_mode = Mode.CHOOSE
		queue_redraw()
		return
	if event.physical_keycode == KEY_BACKSPACE:
		_typed = _typed.substr(0, maxi(0, _typed.length() - 1))
		queue_redraw()
		return
	if event.physical_keycode == KEY_ENTER and _typed.length() == CODE_LEN:
		_join_room()
		return
	var ch := char(event.unicode).to_upper()
	if ch.length() == 1 and TextPainter.glyph_index(ch) >= 0 \
			and _typed.length() < CODE_LEN:
		_typed += ch
		queue_redraw()

func _type_address(event: InputEventKey) -> void:
	if event.physical_keycode == KEY_ESCAPE:
		_mode = Mode.CHOOSE
		queue_redraw()
		return
	if event.physical_keycode == KEY_BACKSPACE:
		_address = _address.substr(0, maxi(0, _address.length() - 1))
		queue_redraw()
		return
	if event.physical_keycode == KEY_ENTER and _address != "":
		_lan_join()
		return
	var ch := char(event.unicode)
	if ch.length() == 1 and "0123456789.:".contains(ch) and _address.length() < ADDRESS_MAX:
		_address += ch
		queue_redraw()

func _quick_game() -> void:
	_via_room = true
	_via_quick = true
	_waited = 0.0
	var relay := Relay.new()
	_watch(relay)
	if relay.quick(_server(), _new_seed()) != OK:
		_failed("NO CONNECTION")
		return
	link = relay
	_mode = Mode.CONNECTING

func _create_room() -> void:
	_via_room = true
	_via_quick = false
	var relay := Relay.new()
	_watch(relay)
	if relay.create(_server(), _new_seed()) != OK:
		_failed("NO CONNECTION")
		return
	link = relay
	_mode = Mode.CONNECTING

func _join_room() -> void:
	_via_room = true
	_via_quick = false
	var relay := Relay.new()
	_watch(relay)
	if relay.join(_server(), _typed) != OK:
		_failed("NO CONNECTION")
		return
	link = relay
	_mode = Mode.CONNECTING

func _server() -> String:
	return relay_url if relay_url != "" else RelayConfig.url()

func _watch(relay: Relay) -> void:
	relay.opened.connect(_on_room_opened)
	relay.peer_joined.connect(_on_peer_joined)
	relay.refused.connect(_failed)
	relay.lost.connect(_failed)

## The room is open. The creator waits for a partner and shows the code; whoever
## joins by that code finds the creator already there and starts at once.
func _on_room_opened(_code: String, slot: int, given_seed: int) -> void:
	local_index = slot
	seed_value = given_seed
	if link.players >= 2:
		_leave(ScreenFlow.Outcome.CONTINUE)
		return
	_mode = Mode.QUICK_WAIT if _via_quick else Mode.ROOM_WAIT
	queue_redraw()

func _lan_host() -> void:
	_via_room = false
	_via_quick = false
	var session := Session.new()
	if session.host() != OK:
		_failed("NO CONNECTION")
		return
	link = session
	local_index = 0
	session.peer_joined.connect(_on_lan_peer_joined)
	_mode = Mode.LAN_WAIT
	queue_redraw()

func _lan_join() -> void:
	_via_room = false
	_via_quick = false
	var session := Session.new()
	var url := _address
	if not url.contains(":"):
		url += ":%d" % Session.DEFAULT_PORT
	if session.join("ws://" + url) != OK:
		_failed("NO CONNECTION")
		return
	link = session
	local_index = 1
	session.packet_received.connect(_on_lan_packet)
	_mode = Mode.CONNECTING
	queue_redraw()

## On the local network the host sets the seed and sends it to the guest: there
## is no server here that could tell both of them.
func _on_lan_peer_joined() -> void:
	seed_value = _new_seed()
	link.send(Protocol.pack_start(seed_value, 2))
	_leave(ScreenFlow.Outcome.CONTINUE)

func _on_lan_packet(data: PackedByteArray) -> void:
	var packet := Protocol.unpack(data)
	if packet.get("kind", Protocol.Kind.INVALID) == Protocol.Kind.START:
		seed_value = packet["seed"]
		_leave(ScreenFlow.Outcome.CONTINUE)

func _on_peer_joined() -> void:
	_leave(ScreenFlow.Outcome.CONTINUE)

func _new_seed() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0) & 0xFFFFFFFF

func _failed(why: String) -> void:
	_trouble = REFUSALS.get(why, "NO CONNECTION")
	_mode = Mode.FAILED
	if link != null:
		link.close()
		link = null
	queue_redraw()

func _leave(outcome: int) -> void:
	if _left:
		return
	_left = true
	set_process(false)
	if outcome != ScreenFlow.Outcome.CONTINUE and link != null:
		link.close()
		link = null
	finished.emit(outcome)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0))
	TextPainter.draw_centred(self, _font, "NETWORK GAME", 40)
	match _mode:
		Mode.CHOOSE:
			for i in ITEMS.size():
				TextPainter.draw_line(self, _font, ITEMS[i],
					Vector2i(TEXT_X, FIRST_Y + i * STEP_Y))
			_draw_cursor()
			TextPainter.draw_centred(self, _font, "ESC BACK", 200, HINT_TINT)
		Mode.QUICK_WAIT:
			TextPainter.draw_centred(self, _font, "LOOKING FOR PLAYER", 100)
			TextPainter.draw_centred(self, _font, waited_text(_waited), 128, CODE_TINT)
			TextPainter.draw_centred(self, _font, "ESC CANCEL", 200, HINT_TINT)
		Mode.ROOM_WAIT:
			TextPainter.draw_centred(self, _font, "ROOM CODE", 88)
			TextPainter.draw_centred(self, _font, link.code, 108, CODE_TINT, CODE_SCALE)
			TextPainter.draw_centred(self, _font, "TELL IT TO YOUR FRIEND", 144, HINT_TINT)
			TextPainter.draw_centred(self, _font, "WAITING FOR PLAYER", 160, HINT_TINT)
			TextPainter.draw_centred(self, _font, "ESC CANCEL", 200, HINT_TINT)
		Mode.CODE_TYPING:
			TextPainter.draw_centred(self, _font, "ROOM CODE", 88)
			TextPainter.draw_centred(self, _font, _typed + "_", 108, CODE_TINT, CODE_SCALE)
			TextPainter.draw_centred(self, _font, "ENTER JOIN  ESC BACK", 200, HINT_TINT)
		Mode.LAN_WAIT:
			TextPainter.draw_centred(self, _font, "WAITING FOR PLAYER", 88)
			var addresses := _local_addresses()
			if addresses.is_empty():
				TextPainter.draw_centred(self, _font, "NO NETWORK", 116, HINT_TINT)
			for i in addresses.size():
				TextPainter.draw_centred(self, _font, addresses[i], 112 + i * 12)
			TextPainter.draw_centred(self, _font, "PORT %d" % Session.DEFAULT_PORT,
				160, HINT_TINT)
			TextPainter.draw_centred(self, _font, "ESC CANCEL", 200, HINT_TINT)
		Mode.LAN_TYPING:
			TextPainter.draw_centred(self, _font, "HOST ADDRESS", 88)
			TextPainter.draw_centred(self, _font, _address + "_", 112)
			TextPainter.draw_centred(self, _font, "ENTER CONNECT  ESC BACK", 200, HINT_TINT)
		Mode.CONNECTING:
			TextPainter.draw_centred(self, _font, "CONNECTING", 104)
			TextPainter.draw_centred(self, _font, "ESC CANCEL", 200, HINT_TINT)
		Mode.FAILED:
			TextPainter.draw_centred(self, _font, _trouble, 88)
			for i in hint_lines().size():
				TextPainter.draw_centred(self, _font, hint_lines()[i],
					120 + i * 14, HINT_TINT)
			TextPainter.draw_centred(self, _font, "ESC BACK", 200, HINT_TINT)

## How long we have been waiting. A stopwatch instead of a count of waiters: for
## the count not to lie, the server would have to broadcast queue changes to
## people who are not in a room yet — a separate channel for the sake of one
## number that would go stale anyway. A stopwatch promises nothing and cannot
## lie.
static func waited_text(seconds: float) -> String:
	var whole := int(seconds)
	return "%d:%02d" % [whole / 60, whole % 60]

## What to tell a person under a failure message. The hint must match the cause:
## the server could not be reached — the address or the server is at fault; the
## direct connection did not work out — Wi-Fi or the macOS permission is. One
## piece of advice for both cases sends people to fix the wrong thing.
func hint_lines() -> Array[String]:
	if _trouble != "NO CONNECTION":
		return []
	if _via_room:
		# The address is shown in full: more often than not it is what is wrong.
		return ["NO SERVER AT", _server_short(), "IS IT RUNNING"] as Array[String]
	# macOS blocks the local network until an application is granted access.
	# Without a hint a person looks for the cause in the router, while it is in
	# the settings.
	return ["SAME WIFI AND", "LOCAL NETWORK", "PERMISSION NEEDED"] as Array[String]

## The address without "ws://" and the trailing path: only the essential part
## fits on a screen line.
func _server_short() -> String:
	var text := _server()
	text = text.trim_prefix("wss://").trim_prefix("ws://").trim_suffix("/ws")
	return text.to_upper()

## Our own addresses on the local network — the guest types one of these. The
## selection lives in LocalAddresses: the engine's naive list puts a VPN address
## first, and a partner will never reach us through it.
func _local_addresses() -> Array[String]:
	return LocalAddresses.of_this_machine().slice(0, 3)

func _draw_cursor() -> void:
	var frame := Frames.tank(Types.TankType.PLAYER, 0, Types.Dir.RIGHT, 0)
	var src := Rect2i((frame % 16) * 16, (frame / 16) * 16, 16, 16)
	var at := Vector2(TEXT_X - 24, FIRST_Y + _choice * STEP_Y - 4)
	draw_texture_rect_region(_sprites, Rect2(at, Vector2(16, 16)), src)
