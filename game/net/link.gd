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

func close() -> void:
	pass
