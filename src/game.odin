package monty

import rl "vendor:raylib"

Scene :: enum {
	Level_Select,
	Playing,
}

Level_ID :: enum {
	Motion,
	Smell,
	Light,
	Touch,
	Drones,
	Range,
	Eye,
	Sonar,
	Fleet,
}

LEVEL_COUNT :: len(Level_ID)

Level_Info :: struct {
	name:        cstring,
	sensor_name: cstring,
	description: cstring,   // rough overview shown in the menu side panel
	detail:      cstring,   // full briefing shown by pressing [D]
	unlocked:    bool,
	completed:   bool,
	vtable:      Level_Vtable,
}

Level_Vtable :: struct {
	init:    proc(game: ^Game_State),
	update:  proc(game: ^Game_State, dt: f32),
	draw:    proc(game: ^Game_State),
	draw_ui: proc(game: ^Game_State),
	cleanup: proc(game: ^Game_State),
}

Popup_Kind :: enum {
	None,
	Confirm_Leave_Level,
	Confirm_Quit_Game,
	Confirm_Reset,
	Level_Complete,
}

Popup_State :: struct {
	kind:          Popup_Kind,
	selected:      int,       // 0 = first option (usually yes/continue), 1 = second
	pending_kind:  Popup_Kind,
	pending_timer: f32,       // counts down; when <= 0 with pending != None, popup opens
}

// MAX_LMS covers the mothership's primary LM + one per drone slot
MAX_LMS :: MAX_DRONES + 1

Game_State :: struct {
	scene:          Scene,
	ship:           Ship,
	world:          World,
	current_level:  Level_ID,
	selected_level: Level_ID,
	levels:         [LEVEL_COUNT]Level_Info,
	camera:         rl.Camera3D,
	popup:          Popup_State,
	quit_requested: bool,

	// Monty core — shared across levels
	model_db:       Model_Database,          // long-term object memory
	lms:            [MAX_LMS]Learning_Module, // LM[0] = mothership, LM[1..] = drones
}

game_init :: proc(game: ^Game_State) {
	game.scene = .Level_Select
	game.selected_level = .Motion

	game.camera = rl.Camera3D {
		position   = {0, 10, 20},
		target     = {0, 0, 0},
		up         = {0, 1, 0},
		fovy       = 60,
		projection = .PERSPECTIVE,
	}

	game.levels[Level_ID.Motion] = {
		name        = "Self-Motion",
		sensor_name = "Gyroscope",
		description = "Fly blind. Track your own displacement.\nYou know where you've been,\nbut not what's out there.",
		detail      = briefing_motion,
		unlocked    = true,
		vtable      = l0_motion_vtable(),
	}
	game.levels[Level_ID.Smell] = {
		name        = "Chemical Sensor",
		sensor_name = "Chem Probe",
		description = "Detect nearby objects by chemical\ngradient. Move to find the source.",
		detail      = briefing_smell,
		unlocked    = false,
		vtable      = l1_smell_vtable(),
	}
	game.levels[Level_ID.Light] = {
		name        = "Photon Probe",
		sensor_name = "Light Sensor",
		description = "A directional brightness sensor.\nYour first feature-at-a-pose.",
		detail      = briefing_light,
		unlocked    = false,
		vtable      = l2_light_vtable(),
	}
	game.levels[Level_ID.Touch] = {
		name        = "Contact Scanner",
		sensor_name = "Hull Probe",
		description = "Touch surfaces. Feel normals and\ntexture. Build your first object graph.",
		detail      = briefing_touch,
		unlocked    = false,
		vtable      = l2_touch_vtable(),
	}
	game.levels[Level_ID.Drones] = {
		name        = "Drone Fleet",
		sensor_name = "Drones",
		description = "Launch drones. Each builds its own\nmodel. Watch them vote over radio.",
		detail      = briefing_drones,
		unlocked    = false,
		vtable      = l4_drones_vtable(),
	}
	game.levels[Level_ID.Range] = {
		name        = "Laser Range",
		sensor_name = "Rangefinder",
		description = "Sense from afar. Where should\nyou look next? Curiosity-driven scan.",
		detail      = briefing_range,
		unlocked    = false,
		vtable      = l5_range_vtable(),
	}
	game.levels[Level_ID.Eye] = {
		name        = "Sensor Array",
		sensor_name = "Optic Array",
		description = "An array of sensors — your retina.\nA thousand columns, all voting.",
		detail      = briefing_eye,
		unlocked    = false,
		vtable      = l6_eye_vtable(),
	}
	game.levels[Level_ID.Sonar] = {
		name        = "Echo Sonar",
		sensor_name = "Sonar",
		description = "Sound gives shape and material.\nDifferent modality, same protocol.",
		detail      = briefing_sonar,
		unlocked    = false,
		vtable      = l7_sonar_vtable(),
	}
	game.levels[Level_ID.Fleet] = {
		name        = "Composition",
		sensor_name = "Fleet AI",
		description = "Parts make wholes. Drones recognize\ncomponents, mothership assembles.",
		detail      = briefing_fleet,
		unlocked    = false,
		vtable      = l8_fleet_vtable(),
	}

	ship_init(&game.ship)
	world_init(&game.world)
	model_db_init(&game.model_db)
	for i in 0..<MAX_LMS {
		lm_init(&game.lms[i], i)
	}

	// Apply saved progress on top of defaults
	save_load(game)
}

