extends GutTest

## Two network screens against a real server. The layer beneath them is already
## checked separately; what is checked here is the wiring — the part that until
## now only broke by hand: which of the two is player one, who receives the
## seed, and when a screen goes into the game.

const PORT := 27351
const SPIN_LIMIT := 600

var _pid := -1
var _url := ""

func after_each() -> void:
	if _pid > 0:
		OS.kill(_pid)
		_pid = -1

func _binary() -> String:
	# The binary lives in the repository root rather than in the Godot project:
	# it is built from server/ and has nothing to do with the game. res:// points
	# into game/, hence the step up.
	return ProjectSettings.globalize_path("res://") + "../.build/relay"

func _start_server() -> bool:
	if not FileAccess.file_exists(_binary()):
		return false
	_url = "ws://127.0.0.1:%d/ws" % PORT
	_pid = OS.create_process(_binary(), ["-addr=127.0.0.1:%d" % PORT])
	if _pid <= 0:
		return false
	for i in SPIN_LIMIT:
		var probe := StreamPeerTCP.new()
		if probe.connect_to_host("127.0.0.1", PORT) == OK:
			for step in 20:
				probe.poll()
				if probe.get_status() == StreamPeerTCP.STATUS_CONNECTED:
					probe.disconnect_from_host()
					return true
				OS.delay_msec(5)
		probe.disconnect_from_host()
		OS.delay_msec(10)
	return false

func _screen() -> Node:
	var node = load("res://ui/net.gd").new()
	node.relay_url = _url
	add_child_autofree(node)
	return node

## An item is chosen by name rather than by number: the numbers already drifted
## once when the list grew.
func _pick(screen: Node, title: String) -> void:
	var index: int = screen.ITEMS.find(title)
	assert_true(index >= 0, "there is no '%s' item in the menu" % title)
	screen._choice = index
	screen._act()

func _spin(screens: Array, check: Callable) -> bool:
	for i in SPIN_LIMIT:
		for screen in screens:
			screen._process(0.016)
		if check.call():
			return true
		OS.delay_msec(5)
	return false

func test_two_screens_meet_by_code_and_agree_on_everything() -> void:
	if not FileAccess.file_exists(_binary()):
		pending("the server is not built: .build/relay is missing (Go required)")
		return
	assert_true(_start_server(), "the server did not start")

	var host := _screen()
	var host_outcome := []
	host.finished.connect(func(value: int) -> void: host_outcome.append(value))
	_pick(host, "CREATE ROOM")
	assert_true(_spin([host], func() -> bool: return host._mode == host.Mode.ROOM_WAIT),
		"the room did not open, the screen stayed at %d" % host._mode)
	assert_eq(host.link.code.length(), 6, "the code is shown to a human, so it is short")
	assert_eq(host_outcome, [], "the creator must wait for a partner rather than go into the game")

	var guest := _screen()
	var guest_outcome := []
	guest.finished.connect(func(value: int) -> void: guest_outcome.append(value))
	_pick(guest, "JOIN ROOM")
	for ch in host.link.code:
		var event := InputEventKey.new()
		event.pressed = true
		event.unicode = ch.unicode_at(0)
		guest._type_code(event)
	var enter := InputEventKey.new()
	enter.pressed = true
	enter.physical_keycode = KEY_ENTER
	guest._type_code(enter)

	assert_true(_spin([host, guest],
		func() -> bool: return not host_outcome.is_empty() and not guest_outcome.is_empty()),
		"the screens did not go into the game: creator %s, guest %s" % [host_outcome, guest_outcome])
	assert_eq(host_outcome, [ScreenFlow.Outcome.CONTINUE])
	assert_eq(guest_outcome, [ScreenFlow.Outcome.CONTINUE])

	# Player order must differ and must match the slot in the room, or both would
	# drive the same tank.
	assert_eq(host.local_index, 0)
	assert_eq(guest.local_index, 1)
	# One seed for both: every level's seed is derived from it.
	assert_eq(guest.seed_value, host.seed_value, "the sides received different seeds")
	assert_ne(host.seed_value, 0, "a game's seed must not be zero")

	host.link.close()
	guest.link.close()

func test_wrong_code_is_explained_and_not_silently_swallowed() -> void:
	if not FileAccess.file_exists(_binary()):
		pending("the server is not built: .build/relay is missing (Go required)")
		return
	assert_true(_start_server(), "the server did not start")

	var guest := _screen()
	_pick(guest, "JOIN ROOM")
	for ch in "ZZZZZZ":
		var event := InputEventKey.new()
		event.pressed = true
		event.unicode = ch.unicode_at(0)
		guest._type_code(event)
	var enter := InputEventKey.new()
	enter.pressed = true
	enter.physical_keycode = KEY_ENTER
	guest._type_code(enter)

	assert_true(_spin([guest], func() -> bool: return guest._mode == guest.Mode.FAILED),
		"the screen did not answer a foreign code")
	assert_eq(guest._trouble, "NO SUCH ROOM", "the human must be told what exactly is wrong")

## The whole quick game: two screens against a real server. Nobody dictated a
## code and nobody typed an address — the server brought them together.
func test_two_screens_meet_by_pressing_one_button() -> void:
	if not FileAccess.file_exists(_binary()):
		pending("the server is not built: .build/relay is missing (Go required)")
		return
	assert_true(_start_server(), "the server did not start")

	var first := _screen()
	var first_outcome := []
	first.finished.connect(func(value: int) -> void: first_outcome.append(value))
	_pick(first, "QUICK GAME")
	assert_true(_spin([first], func() -> bool: return first._mode == first.Mode.QUICK_WAIT),
		"the first one did not start waiting, the screen is in state %d" % first._mode)
	assert_eq(first_outcome, [], "a waiter must wait rather than go into the game")

	var second := _screen()
	var second_outcome := []
	second.finished.connect(func(value: int) -> void: second_outcome.append(value))
	_pick(second, "QUICK GAME")

	assert_true(_spin([first, second],
		func() -> bool: return not first_outcome.is_empty() and not second_outcome.is_empty()),
		"the screens did not go into the game: first %s, second %s" % [first_outcome, second_outcome])
	assert_eq(first_outcome, [ScreenFlow.Outcome.CONTINUE])
	assert_eq(second_outcome, [ScreenFlow.Outcome.CONTINUE])

	# Player order must differ, or both would drive the same tank.
	assert_eq(first.local_index, 0)
	assert_eq(second.local_index, 1)
	assert_eq(second.seed_value, first.seed_value, "the sides received different seeds")
	assert_ne(first.seed_value, 0, "a game's seed must not be zero")

	first.link.close()
	second.link.close()

## Quick game and a room by code do not get in each other's way: matchmaking
## must not seat a random passer-by in a room whose code was dictated to
## somebody.
func test_quick_does_not_steal_a_private_room() -> void:
	if not FileAccess.file_exists(_binary()):
		pending("the server is not built: .build/relay is missing (Go required)")
		return
	assert_true(_start_server(), "the server did not start")

	var private := _screen()
	_pick(private, "CREATE ROOM")
	assert_true(_spin([private], func() -> bool: return private._mode == private.Mode.ROOM_WAIT),
		"the private room did not open")

	var stranger := _screen()
	_pick(stranger, "QUICK GAME")
	assert_true(_spin([private, stranger],
		func() -> bool: return stranger._mode == stranger.Mode.QUICK_WAIT),
		"the passer-by did not start waiting")
	assert_ne(stranger.link.code, private.link.code,
		"matchmaking took a room whose code had already been dictated")

	private.link.close()
	stranger.link.close()
