class_name ClientInfo extends RefCounted

## What this client tells the server about itself in the hello: platform and
## version, and in a browser its family and system. The server folds whatever it does not recognise into "other" or
## "unknown", so a wrong guess here costs a metric series, not a connection —
## still, mapping to the values it actually lists keeps a phone from being
## counted as a desktop and a dev build from claiming a release it is not.

## `has_feature` is a seam: `OS.has_feature` cannot be called with a made-up
## name from a test without actually running inside that environment, and a
## Callable lets a test hand in whatever the fake browser would answer.
static func platform_name(os_name: String, has_feature: Callable) -> String:
	if has_feature.call("web"):
		if has_feature.call("web_android"):
			return "web_android"
		if has_feature.call("web_ios"):
			return "web_ios"
		return "web"
	match os_name:
		"macOS":
			return "macos"
		"Windows":
			return "windows"
		"Linux":
			return "linux"
		"Android":
			return "android"
		"iOS":
			return "ios"
		_:
			# FreeBSD and the like: a real machine, just not one with a series
			# of its own. The server folds it into "other" regardless.
			return "other"

## The project's own version. Left at "0.0.0" by default and stamped to the
## real number only by the release workflow, right before that build — a dev
## build has no business claiming a release it was not given.
static func version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0.0.0"))

## The browser's family, out of its user agent. Checked from the most particular
## down: Edge, Opera, Yandex and Samsung's all say "Chrome" too, every Chrome
## says "Safari", and Chrome and Firefox on an iPhone go by names of their own.
static func browser_family(user_agent: String) -> String:
	for family in [
		["edge", ["Edg/", "EdgA/", "EdgiOS/"]],
		["opera", ["OPR/", "OPT/"]],
		["yandex", ["YaBrowser/"]],
		["samsung", ["SamsungBrowser/"]],
		["firefox", ["Firefox/", "FxiOS/"]],
		["chrome", ["Chrome/", "CriOS/", "Chromium/"]],
		["safari", ["Safari/"]],
	]:
		for mark in family[1]:
			if user_agent.contains(mark):
				return family[0]
	return "other"

## The system under the browser. An iPhone says "like Mac OS X" and an Android
## says "Linux", so each goes before the one it mentions. An iPad asking for the
## desktop site says "Macintosh" and is counted as one: the user agent cannot
## tell them apart.
static func system_family(user_agent: String) -> String:
	for family in [
		["ios", ["iPhone", "iPad", "iPod"]],
		["android", ["Android"]],
		["chromeos", ["CrOS"]],
		["windows", ["Windows"]],
		["macos", ["Macintosh", "Mac OS X"]],
		["linux", ["Linux", "X11"]],
	]:
		for mark in family[1]:
			if user_agent.contains(mark):
				return family[0]
	return "other"

## What the hello says: the platform and version, and in a browser its family
## and system — two words, never the user agent, which is far closer to telling
## one person from another than anything the server needs.
static func fields_for(platform: String, release: String, user_agent: String) -> Dictionary:
	var said := {"platform": platform, "version": release}
	if platform.begins_with("web"):
		said["browser"] = browser_family(user_agent)
		said["os"] = system_family(user_agent)
	return said

static func fields() -> Dictionary:
	var user_agent := ""
	if OS.has_feature("web"):
		var read = JavaScriptBridge.eval("navigator.userAgent", true)
		if typeof(read) == TYPE_STRING:
			user_agent = read
	return fields_for(platform_name(OS.get_name(), Callable(OS, "has_feature")), version(), user_agent)