game_update :: proc(game: ^Game_State, dt: f32) {
	// Pending popup: tick down the delay, then promote to active
	if game.popup.pending_kind != .None && game.popup.kind == .None {
		game.popup.pending_timer -= dt
		if game.popup.pending_timer <= 0 {
			popup_show(game, game.popup.pending_kind)
			game.popup.pending_kind = .None
		}
	}

	// Popups eat all input while active
	if game.popup.kind != .None {
		popup_update(game)
		return
	}

	switch game.scene {
	case .Level_Select:
		level_select_update(game, dt)
	case .Playing:
		vtable := game.levels[game.current_level].vtable
		if vtable.update != nil {
			vtable.update(game, dt)
		}
	}
}

popup_show :: proc(game: ^Game_State, kind: Popup_Kind) {
	game.popup.kind = kind
	game.popup.selected = 0
	game.popup.pending_kind = .None
	game.popup.pending_timer = 0
}

// Show a popup after `delay` seconds — gives the moment to land
popup_show_delayed :: proc(game: ^Game_State, kind: Popup_Kind, delay: f32) {
	game.popup.pending_kind  = kind
	game.popup.pending_timer = delay
}

popup_update :: proc(game: ^Game_State) {
	if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressed(.A) {
		game.popup.selected = max(game.popup.selected - 1, 0)
	}
	if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressed(.D) {
		game.popup.selected = min(game.popup.selected + 1, 1)
	}

	// ESC dismisses the popup (cancel)
	if rl.IsKeyPressed(.ESCAPE) {
		game.popup.kind = .None
		return
	}

	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE) {
		switch game.popup.kind {
		case .Confirm_Leave_Level:
			if game.popup.selected == 0 {
				game.popup.kind = .None
				game_return_to_select(game)
			} else {
				game.popup.kind = .None
			}
		case .Confirm_Quit_Game:
			if game.popup.selected == 0 {
				game.quit_requested = true
			} else {
				game.popup.kind = .None
			}
		case .Confirm_Reset:
			if game.popup.selected == 0 {
				save_reset(game)
				game.popup.kind = .None
			} else {
				game.popup.kind = .None
			}
		case .Level_Complete:
			game.popup.kind = .None
			if game.popup.selected == 0 {
				save_write(game)
				next := next_level(game.current_level)
				if next != nil {
					game_enter_level(game, next.?)
				} else {
					game_return_to_select(game)
				}
			} else {
				save_write(game)
				game_return_to_select(game)
			}
		case .None:
		}
	}
}

next_level :: proc(current: Level_ID) -> Maybe(Level_ID) {
	idx := int(current)
	if idx + 1 < LEVEL_COUNT {
		return Level_ID(idx + 1)
	}
	return nil
}

game_draw :: proc(game: ^Game_State) {
	switch game.scene {
	case .Level_Select:
		level_select_draw(game)
	case .Playing:
		vtable := game.levels[game.current_level].vtable
		if vtable.draw != nil {
			vtable.draw(game)
		}
		if vtable.draw_ui != nil {
			vtable.draw_ui(game)
		}
	}

	if game.popup.kind != .None {
		popup_draw(game)
	}
}

