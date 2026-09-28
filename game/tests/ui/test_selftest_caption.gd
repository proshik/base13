extends GutTest

## The selftest's result is read off a phone's screen, where there is no console.
## On one line it ran past the edge of the picture and cut off RESIM, the number
## the check is for.

const App := preload("res://ui/app.gd")

func test_every_line_fits_the_screen() -> void:
	var lines: Array[String] = App.selftest_lines(false, 4294967295, 99999, 99999, 99999)
	for line in lines:
		assert_lte(TextPainter.width_of(line), TextPainter.SCREEN_WIDTH, "'%s' is cut off" % line)

func test_the_numbers_are_all_there() -> void:
	var text := "\n".join(App.selftest_lines(true, 2233634213, 141, 50, 2900))
	for part in ["OK", "2233634213", "TICK 141", "SAVE 50", "RESIM 2900"]:
		assert_string_contains(text, part)

func test_every_line_can_be_drawn() -> void:
	for line in App.selftest_lines(false, 1, 2, 3, 4):
		for i in line.length():
			if line[i] != " ":
				assert_true(TextPainter.glyph_index(line[i]) >= 0, "'%s' cannot be drawn" % line)
