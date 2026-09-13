class_name EventLog

## An event accumulator lifted out of the simulation: the core's modules write
## here without holding a reference to GameSim — reference cycles between
## RefCounted objects leak in Godot.

var _events: Array = []

func add(type: int, pos: Vector2i = Vector2i.ZERO, data: int = 0) -> void:
	_events.append(SimEvent.new(type, pos, data))

func drain() -> Array:
	var out := _events
	_events = []
	return out
