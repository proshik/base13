class_name RelayConfig
extends RefCounted

## Where to look for the room server.
##
## In a browser the page and the server usually live on the same host, so the
## address is derived from the page address — otherwise the build would have to
## be rebuilt for every domain. On desktop the address comes from a launch flag,
## and by default it is this machine: that way the whole game can be checked
## without deploying anything.

## Deliberately not 8080: that one is taken on almost any working machine — by
## a debug server, a port-forward, anything. Silently reaching the wrong place
## is far worse than reaching nothing: the game would connect to somebody else's
## service and freeze for no visible reason. A neighbouring number to the direct
## connection port, so the two stay together.
const DEFAULT := "ws://127.0.0.1:27014/ws"
const PATH := "/ws"
const FLAG := "--relay="

static func url() -> String:
	return resolve(OS.get_cmdline_user_args(), _page_url())

## The pure part, and that is what the tests exercise: parsing with no access
## to the environment.
static func resolve(args: PackedStringArray, page: String) -> String:
	for arg in args:
		if arg.begins_with(FLAG):
			var given := arg.substr(FLAG.length())
			if given != "":
				return given
	if page == "":
		return DEFAULT
	return from_page(page)

## The page yields the server address: https means a secure socket, or the
## browser will refuse to open it from an https page.
static func from_page(page: String) -> String:
	var rest := page
	var scheme := "ws://"
	if page.begins_with("https://"):
		scheme = "wss://"
		rest = page.substr(8)
	elif page.begins_with("http://"):
		rest = page.substr(7)
	else:
		# The page was not opened over the network — with file:// there is
		# nowhere to take a server address from.
		return DEFAULT
	var query := ""
	var mark := rest.find("?")
	if mark >= 0:
		query = rest.substr(mark + 1)
		rest = rest.substr(0, mark)
	var slash := rest.find("/")
	var host := rest.substr(0, slash) if slash >= 0 else rest
	if host == "":
		return DEFAULT
	# The parameter is for a developer's own machine: a local build pointed at
	# another server without rebuilding. On a public page it would let a link
	# send a player's game to any server it names, with our address still in the
	# bar and nothing on screen looking wrong.
	var override := _query_value(query, "relay")
	if override != "" and _is_local(host):
		return override
	return scheme + host + PATH

## Is this page served from the machine it is read on? Only those two names are:
## the browser counts them as a secure origin, and nobody else's page can carry
## them.
static func _is_local(host: String) -> bool:
	var name := host
	var colon := name.rfind(":")
	if colon >= 0 and not name.ends_with("]"):
		name = name.substr(0, colon)
	return name == "localhost" or name == "127.0.0.1" or name == "[::1]"

static func _query_value(query: String, key: String) -> String:
	for pair in query.split("&", false):
		var eq := pair.find("=")
		if eq > 0 and pair.substr(0, eq) == key:
			return pair.substr(eq + 1).uri_decode()
	return ""

static func _page_url() -> String:
	if not OS.has_feature("web"):
		return ""
	var here = JavaScriptBridge.eval("window.location.href", true)
	return here if typeof(here) == TYPE_STRING else ""
