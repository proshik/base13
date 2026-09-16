class_name Rollback

## Both sides' input laid out by tick, for a game that does not wait on the network
## while it can guess.
##
## A tick is computed as soon as our own input for it is known. The partner's, if
## it has not arrived, is guessed — whatever they held on the latest tick we know
## — and the guess is remembered. When the real input arrives and differs,
## `rollback_from()` names the earliest tick computed on a wrong guess, and the game
## goes back and computes from there again.
##
## `confirmed()` is the last tick up to which all of the partner's input is real. A
## world there is the same on both sides; only such a world may end a level or be
## compared by hash.
##
## A pure class, like the lockstep buffer before it: no nodes, no sockets.

## A press made on tick N takes effect on N + INPUT_DELAY: long enough for the
## packet to leave, too short to feel.
const INPUT_DELAY := 2
## How far past the confirmed tick the game may run on guesses: 200 ms. Further,
## and a correction throws the partner's tank across the field. Past it the game
## stands and waits.
const MAX_ROLLBACK := 12
## The first ticks carry no input on either side. Five, as in the lockstep client
## of 0.5.0, which fills in exactly these: the two play together only while they
## agree on this.
const START := 5
## How many past ticks to keep. The same bound limits how far ahead a partner's
## packet may be.
const KEEP := 240

var _local_index: int
var _local := {}           ## tick -> our bits
var _remote := {}          ## tick -> the partner's real bits
var _used := {}            ## tick -> the guess a tick was computed with
var _confirmed := START - 1
var _remote_edge := -1
var _mismatch := -1
var _hashes := {}          ## confirmed tick -> our hash
var _remote_hashes := {}   ## tick -> the partner's hash, waiting for ours

func _init(local_index: int) -> void:
	_local_index = local_index
	for tick in START:
		_local[tick] = 0
		_remote[tick] = 0

func submit_local(tick: int, bits: int) -> void:
	if not _local.has(tick):
		_local[tick] = bits

## Our own input for a tick, as it was sent. Zero for a tick never pressed.
func local_input(tick: int) -> int:
	return _local.get(tick, 0)

## A repeated packet does not overwrite what was accepted: networks duplicate, and
## changing input a tick was already confirmed on is a desync.
func submit_remote(tick: int, bits: int) -> void:
	if _remote.has(tick):
		return
	_remote[tick] = bits
	_remote_edge = maxi(_remote_edge, tick)
	while _remote.has(_confirmed + 1):
		_confirmed += 1
	if _used.has(tick) and _used[tick] != bits:
		_mismatch = tick if _mismatch < 0 else mini(_mismatch, tick)

## The furthest tick the partner has sent input for.
func remote_edge() -> int:
	return _remote_edge

func confirmed() -> int:
	return _confirmed

func can_predict(tick: int) -> bool:
	return _local.has(tick) and tick - _confirmed <= MAX_ROLLBACK

## Both players' input in slot order — identical on both sides once it is real.
## A guess is remembered, so that the real input can be held up against it.
func inputs_for(tick: int) -> Array[int]:
	var mine: int = _local.get(tick, 0)
	var theirs := _guess(tick)
	if _remote.has(tick):
		_used.erase(tick)
	else:
		_used[tick] = theirs
	if _local_index == 0:
		return [mine, theirs] as Array[int]
	return [theirs, mine] as Array[int]

func _guess(tick: int) -> int:
	if _remote.has(tick):
		return _remote[tick]
	var t := mini(tick - 1, _remote_edge)
	while t >= 0 and not _remote.has(t):
		t -= 1
	return _remote.get(t, 0)

## The earliest tick computed on a guess the real input has since contradicted, or
## -1. Cleared by whoever computes again from it.
func rollback_from() -> int:
	return _mismatch

func clear_rollback() -> void:
	_mismatch = -1

## Our hash of a confirmed tick. False if the partner's for it is already here and
## differs.
func record_hash(tick: int, value: int) -> bool:
	_hashes[tick] = value
	if not _remote_hashes.has(tick):
		return true
	var theirs: int = _remote_hashes[tick]
	_remote_hashes.erase(tick)
	return theirs == value

## The partner's hash. One for a tick we have not confirmed yet waits for ours
## rather than being taken for a match.
func submit_remote_hash(tick: int, value: int) -> bool:
	if _hashes.has(tick):
		return _hashes[tick] == value
	_remote_hashes[tick] = value
	return true

func forget_before(tick: int) -> void:
	for store in [_local, _remote, _used, _hashes, _remote_hashes]:
		for key in store.keys():
			if key < tick:
				store.erase(key)
