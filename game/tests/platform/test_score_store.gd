extends GutTest

func test_round_trip() -> void:
	assert_eq(ScoreStore.parse(ScoreStore.serialise(20000)), 20000)

func test_reads_a_normal_file() -> void:
	assert_eq(ScoreStore.parse("best=12345\n"), 12345)

func test_ignores_surrounding_whitespace() -> void:
	assert_eq(ScoreStore.parse("  best = 700 \n"), 700)

func test_missing_file_means_no_record() -> void:
	assert_eq(ScoreStore.parse(""), 0)

func test_garbage_means_no_record_and_not_a_crash() -> void:
	# A damaged config is no reason to refuse a game.
	assert_eq(ScoreStore.parse("  garbage"), 0)
	assert_eq(ScoreStore.parse("best=not a number"), 0)
	assert_eq(ScoreStore.parse("an entirely wrong format"), 0)

func test_negative_is_treated_as_no_record() -> void:
	assert_eq(ScoreStore.parse("best=-5"), 0)

func test_unknown_keys_do_not_confuse_it() -> void:
	assert_eq(ScoreStore.parse("volume=3\nbest=42\nlanguage=ru\n"), 42)

func test_a_key_that_merely_starts_the_same_is_not_taken() -> void:
	assert_eq(ScoreStore.parse("bestiary=99\n"), 0,
		"a key that merely starts alike is not that key")
