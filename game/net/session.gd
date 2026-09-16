class_name Session
extends Link

## A connection between the two sides over WebSocket. A thin wrapper: packet
## parsing lives in Protocol, laying input out by tick in Rollback, and only the
## socket is here.
##
## WebSocket everywhere — on the local network and later through the relay. The
## reason is the browser: it speaks nothing else, and cross-play is required.
## Building raw UDP for the LAN case would be a second body of code and a second
## set of bugs with no gain at our traffic: six bytes sixty times a second.

enum State { IDLE, LISTENING, CONNECTING, CONNECTED, FAILED, CLOSED }

const DEFAULT_PORT := 27013

var state := State.IDLE
var is_host := false

var _peer: WebSocketMultiplayerPeer = null

## Listening explicitly over IPv4. The engine's default is "*", which on macOS
## yields a v6-only socket: the guest types an address like 192.168.x.x and the
## connection is refused even though the port is open. That exact case was what
## kept network play from working.
const BIND_IPV4 := "0.0.0.0"

func host(port: int = DEFAULT_PORT) -> Error:
	_peer = WebSocketMultiplayerPeer.new()
	var err := _peer.create_server(port, BIND_IPV4)
	if err != OK:
		state = State.FAILED
		return err
	is_host = true
	state = State.LISTENING
	_connect_signals()
	return OK

func join(url: String) -> Error:
	_peer = WebSocketMultiplayerPeer.new()
	var err := _peer.create_client(url)
	if err != OK:
		state = State.FAILED
		return err
	is_host = false
	state = State.CONNECTING
	_connect_signals()
	return OK

func _connect_signals() -> void:
	_peer.peer_connected.connect(func(_id: int) -> void:
		state = State.CONNECTED
		peer_joined.emit())
	_peer.peer_disconnected.connect(func(_id: int) -> void:
		state = State.CLOSED
		peer_left.emit())

## Called every frame: pumps the socket and hands out what arrived.
func poll() -> void:
	if _peer == null:
		return
	_peer.poll()
	if not is_host:
		match _peer.get_connection_status():
			MultiplayerPeer.CONNECTION_DISCONNECTED:
				if state == State.CONNECTING:
					state = State.FAILED
				elif state == State.CONNECTED:
					state = State.CLOSED
					peer_left.emit()
			MultiplayerPeer.CONNECTION_CONNECTED:
				if state == State.CONNECTING:
					state = State.CONNECTED
					peer_joined.emit()
	while _peer.get_available_packet_count() > 0:
		packet_received.emit(_peer.get_packet())

func send(data: PackedByteArray) -> void:
	if _peer == null or state != State.CONNECTED:
		return
	_peer.put_packet(data)

func linked() -> bool:
	return state == State.CONNECTED

## There is nothing to restore a direct connection with: the partner knows only
## an address, and there is no room with a journal here.
## No room here to count: on a direct link the partner is present exactly while
## the connection is.
func partner_present() -> bool:
	return linked()

func dead() -> bool:
	return state == State.FAILED or state == State.CLOSED

func close() -> void:
	if _peer != null:
		_peer.close()
		_peer = null
	state = State.CLOSED
