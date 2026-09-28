extends GutTest

## Who plays by touch. A phone's browser says so through its pointer; a laptop with a
## touch screen has a mouse first and keeps the keyboard's screens.

func after_each() -> void:
	TouchDevice.force(-1)

func test_a_phone_browser_is_touch() -> void:
	assert_true(TouchDevice.decide("Web", "coarse"))

func test_a_desktop_browser_is_not() -> void:
	assert_false(TouchDevice.decide("Web", "fine"))
	assert_false(TouchDevice.decide("Web", ""), "an unanswered question is not a finger")

func test_native_phones_are_touch() -> void:
	assert_true(TouchDevice.decide("Android", ""))
	assert_true(TouchDevice.decide("iOS", ""))

func test_a_desktop_is_not() -> void:
	assert_false(TouchDevice.decide("macOS", ""))
	assert_false(TouchDevice.decide("Windows", ""))

func test_the_test_machine_is_not_touch() -> void:
	# Headless: no browser, no phone. Every other test relies on this.
	assert_false(TouchDevice.present())

func test_force_overrides_and_resets() -> void:
	TouchDevice.force(1)
	assert_true(TouchDevice.present())
	TouchDevice.force(-1)
	assert_false(TouchDevice.present())
