extends GutTest

## The server folds an unrecognised platform into "other" and a missing one
## into "unknown" — but only for values it does not know. A client that claims
## something outside the closed set would silently start a series of its own,
## so every OS name Godot can report has to land on a value the server lists.

func _no_feature(_name: String) -> bool:
	return false

func test_each_os_name_maps_to_a_closed_value() -> void:
	var has_feature := Callable(self, "_no_feature")
	assert_eq(ClientInfo.platform_name("macOS", has_feature), "macos")
	assert_eq(ClientInfo.platform_name("Windows", has_feature), "windows")
	assert_eq(ClientInfo.platform_name("Linux", has_feature), "linux")
	assert_eq(ClientInfo.platform_name("Android", has_feature), "android")
	assert_eq(ClientInfo.platform_name("iOS", has_feature), "ios")
	# FreeBSD and its relatives are real machines nobody has budgeted a series
	# for; the server folds any name outside its list into "other" already.
	assert_eq(ClientInfo.platform_name("FreeBSD", has_feature), "other")

func test_a_phone_browser_is_told_apart() -> void:
	var android_web := func(name: String) -> bool:
		return name == "web" or name == "web_android"
	assert_eq(ClientInfo.platform_name("Linux", android_web), "web_android",
		"a phone's browser must not be counted with a desktop one")

	var ios_web := func(name: String) -> bool:
		return name == "web" or name == "web_ios"
	assert_eq(ClientInfo.platform_name("iOS", ios_web), "web_ios")

	var desktop_web := func(name: String) -> bool:
		return name == "web"
	assert_eq(ClientInfo.platform_name("Linux", desktop_web), "web",
		"a browser with neither phone feature is a desktop or unknown one")

func test_project_version_is_three_numbers() -> void:
	# Guards the target the release workflow stamps: if this ever stops
	# looking like N.N.N, tools/stamp_version.sh has nothing safe to rewrite.
	var regex := RegEx.new()
	regex.compile("^[0-9]+\\.[0-9]+\\.[0-9]+$")
	assert_true(regex.search(ClientInfo.version()) != null,
		"project version %s is not N.N.N" % ClientInfo.version())
