class_name StageLayout

## Where the 256×240 picture stands on a touch screen, and what is left for the
## thumbs. On its side the viewport keeps the picture's height and takes the
## window's width: the picture stands in the middle, the stick in the strip to its
## left, the buttons in the strip to its right. Upright the viewport keeps the
## picture's width and takes the window's height: the picture stands at the top,
## and everything below it is the thumbs'.

const BASE := Vector2i(256, 240)
## Upright, room above the picture for a phone's notch over a home-screen install,
## where nothing of the browser stands between the page and the top of the screen.
const TOP_MARGIN := 16
## Upright, the least height the controls need below the picture: a shorter
## window gives up the margin first.
const CONTROLS_MIN := 160
## Upright, the stick's share of the width below the picture. The rest holds START
## in the middle and FIRE on the right; the gap leaves START's hit target clear.
const STICK_SHARE := 0.4
## Upright, how high above the bottom the thumbs rest: a phone held upright is held
## by its bottom half.
const ROW_FROM_BOTTOM := 56.0
## A phone game has a square field and a HUD row below it.
const MOBILE_GAME := Vector2(256, 288)
const DECK_HEIGHT := 140.0

static func offset_x(viewport_width: float) -> int:
	return maxi(0, (int(viewport_width) - BASE.x) / 2)

## Taller than wide. A square plays on its side: an iPad held either way is near
## enough.
static func portrait(window: Vector2i) -> bool:
	return window.y > window.x

## The picture's top left corner in a viewport of this size.
static func picture_at(view: Vector2) -> Vector2i:
	if not _upright(view):
		return Vector2i(offset_x(view.x), 0)
	var spare := int(view.y) - BASE.y
	return Vector2i(0, TOP_MARGIN if spare >= TOP_MARGIN + CONTROLS_MIN else 0)

## Where a thumb may land to take the stick: all of it, so there is no spot to hit.
static func stick_zone(view: Vector2, playing := false) -> Rect2:
	if not _upright(view):
		var left := game_rect(view).position.x if playing else float(offset_x(view.x))
		return Rect2(0, 0, left, view.y)
	var top := game_rect(view).end.y if playing else float(picture_at(view).y + BASE.y)
	return Rect2(0, top, roundf(view.x * STICK_SHARE), view.y - top)

## Where the two buttons stand.
static func button_zone(view: Vector2, playing := false) -> Rect2:
	if not _upright(view):
		var left := game_rect(view).end.x if playing else float(offset_x(view.x) + BASE.x)
		return Rect2(left, 0, view.x - left, view.y)
	var stick := stick_zone(view, playing)
	return Rect2(stick.end.x, stick.position.y, view.x - stick.end.x, stick.size.y)

## The height the cross and the buttons rest at. On its side, a little below the
## middle of the strips; upright, low, where the thumbs already are — but never so
## low on a short window that a control leaves the space below the picture.
static func thumb_row(view: Vector2, playing := false) -> float:
	if not _upright(view):
		return view.y * 0.6
	var zone := stick_zone(view, playing)
	return maxf(view.y - ROW_FROM_BOTTOM, zone.position.y + 40.0)

## A viewport is upright when it kept the picture's width and grew down.
static func _upright(view: Vector2) -> bool:
	return view.y > view.x

## The phone's field is 240 square in a 256-wide frame, with a 32-high HUD row
## underneath. A short portrait gives the controls 140 first; landscape fits the
## whole frame to the window's height and leaves the thumbs the side strips.
static func game_rect(view: Vector2) -> Rect2:
	if not _upright(view):
		var factor := minf(view.y / MOBILE_GAME.y, view.x / MOBILE_GAME.x)
		var size := MOBILE_GAME * factor
		return Rect2(Vector2((view.x - size.x) / 2.0, 0), size)
	var top := 8.0 if view.y >= MOBILE_GAME.y + DECK_HEIGHT + 8.0 else 0.0
	var factor := minf(view.x / MOBILE_GAME.x,
		maxf(1.0, view.y - DECK_HEIGHT - top) / MOBILE_GAME.y)
	var size := MOBILE_GAME * factor
	return Rect2(Vector2((view.x - size.x) / 2.0, top), size)

static func deck_rect(view: Vector2, playing := false) -> Rect2:
	var top := maxf(stick_zone(view, playing).position.y, view.y - DECK_HEIGHT)
	return Rect2(0, top, view.x, view.y - top)
