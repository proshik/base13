class_name ClientInfo extends RefCounted

## What this client tells the server about itself in the hello: platform and
## version. The server folds whatever it does not recognise into "other" or
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

static func fields() -> Dictionary:
	return {
		"platform": platform_name(OS.get_name(), Callable(OS, "has_feature")),
		"version": version(),
	}
