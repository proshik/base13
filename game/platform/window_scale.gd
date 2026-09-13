class_name WindowScale

## Fitting the window size to the screen. Pixel art must not be stretched by a
## fraction: the scale has to be a whole number, or the pixels end up different
## sizes and the picture falls apart. So the window is not "somewhat bigger" but
## an exact multiple of 256x240.

const BASE := Vector2i(256, 240)
const MAX_SCALE := 8
const TITLE_BAR := 40   ## height allowance for the window title bar

## `usable` is the part of the screen actually available to a window: menu bar
## and dock excluded.
static func best_scale(usable: Vector2i, reserve := TITLE_BAR) -> int:
	var by_width := usable.x / BASE.x
	var by_height := (usable.y - reserve) / BASE.y
	return clampi(mini(by_width, by_height), 1, MAX_SCALE)
