class_name Audio
extends Node

## Turns core events into sound, exactly the way effects.gd turns them into
## explosions. The core plays no sounds and knows nothing about them.

const SFX_PATH := "res://assets/sfx/%s.wav"
const VOICES := 8
const ENGINE_DB := -12.0  ## the hum is background: it must not argue with the effects
const DUCK_DB := -20.0    ## how far to duck the hum while an effect plays
const DUCK_SECONDS := 0.12

## Event to sound name. Empty means "deliberately silent".
const EVENT_SOUNDS := {
	Types.Event.SHOT_FIRED: "shot",
	Types.Event.BULLET_HIT_BRICK: "hit_brick",
	Types.Event.BULLET_HIT_STEEL: "hit_steel",
	Types.Event.BULLET_HIT_BULLET: "hit_bullet",
	Types.Event.TANK_DESTROYED: "boom_tank",
	Types.Event.PLAYER_DESTROYED: "boom_player",
	Types.Event.BASE_DESTROYED: "boom_base",
	Types.Event.BONUS_SPAWNED: "bonus_appear",
	Types.Event.BONUS_TAKEN: "bonus_take",
	Types.Event.ENEMY_SPAWNED: "enemy_spawn",
	Types.Event.LEVEL_CLEARED: "jingle_clear",
	Types.Event.GAME_OVER: "jingle_gameover",
}

var _voices: Array = []
var _streams := {}
var _engine: AudioStreamPlayer = null
var _engine_name := ""
var _duck_left := 0.0

static func sound_for(event_type: int) -> String:
	return EVENT_SOUNDS.get(event_type, "")

## Identical sounds within a tick collapse into one: the chip had a single
## channel for each, and four overlaid copies of a click give mush instead of a
## click.
static func names_for(events: Array) -> Array[String]:
	var out: Array[String] = []
	for e in events:
		var name: String = sound_for(e.type)
		if name != "" and not out.has(name):
			out.append(name)
	return out

## One hum for both players: the chip had one channel, and two overlaid hums
## give mush instead of an engine.
static func engine_sound(alive: bool, moving: bool) -> String:
	if not alive:
		return ""
	return "engine_move" if moving else "engine_idle"

func set_engine(name: String) -> void:
	if name == _engine_name:
		return
	_engine_name = name
	if _engine == null:
		_engine = AudioStreamPlayer.new()
		add_child(_engine)
	if name == "":
		_engine.stop()
		return
	_engine.stream = _stream(name)
	_duck_left = 0.0
	_engine.volume_db = ENGINE_DB
	_engine.play()

func _ready() -> void:
	# Up front rather than on the first shot: loading inside a tick is a
	# noticeable hitch at exactly the moment the player first pressed fire.
	for name in EVENT_SOUNDS.values():
		_stream(name)
	for name in ["engine_idle", "engine_move"]:
		_stream(name)
	for i in VOICES:
		var player := AudioStreamPlayer.new()
		add_child(player)
		_voices.append(player)

func absorb(events: Array) -> void:
	for name in names_for(events):
		play(name)

func play(name: String) -> void:
	if name == "":
		return
	var stream := _stream(name)
	if stream == null:
		return
	_duck_engine()
	for player in _voices:
		if not player.playing:
			player.stream = stream
			player.play()
			return
	# Every voice is busy — the oldest gives way: silence is worse than a cut.
	_voices[0].stream = stream
	_voices[0].play()

## On the chip an effect cut through the engine — there were not enough
## channels. We reproduce the most noticeable part of that: the hum ducks while
## an effect plays.
##
## By a counter rather than a timer: a timer with a closure would be created on
## every shot and would linger if the game were closed before it fired.
func _duck_engine() -> void:
	if _engine == null or not _engine.playing:
		return
	_duck_left = DUCK_SECONDS
	_engine.volume_db = DUCK_DB

func _process(delta: float) -> void:
	if _duck_left <= 0.0:
		return
	_duck_left -= delta
	if _duck_left <= 0.0 and _engine != null:
		_engine.volume_db = ENGINE_DB

func _stream(name: String) -> AudioStream:
	if not _streams.has(name):
		_streams[name] = ResourceLoader.load(SFX_PATH % name)
	return _streams[name]

func _exit_tree() -> void:
	# The hum is looped and is still playing on exit. Without an explicit stop
	# its stream and the resource copy stay alive, and Godot reports a leak.
	if _engine != null:
		_engine.stop()
		_engine.stream = null
	for player in _voices:
		player.stop()
		player.stream = null
	_streams.clear()
