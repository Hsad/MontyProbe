package monty

import rl "vendor:raylib"

SCREEN_W :: 1280
SCREEN_H :: 800
TITLE :: "Monty: Evolving Sensors"

main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.InitWindow(SCREEN_W, SCREEN_H, TITLE)
	defer rl.CloseWindow()

	rl.SetTargetFPS(60)

	game := new(Game_State)
	game_init(game)
	defer { game_cleanup(game); free(game) }

	rl.SetExitKey(.KEY_NULL) // We handle ESC ourselves
	for !rl.WindowShouldClose() && !game.quit_requested {
		dt := rl.GetFrameTime()
		game_update(game, dt)

		rl.BeginDrawing()
		rl.ClearBackground(Color{10, 10, 20, 255})
		game_draw(game)
		rl.EndDrawing()
	}
}
