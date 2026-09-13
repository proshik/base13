extends GutTest

func test_same_seed_gives_same_sequence() -> void:
	var a := Rng.new(12345)
	var b := Rng.new(12345)
	for i in 100:
		assert_eq(a.next_u32(), b.next_u32(), "step %d must match" % i)

func test_different_seeds_diverge() -> void:
	var a := Rng.new(1)
	var b := Rng.new(2)
	var same := 0
	for i in 50:
		if a.next_u32() == b.next_u32():
			same += 1
	assert_lt(same, 5, "different seeds must not produce nearly identical streams")

func test_next_u32_stays_in_32_bits() -> void:
	var r := Rng.new(999)
	for i in 1000:
		var v := r.next_u32()
		assert_between(v, 0, 0xFFFFFFFF, "the value is outside 32 bits")

func test_zero_seed_does_not_lock_up() -> void:
	var r := Rng.new(0)
	var first := r.next_u32()
	var second := r.next_u32()
	assert_ne(first, 0, "a zero state would lock the generator up")
	assert_ne(first, second, "the stream must not stand still")

func test_next_range_respects_bounds() -> void:
	var r := Rng.new(7)
	for i in 500:
		var v := r.next_range(3, 8)
		assert_between(v, 3, 7, "next_range is the half-open interval [3, 8)")

func test_next_range_covers_whole_interval() -> void:
	var r := Rng.new(7)
	var seen := {}
	for i in 500:
		seen[r.next_range(0, 4)] = true
	assert_eq(seen.size(), 4, "all four values must appear")

func test_chance_zero_and_hundred_are_absolute() -> void:
	var r := Rng.new(42)
	for i in 100:
		assert_false(r.chance(0), "chance(0) never fires")
		assert_true(r.chance(100), "chance(100) always fires")
