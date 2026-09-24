class_name Link
extends RefCounted

## The common shape of a link between the two sides of a game. There are two of
## them: a direct connection on the local network and a room through the relay.
## Input, hash comparison and the game screen are the same in both cases, so
## everything above works against this shape rather than against a particular
## piece of plumbing.

signal packet_received(data: PackedByteArray)
signal peer_joined
signal peer_left

func poll() -> void:
	pass

func send(_data: PackedByteArray) -> void:
	pass

## Whether the link is up right now. A broken link is not always the end of the
## game: through the relay a side comes back and catches up. The game screen
## needs this to tell the human why everything has frozen.
func linked() -> bool:
	return true

## Whether the other side is still there — not whether they are quiet right now.
## A partner who shut their window is silent in exactly the way one who looked
## away is, and only the link can tell the two apart.
func partner_present() -> bool:
	return true

## There will be no link any more: nothing left to restore, or nothing left to
## wait for. It differs from `linked()` in being final — time to end the game
## rather than to show "reconnecting".
func dead() -> bool:
	return false

## How a stretch of play went on this side: `speed`, `waits`, `delay` and `fps`,
## and the rest of the `[net]` line beside them, all whole numbers. Only a server
## can be told, so a direct link on the local network and the links tests stand
## up take it and say nothing.
func report_pace(_pace: Dictionary) -> void:
	pass

## The two worlds parted, first on `tick`, or -1 when it is not known. Said once
## a match, for the same reason as above.
func report_desync(_tick := -1) -> void:
	pass

## One event of this side's, for the server's log: a word from the server's
## closed set and the whole numbers that word takes.
func report_note(_what: String, _figures := {}) -> void:
	pass

func close() -> void:
	pass
