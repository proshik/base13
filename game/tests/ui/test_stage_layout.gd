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

## An iPhone 16 Pro held upright in Safari: the viewport keeps the picture's width,
## 256, and grows down to 556.
const UPRIGHT := Vector2(256, 556)
## The same phone on its side: the viewport keeps the height, 240, and grows across.
const ON_ITS_SIDE := Vector2(600, 240)

func test_upright_the_picture_stands_at_the_top() -> void:
	var at := StageLayout.picture_at(UPRIGHT)
	assert_eq(at.x, 0)
	assert_between(at.y, 0, StageLayout.TOP_MARGIN, "the picture is at the top")

func test_on_its_side_the_picture_is_centred() -> void:
	assert_eq(StageLayout.picture_at(ON_ITS_SIDE), Vector2i(172, 0))

func test_upright_the_thumbs_have_everything_below_the_picture() -> void:
	var bottom := StageLayout.picture_at(UPRIGHT).y + StageLayout.BASE.y
	var stick := StageLayout.stick_zone(UPRIGHT)
	var buttons := StageLayout.button_zone(UPRIGHT)
	assert_gte(stick.position.y, float(bottom), "the stick covers the picture")
	assert_gte(buttons.position.y, float(bottom), "the buttons cover the picture")
	assert_eq(stick.end.y, UPRIGHT.y)
	assert_eq(buttons.end.y, UPRIGHT.y)
	assert_lte(stick.end.x, buttons.position.x, "the two zones overlap")
	assert_gte(stick.size.x, 112.0, "a thumb needs room to land anywhere and pull")

func test_on_its_side_the_thumbs_have_the_strips() -> void:
	var stick := StageLayout.stick_zone(ON_ITS_SIDE)
	var buttons := StageLayout.button_zone(ON_ITS_SIDE)
	assert_eq(stick, Rect2(0, 0, 172, 240))
	assert_eq(buttons, Rect2(428, 0, 172, 240))

func test_a_short_upright_window_gives_up_the_margin() -> void:
	# Safari's bars take height: the controls need it more than the notch does.
	assert_eq(StageLayout.picture_at(Vector2(256, 400)).y, 0)

func test_upright_the_thumbs_sit_low() -> void:
	# A phone held upright is held by its bottom half: the controls go where the
	# thumbs already are, not in the middle of the space below the picture.
	var row := StageLayout.thumb_row(UPRIGHT)
	assert_gte(row, UPRIGHT.y - 72.0, "the controls float too high")
	assert_lt(row, UPRIGHT.y - 32.0, "the controls fall off the bottom")

func test_a_short_upright_window_keeps_the_row_below_the_picture() -> void:
	var view := Vector2(256, 400)
	var top := StageLayout.stick_zone(view).position.y
	assert_gte(StageLayout.thumb_row(view), top + 32.0)
