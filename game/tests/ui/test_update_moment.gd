extends GutTest

## A new release reaches an installed game only when the page asks for it: the
## service worker keeps serving the old one until every window of the game is
## closed. The page asks where a reload loses nothing.

const App := preload("res://ui/app.gd")

func test_the_splash_and_the_menu_take_an_update() -> void:
	assert_true(App.update_moment(ScreenFlow.Screen.SPLASH))
	assert_true(App.update_moment(ScreenFlow.Screen.MENU))

func test_nothing_else_does() -> void:
	# A reload in a level throws the level away; on the network screen, the room.
	for screen in [ScreenFlow.Screen.GAME, ScreenFlow.Screen.STATS,
			ScreenFlow.Screen.GAMEOVER, ScreenFlow.Screen.NET, ScreenFlow.Screen.DESYNC]:
		assert_false(App.update_moment(screen), "screen %d would be thrown away" % screen)
