class_name HeldKeys

## Keys the way a person holds them: a direction or nothing for a quarter of a
## second to a second, fire pressed now and then. A guess about the partner is
## "what they held last", so only keys like these say how often a guess fails —
## the golden run's keys change every tick and are for correctness, not for this.

const DIRECTIONS := [0, Types.IN_UP, Types.IN_DOWN, Types.IN_LEFT, Types.IN_RIGHT]

static func frames(seed_value: int, ticks: int) -> Array:
	var rng := Rng.new(seed_value)
	var out: Array = []
	var held: Array[int] = [0, 0]
	var left: Array[int] = [0, 0]
	for t in ticks:
		var row: Array[int] = [0, 0]
		for slot in 2:
			if left[slot] == 0:
				held[slot] = DIRECTIONS[rng.next_range(0, DIRECTIONS.size())]
				if rng.chance(30):
					held[slot] |= Types.IN_FIRE
				left[slot] = rng.next_range(15, 61)
			left[slot] -= 1
			row[slot] = held[slot]
		out.append(row)
	return out
