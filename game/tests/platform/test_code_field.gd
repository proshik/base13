extends GutTest

## The page's own field for a room code is made by a script the game formats and
## hands to the browser. A stray `%` in its CSS broke the formatting, the browser
## got no script, and the phone had no field to type into.

func test_the_page_script_formats() -> void:
	var script: String = CodeField.OPEN % [JSON.stringify(CodeField.ID), JSON.stringify("AB2")]
	assert_string_contains(script, "left:50%;")
	assert_string_contains(script, "translateX(-50%)")
	assert_string_contains(script, "\"AB2\"")
	assert_string_contains(script, "\"%s\"" % CodeField.ID)

func test_the_closing_script_formats() -> void:
	var script: String = CodeField.CLOSE % JSON.stringify(CodeField.ID)
	assert_string_contains(script, "\"%s\"" % CodeField.ID)

func test_the_share_script_formats() -> void:
	var script: String = RoomLink.SEND % JSON.stringify("https://base13.example/?room=ABC234")
	assert_string_contains(script, "\"https://base13.example/?room=ABC234\"")
