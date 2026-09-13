extends GutTest

const ATLASES := {
	"res://assets/sprites.png": Vector2i(256, 96),
	"res://assets/terrain.png": Vector2i(64, 8),
	"res://assets/bullets.png": Vector2i(16, 4),
	"res://assets/font.png": Vector2i(128, 24),
}

func _image(path: String) -> Image:
	var texture: Texture2D = ResourceLoader.load(path)
	assert_not_null(texture, "atlas %s is missing" % path)
	return texture.get_image()

func _frame_is_drawn(img: Image, frame: int, cell: int, columns: int) -> bool:
	var ox := (frame % columns) * cell
	var oy := (frame / columns) * cell
	for y in cell:
		for x in cell:
			if img.get_pixel(ox + x, oy + y).a > 0.0:
				return true
	return false

func test_atlases_have_the_expected_size() -> void:
	for path in ATLASES:
		var img := _image(path)
		assert_eq(Vector2i(img.get_width(), img.get_height()), ATLASES[path],
			"the size of atlas %s" % path)

func test_every_sprite_frame_is_drawn() -> void:
	var img := _image("res://assets/sprites.png")
	for frame in 86:
		assert_true(_frame_is_drawn(img, frame, 16, 16),
			"frame %d in sprites.png is empty: the sprite was not drawn" % frame)

func test_every_terrain_and_bullet_frame_is_drawn() -> void:
	var terrain := _image("res://assets/terrain.png")
	for frame in 6:
		assert_true(_frame_is_drawn(terrain, frame, 8, 8), "terrain frame %d is empty" % frame)
	var bullets := _image("res://assets/bullets.png")
	for frame in 4:
		assert_true(_frame_is_drawn(bullets, frame, 4, 4), "bullet frame %d is empty" % frame)

func test_every_font_glyph_is_drawn() -> void:
	var img := _image("res://assets/font.png")
	for frame in TextPainter.COLON + 1:
		assert_true(_frame_is_drawn(img, frame, 8, 16), "glyph %d is empty" % frame)

## The glyph number is computed by arithmetic rather than a table: drifting out
## of step with the atlas, it would draw a neighbouring letter instead of the
## right one — and nothing would fail.
func test_glyph_numbers_match_the_atlas_order() -> void:
	assert_eq(TextPainter.glyph_index("0"), 0)
	assert_eq(TextPainter.glyph_index("9"), 9)
	assert_eq(TextPainter.glyph_index("A"), 10)
	assert_eq(TextPainter.glyph_index("Z"), 35)
	assert_eq(TextPainter.glyph_index("."), 36)
	assert_eq(TextPainter.glyph_index(":"), 37)

## An address without dots is not an address: "192.168.1.5" was drawn as
## "19216815".
func test_an_address_is_drawn_whole() -> void:
	for ch in "192.168.31.5:8080":
		assert_true(TextPainter.glyph_index(ch) >= 0,
			"the character '%s' from the address is unknown to the font" % ch)

func test_tank_directions_differ() -> void:
	# A tank facing up and a tank facing right are a rotation, not the same
	# frame.
	var img := _image("res://assets/sprites.png")
	var up := img.get_region(Rect2i(0, 0, 16, 16))
	var right := img.get_region(Rect2i(32, 0, 16, 16))
	assert_ne(up.get_data(), right.get_data(), "a tank's directions must differ")

func test_icon_is_square_and_drawn() -> void:
	# The icon is ours, made from our own sprites: no foreign picture may be
	# dragged into the project.
	var img := _image("res://assets/icon.png")
	assert_eq(img.get_width(), img.get_height(), "the icon must be square")
	assert_gte(img.get_width(), 128, "a small icon would smear in the dock")
	var lit := 0
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			if img.get_pixel(x, y).a > 0.0:
				lit += 1
	assert_gt(lit, 0, "the icon is empty")

func test_boot_splash_is_ours() -> void:
	# Without a splash of our own, Godot shows its own logo at startup.
	var img := _image("res://assets/boot.png")
	assert_gte(img.get_width(), 256, "a splash smaller than the game window would smear")
	var lit := 0
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			if img.get_pixel(x, y).r > 0.3:
				lit += 1
	assert_gt(lit, 0, "the splash is empty, nothing is drawn on it")

func test_macos_icon_follows_the_guidelines() -> void:
	# A 1024 canvas with the body a rounded square with margins: the canvas
	# corners are transparent, the body corners are rounded, the centre is
	# opaque. macOS applies no mask of its own.
	var img := _image("res://assets/icon_macos.png")
	assert_eq(Vector2i(img.get_width(), img.get_height()), Vector2i(1024, 1024))
	assert_eq(img.get_pixel(2, 2).a, 0.0, "the corner of the canvas is a transparent margin")
	assert_eq(img.get_pixel(105, 105).a, 0.0, "the corner of the body is cut by the rounding")
	assert_gt(img.get_pixel(512, 512).a, 0.9, "the centre is opaque")
	assert_gt(img.get_pixel(512, 110).a, 0.9, "the top of the body is inside the mask")
