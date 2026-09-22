extends Node2D

## The game screen: it holds the current level's simulation, pumps the ticks and
## hands the state over to be drawn. The campaign comes from outside and outlives
## this screen: the screen is recreated for every level, while score and lives
## are not.
##
## The internal phases are about a level's lifecycle, not about screens. The end
## of the game leaves here as a signal: that is a separate screen, not a phase.

signal finished(outcome: int)

const FIELD_ORIGIN := Vector2i(8, 16)
const INTRO_SECONDS := 2.0
## The last explosion burns out over this many ticks. Counted in ticks rather than
## seconds so that both sides of a network game end on the same one.
const OUTRO_TICKS := 90
## How long a partner who has left the room is waited for. The same figure the
## relay gives our own link before it gives up: a room outlives a drop, so they
## may still come back, and either way the wait has to end at some point.
const PARTNER_GRACE := 30.0

const LOST_SECONDS := 2.5

enum Phase { INTRO, PLAY, OUTRO, LOST_LINK, DONE }

var _campaign: Campaign = null
var _sim: GameSim = null
var _match: NetMatch = null
## The tick a level ends on, once the confirmed world has cleared or lost it.
var _end_tick := -1
var _effects := Effects.new()
var _phase := Phase.INTRO
var _timer := 0.0
var _moving := false
var _paused := false
var _leaving := false   ## the network's answer to Esc: a question, not a pause
var _status := ""
var _partner_missing := 0.0
var _input: InputSource = LocalInput.new()

@onready var _field: Field = $Field
@onready var _hud: HudPanel = $Hud
@onready var _banner: Banner = $Banner
@onready var _audio: Audio = $Audio
@onready var _pause: PauseOverlay = $Pause
var _stats: NetStats = null

func _ready() -> void:
	_field.position = FIELD_ORIGIN
	# Created in code rather than in the scene: this is a debug overlay and has
	# no business in the layout.
	_stats = NetStats.new()
	add_child(_stats)

## The input source comes from outside: in a single-player game it stays the
## keyboard, in a network game it becomes the network input. The screen knows
## nothing of the difference.
func use_input(source: InputSource) -> void:
	_input = source

func desync_tick() -> int:
	return _input.desync_tick if _input is NetInput else -1

func configure(campaign: Campaign, _players: int, _best: int) -> void:
	_campaign = campaign
	_effects = Effects.new()
	_begin_level()

func _begin_level() -> void:
	# The hum is silenced on every change of state: in the INTRO and DONE phases
	# the loop does not run, so _update_engine is never called and the engine
	# would stay on.
	_audio.set_engine("")
	var level := LevelLoader.load_level(_campaign.level_file())
	if level.error != "":
		# With no level there is nothing to play — we go back up rather than sit
		# with an empty simulation that _process would trip over every frame.
		push_error("level %d cannot be read: %s" % [_campaign.level_file(), level.error])
		_phase = Phase.DONE
		finished.emit(ScreenFlow.Outcome.LOST)
		return
	_sim = GameSim.new(level, _campaign.level_seed(), SimConfig.new(),
		_campaign.level_number, _campaign.slots.size(), _campaign.carryover())
	_match = NetMatch.new(_sim, _input)
	_end_tick = -1
	_banner.show_text("STAGE %d" % _campaign.level_number)
	_phase = Phase.INTRO
	_timer = INTRO_SECONDS

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_ESCAPE:
		_on_escape()
	elif event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_Q and (_paused or _leaving):
		_quit_to_menu()
	elif event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_L:
		# Network numbers right on the screen: a screenshot is easier than digging
		# them out of the developer console on somebody else's machine.
		_stats.visible = not _stats.visible
	elif event is InputEventJoypadButton and event.pressed \
			and event.button_index == JOY_BUTTON_START:
		_on_escape()

## A hidden browser tab stops running the loop but not the audio: the looped hum
## would go on sounding out of a window that has stopped drawing anything, and
## from the other room it is indistinguishable from the game still running. This
## notification is the last thing that reaches us before the freeze.
func _notification(what: int) -> void:
	if what != NOTIFICATION_APPLICATION_FOCUS_OUT \
			and what != NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		return
	if _audio != null:
		_audio.set_engine("")

func _networked() -> bool:
	return _input is NetInput

## Esc means two different things, and on the network the difference matters.
## Alone it stops the world. On the network there is no world to stop: pausing
## here would freeze the partner's screen with no explanation, and past a proxy's
## idle timeout it would end the match outright — a paused screen polls no
## socket, so not even the heartbeat goes out. So the network gets a question,
## and the game keeps running behind it.
func _on_escape() -> void:
	if not _networked():
		_toggle_pause()
		return
	_leaving = not _leaving
	_pause.set_shown(_leaving, PauseOverlay.Kind.LEAVE)

func _toggle_pause() -> void:
	_paused = not _paused
	_pause.set_shown(_paused)
	# The engine falls silent while paused: a continuous hum over a stopped game
	# sounds like a hang.
	_audio.set_engine("")
	if not _paused and _match != null:
		# Time passed while we stood still: without a reset the first frame would
		# hand over a backlog of catch-up ticks and the game would lurch.
		_match.reset_pump()

