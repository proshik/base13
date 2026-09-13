class_name TextPainter

## The font lives in the same kind of atlas as the sprites: digits, capital
## Latin letters, then a period and a colon. A real font would drag in a
## resource that cannot be written by hand as text, and no more characters are
## needed in this interface anyway.

const GLYPH_PX := 8    ## cell size in the atlas
const ADVANCE := 6     ## a glyph fills five columns of the cell plus a space
const COLUMNS := 16
const DIGITS := 10
const LETTERS := 26
## The glyph numbering is fixed by the atlas generator: a reshuffle would shift
## every caption in the game at once.
const DOT := DIGITS + LETTERS
const COLON := DOT + 1
const SCREEN_WIDTH := 256

## Caption width in pixels. Measuring by GLYPH_PX is wrong: two columns of each
## cell are empty, and the caption comes out wider than it looks.
static func width_of(text: String, scale := 1) -> int:
	return text.length() * ADVANCE * scale

static func glyph_index(ch: String) -> int:
	if ch.length() != 1:
		return -1
	var code := ch.to_upper().unicode_at(0)
	if code >= 48 and code <= 57:        # '0'..'9'
		return code - 48
	if code >= 65 and code <= 90:        # 'A'..'Z'
		return DIGITS + code - 65
	if ch == ".":
		return DOT
	if ch == ":":
		return COLON
	return -1

## Whole-number scale only: a fractional one would stretch the font cells
## unevenly and the letters would vary in thickness. The larger size is for
## captions that get read aloud — a room code is dictated over the phone.
static func draw_line(node: CanvasItem, atlas: Texture2D, text: String,
		at: Vector2i, tint := Color.WHITE, scale := 1) -> void:
	for i in text.length():
		var glyph := glyph_index(text[i])
		if glyph < 0:
			continue
		var src := Rect2i((glyph % COLUMNS) * GLYPH_PX, (glyph / COLUMNS) * GLYPH_PX,
			GLYPH_PX, GLYPH_PX)
		var dst := Rect2(at + Vector2i(i * ADVANCE * scale, 0),
			Vector2(GLYPH_PX * scale, GLYPH_PX * scale))
		node.draw_texture_rect_region(atlas, dst, src, tint)

## A line centred on the 256-wide screen: otherwise every screen would carry its
## own copy of this arithmetic.
static func draw_centred(node: CanvasItem, atlas: Texture2D, text: String,
		y: int, tint := Color.WHITE, scale := 1) -> void:
	var x := (SCREEN_WIDTH - width_of(text, scale)) / 2
	draw_line(node, atlas, text, Vector2i(x, y), tint, scale)
