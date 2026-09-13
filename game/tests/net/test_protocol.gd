extends GutTest

func test_input_packet_survives_a_round_trip() -> void:
	var packed := Protocol.pack_input(1234, Types.IN_UP | Types.IN_FIRE)
	var parsed := Protocol.unpack(packed)
	assert_eq(parsed.kind, Protocol.Kind.INPUT)
	assert_eq(parsed.tick, 1234)
	assert_eq(parsed.bits, Types.IN_UP | Types.IN_FIRE)

func test_hash_packet_survives_a_round_trip() -> void:
	var parsed := Protocol.unpack(Protocol.pack_hash(600, 2233634213))
	assert_eq(parsed.kind, Protocol.Kind.HASH)
	assert_eq(parsed.tick, 600)
	assert_eq(parsed.hash, 2233634213)

func test_start_packet_carries_the_seed_and_player_count() -> void:
	var parsed := Protocol.unpack(Protocol.pack_start(987654321, 2))
	assert_eq(parsed.kind, Protocol.Kind.START)
	assert_eq(parsed.seed, 987654321)
	assert_eq(parsed.players, 2)

func test_full_thirty_two_bit_hash_is_not_truncated() -> void:
	# The hash fills all thirty-two bits; signed packing would eat the top one.
	var parsed := Protocol.unpack(Protocol.pack_hash(1, 0xFFFFFFFF))
	assert_eq(parsed.hash, 0xFFFFFFFF)

func test_input_packet_is_small() -> void:
	# Sixty packets a second per player: every extra byte is traffic.
	assert_lte(Protocol.pack_input(1000, 31).size(), 8,
		"an input packet must stay tiny")

func test_all_five_input_bits_survive() -> void:
	var all_bits := Types.IN_UP | Types.IN_DOWN | Types.IN_LEFT | Types.IN_RIGHT | Types.IN_FIRE
	assert_eq(Protocol.unpack(Protocol.pack_input(7, all_bits)).bits, all_bits)

func test_garbage_is_rejected_and_does_not_crash() -> void:
	# The network delivers anything at all, including truncated and foreign data.
	assert_eq(Protocol.unpack(PackedByteArray()).kind, Protocol.Kind.INVALID)
	assert_eq(Protocol.unpack(PackedByteArray([0, 1])).kind, Protocol.Kind.INVALID)
	var unknown := PackedByteArray([200, 0, 0, 0, 0, 0, 0, 0, 0])
	assert_eq(Protocol.unpack(unknown).kind, Protocol.Kind.INVALID)

func test_truncated_packet_is_rejected() -> void:
	var good := Protocol.pack_hash(5, 42)
	var cut := good.slice(0, good.size() - 2)
	assert_eq(Protocol.unpack(cut).kind, Protocol.Kind.INVALID)

func test_negative_tick_is_rejected() -> void:
	assert_eq(Protocol.unpack(Protocol.pack_input(-1, 0)).kind, Protocol.Kind.INVALID)
