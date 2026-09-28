extends GutTest

## Where the picture stands when the viewport is widened for the thumbs.

func test_the_picture_is_centred() -> void:
	# An iPhone in landscape at scale four: 633 base pixels across.
	assert_eq(StageLayout.offset_x(633.0), 188)

func test_a_viewport_no_wider_than_the_picture_has_no_offset() -> void:
	assert_eq(StageLayout.offset_x(256.0), 0)
	assert_eq(StageLayout.offset_x(200.0), 0, "a narrow window must not push it off")

func test_portrait() -> void:
	assert_true(StageLayout.portrait(Vector2i(1170, 2532)))
	assert_false(StageLayout.portrait(Vector2i(2532, 1170)))
	assert_false(StageLayout.portrait(Vector2i(1000, 1000)), "a square plays")
