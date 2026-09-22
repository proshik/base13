class_name NetMatch

## One level's ticks, frame by frame: forward on the input there is, back and
## forward again when a guess about the partner turns out wrong.
##
## The game screen and the tests drive this very loop; there is no second copy of
## it to drift apart.
##
## `_worlds[s]` is the world before tick `s` is computed — its `tick` is `s` — kept
## for every tick that might have to be computed again. The world after tick `k` is
## `_worlds[k + 1]`, or the live world when `k + 1` is where the game stands.

const NO_HORIZON := -1

## What one frame did, for the screen.
class Frame:
	var steps: Array = []     ## Step, in the order computed
	var ran := 0              ## ticks computed going forward
	var waited := false       ## stood for the partner
	var moved := false        ## a player's tank moved on the last tick computed
	var rollback_depth := 0

class Step:
	var tick := 0
	var events: Array = []    ## only those not shown before
	var forward := false

var _sim: GameSim
var _source: InputSource
var _pump := TickPump.new()
var _worlds := {}
var _filter := EventFilter.new()
## The last confirmed tick whose hash has been dealt with.
var _checked := -1
var _horizon := NO_HORIZON

func _init(sim: GameSim, source: InputSource) -> void:
	_sim = sim
	_source = source
	_checked = _sim.get_state().tick - 1

func sim() -> GameSim:
	return _sim

func source() -> InputSource:
	return _source

## No tick at or past this one is computed. The end of a level stops here, so that
## both sides finish on the same tick.
func set_horizon(tick: int) -> void:
	_horizon = tick

func reset_pump() -> void:
	_pump.reset()

func advance(delta: float) -> Frame:
	var frame := Frame.new()
	_source.pump()
	_step_back(frame)
	var due := _pump.due(delta)
	var skipped := 0
	for i in due:
		var t: int = _sim.get_state().tick
		if _horizon != NO_HORIZON and t >= _horizon:
			break
		_source.capture(t)
		if not _source.can_predict(t):
			frame.waited = true
			break
		if _source.should_skip(t):
			skipped += 1
			break
		_compute(t, frame, true, true)
		_source.note_tick(t)
		frame.ran += 1
	# A skipped tick spends its time: that is what lets the partner catch up.
	_pump.spend(frame.ran + skipped, frame.waited)
	_confirm()
	# Packets that arrive here are dealt with next frame, rollback first — which is
	# why _confirm comes before and not after.
	_source.flush()
	return frame

## The world both sides agree on: after the last tick all of whose input is real.
func confirmed_world() -> WorldState:
	var now: int = _sim.get_state().tick
	return _world(mini(_source.confirmed(), now - 1) + 1)

## The tick a level that has ended in the confirmed world stops on, `outro` ticks
## after the world it ended in; -1 while it goes on.
##
## Counted from the world the end happened in, never from the one it was seen in:
## the confirmed tick moves on as the partner's packets come, and they come in
## bunches — one frame confirms a tick on one side and five on the other. Two ends
## counted from there came out ticks apart; the earlier side finished and fell
## silent, and the later stood for input that would never come. Alone the two are
## the same world, so a level alone ends where it always did.
func level_end(outro: int) -> int:
	var world := confirmed_world()
	if not (world.level_cleared or world.game_over):
		return -1
	return world.ended_at + outro

func _step_back(frame: Frame) -> void:
	var from := _source.rollback_from()
	if from < 0:
		return
	_source.clear_rollback()
	var now: int = _sim.get_state().tick
	if from >= now:
		return
	if not _worlds.has(from):
		push_error("no world kept for tick %d to step back to" % from)
		return
	var began := Time.get_ticks_usec()
	_sim.restore(_worlds[from])
	for t in range(from, now):
		# The world before `from` is the one just restored; saving it again would
		# only copy it.
		_compute(t, frame, false, t != from)
	frame.rollback_depth = now - from
	_source.note_rollback(now - from, Time.get_ticks_usec() - began)

func _compute(t: int, frame: Frame, forward: bool, save: bool) -> void:
	var confirmed := _source.confirmed()
	# A world is kept when this tick may be computed again (it runs on a guess), or
	# when its hash is still owed further back and will be read from here.
	if save and (t > confirmed or t > _checked + 1):
		_worlds[t] = _sim.save()
	var before := _player_positions()
	_sim.tick(_source.inputs_for(t))
	frame.moved = _player_positions() != before
	var step := Step.new()
	step.tick = t
	step.forward = forward
	step.events = _filter.fresh(t, _sim.drain_events())
	frame.steps.append(step)
	if t == _checked + 1 and t <= confirmed:
		_checked = t
		if _source.wants_hash(t):
			_source.after_confirmed(t, _sim.state_hash())

func _confirm() -> void:
	if _source.rollback_from() >= 0:
		return
	var now: int = _sim.get_state().tick
	var through := mini(_source.confirmed(), now - 1)
	while _checked < through:
		_checked += 1
		if _source.wants_hash(_checked):
			_source.after_confirmed(_checked, _world(_checked + 1).hash_value())
	var keep_from := through + 1
	for s in _worlds.keys():
		if s < keep_from:
			_worlds.erase(s)
	_filter.forget_before(keep_from)

func _world(s: int) -> WorldState:
	if s == _sim.get_state().tick:
		return _sim.get_state()
	return (_worlds[s] as SimSnapshot).state

func _player_positions() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for t in _sim.get_state().player_tanks():
		out.append(t.pos)
	return out
