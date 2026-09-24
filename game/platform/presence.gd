class_name Presence extends Node

## Whether the player can see the game and whether its window takes the keys.
##
## A tab out of sight stops the game's loop: the partner stands, and the server
## sees a stream gone quiet — the same picture a network falling short draws. A
## window that lost focus stops taking keys, and a press that never arrived
## reads as input lost on the way. Each change is said as one word — `hidden`,
## `visible`, `blur`, `focus` — and the root hands it to the server's log.
##
## In a browser the page's own events say it, not the engine's notifications:
## the engine hears of a change on its next frame, and a hidden tab has no next
## frame until it is shown again, so "hidden" would reach the server together
## with "visible". A page event runs its callback at once, and the note goes on
## the socket before the loop stops. On a desktop or a phone the loop does not
## stop for the window, and the engine's notifications are in time.

signal changed(what: String)

## The page's callbacks and the objects they hang on: dropped, they would be
## collected and the page would call into nothing.
var _held: Array = []

func _ready() -> void:
	if OS.has_feature("web"):
		_listen_to_the_page()

func _notification(what: int) -> void:
	if OS.has_feature("web"):
		return
	var word := word_for(what)
	if word != "":
		changed.emit(word)

## The word for an engine notification, or "" for one that is no change of
## sight or focus.
static func word_for(what: int) -> String:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			return "blur"
		NOTIFICATION_APPLICATION_FOCUS_IN:
			return "focus"
		NOTIFICATION_APPLICATION_PAUSED:
			return "hidden"
		NOTIFICATION_APPLICATION_RESUMED:
			return "visible"
	return ""

func _listen_to_the_page() -> void:
	var document = JavaScriptBridge.get_interface("document")
	var window = JavaScriptBridge.get_interface("window")
	if document == null or window == null:
		return
	var on_sight = JavaScriptBridge.create_callback(_on_sight)
	var on_blur = JavaScriptBridge.create_callback(_on_blur)
	var on_focus = JavaScriptBridge.create_callback(_on_focus)
	document.addEventListener("visibilitychange", on_sight)
	window.addEventListener("blur", on_blur)
	window.addEventListener("focus", on_focus)
	_held = [document, window, on_sight, on_blur, on_focus]

## Read as the state's name, a string: a boolean handed back from the page does
## not always arrive as one.
func _on_sight(_args: Array) -> void:
	var state = JavaScriptBridge.eval("document.visibilityState", true)
	changed.emit("hidden" if str(state) == "hidden" else "visible")

func _on_blur(_args: Array) -> void:
	changed.emit("blur")

func _on_focus(_args: Array) -> void:
	changed.emit("focus")
