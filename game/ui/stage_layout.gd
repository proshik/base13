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
## Upright, the stick's share of the width below the picture: a little over half,
## since a thumb pulls across it and only taps the buttons.
const STICK_SHARE := 0.55

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
static func stick_zone(view: Vector2) -> Rect2:
	if not _upright(view):
		return Rect2(0, 0, offset_x(view.x), view.y)
	var top := float(picture_at(view).y + BASE.y)
	return Rect2(0, top, roundf(view.x * STICK_SHARE), view.y - top)

## Where the two buttons stand.
static func button_zone(view: Vector2) -> Rect2:
	if not _upright(view):
		var left := float(offset_x(view.x) + BASE.x)
		return Rect2(left, 0, view.x - left, view.y)
	var stick := stick_zone(view)
	return Rect2(stick.end.x, stick.position.y, view.x - stick.end.x, stick.size.y)

## A viewport is upright when it kept the picture's width and grew down.
static func _upright(view: Vector2) -> bool:
	return view.y > view.x
