extends GutTest

var t: Terrain

func before_each() -> void:
	t = Terrain.new()

func test_starts_empty() -> void:
	for cy in Consts.GRID:
		for cx in Consts.GRID:
			assert_eq(t.get_cell(cx, cy), Types.Cell.EMPTY)

func test_set_and_get() -> void:
	t.set_cell(3, 4, Types.Cell.BRICK)
	assert_eq(t.get_cell(3, 4), Types.Cell.BRICK)
	assert_eq(t.get_cell(4, 3), Types.Cell.EMPTY, "neighbouring cells are untouched")

func test_out_of_bounds_reads_as_steel() -> void:
	assert_eq(t.get_cell(-1, 0), Types.Cell.STEEL)
	assert_eq(t.get_cell(0, -1), Types.Cell.STEEL)
	assert_eq(t.get_cell(Consts.GRID, 0), Types.Cell.STEEL)
	assert_true(t.blocks_tank(-1, 0), "beyond the border a tank cannot pass")
	assert_true(t.blocks_bullet(-1, 0), "beyond the border a bullet stops")

func test_blocking_rules() -> void:
	t.set_cell(1, 1, Types.Cell.BRICK)
	t.set_cell(2, 1, Types.Cell.STEEL)
	t.set_cell(3, 1, Types.Cell.WATER)
	t.set_cell(4, 1, Types.Cell.TREES)
	t.set_cell(5, 1, Types.Cell.ICE)

	assert_true(t.blocks_tank(1, 1), "brick stops a tank")
	assert_true(t.blocks_tank(2, 1), "concrete stops a tank")
	assert_true(t.blocks_tank(3, 1), "water stops a tank")
	assert_false(t.blocks_tank(4, 1), "a tank drives through forest")
	assert_false(t.blocks_tank(5, 1), "a tank drives over ice")

	assert_true(t.blocks_bullet(1, 1), "brick stops a bullet")
	assert_true(t.blocks_bullet(2, 1), "concrete stops a bullet")
	assert_false(t.blocks_bullet(3, 1), "a bullet flies over water")
	assert_false(t.blocks_bullet(4, 1), "a bullet flies through forest")
	assert_false(t.blocks_bullet(5, 1), "a bullet flies over ice")

func test_cell_at_unit() -> void:
	assert_eq(t.cell_at_unit(Vector2i(0, 0)), Vector2i(0, 0))
	assert_eq(t.cell_at_unit(Vector2i(Consts.CELL - 1, 0)), Vector2i(0, 0))
	assert_eq(t.cell_at_unit(Vector2i(Consts.CELL, 0)), Vector2i(1, 0))

func test_rect_blocks_tank_covers_all_touched_cells() -> void:
	# A 256-unit tank covers exactly two cells on each axis when grid-aligned.
	t.set_cell(2, 0, Types.Cell.BRICK)
	assert_true(t.rect_blocks_tank(Vector2i(Consts.CELL, 0), Consts.TANK),
		"a tank on cells 1..2 touches the brick in cell 2")
	assert_false(t.rect_blocks_tank(Vector2i(0, 0), Consts.TANK),
		"a tank on cells 0..1 does not touch the brick")

func test_rect_outside_field_is_blocked() -> void:
	assert_true(t.rect_blocks_tank(Vector2i(-1, 0), Consts.TANK))
	assert_true(t.rect_blocks_tank(Vector2i(Consts.FIELD - Consts.TANK + 1, 0), Consts.TANK))
	assert_false(t.rect_blocks_tank(Vector2i(Consts.FIELD - Consts.TANK, 0), Consts.TANK),
		"flush against the right edge is still allowed")

func test_destroy_brick() -> void:
	t.set_cell(5, 5, Types.Cell.BRICK)
	assert_eq(t.destroy_cell(5, 5, false), Types.Cell.BRICK, "the destroyed type came back")
	assert_eq(t.get_cell(5, 5), Types.Cell.EMPTY)

func test_steel_needs_power() -> void:
	t.set_cell(5, 5, Types.Cell.STEEL)
	assert_eq(t.destroy_cell(5, 5, false), -1, "without the third star concrete does not break")
	assert_eq(t.get_cell(5, 5), Types.Cell.STEEL)
	assert_eq(t.destroy_cell(5, 5, true), Types.Cell.STEEL)
	assert_eq(t.get_cell(5, 5), Types.Cell.EMPTY)

func test_water_and_trees_are_indestructible() -> void:
	t.set_cell(5, 5, Types.Cell.WATER)
	t.set_cell(6, 5, Types.Cell.TREES)
	assert_eq(t.destroy_cell(5, 5, true), -1)
	assert_eq(t.destroy_cell(6, 5, true), -1)

func test_clone_is_independent() -> void:
	t.set_cell(1, 1, Types.Cell.BRICK)
	var copy := t.clone()
	copy.set_cell(1, 1, Types.Cell.EMPTY)
	assert_eq(t.get_cell(1, 1), Types.Cell.BRICK, "the original must not change")

func test_checksum_reacts_to_change() -> void:
	var before := t.cells_checksum()
	t.set_cell(7, 7, Types.Cell.BRICK)
	assert_ne(before, t.cells_checksum())
