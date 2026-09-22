class_name InputSource

## Where the game screen takes its input from. In a single-player game the
## keyboard and gamepad; in a network game the rollback buffer. The screen knows
## nothing of the difference.
##
## A base class rather than an interface: GDScript has no interfaces, so the
## default behaviour is the single-player one, where there is nothing to wait
## for and nobody to send to.

## Once per frame: pump the network and parse what arrived. Separate from the
## ticks, because a frame may produce none of them while the link still has to be
## serviced — otherwise the connection seizes up.
func pump() -> void:
	pass

## Capture local input for a future tick and send it to the partner.
func capture(_now: int) -> void:
	pass

## Both players' input for this tick.
func inputs_for(_tick: int) -> Array[int]:
	return [0, 0] as Array[int]

## Push what has accumulated out to the network. Separate from `pump()` because
## it happens at a different moment: `pump()` parses arrivals at the start of a
## frame, `flush()` sends what was captured at the end. Does nothing in a
## single-player game.
func flush() -> void:
	pass

## A tick number past any game: alone, every tick is confirmed the moment it is.
const ALL_CONFIRMED := 1 << 62

## Whether this tick may be computed now — on real input, or on a guess about the
## partner's. Alone, always.
func can_predict(_tick: int) -> bool:
	return true

## The last tick all of whose input is real.
func confirmed() -> int:
	return ALL_CONFIRMED

## The earliest computed tick whose guess turned out wrong, or -1.
func rollback_from() -> int:
	return -1

func clear_rollback() -> void:
	pass

## The ticks stand at the end of a level's horizon; this tick is not computed.
## Alone, there is nothing to wait for there.
func stand_at_horizon(_tick: int) -> void:
	pass

## Whether to let this tick pass uncomputed and fall back into step with the
## partner.
func should_skip(_tick: int) -> bool:
	return false

## Whether the hash of this confirmed tick is compared with the partner's.
func wants_hash(_tick: int) -> bool:
	return false

func after_confirmed(_tick: int, _world_hash: int) -> void:
	pass

## A tick computed going forward, not computed again.
func note_tick(_tick: int) -> void:
	pass

## A step back: how many ticks were computed again and how long that took.
func note_rollback(_depth: int, _usec: int) -> void:
	pass

## Whether there is a link. In a single-player game there is nothing to wait
## for, hence yes.
func linked() -> bool:
	return true

## Time to end the game: the link is lost for good.
func dead() -> bool:
	return false
