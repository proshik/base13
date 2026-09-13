extends GutTest

func test_field_geometry_is_consistent() -> void:
	assert_eq(Consts.GRID, 26, "the field is 26 cells to a side")
	assert_eq(Consts.CELL_PX, 8, "a terrain cell is 8 pixels")
	assert_eq(Consts.FIELD_PX, 208, "the field is 208 pixels")
	assert_eq(Consts.FIELD, 3328, "the field is 3328 units")
	assert_eq(Consts.TANK, 256, "a tank is 16 pixels = 256 units")
	assert_eq(Consts.CELL, 128, "a cell is 8 pixels = 128 units")
