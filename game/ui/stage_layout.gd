class_name StageLayout

## Where the 256×240 picture stands in a viewport widened for the thumbs. On a touch
## screen the viewport keeps its height and takes the window's width, so the strips
## beside the picture are free for the stick and the buttons; the picture stays in
## the middle, at a whole scale as everywhere else.

const BASE := Vector2i(256, 240)

static func offset_x(viewport_width: float) -> int:
	return maxi(0, (int(viewport_width) - BASE.x) / 2)

## Taller than wide. A square plays: an iPad held either way is near enough.
static func portrait(window: Vector2i) -> bool:
	return window.y > window.x
