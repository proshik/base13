extends GutTest

## The meeting screen. What is checked is what has already broken here: picking
## an item, typing a code and the captions — the game's font knows only capital
## Latin letters and digits, and arbitrary text from the server will simply not
## render.

var net

func before_each() -> void:
	net = load("res://ui/net.gd").new()
	add_child_autofree(net)

func after_each() -> void:
	if net.link != null:
		net.link.close()
		net.link = null

## An item is chosen by name rather than by number: the numbers already drifted
## once when the list grew, and the tests failed for no good reason.
func _pick(title: String) -> void:
	var index: int = net.ITEMS.find(title)
	assert_true(index >= 0, "there is no '%s' item in the menu" % title)
	net._choice = index
	net._act()

func _press(keycode: int, unicode := 0) -> InputEventKey:
	var event := InputEventKey.new()
	event.pressed = true
	event.physical_keycode = keycode
	event.unicode = unicode
	return event

func test_join_room_asks_for_a_code() -> void:
	_pick("JOIN ROOM")
	assert_eq(net._mode, net.Mode.CODE_TYPING)

func test_lan_join_asks_for_an_address() -> void:
	_pick("LAN JOIN")
	assert_eq(net._mode, net.Mode.LAN_TYPING)

func test_typed_code_is_upper_case_and_bounded() -> void:
	_pick("JOIN ROOM")
	for ch in "ab3xy9z":
		net._type_code(_press(0, ch.unicode_at(0)))
	# Six characters is the length of a code; a seventh must not be accepted.
	assert_eq(net._typed, "AB3XY9")

func test_code_ignores_what_the_font_cannot_draw() -> void:
	_pick("JOIN ROOM")
	for ch in "A-B_C":
		net._type_code(_press(0, ch.unicode_at(0)))
	assert_eq(net._typed, "ABC")

func test_backspace_erases_the_last_character() -> void:
	_pick("JOIN ROOM")
	net._type_code(_press(0, "Q".unicode_at(0)))
	net._type_code(_press(KEY_BACKSPACE))
	assert_eq(net._typed, "")

func test_every_refusal_can_be_drawn_and_fits_the_screen() -> void:
	# A refusal in an unrenderable alphabet would look to a person like blank
	# space: the font is made of digits and capital Latin letters, and nothing
	# else is in it.
	for key in net.REFUSALS:
		var text: String = net.REFUSALS[key]
		for i in text.length():
			if text[i] == " ":
				continue
			assert_true(TextPainter.glyph_index(text[i]) >= 0,
				"the caption '%s' contains a character unknown to the font" % text)
		assert_lt(TextPainter.width_of(text), TextPainter.SCREEN_WIDTH,
			"the caption '%s' does not fit on the screen" % text)

func test_creator_waits_for_the_partner_and_shows_the_code() -> void:
	var relay := Relay.new()
	relay.code = "ABC234"
	relay.players = 1
	net.link = relay
	net._on_room_opened("ABC234", 0, 777)
	assert_eq(net._mode, net.Mode.ROOM_WAIT, "the creator must be shown the code")
	assert_eq(net.local_index, 0)
	assert_eq(net.seed_value, 777)

## Whoever joins by code finds the partner already there: nobody to wait for,
## the game starts.
func test_joining_player_starts_at_once() -> void:
	var relay := Relay.new()
	relay.code = "ABC234"
	relay.players = 2
	net.link = relay
	var outcome := []
	net.finished.connect(func(value: int) -> void: outcome.append(value))
	net._on_room_opened("ABC234", 1, 777)
	assert_eq(outcome, [ScreenFlow.Outcome.CONTINUE])
	assert_eq(net.local_index, 1, "whoever joined is player two")

func test_refusal_drops_the_link_and_names_the_cause() -> void:
	net.link = Relay.new()
	net._failed("no_room")
	assert_eq(net._mode, net.Mode.FAILED)
	assert_eq(net._trouble, "NO SUCH ROOM")
	assert_null(net.link, "there is no reason to keep a failed connection")

func test_room_code_fits_the_screen_at_its_larger_size() -> void:
	# The code is drawn large, and "it fits when small" proves nothing here:
	# six characters at triple width are half the screen.
	var widest := "W".repeat(net.CODE_LEN + 1)   # plus room for the typing cursor
	assert_lt(TextPainter.width_of(widest, net.CODE_SCALE),
		TextPainter.SCREEN_WIDTH, "the large code does not fit on the screen")

