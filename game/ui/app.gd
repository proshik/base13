extends Node

## The root node: it holds the current screen and swaps it. It has no game logic
## of its own — only the campaign, which must outlive a change of screens, and
## the window, of which there is one for the whole application.

const SCENES := {
	ScreenFlow.Screen.SPLASH: "res://ui/splash.tscn",
	ScreenFlow.Screen.MENU: "res://ui/menu.tscn",
	ScreenFlow.Screen.GAME: "res://ui/game.tscn",
	ScreenFlow.Screen.STATS: "res://ui/stats.tscn",
	ScreenFlow.Screen.GAMEOVER: "res://ui/gameover.tscn",
	ScreenFlow.Screen.NET: "res://ui/net.tscn",
	ScreenFlow.Screen.DESYNC: "res://ui/desync.tscn",
}

const ICON_PATH := "res://assets/icon.png"
const ICON_PATH_MAC := "res://assets/icon_macos.png"

var _screen := ScreenFlow.Screen.SPLASH
var _current: Node = null
var _campaign: Campaign = null
var _players := 1
var _best := 0
var _link: Link = null
var _local_index := 0
var _net_seed := 0
## The input delay the last level of a network match ended with. A new NetInput
## comes with every level, and starting each from scratch meant ten seconds of
## stutter at the start of every level on a slow path. Zero before the first.
var _net_delay := 0
var _desync_tick := -1

func _ready() -> void:
	_set_icon()
	_fit_window()
	_best = ScoreStore.load_best()
	if _wants_selftest():
		_run_selftest()
		return
	_show(_screen)

## A determinism self-check. It matters most in the browser: cross-platform
## network co-op is possible only if WASM computes the world bit for bit the way
## the desktop does. The result goes both to the console and onto the screen —
## the latter is visible without opening developer tools.
##
## To run: `godot -- --selftest` on desktop, `?selftest` in the page address.
func _wants_selftest() -> bool:
	if OS.get_cmdline_user_args().has("--selftest"):
		return true
	if not OS.has_feature("web"):
		return false
	# We parse the string ourselves: returning a ready-made boolean from JS is
	# unreliable, the marshalling hands back something other than expected.
	var search = JavaScriptBridge.eval("window.location.search", true)
	return typeof(search) == TYPE_STRING and (search as String).contains("selftest")

func _run_selftest() -> void:
	var actual := Golden.run()
	var matched := actual == Golden.EXPECTED
	print("SELFTEST %s: got %d, golden %d" % [
		"MATCHED" if matched else "DIVERGED", actual, Golden.EXPECTED])
	# The result goes on screen and not only to the console: in a browser the
	# export shell overrides the tab title, and reaching the console means
	# opening developer tools.
	var banner: Banner = Banner.new()
	add_child(banner)
	banner.show_text("SELFTEST %s %d" % ["OK" if matched else "FAIL", actual])

## The icon is also set at runtime: the project setting is enough for a built
## application, but when running from the editor the engine's logo would
## otherwise sit in the dock.
func _set_icon() -> void:
	# In the macOS dock every icon is a rounded square with margins; a square
	# filling the whole canvas would look foreign there. On the other platforms
	# it is the other way round.
	var path := ICON_PATH_MAC if OS.get_name() == "macOS" else ICON_PATH
	var texture: Texture2D = load(path)
	if texture != null:
		DisplayServer.set_icon(texture.get_image())

## Fits the window to the screen by a whole-number scale. A fractional one would
## stretch the pixels unevenly and the pixel art would fall apart. It lives in
## the root rather than in the game screen: there is one window for the whole
## application, and no reason to recompute it on every change of screen.
func _fit_window() -> void:
	var screen := DisplayServer.window_get_current_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var size := WindowScale.BASE * WindowScale.best_scale(usable.size)
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_position(usable.position + (usable.size - size) / 2)

func _toggle_fullscreen() -> void:
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		_fit_window()
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_F:
		_toggle_fullscreen()

