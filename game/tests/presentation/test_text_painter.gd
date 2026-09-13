extends GutTest

func test_digits_come_first() -> void:
	assert_eq(TextPainter.glyph_index("0"), 0)
	assert_eq(TextPainter.glyph_index("9"), 9)

func test_letters_follow_the_digits() -> void:
	assert_eq(TextPainter.glyph_index("A"), 10)
	assert_eq(TextPainter.glyph_index("Z"), 35)

func test_lowercase_is_treated_as_uppercase() -> void:
	assert_eq(TextPainter.glyph_index("a"), TextPainter.glyph_index("A"))

func test_space_and_unknown_characters_are_skipped() -> void:
	assert_eq(TextPainter.glyph_index(" "), -1)
	assert_eq(TextPainter.glyph_index("!"), -1)
	assert_eq(TextPainter.glyph_index(""), -1)

func test_advance_is_narrower_than_the_cell() -> void:
	# A glyph is drawn in five columns of an 8x8 cell; advancing by all eight
	# would stretch a caption wider than it needs to be.
	assert_lt(TextPainter.ADVANCE, TextPainter.GLYPH_PX)

func test_width_counts_by_advance() -> void:
	assert_eq(TextPainter.width_of("ENEMY"), 5 * TextPainter.ADVANCE)
	assert_eq(TextPainter.width_of(""), 0)

func test_hud_labels_fit_the_panel() -> void:
	# Exactly the break that made captions get clipped by the edge of the screen.
	for label in ["ENEMY", "STAGE", "1P", "2P"]:
		assert_lte(TextPainter.width_of(label) + HudPanel.TEXT_LEFT,
			int(HudPanel.PANEL_SIZE.x),
			"the caption %s does not fit in the panel" % label)
