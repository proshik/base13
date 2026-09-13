extends GutTest

## The run itself lives in core/golden.gd: more than this test uses it — the web
## build checks with it that the browser computes the world as the desktop does.

func test_recorded_run_still_produces_the_same_state() -> void:
	var actual := Golden.run()
	assert_eq(actual, Golden.EXPECTED, "the golden run diverged; actual hash: %d" % actual)

func test_the_run_is_repeatable_within_one_process() -> void:
	assert_eq(Golden.run(), Golden.run(), "two runs in a row must match")