func _process(delta: float) -> void:
	if _paused:
		return
	match _phase:
		Phase.INTRO:
			# The link is serviced behind the caption too: a delay carried from
			# the last level goes out as a band of input before the first tick,
			# and the partner's band comes in.
			_input.pump()
			_timer -= delta
			if _timer <= 0.0:
				_banner.hide_banner()
				_phase = Phase.PLAY
		Phase.PLAY:
			_advance(delta)
			if not _link_holds(delta):
				return
			# A frozen screen with no explanation reads to a human as a hang, so
			# whatever stopped the picture gets named.
			_show_status(_network_status())
			# Only a world both sides agree on ends a level: on a guess the base
			# may have fallen that did not.
			var end := _match.level_end(OUTRO_TICKS)
			if end >= 0:
				_end_tick = end
				_match.set_horizon(_end_tick)
				_phase = Phase.OUTRO
		Phase.OUTRO:
			# The simulation keeps running: the last explosion must burn out.
			_advance(delta)
			if not _link_holds(delta):
				return
			if _match.confirmed_world().tick >= _end_tick:
				_finish_level()
		Phase.LOST_LINK:
			# We do not leave at once: the caption must be readable first.
			_timer -= delta
			if _timer <= 0.0:
				# Whoever is still here did not walk away, and what they played
				# counts. So the match ends the way a lost level ends rather than
				# the way quitting does: through the tally and the score, which is
				# where the high score is written. Leaving by Q still records
				# nothing — that one did walk away.
				_finish_level()
		Phase.DONE:
			pass

## False once the match cannot go on: the worlds parted, the link is gone for good,
## or the partner left and did not come back. The outro needs this too — it now
## ends on a confirmed tick, and a partner gone mid-outro would hold it forever.
func _link_holds(delta: float) -> bool:
	if _input is NetInput and _input.desynced:
		# There is no point continuing: the sides hold different worlds.
		_phase = Phase.DONE
		finished.emit(ScreenFlow.Outcome.DESYNC)
		return false
	if _input.dead():
		_show_status("CONNECTION LOST")
		_phase = Phase.LOST_LINK
		_timer = LOST_SECONDS
		return false
	# A partner who shut their window never comes back, and nothing else would ever
	# end this game: our own link is fine, so `dead()` stays false and the caption
	# would stand until somebody closed the window.
	if _networked() and not _input.partner_present():
		_partner_missing += delta
		if _partner_missing >= PARTNER_GRACE:
			_show_status("PARTNER LEFT")
			_phase = Phase.LOST_LINK
			_timer = LOST_SECONDS
			return false
	else:
		_partner_missing = 0.0
	return true

## Three different things can stop the picture and a human must be able to tell
## them apart: our own link is gone, or it is fine and the partner is not
## sending. The second one has no fault to find on this machine, and without a
## caption people look for one.
func _network_status() -> String:
	if not _networked():
		return ""
	if not _input.linked():
		return "RECONNECTING"
	if _input.waiting_for_partner():
		return "WAITING FOR PARTNER"
	return ""

func _show_status(text: String) -> void:
	if text == _status:
		return
	_status = text
	if text != "":
		# A continuous hum over a stopped game sounds like a hang of its own.
		_audio.set_engine("")
		_banner.show_text(text)
		return
	# The time spent waiting is not reset here: the pump forgets a long stand by
	# itself. Resetting when the caption went — sixty frames, a second at 60 Hz
	# and less than half of one at 144 — left the two sides with different debts.
	_banner.hide_banner()

func _advance(delta: float) -> void:
	if _match == null:
		return
	var frame := _match.advance(delta)
	for step in frame.steps:
		# Effects age inside the tick loop and only on ticks going forward: a tick
		# computed again must not run an explosion ahead of the game.
		_effects.absorb(step.events)
		_audio.absorb(step.events)
		if step.forward:
			_effects.advance()
	if not frame.steps.is_empty():
		_moving = frame.moved
	var state := _sim.get_state()
	var items := ViewModel.build(state, _sim.get_config())
	items.append_array(_effects.items())
	_field.sync(state, items)
	_hud.show_model(ViewModel.hud(state))
	# While a caption is up the game is not running for the human: the hum would
	# be a hang of its own.
	if _status == "":
		_update_engine(state)
	if _stats.visible and _input is NetInput:
		_stats.show_line(_input.last_report)

## One hum for everyone: if any player is moving, the tone is the moving one.
## Movement is determined from positions rather than a flag out of the core: the
## core knows nothing about sound, and adding a "moving" field to it for the sake
## of a hum is not allowed.
func _update_engine(state: WorldState) -> void:
	var alive := not state.player_tanks().is_empty()
	_audio.set_engine(Audio.engine_sound(alive, _moving))

func _quit_to_menu() -> void:
	_audio.set_engine("")
	_phase = Phase.DONE
	finished.emit(ScreenFlow.Outcome.QUIT)

func _finish_level() -> void:
	_campaign.finish_level(_match.confirmed_world())
	_audio.set_engine("")
	_phase = Phase.DONE
	var outcome := ScreenFlow.Outcome.LOST if _campaign.game_over \
		else ScreenFlow.Outcome.CONTINUE
	finished.emit(outcome)
