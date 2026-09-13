extends GutTest

func test_splash_leads_to_the_menu() -> void:
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.SPLASH, ScreenFlow.Outcome.CONTINUE),
		ScreenFlow.Screen.MENU)

func test_menu_starts_the_game() -> void:
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.MENU, ScreenFlow.Outcome.CONTINUE),
		ScreenFlow.Screen.GAME)

func test_level_always_ends_with_statistics() -> void:
	# Both a win and a loss show the tally — as in the original.
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.GAME, ScreenFlow.Outcome.CONTINUE),
		ScreenFlow.Screen.STATS)
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.GAME, ScreenFlow.Outcome.LOST),
		ScreenFlow.Screen.STATS)

func test_statistics_decide_where_to_go() -> void:
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.STATS, ScreenFlow.Outcome.CONTINUE),
		ScreenFlow.Screen.GAME)
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.STATS, ScreenFlow.Outcome.LOST),
		ScreenFlow.Screen.GAMEOVER)

func test_game_over_returns_to_the_menu() -> void:
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.GAMEOVER, ScreenFlow.Outcome.CONTINUE),
		ScreenFlow.Screen.MENU)

func test_unknown_screen_falls_back_to_the_menu() -> void:
	assert_eq(ScreenFlow.next(9999, ScreenFlow.Outcome.CONTINUE), ScreenFlow.Screen.MENU,
		"an unknown screen is no reason to hang with no way out")

func test_a_full_game_returns_to_the_menu() -> void:
	# Splash, menu, level, statistics, game over, menu — the circle must close.
	var screen := ScreenFlow.Screen.SPLASH
	var seen: Array[int] = [screen]
	var outcomes := [ScreenFlow.Outcome.CONTINUE, ScreenFlow.Outcome.CONTINUE,
		ScreenFlow.Outcome.CONTINUE, ScreenFlow.Outcome.LOST, ScreenFlow.Outcome.CONTINUE]
	for outcome in outcomes:
		screen = ScreenFlow.next(screen, outcome)
		seen.append(screen)
	assert_eq(seen, [ScreenFlow.Screen.SPLASH, ScreenFlow.Screen.MENU,
		ScreenFlow.Screen.GAME, ScreenFlow.Screen.STATS, ScreenFlow.Screen.GAMEOVER,
		ScreenFlow.Screen.MENU] as Array[int])

func test_winning_streak_never_leaves_the_level_loop() -> void:
	# While we keep winning we cycle between level and tally and never reach the
	# menu.
	var screen := ScreenFlow.Screen.GAME
	for i in 6:
		screen = ScreenFlow.next(screen, ScreenFlow.Outcome.CONTINUE)
		assert_true(screen == ScreenFlow.Screen.GAME or screen == ScreenFlow.Screen.STATS,
			"winning, there is nowhere to fall out of the level cycle")

func test_every_screen_has_a_scene() -> void:
	# A typo in a path would surface only at launch, and not even then right
	# away: the root node skips a screen it cannot find rather than crashing.
	var app := load("res://ui/app.gd")
	for screen in ScreenFlow.Screen.values():
		var path: String = app.SCENES.get(screen, "")
		assert_true(ResourceLoader.exists(path),
			"screen %d has no scene at path %s" % [screen, path])

func test_quitting_a_level_goes_straight_to_the_menu() -> void:
	# The only way out of a running game into the menu, other than losing.
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.GAME, ScreenFlow.Outcome.QUIT),
		ScreenFlow.Screen.MENU)

func test_menu_can_lead_to_the_network_screen() -> void:
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.MENU, ScreenFlow.Outcome.NET),
		ScreenFlow.Screen.NET)

func test_network_screen_starts_the_game_or_goes_back() -> void:
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.NET, ScreenFlow.Outcome.CONTINUE),
		ScreenFlow.Screen.GAME, "connected, so we play")
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.NET, ScreenFlow.Outcome.QUIT),
		ScreenFlow.Screen.MENU, "it did not work out: back to the menu, not into the game")

func test_desync_is_shown_and_returns_to_the_menu() -> void:
	# A desync skips the tally: showing statistics for a game the two sides
	# disagree about would be a lie.
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.GAME, ScreenFlow.Outcome.DESYNC),
		ScreenFlow.Screen.DESYNC)
	assert_eq(ScreenFlow.next(ScreenFlow.Screen.DESYNC, ScreenFlow.Outcome.CONTINUE),
		ScreenFlow.Screen.MENU)