popup_draw :: proc(game: ^Game_State) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())

	// Dim overlay
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), Color{0, 0, 0, 160})

	box_w: f32 = 420
	box_h: f32 = 160
	bx := sw / 2 - box_w / 2
	by := sh / 2 - box_h / 2

	// Box background
	rl.DrawRectangleRounded({bx, by, box_w, box_h}, 0.08, 8, Color{20, 25, 40, 240})
	rl.DrawRectangleRoundedLinesEx({bx, by, box_w, box_h}, 0.08, 8, 2, Color{80, 120, 200, 200})

	title: cstring
	opt_a: cstring
	opt_b: cstring

	switch game.popup.kind {
	case .Confirm_Leave_Level:
		title = "Leave this level?"
		opt_a = "Yes, leave"
		opt_b = "Keep playing"
	case .Confirm_Quit_Game:
		title = "Quit game?"
		opt_a = "Quit"
		opt_b = "Stay"
	case .Confirm_Reset:
		title = "Reset all progress?"
		opt_a = "Reset"
		opt_b = "Cancel"
	case .Level_Complete:
		next := next_level(game.current_level)
		if next != nil {
			next_name := game.levels[next.?].name
			title = "Level complete!"
			opt_a = "Next level"
			opt_b = "Back to map"
		} else {
			title = "All levels complete!"
			opt_a = "Back to map"
			opt_b = "Back to map"
		}
	case .None:
		return
	}

	// Title
	title_w := rl.MeasureText(title, 26)
	rl.DrawText(title, i32(sw / 2) - title_w / 2, i32(by) + 25, 26, Color{255, 255, 255, 255})

	// Buttons
	btn_w: f32 = 160
	btn_h: f32 = 40
	btn_y := by + box_h - 60
	btn_a_x := sw / 2 - btn_w - 15
	btn_b_x := sw / 2 + 15

	// Button A
	a_bg: Color = game.popup.selected == 0 ? {60, 100, 200, 255} : {40, 50, 70, 200}
	a_border: Color = game.popup.selected == 0 ? {100, 160, 255, 255} : {60, 70, 90, 150}
	rl.DrawRectangleRounded({btn_a_x, btn_y, btn_w, btn_h}, 0.2, 4, a_bg)
	rl.DrawRectangleRoundedLinesEx({btn_a_x, btn_y, btn_w, btn_h}, 0.2, 4, 1, a_border)
	a_tw := rl.MeasureText(opt_a, 18)
	rl.DrawText(opt_a, i32(btn_a_x + btn_w / 2) - a_tw / 2, i32(btn_y) + 11, 18, Color{255, 255, 255, 255})

	// Button B
	b_bg: Color = game.popup.selected == 1 ? {60, 100, 200, 255} : {40, 50, 70, 200}
	b_border: Color = game.popup.selected == 1 ? {100, 160, 255, 255} : {60, 70, 90, 150}
	rl.DrawRectangleRounded({btn_b_x, btn_y, btn_w, btn_h}, 0.2, 4, b_bg)
	rl.DrawRectangleRoundedLinesEx({btn_b_x, btn_y, btn_w, btn_h}, 0.2, 4, 1, b_border)
	b_tw := rl.MeasureText(opt_b, 18)
	rl.DrawText(opt_b, i32(btn_b_x + btn_w / 2) - b_tw / 2, i32(btn_y) + 11, 18, Color{255, 255, 255, 255})

	// Hint
	rl.DrawText("[LEFT/RIGHT] Select  [ENTER] Confirm  [ESC] Cancel", i32(sw / 2) - 210, i32(by + box_h) + 10, 14, Color{80, 100, 140, 150})
}

game_cleanup :: proc(game: ^Game_State) {
	vtable := game.levels[game.current_level].vtable
	if vtable.cleanup != nil {
		vtable.cleanup(game)
	}
	ship_cleanup(&game.ship)
	world_cleanup(&game.world)
}

game_enter_level :: proc(game: ^Game_State, level: Level_ID) {
	if !game.levels[level].unlocked do return

	// Cleanup previous level if playing
	if game.scene == .Playing {
		vtable := game.levels[game.current_level].vtable
		if vtable.cleanup != nil {
			vtable.cleanup(game)
		}
	}

	game.current_level = level
	game.scene = .Playing

	vtable := game.levels[level].vtable
	if vtable.init != nil {
		vtable.init(game)
	}
}

game_return_to_select :: proc(game: ^Game_State) {
	vtable := game.levels[game.current_level].vtable
	if vtable.cleanup != nil {
		vtable.cleanup(game)
	}
	game.scene = .Level_Select
}
