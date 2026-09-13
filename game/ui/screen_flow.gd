class_name ScreenFlow

## Which screen follows which. Kept apart from the nodes because the flow of
## screens is a rule and not a layout: a rule is checked by a test, a layout is
## checked by running the game.

enum Screen { SPLASH, MENU, GAME, STATS, GAMEOVER, NET, DESYNC }
enum Outcome { CONTINUE, LOST, QUIT, DESYNC, NET }

static func next(screen: int, outcome: int) -> int:
	match screen:
		Screen.SPLASH:
			return Screen.MENU
		Screen.MENU:
			return Screen.NET if outcome == Outcome.NET else Screen.GAME
		Screen.NET:
			# The connection did not work out — back to the menu, not into the
			# game.
			return Screen.GAME if outcome == Outcome.CONTINUE else Screen.MENU
		Screen.GAME:
			# Both a win and a loss lead to the tally — as in the original.
			# Quitting from the pause and a desync skip it.
			if outcome == Outcome.QUIT:
				return Screen.MENU
			if outcome == Outcome.DESYNC:
				return Screen.DESYNC
			return Screen.STATS
		Screen.DESYNC:
			return Screen.MENU
		Screen.STATS:
			return Screen.GAMEOVER if outcome == Outcome.LOST else Screen.GAME
		Screen.GAMEOVER:
			return Screen.MENU
	return Screen.MENU
