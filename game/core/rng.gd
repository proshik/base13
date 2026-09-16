class_name Rng

## A deterministic xorshift32. The only source of randomness in the core:
## the engine's own random calls are forbidden here, because they break
## reproducibility.

const MASK := 0xFFFFFFFF
const FALLBACK_SEED := 0x9E3779B9

var _state: int

func _init(seed_value: int) -> void:
	_state = seed_value & MASK
	if _state == 0:
		# Zero is a fixed point of xorshift; the stream would stall forever.
		_state = FALLBACK_SEED

func next_u32() -> int:
	var x := _state
	x = (x ^ (x << 13)) & MASK
	x = x ^ (x >> 17)
	x = (x ^ (x << 5)) & MASK
	_state = x
	return _state

func next_range(lo: int, hi: int) -> int:
	if hi <= lo:
		return lo
	return lo + (next_u32() % (hi - lo))

func chance(percent: int) -> bool:
	if percent <= 0:
		return false
	if percent >= 100:
		return true
	return next_range(0, 100) < percent

func pick(items: Array) -> Variant:
	if items.is_empty():
		return null
	return items[next_range(0, items.size())]

func get_state() -> int:
	return _state

## Only for stepping a simulation back: a state read by get_state() is never zero,
## so there is no fixed point to guard against here.
func set_state(value: int) -> void:
	_state = value & MASK
