package monty

import rl "vendor:raylib"

SCREEN_W :: 1280
SCREEN_H :: 800
TITLE :: "Monty: Evolving Sensors"

// Hack-Regular.ttf embedded at compile time; loaded into raylib's
// font atlas at startup so we can render briefing prose at high sizes
// without raster scaling artifacts.
HACK_FONT_DATA :: #load("../assets/fonts/Hack-Regular.ttf")

g_font: rl.Font

main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.InitWindow(SCREEN_W, SCREEN_H, TITLE)
	defer rl.CloseWindow()

	rl.SetTargetFPS(60)

	// Atlas baked at 48px — sharp from ~12px up to about 50px
	g_font = rl.LoadFontFromMemory(".ttf", raw_data(HACK_FONT_DATA),
		i32(len(HACK_FONT_DATA)), 48, nil, 0)
	rl.SetTextureFilter(g_font.texture, .BILINEAR)
	defer rl.UnloadFont(g_font)

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
