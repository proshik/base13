class_name Campaign

## What lives between levels: score, lives, level number, wrapping around.
## It sits in the core because these are game rules and not presentation: they
## change how a game ends. It knows nothing of the engine — the isolation check
## covers this file too.

const LEVEL_FILES := 35
const SEED_STEP := 2654435761   ## the golden ratio in 32 bits: spreads adjacent numbers apart

var level_number := 1
var game_over := false
var slots: Array = []          ## Entities.Carryover per player, by index
var last_kills: Array = []     ## the tally for the level just finished
var finished_level := 0        ## the number of the level that just ended

var _base_seed := 0
var _config: SimConfig

func _init(player_count: int, config: SimConfig, base_seed: int) -> void:
	_config = config
	_base_seed = base_seed
	for i in player_count:
		var c := Entities.Carryover.new()
		c.lives = config.start_lives
		slots.append(c)
		last_kills.append([0, 0, 0, 0] as Array[int])

## Which layout file to read: there are thirty-five of them, and the levels
## never run out.
func level_file() -> int:
	return ((level_number - 1) % LEVEL_FILES) + 1

## A level's seed is derived from the base one rather than drawn anew:
## a whole game replays from a single number.
func level_seed() -> int:
	return Rng.new(_base_seed + level_number * SEED_STEP).next_u32()

func carryover() -> Array:
	return slots

func total_score() -> int:
	var sum := 0
	for c in slots:
		sum += c.score
	return sum

## Called exactly once, when the level's simulation has ended — and it can
## only end in a win or a loss.
func finish_level(state: WorldState) -> void:
	for i in slots.size():
		if i >= state.players.size():
			continue
		var p: Entities.PlayerState = state.players[i]
		slots[i].lives = p.lives
		slots[i].score = p.score
		slots[i].stars = 0     ## upgrades do not carry over
		# The tally is remembered here because the world state does not survive
		# to the statistics screen: the game screen is destroyed by then.
		var counted: Array[int] = [0, 0, 0, 0]
		for k in counted.size():
			counted[k] = p.kills[k]
			slots[i].kills[k] += p.kills[k]
		last_kills[i] = counted
	finished_level = level_number
	if state.level_cleared:
		level_number += 1
	else:
		game_over = true
