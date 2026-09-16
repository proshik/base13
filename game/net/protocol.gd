class_name Protocol

## Packing of network game packets. Only key presses and hashes travel — world
## state is never sent: both sides compute it themselves.
##
## Parsing must survive any garbage: the network delivers truncated, foreign and
## repeated data alike. No input may crash the game.

enum Kind { INVALID, INPUT, HASH, START, PACE }

## The size depends on the kind: there are sixty input packets a second per
## player, and holding four bytes for five bits in them is pure waste of the
## channel.
const SIZE_INPUT := 6   ## kind (1) + tick number (4) + bits (1)
const SIZE_WIDE := 9    ## kind (1) + tick number (4) + four bytes of payload
const MAX_U32 := 0xFFFFFFFF
## Added to a lead so that a negative one fits the unsigned four bytes.
const LEAD_BIAS := 0x80000000

static func pack_input(tick: int, bits: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(SIZE_INPUT)
	out[0] = Kind.INPUT
	out.encode_u32(1, tick & MAX_U32)
	out[5] = bits & 0xFF
	return out

static func pack_hash(tick: int, hash_value: int) -> PackedByteArray:
	return _pack(Kind.HASH, tick, hash_value)

## The host sets the campaign seed: every level's seed is derived from it, so
## both sides get identical enemy waves without a single extra byte.
static func pack_start(seed_value: int, players: int) -> PackedByteArray:
	return _pack(Kind.START, players, seed_value)

## How far ahead of the partner this side runs, in ticks. A client of 0.5.0 takes
## it for garbage and drops it.
static func pack_pace(tick: int, lead: int) -> PackedByteArray:
	return _pack(Kind.PACE, tick, lead + LEAD_BIAS)

static func _pack(kind: int, tick: int, payload: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(SIZE_WIDE)
	out[0] = kind
	out.encode_u32(1, tick & MAX_U32)
	out.encode_u32(5, payload & MAX_U32)
	return out

## Returns a dictionary with a `kind` key; INVALID has no other keys.
## A dictionary rather than a class: a packet lives for one call and is never
## stored.
static func unpack(data: PackedByteArray) -> Dictionary:
	if data.size() < 1:
		return {"kind": Kind.INVALID}
	var kind: int = data[0]
	if kind == Kind.INPUT:
		if data.size() != SIZE_INPUT:
			return {"kind": Kind.INVALID}
		var input_tick: int = data.decode_u32(1)
		# The tick number is packed unsigned; a negative one would arrive huge.
		if input_tick > MAX_U32 / 2:
			return {"kind": Kind.INVALID}
		return {"kind": Kind.INPUT, "tick": input_tick, "bits": data[5]}
	if data.size() != SIZE_WIDE:
		return {"kind": Kind.INVALID}
	var tick: int = data.decode_u32(1)
	var payload: int = data.decode_u32(5)
	match kind:
		Kind.HASH:
			if tick > MAX_U32 / 2:
				return {"kind": Kind.INVALID}
			return {"kind": Kind.HASH, "tick": tick, "hash": payload}
		Kind.START:
			return {"kind": Kind.START, "players": tick, "seed": payload}
		Kind.PACE:
			if tick > MAX_U32 / 2:
				return {"kind": Kind.INVALID}
			return {"kind": Kind.PACE, "tick": tick, "lead": payload - LEAD_BIAS}
	return {"kind": Kind.INVALID}
