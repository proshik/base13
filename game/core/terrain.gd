class_name Terrain

## A 26x26 grid of 8-pixel cells. Fine — half a tile — because a bullet chews a
## quarter out of a brick rather than the whole block.

var _cells: PackedByteArray

func _init() -> void:
	_cells = PackedByteArray()
	_cells.resize(Consts.GRID * Consts.GRID)
	_cells.fill(Types.Cell.EMPTY)

static func in_bounds(cx: int, cy: int) -> bool:
	return cx >= 0 and cy >= 0 and cx < Consts.GRID and cy < Consts.GRID

func get_cell(cx: int, cy: int) -> int:
	# Beyond the field lies concrete: the borders go through the same code as
	# the walls.
	if not in_bounds(cx, cy):
		return Types.Cell.STEEL
	return _cells[cy * Consts.GRID + cx]

func set_cell(cx: int, cy: int, value: int) -> void:
	if not in_bounds(cx, cy):
		return
	_cells[cy * Consts.GRID + cx] = value

func blocks_tank(cx: int, cy: int) -> bool:
	var c := get_cell(cx, cy)
	return c == Types.Cell.BRICK or c == Types.Cell.STEEL or c == Types.Cell.WATER

func blocks_bullet(cx: int, cy: int) -> bool:
	var c := get_cell(cx, cy)
	return c == Types.Cell.BRICK or c == Types.Cell.STEEL

func cell_at_unit(v: Vector2i) -> Vector2i:
	return Vector2i(_div_floor(v.x, Consts.CELL), _div_floor(v.y, Consts.CELL))

func rect_blocks_tank(pos: Vector2i, size: int) -> bool:
	var c0 := cell_at_unit(pos)
	var c1 := cell_at_unit(pos + Vector2i(size - 1, size - 1))
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			if blocks_tank(cx, cy):
				return true
	return false

func destroy_cell(cx: int, cy: int, can_break_steel: bool) -> int:
	var c := get_cell(cx, cy)
	if c == Types.Cell.BRICK or (c == Types.Cell.STEEL and can_break_steel and in_bounds(cx, cy)):
		set_cell(cx, cy, Types.Cell.EMPTY)
		return c
	return -1

func clone() -> Terrain:
	var copy := Terrain.new()
	copy._cells = _cells.duplicate()
	return copy

func cells_checksum() -> int:
	var h := 2166136261
	for i in _cells.size():
		h = (h ^ _cells[i]) & 0xFFFFFFFF
		h = (h * 16777619) & 0xFFFFFFFF
	return h

## Division rounding towards minus infinity: GDScript's built-in integer
## division truncates towards zero, which would pick the wrong cell for a
## negative coordinate.
static func _div_floor(a: int, b: int) -> int:
	if a >= 0:
		return a / b
	return -(((-a) + b - 1) / b)
