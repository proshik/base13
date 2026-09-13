class_name SimEvent

## The core plays no sounds and creates no animations — it reports what
## happened, and the presentation layer decides how to show it. Events are not
## sent over the network: with an identical simulation they are identical on
## both sides.

var type := 0
var pos := Vector2i.ZERO
var data := 0

func _init(p_type: int, p_pos: Vector2i = Vector2i.ZERO, p_data: int = 0) -> void:
	type = p_type
	pos = p_pos
	data = p_data
