class_name PressFeed
extends Node

## Hands the events the engine delivers to `PressLatch` as they come, or a tap that
## goes down and up between two ticks reaches neither. A node, because only a node
## is given the events; `_input` rather than `_unhandled_input`, because a control
## holding the focus would take a key first.

var _open: Callable

## `open` says whether presses are wanted right now. Every event goes through all
## the same: the latch follows the stick even while presses are not wanted.
func _init(open: Callable) -> void:
	_open = open

func _input(event: InputEvent) -> void:
	PressLatch.note(event, _open.call())
