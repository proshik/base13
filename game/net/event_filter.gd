class_name EventFilter

## What a tick computed again may add to the screen and the speakers.
##
## A tick computed on a guess and again on the partner's real input yields its
## events twice. What was already shown is not shown again; what is new is; and
## what no longer happens is left alone — a sound cannot be called back, and a
## flash that should not have been burns out by itself.
##
## An event is known by its type, place and payload within its tick. Identical
## events on one tick — two hits in one brick cell — are counted, not merged.

var _shown := {}   ## tick -> Array of keys shown so far

func fresh(tick: int, events: Array) -> Array:
	var seen: Array = _shown.get(tick, [])
	var unmatched := seen.duplicate()
	var out: Array = []
	for e in events:
		var key := _key(e)
		var i := unmatched.find(key)
		if i >= 0:
			unmatched.remove_at(i)
			continue
		out.append(e)
		seen.append(key)
	_shown[tick] = seen
	return out

func forget_before(tick: int) -> void:
	for key in _shown.keys():
		if key < tick:
			_shown.erase(key)

static func _key(e: SimEvent) -> String:
	return "%d:%d:%d:%d" % [e.type, e.pos.x, e.pos.y, e.data]
