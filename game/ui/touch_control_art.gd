class_name TouchControlArt
extends Node2D

## The console panel and its moving surfaces. Hit targets belong to TouchControls:
## only the drawing moves, so a finger never chases an animating button.

const PANEL := Color("30302e")
const SOCKET := Color("1a1a19")
const CROSS := Color("d4d0c5")
const INSET := Color("b9b5ab")
const FIRE := Color("d85242")
const START := Color("aaa69b")
const INK := Color("eee9df")
const CELL := 24.0
const FIRE_RADIUS := 30.0
const START_SIZE := Vector2(32, 10)
const PRESS_SECONDS := 0.07
const RELEASE_SECONDS := 0.18

var _font: Texture2D = preload("res://assets/font.png")
var _cross: Node2D
var _fire: Node2D
var _start: Node2D
var _rest := {}
var _down := {}
var _tweens := {}
var _panels: Array[Rect2] = []
var _direction := 0
var _start_text := "START"

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_cross = _surface("CrossSurface", _paint_cross)
	_fire = _surface("FireSurface", _paint_fire)
	_start = _surface("StartSurface", _paint_start)

func _surface(title: String, paint: Callable) -> Node2D:
	var node := Node2D.new()
	node.name = title
	node.draw.connect(paint)
	add_child(node)
	return node

func place(cross: Vector2, fire: Vector2, start: Vector2, panels: Array[Rect2]) -> void:
	_rest = {&"cross": cross, &"touch_fire": fire, &"touch_start": start}
	_panels = panels
	for action in _rest:
		_stop_tween(action)
		var node := _node(action)
		node.position = _rest[action] + Vector2(0, 2 if _down.has(action) else 0)
	queue_redraw()

func set_start_text(text: String) -> void:
	_start_text = text
	queue_redraw()

func steer(direction: int) -> void:
	_direction = direction
	press(&"cross", direction != 0)
	_cross.queue_redraw()

func press(action: StringName, held: bool) -> void:
	if _down.has(action) == held:
		return
	if held:
		_down[action] = true
	else:
		_down.erase(action)
	_stop_tween(action)
	var node := _node(action)
	var target: float = _rest[action].y + (2.0 if held else 0.0)
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_QUAD if held else Tween.TRANS_BACK)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(node, "position:y", target, PRESS_SECONDS if held else RELEASE_SECONDS)
	_tweens[action] = tween
	node.queue_redraw()

func _node(action: StringName) -> Node2D:
	match action:
		&"touch_fire": return _fire
		&"touch_start": return _start
	return _cross

func _stop_tween(action: StringName) -> void:
	if _tweens.has(action):
		(_tweens[action] as Tween).kill()
		_tweens.erase(action)

func _draw() -> void:
	for panel in _panels:
		draw_rect(panel, PANEL)
		draw_line(panel.position, Vector2(panel.end.x, panel.position.y), Color("55554d"))
		if panel.size.y > 100:
			draw_line(panel.position + Vector2(12, 20),
				Vector2(panel.end.x - 12, panel.position.y + 20), Color("484843"))
	if _rest.is_empty():
		return
	var fire: Vector2 = _rest[&"touch_fire"]
	var start: Vector2 = _rest[&"touch_start"]
	draw_circle(fire + Vector2(0, 1), FIRE_RADIUS + 5, Color("61615a"), true, -1, true)
	draw_circle(fire, FIRE_RADIUS + 5, SOCKET, true, -1, true)
	_capsule(self, start + Vector2(0, 1), START_SIZE + Vector2(6, 6), Color("66665e"))
	_capsule(self, start, START_SIZE + Vector2(6, 6), SOCKET)
	_label("FIRE", fire + Vector2(0, FIRE_RADIUS + 12))
	_label(_start_text, start + Vector2(0, START_SIZE.y / 2 + 5))

func _paint_fire() -> void:
	var held := _down.has(&"touch_fire")
	_fire.draw_circle(Vector2(0, 1 if held else 3), FIRE_RADIUS, Color("832e24"), true, -1, true)
	_fire.draw_circle(Vector2.ZERO, FIRE_RADIUS, FIRE.darkened(0.1) if held else FIRE, true, -1, true)
	_fire.draw_circle(Vector2.ZERO, FIRE_RADIUS - 0.7, Color("ec7566").darkened(0.15) if held
		else Color("ec7566"), false, 1.3, true)

func _paint_start() -> void:
	var held := _down.has(&"touch_start")
	_capsule(_start, Vector2(0, 1 if held else 2), START_SIZE, Color("57544e"))
	_capsule(_start, Vector2.ZERO, START_SIZE, START.darkened(0.1) if held else START)

func _paint_cross() -> void:
	var half := CELL / 2
	var outline := PackedVector2Array([
		Vector2(-half, -3 * half), Vector2(half, -3 * half),
		Vector2(half, -half), Vector2(3 * half, -half),
		Vector2(3 * half, half), Vector2(half, half),
		Vector2(half, 3 * half), Vector2(-half, 3 * half),
		Vector2(-half, half), Vector2(-3 * half, half),
		Vector2(-3 * half, -half), Vector2(-half, -half),
	])
	var shadow := outline.duplicate()
	for i in shadow.size():
		shadow[i].y += 1 if _direction != 0 else 3
	_cross.draw_colored_polygon(shadow, Color("10100f"))
	_cross.draw_colored_polygon(outline, CROSS)
	_cross.draw_rect(Rect2(-Vector2.ONE * half, Vector2.ONE * CELL), INSET)
	for pair in [[Types.IN_UP, Vector2.UP], [Types.IN_DOWN, Vector2.DOWN],
			[Types.IN_LEFT, Vector2.LEFT], [Types.IN_RIGHT, Vector2.RIGHT]]:
		var way: Vector2 = pair[1]
		var centre := way * CELL
		if _direction == pair[0]:
			_cross.draw_rect(Rect2(centre - Vector2.ONE * (half - 1),
				Vector2.ONE * (CELL - 2)), Color("f2e9d4"))
		var across := Vector2(-way.y, way.x)
		_cross.draw_colored_polygon(PackedVector2Array([
			centre + way * 4, centre - way * 3 + across * 4,
			centre - way * 3 - across * 4]), Color("77756e"))

func _capsule(node: Node2D, centre: Vector2, size: Vector2, color: Color) -> void:
	var radius := size.y / 2
	var span := size.x / 2 - radius
	node.draw_rect(Rect2(centre - Vector2(span, radius), Vector2(span * 2, size.y)), color)
	for side in [-1, 1]:
		node.draw_circle(centre + Vector2(span * side, 0), radius, color, true, -1, true)

func _label(text: String, top_centre: Vector2) -> void:
	var at := Vector2i(int(top_centre.x) - TextPainter.width_of(text) / 2, int(top_centre.y))
	TextPainter.draw_line(self, _font, text, at, INK)
