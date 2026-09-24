extends GutTest

## A tab out of sight stops the game's loop, and to the partner and to the server
## that looks exactly like a network falling short; a window that lost focus stops
## taking keys, and that looks like input going missing. The server is told each
## change, and its log tells a player looking elsewhere from a lag.

## On a desktop the engine's own notifications say it: focus leaving and coming
## back, and on a phone the application put away and brought back.
func test_a_notification_is_named_by_one_word() -> void:
	assert_eq(Presence.word_for(Node.NOTIFICATION_APPLICATION_FOCUS_OUT), "blur")
	assert_eq(Presence.word_for(Node.NOTIFICATION_APPLICATION_FOCUS_IN), "focus")
	assert_eq(Presence.word_for(Node.NOTIFICATION_APPLICATION_PAUSED), "hidden")
	assert_eq(Presence.word_for(Node.NOTIFICATION_APPLICATION_RESUMED), "visible")
	assert_eq(Presence.word_for(Node.NOTIFICATION_READY), "", "not every notification is a change")

func test_a_change_is_said_once() -> void:
	var presence := Presence.new()
	add_child_autofree(presence)
	var said: Array[String] = []
	presence.changed.connect(func(what: String) -> void: said.append(what))
	presence.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	presence.notification(Node.NOTIFICATION_PROCESS)
	presence.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	assert_eq(said, ["blur", "focus"] as Array[String])

## The root hands each change to the link of a network game, and to nothing
## outside one.
class Noted extends Link:
	var notes: Array[String] = []
	func report_note(what: String, _figures := {}) -> void:
		notes.append(what)

func test_the_root_tells_the_link_of_a_network_game() -> void:
	var app: Node = load("res://ui/app.gd").new()
	app._on_presence("hidden")
	var link := Noted.new()
	app._link = link
	app._on_presence("hidden")
	app._on_presence("visible")
	assert_eq(link.notes, ["hidden", "visible"] as Array[String])
	app.free()
