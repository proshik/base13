extends GutTest

func test_macbook_fourteen_fits_three_times() -> void:
	# 1512x982 is the MacBook Pro 14's default logical resolution.
	assert_eq(WindowScale.best_scale(Vector2i(1512, 982)), 3)

func test_more_space_setting_gives_four() -> void:
	# The same device in "more space" mode.
	assert_eq(WindowScale.best_scale(Vector2i(1800, 1169)), 4)

func test_height_is_the_binding_constraint() -> void:
	# The field is wider than it is tall, so height is always the constraint.
	assert_eq(WindowScale.best_scale(Vector2i(4000, 982)), 3,
		"a wide monitor grants no extra scale if it is short")

func test_big_monitor_is_capped() -> void:
	assert_eq(WindowScale.best_scale(Vector2i(7680, 4320)), WindowScale.MAX_SCALE,
		"we stop at eight: beyond that a window larger than the screen is pointless")

func test_tiny_screen_never_goes_below_one() -> void:
	assert_eq(WindowScale.best_scale(Vector2i(200, 150)), 1,
		"less than one pixel per pixel does not happen")

func test_reserve_is_taken_off_the_height() -> void:
	assert_eq(WindowScale.best_scale(Vector2i(1024, 960 + 40), 40), 4)
	assert_eq(WindowScale.best_scale(Vector2i(1024, 960 + 39), 40), 3,
		"a pixel short for the title bar: take the smaller scale")

func test_window_size_is_the_base_times_scale() -> void:
	assert_eq(WindowScale.BASE * 3, Vector2i(768, 720))
