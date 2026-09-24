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

## A browser's hello names its family and the system under it, worked out here
## from the user agent: the server's log says "Chrome on macOS" without ever
## being handed the user agent, which is far closer to a fingerprint than either
## word. Whatever is not recognised is "other", which the server lists too.
func test_a_user_agent_is_named_by_family_only() -> void:
	for c in [
		["Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36", "chrome", "macos"],
		["Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15", "safari", "macos"],
		["Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0", "firefox", "windows"],
		["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36 Edg/129.0", "edge", "windows"],
		["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0 Safari/537.36 OPR/113.0", "opera", "windows"],
		["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 YaBrowser/24.7 Safari/537.36", "yandex", "windows"],
		["Mozilla/5.0 (Linux; Android 14; SM-S911B) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/25.0 Chrome/121.0 Mobile Safari/537.36", "samsung", "android"],
		["Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Mobile Safari/537.36", "chrome", "android"],
		["Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/129.0 Mobile/15E148 Safari/604.1", "chrome", "ios"],
		["Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/130.0 Mobile/15E148 Safari/605.1.15", "firefox", "ios"],
		["Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1", "safari", "ios"],
		["Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36", "chrome", "linux"],
		["Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36", "chrome", "chromeos"],
		["curl/8.7.1", "other", "other"],
		["", "other", "other"],
	]:
		assert_eq(ClientInfo.browser_family(c[0]), c[1], "the browser of %s" % c[0])
		assert_eq(ClientInfo.system_family(c[0]), c[2], "the system of %s" % c[0])

## Only a browser has a user agent to name, and only its hello carries the two
## words; a desktop build's hello stays as it was.
func test_only_a_browser_names_its_family() -> void:
	var chrome_mac := "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36"
	assert_eq(ClientInfo.fields_for("web", "0.6.5", chrome_mac),
		{"platform": "web", "version": "0.6.5", "browser": "chrome", "os": "macos"})
	assert_eq(ClientInfo.fields_for("web_ios", "0.6.5", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"),
		{"platform": "web_ios", "version": "0.6.5", "browser": "safari", "os": "ios"})
	assert_eq(ClientInfo.fields_for("macos", "0.6.5", ""), {"platform": "macos", "version": "0.6.5"})
