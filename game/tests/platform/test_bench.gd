extends GutTest

func test_the_measurement_names_three_positive_whole_numbers() -> void:
	var m := Bench.measure()
	for key in ["tick_us", "save_us", "resim_us"]:
		assert_true(m.has(key), "%s is missing" % key)
		assert_eq(typeof(m[key]), TYPE_INT, "%s is not whole" % key)
		assert_gt(m[key], 0, "%s measured nothing" % key)
