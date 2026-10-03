extends GutTest

## The mobile field grows into the old HUD column; desktop keeps that column.

var screen: Node2D

func before_each() -> void:
	TouchDevice.force(0)
	screen = load("res://ui/game.tscn").instantiate()
	add_child_autofree(screen)

func after_each() -> void:
	TouchDevice.force(-1)

func _mobile(view: Vector2) -> void:
	if screen.has_method("layout_touch"):
		screen.call("layout_touch", view)

func test_mobile_has_a_larger_square_field_and_a_row_below_it() -> void:
	_mobile(Vector2(256, 556))
	var field := screen.get_node("Field") as Node2D
	var hud := screen.get_node("Hud") as Node2D
	var width := 208.0 * field.global_scale.x
	var height := 208.0 * field.global_scale.y
	assert_gt(width, 208.0, "the old right column still takes the field's width")
	assert_almost_eq(width, height, 0.01, "the field was stretched")
	assert_gte(hud.global_position.y, field.global_position.y + height)

func test_short_and_rotated_mobile_screens_fit_the_field_and_hud() -> void:
	for view in [Vector2(256, 400), Vector2(600, 240), Vector2(256, 556)]:
		_mobile(view)
		var field := screen.get_node("Field") as Node2D
		var hud := screen.get_node("Hud") as Node2D
		var end := field.global_position + Vector2(208, 208) * field.global_scale
		assert_gte(hud.global_position.y, end.y, "the HUD is back beside the field")
		assert_lte(end.x, view.x)
		assert_lte(end.y, view.y)
		assert_lte(hud.global_position.y + 32.0 * hud.global_scale.y, view.y)

func test_desktop_keeps_the_original_field_and_right_panel() -> void:
	var field := screen.get_node("Field") as Node2D
	var hud := screen.get_node("Hud") as Node2D
	assert_eq(field.position, Vector2(8, 16))
	assert_eq(field.scale, Vector2.ONE)
	assert_eq(hud.position, Vector2(216, 16))
	assert_eq(hud.scale, Vector2.ONE)