## The hint under a failure once advised checking Wi-Fi when the server simply
## was not running. Advice pointing the wrong way is worse than none: a person
## goes off to fix what is not broken.
func test_hint_after_a_failed_room_names_the_server() -> void:
	net.relay_url = "ws://192.168.31.5:8080/ws"
	net._via_room = true
	net._failed("NO CONNECTION")
	var hint := "".join(net.hint_lines())
	assert_string_contains(hint, "192.168.31.5:8080",
		"the human must be shown where the game was knocking")
	assert_false(hint.contains("WIFI"), "Wi-Fi has nothing to do with it")

func test_hint_after_a_failed_lan_game_speaks_of_wifi_and_permission() -> void:
	net._via_room = false
	net._failed("NO CONNECTION")
	var hint := "".join(net.hint_lines())
	assert_string_contains(hint, "WIFI")
	assert_string_contains(hint, "PERMISSION")

func test_refusal_by_the_server_needs_no_hint() -> void:
	# "No such room" explains itself; advice here is only noise.
	net._via_room = true
	net._failed("no_room")
	assert_eq(net.hint_lines(), [] as Array[String])

func test_every_hint_line_can_be_drawn_and_fits() -> void:
	net.relay_url = "ws://192.168.100.200:8080/ws"
	for via_room in [true, false]:
		net._via_room = via_room
		net._failed("NO CONNECTION")
		for line in net.hint_lines():
			for i in line.length():
				if line[i] == " ":
					continue
				assert_true(TextPainter.glyph_index(line[i]) >= 0,
					"the line '%s' contains a character unknown to the font" % line)
			assert_lt(TextPainter.width_of(line), TextPainter.SCREEN_WIDTH,
				"the line '%s' does not fit on the screen" % line)

## --- quick game ---

func test_quick_game_is_the_first_item() -> void:
	# The most common way to start, hence the first in the list.
	assert_eq(net.ITEMS[0], "QUICK GAME")

func test_waiting_player_sees_that_he_is_waiting() -> void:
	var relay := Relay.new()
	relay.players = 1
	net.link = relay
	net._via_quick = true
	net._on_room_opened("ABC234", 0, 111)
	assert_eq(net._mode, net.Mode.QUICK_WAIT,
		"whoever pressed quick game has no use for a code: there is nobody to dictate it to")
	assert_eq(net.local_index, 0)
	assert_eq(net.seed_value, 111)

func test_matched_player_starts_at_once() -> void:
	var relay := Relay.new()
	relay.players = 2
	net.link = relay
	var outcome := []
	net.finished.connect(func(value: int) -> void: outcome.append(value))
	net._on_room_opened("ABC234", 1, 111)
	assert_eq(outcome, [ScreenFlow.Outcome.CONTINUE])
	assert_eq(net.local_index, 1, "the matched one is player two")

## The creator of a private room and someone waiting on quick game land in the
## same handler but must see different things: one needs the code, the other
## does not.
func test_private_and_quick_waiting_look_different() -> void:
	var private := Relay.new()
	private.code = "ABC234"
	private.players = 1
	net.link = private
	net._via_quick = false
	net._on_room_opened("ABC234", 0, 1)
	assert_eq(net._mode, net.Mode.ROOM_WAIT)

	net._mode = net.Mode.CHOOSE
	net._via_quick = true
	net._on_room_opened("ABC234", 0, 1)
	assert_eq(net._mode, net.Mode.QUICK_WAIT)

func test_waiting_clock_counts_whole_seconds() -> void:
	# A stopwatch instead of a count of waiters: it promises nothing and cannot
	# lie.
	assert_eq(net.waited_text(0.0), "0:00")
	assert_eq(net.waited_text(9.4), "0:09")
	assert_eq(net.waited_text(75.0), "1:15")
	assert_eq(net.waited_text(605.0), "10:05")

func test_waiting_screen_text_fits_and_is_drawable() -> void:
	for line in ["LOOKING FOR PLAYER", "ESC CANCEL", net.waited_text(605.0)]:
		for i in line.length():
			if line[i] == " ":
				continue
			assert_true(TextPainter.glyph_index(line[i]) >= 0,
				"the line '%s' contains a character unknown to the font" % line)
		assert_lt(TextPainter.width_of(line), TextPainter.SCREEN_WIDTH,
			"the line '%s' does not fit on the screen" % line)
