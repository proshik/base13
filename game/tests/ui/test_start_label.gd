extends GutTest

## The screen's START button pauses a level, so in a level it says PAUSE.

const App := preload("res://ui/app.gd")

func test_a_level_says_pause() -> void:
	assert_eq(App.start_label(ScreenFlow.Screen.GAME), TouchControls.PAUSE_TEXT)

func test_everywhere_else_says_start() -> void:
	for screen in [ScreenFlow.Screen.SPLASH, ScreenFlow.Screen.MENU, ScreenFlow.Screen.NET,
			ScreenFlow.Screen.STATS, ScreenFlow.Screen.GAMEOVER]:
		assert_eq(App.start_label(screen), TouchControls.START_TEXT)
