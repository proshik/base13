extends GutTest

## The server address comes from the environment, and a mistake here is
## expensive: the game simply connects nowhere and the reason is invisible.

func test_flag_wins_over_everything() -> void:
	var args := PackedStringArray(["--relay=ws://example.org:9000/ws"])
	assert_eq(RelayConfig.resolve(args, "https://base13.example/index.html"),
		"ws://example.org:9000/ws")

func test_desktop_without_flag_looks_at_this_machine() -> void:
	assert_eq(RelayConfig.resolve(PackedStringArray(), ""), RelayConfig.DEFAULT)

func test_empty_flag_is_ignored() -> void:
	assert_eq(RelayConfig.resolve(PackedStringArray(["--relay="]), ""),
		RelayConfig.DEFAULT)

func test_page_over_https_gives_secure_socket() -> void:
	# From an https page the browser will open only wss — otherwise it refuses.
	assert_eq(RelayConfig.from_page("https://base13.example/game/index.html"),
		"wss://base13.example/ws")

func test_page_over_http_gives_plain_socket() -> void:
	assert_eq(RelayConfig.from_page("http://192.168.1.5:8000/index.html"),
		"ws://192.168.1.5:8000/ws")

func test_page_query_can_point_elsewhere() -> void:
	# Checking a page on one's own machine against somebody else's server: there
	# is no need to rebuild for that.
	assert_eq(RelayConfig.from_page(
		"http://localhost:8000/?relay=ws%3A%2F%2Fhost%3A8080%2Fws"),
		"ws://host:8080/ws")

func test_a_local_page_by_address_takes_the_query_too() -> void:
	assert_eq(RelayConfig.from_page(
		"http://127.0.0.1:8000/?relay=ws%3A%2F%2Fhost%3A8080%2Fws"),
		"ws://host:8080/ws")

func test_a_public_page_ignores_the_query() -> void:
	# A link to our own page must not send the game somewhere else: the address
	# bar would show us while the server is the link's.
	assert_eq(RelayConfig.from_page(
		"https://base13.example/?relay=wss%3A%2F%2Fevil.example%2Fws"),
		"wss://base13.example/ws")

func test_page_without_host_falls_back() -> void:
	assert_eq(RelayConfig.from_page("file:///tmp/index.html"), RelayConfig.DEFAULT)
