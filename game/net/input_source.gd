class_name InputSource

## Where the game screen takes its input from. In a single-player game the
## keyboard and gamepad; in a network game the lockstep buffer. The screen knows
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

## Whether this tick may be computed. On the network, only once both sides'
## input has arrived.
func can_advance(_tick: int) -> bool:
	return true

## Both players' input for this tick.
func inputs_for(_tick: int) -> Array[int]:
	return [0, 0] as Array[int]

## Push what has accumulated out to the network. Separate from `pump()` because
## it happens at a different moment: `pump()` parses arrivals at the start of a
## frame, `flush()` sends what was captured at the end. Does nothing in a
## single-player game.
func flush() -> void:
	pass

## Called once a tick has been computed: the hash comparison lives here.
func after_tick(_tick: int, _world_hash: int) -> void:
	pass

## Whether there is a link. In a single-player game there is nothing to wait
## for, hence yes.
func linked() -> bool:
	return true

## Time to end the game: the link is lost for good.
func dead() -> bool:
	return false