func _show(screen: int, skipped := 0) -> void:
	if _current != null:
		_current.queue_free()
		_current = null
	_screen = screen

	# A screen not yet written is skipped rather than crashing the game: while a
	# part is still unfinished, every intermediate commit must stay playable.
	# The counter guards against a cycle made only of missing scenes.
	var path: String = SCENES.get(screen, "")
	if path == "" or not ResourceLoader.exists(path):
		if skipped >= SCENES.size():
			push_error("not a single screen was found — there is nothing to show")
			return
		push_warning("no scene for screen %d (%s) — skipping" % [screen, path])
		_show(ScreenFlow.next(screen, ScreenFlow.Outcome.CONTINUE), skipped + 1)
		return

	if screen == ScreenFlow.Screen.GAME and _campaign == null:
		# In a network game the seed comes from whoever started: every level's
		# seed is derived from it, so the enemy waves match on both sides.
		var campaign_seed := _net_seed if _link != null else _new_seed()
		_campaign = Campaign.new(_players, SimConfig.new(), campaign_seed)
	_current = load(path).instantiate()
	add_child(_current)
	if screen == ScreenFlow.Screen.GAME and _link != null:
		_current.use_input(NetInput.new(_link, _local_index, Callable(),
			NetInput.starting_delay(_link, _net_delay)))
	if screen == ScreenFlow.Screen.DESYNC:
		_current.show_tick(_desync_tick)
	if _current.has_method("configure"):
		_current.configure(_campaign, _players, _best)
	_current.finished.connect(_on_finished)
	if screen == ScreenFlow.Screen.GAMEOVER:
		_save_record()

## The high score is written when the game-over screen is shown, not when it is
## dismissed: the window may be closed right on it, and "NEW RECORD" on screen
## must be true. Writing earlier — on every tank destroyed — is pointless.
func _save_record() -> void:
	if _current == null or not _current.has_method("best"):
		return
	var updated: int = _current.best()
	if updated > _best:
		_best = updated
		ScoreStore.save_best(_best)

## Every game gets its own seed, or each opening plays out identically: the
## first enemies roll out on the same ticks and swing their turrets the same
## way. The clock may be touched only here, in the screen layer: the core
## receives the seed as a parameter, and for replays or the network it is simply
## written down.
## When a network game ends the link is closed: there is no reason to keep a
## socket open after returning to the menu, and a forgotten connection gets in
## the way of the next one.
func _drop_link() -> void:
	if _link != null:
		_link.close()
		_link = null
	_net_seed = 0
	_local_index = 0
	_net_delay = 0

func _new_seed() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0) & 0xFFFFFFFF

func _on_finished(outcome: int) -> void:
	if _screen == ScreenFlow.Screen.GAME and _link != null:
		_net_delay = _current.net_delay()
	if _screen == ScreenFlow.Screen.NET:
		if outcome == ScreenFlow.Outcome.CONTINUE:
			_link = _current.link
			_local_index = _current.local_index
			_net_seed = _current.seed_value
			_net_delay = 0
			_players = 2
			_campaign = null
		else:
			_drop_link()
		_show(ScreenFlow.next(_screen, outcome))
		return
	if _screen == ScreenFlow.Screen.GAME and outcome == ScreenFlow.Outcome.DESYNC:
		_desync_tick = _current.desync_tick()
		_drop_link()
		_show(ScreenFlow.Screen.DESYNC)
		return
	if _screen == ScreenFlow.Screen.MENU:
		# ScreenFlow decides where to go — it is covered by tests. A special case
		# here once sent the network menu item straight into the game, past the
		# network screen.
		if outcome != ScreenFlow.Outcome.NET:
			_players = _current.players()
			_campaign = null
		_show(ScreenFlow.next(_screen, outcome))
		return
	if _screen == ScreenFlow.Screen.GAMEOVER or outcome == ScreenFlow.Outcome.QUIT:
		_campaign = null
		_drop_link()
	_show(ScreenFlow.next(_screen, outcome))
