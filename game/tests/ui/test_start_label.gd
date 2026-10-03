extends GutTest

## The console button keeps its START label, including when it pauses a level.

const App := preload("res://ui/app.gd")

func test_a_level_keeps_start() -> void:
	assert_eq(App.start_label(ScreenFlow.Screen.GAME), TouchControls.START_TEXT)

func test_everywhere_else_says_start() -> void:
	for screen in [ScreenFlow.Screen.SPLASH, ScreenFlow.Screen.MENU, ScreenFlow.Screen.NET,
			ScreenFlow.Screen.STATS, ScreenFlow.Screen.GAMEOVER]:
		assert_eq(App.start_label(screen), TouchControls.START_TEXT)
