extends GutTest

## A room's code carried in the page address, from one phone's share sheet to
## another's browser.

func test_a_code_is_read_from_the_link() -> void:
	assert_eq(RoomLink.code_in("https://base13.example/?room=ABC234"), "ABC234")
	assert_eq(RoomLink.code_in("https://base13.example/index.html?x=1&room=ABC234#top"),
		"ABC234")

func test_no_code_is_empty() -> void:
	assert_eq(RoomLink.code_in("https://base13.example/"), "")
	assert_eq(RoomLink.code_in("https://base13.example/?relay=ws"), "")
	assert_eq(RoomLink.code_in(""), "")

func test_a_code_in_the_link_is_cleaned() -> void:
	# A link is a stranger's text. What it carries reaches the screen and the
	# server only through the same rule as a typed code.
	var raw := RoomLink.code_in("https://base13.example/?room=ab%0Ac2%2034xyz")
	assert_eq(load("res://ui/net.gd").clean_code(raw), "ABC234")

func test_the_link_is_the_page_with_the_code() -> void:
	assert_eq(RoomLink.url_for("https://base13.example/index.html?selftest#x", "ABC234"),
		"https://base13.example/index.html?room=ABC234")
	assert_eq(RoomLink.url_for("https://base13.example/", "ABC234"),
		"https://base13.example/?room=ABC234")

func test_nothing_to_share_off_the_web() -> void:
	assert_eq(RoomLink.send("https://base13.example/?room=ABC234"), "")
