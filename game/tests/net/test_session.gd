extends GutTest

## A real connection, host and guest in one process. The socket works in
## headless too, so the transport is checked by a test and not only by hand on
## two machines.

const PORT := 27113
const SPIN_LIMIT := 400   ## frames to wait before we call it a failure

var host: Session
var guest: Session

func before_each() -> void:
	host = Session.new()
	guest = Session.new()

func after_each() -> void:
	host.close()
	guest.close()

## Pumps both sides until the condition holds or patience runs out.
func _spin_until(check: Callable) -> bool:
	for i in SPIN_LIMIT:
		host.poll()
		guest.poll()
		if check.call():
			return true
		OS.delay_msec(5)
	return false

func test_guest_connects_to_host() -> void:
	assert_eq(host.host(PORT), OK, "the host must take the port")
	assert_eq(guest.join("ws://127.0.0.1:%d" % PORT), OK)
	assert_true(_spin_until(func() -> bool:
		return host.state == Session.State.CONNECTED \
			and guest.state == Session.State.CONNECTED),
		"the sides did not connect")

func test_packet_travels_both_ways() -> void:
	host.host(PORT + 1)
	guest.join("ws://127.0.0.1:%d" % (PORT + 1))
	assert_true(_spin_until(func() -> bool:
		return guest.state == Session.State.CONNECTED), "did not connect")

	var seen_by_guest: Array = []
	var seen_by_host: Array = []
	guest.packet_received.connect(func(d: PackedByteArray) -> void: seen_by_guest.append(d))
	host.packet_received.connect(func(d: PackedByteArray) -> void: seen_by_host.append(d))

	host.send(Protocol.pack_input(42, Types.IN_UP))
	guest.send(Protocol.pack_input(42, Types.IN_LEFT))
	assert_true(_spin_until(func() -> bool:
		return seen_by_guest.size() > 0 and seen_by_host.size() > 0),
		"the packets never arrived")

	var from_host := Protocol.unpack(seen_by_guest[0])
	assert_eq(from_host.kind, Protocol.Kind.INPUT)
	assert_eq(from_host.tick, 42)
	assert_eq(from_host.bits, Types.IN_UP)

	var from_guest := Protocol.unpack(seen_by_host[0])
	assert_eq(from_guest.bits, Types.IN_LEFT)

func test_joining_nowhere_fails_instead_of_hanging() -> void:
	# A wrong address — the game must say so honestly rather than wait forever.
	guest.join("ws://127.0.0.1:%d" % (PORT + 2))
	assert_true(_spin_until(func() -> bool:
		return guest.state == Session.State.FAILED),
		"connecting into nothing must end in a refusal")

func test_sending_before_connection_is_silent() -> void:
	# Sending before the connection is up must not crash the game: the screens
	# call send without asking whether the link is ready.
	host.send(Protocol.pack_input(1, 0))
	assert_eq(host.state, Session.State.IDLE)
