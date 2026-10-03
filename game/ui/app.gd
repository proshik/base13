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
var _desync_tick := -1
var _touch: TouchControls = null
## A room's code the page was opened with: the game starts on the join screen with
## it in. Used once — back in the menu, the network screen opens as usual.
var _room_code := ""
## Android's browser can hide its bars when asked from a tap; an iPhone's cannot,
## there the home-screen install is the way.
var _wants_fullscreen := false

func _ready() -> void:
	_set_icon()
	_fit_window()
	if TouchDevice.present():
		_fit_touch()
	var presence := Presence.new()
	presence.changed.connect(_on_presence)
	add_child(presence)
	_best = ScoreStore.load_best()
	if _wants_selftest():
		_run_selftest()
		return
	if OS.has_feature("web"):
		JavaScriptBridge.pwa_update_available.connect(_take_update)
	_room_code = RoomLink.code_in(RelayConfig.page_url())
	if _room_code != "":
		_screen = ScreenFlow.Screen.NET
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
	var cost := Bench.measure()
	print("SELFTEST TIMING tick %d us, save %d us, restore and %d ticks again %d us" % [
		cost["tick_us"], cost["save_us"], Bench.DEPTH, cost["resim_us"]])
	# The result goes on screen and not only to the console: in a browser the
	# export shell overrides the tab title, and reaching the console means
	# opening developer tools.
	var banner: Banner = Banner.new()
	add_child(banner)
	banner.show_text("\n".join(selftest_lines(matched, actual, cost["tick_us"],
		cost["save_us"], cost["resim_us"])))

## The result as the screen shows it. Two lines: on one it ran past the edge of the
## picture and cut off RESIM, which on a phone, with no console, left nothing to read
## it from. Digits and capital letters only: the atlas font has nothing else.
static func selftest_lines(matched: bool, checksum: int, tick_us: int, save_us: int,
		resim_us: int) -> Array[String]:
	return [
		"SELFTEST %s %d" % ["OK" if matched else "FAIL", checksum],
		"TICK %d SAVE %d RESIM %d" % [tick_us, save_us, resim_us],
	] as Array[String]

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

## A phone gives the picture the whole of one side and the thumbs the rest: on its
## side the picture keeps its height and the stick and the buttons stand in the
## strips beside it; upright it keeps its width and they stand below it. Laid out
## again whenever the window changes — a browser's bars come and go, and the
## phone turns.
##
## The scale is not whole here, unlike the desktop window: a whole one left a
## third of a phone's height empty in Safari, and at three device pixels to a
## point the uneven pixels it trades that for are hard to see.
func _fit_touch() -> void:
	var root := get_tree().root
	root.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL
	# The engine grows the viewport along whichever side the window has to spare:
	# down when the phone is upright, across when it lies on its side. Switched by
	# hand on every resize instead, it was laid out once against a window size
	# that was already gone, and on an iPhone the picture took three quarters of
	# the width.
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	# Beyond the picture was the engine's letterbox; now it is the clear colour.
	RenderingServer.set_default_clear_color(Color.BLACK)
	_touch = TouchControls.new()
	add_child(_touch)
	_wants_fullscreen = ClientInfo.platform_name(OS.get_name(),
		Callable(OS, "has_feature")) == "web_android"
	root.size_changed.connect(_relayout)
	_relayout()

func _relayout() -> void:
	if _touch == null:
		return
	var view := get_viewport().get_visible_rect().size
	var screen := _current as Node2D
	if screen != null:
		screen.position = Vector2(StageLayout.picture_at(view))
	_touch.place(view)

func _input(event: InputEvent) -> void:
	if _wants_fullscreen and event is InputEventScreenTouch and event.pressed:
		_wants_fullscreen = false
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
	_relayout()
	if screen == ScreenFlow.Screen.GAME and _link != null:
		_current.use_input(NetInput.new(_link, _local_index))
	if screen == ScreenFlow.Screen.STATS:
		_current.skippable = _link == null
	if screen == ScreenFlow.Screen.DESYNC:
		_current.show_tick(_desync_tick)
	if _current.has_method("configure"):
		_current.configure(_campaign, _players, _best)
	if screen == ScreenFlow.Screen.NET and _room_code != "":
		_current.prefill(_room_code)
		_room_code = ""
	_current.finished.connect(_on_finished)
	if screen == ScreenFlow.Screen.GAMEOVER:
		_save_record()
	_take_update()

## The service worker serves the game from its own cache, and a new release it
## finds only waits beside it until every window of the game is closed — on a
## phone that keeps the game on its home screen, until it is next swiped away.
## So the page asks for it, and reloads into it, where a reload loses nothing.
func _take_update() -> void:
	if OS.has_feature("web") and update_moment(_screen) and JavaScriptBridge.pwa_needs_update():
		JavaScriptBridge.pwa_update()

static func update_moment(screen: int) -> bool:
	return screen == ScreenFlow.Screen.SPLASH or screen == ScreenFlow.Screen.MENU

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

## A tab or window going out of sight or focus, in a network game told to the
## server as well as to the console: it is what tells a player looking elsewhere
## from a lag. Outside a network game there is nobody to tell.
func _on_presence(what: String) -> void:
	if _link == null:
		return
	print("[net] " + what)
	_link.report_note(what)

func _new_seed() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0) & 0xFFFFFFFF

func _on_finished(outcome: int) -> void:
	if _screen == ScreenFlow.Screen.NET:
		if outcome == ScreenFlow.Outcome.CONTINUE:
			_link = _current.link
			_local_index = _current.local_index
			_net_seed = _current.seed_value
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
