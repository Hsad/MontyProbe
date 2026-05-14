package monty

import rl "vendor:raylib"
import "core:math"

// Star chart level selector.
// Left: vertical node path (star systems).
// Right-top: ship preview with accumulated sensors.
// Right-bottom: description of selected level.

@(private = "file")
select_anim_t: f32 = 0

@(private = "file")
locked_flash: f32 = 0  // counts down when player tries to enter a locked level

level_select_update :: proc(game: ^Game_State, dt: f32) {
	select_anim_t += dt
	if locked_flash > 0 do locked_flash -= dt

	// About page intercepts all keys
	if about_is_open() {
		if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.I) || rl.IsKeyPressed(.BACKSPACE) {
			about_close()
			return
		}
		about_handle_scroll(dt)
		return
	}

	// Briefing overlay intercepts most keys
	if briefing_is_open() {
		if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.D) || rl.IsKeyPressed(.BACKSPACE) {
			briefing_close()
			return
		}
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE) {
			if game.levels[game.selected_level].unlocked {
				briefing_close()
				game_enter_level(game, game.selected_level)
			} else {
				locked_flash = 1.2
			}
		}
		// LEFT/RIGHT navigates between levels (resets scroll on change)
		sel := int(game.selected_level)
		old_sel := sel
		if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressed(.L) do sel = min(sel + 1, LEVEL_COUNT - 1)
		if rl.IsKeyPressed(.LEFT)  || rl.IsKeyPressed(.H) do sel = max(sel - 1, 0)
		if sel != old_sel {
			game.selected_level = Level_ID(sel)
			briefing_on_level_change()
		}
		// UP/DOWN scrolls the content
		briefing_handle_scroll(dt)
		return
	}

	sel := int(game.selected_level)

	if rl.IsKeyPressed(.DOWN) || rl.IsKeyPressed(.J) {
		sel = min(sel + 1, LEVEL_COUNT - 1)
	}
	if rl.IsKeyPressed(.UP) || rl.IsKeyPressed(.K) {
		sel = max(sel - 1, 0)
	}
	game.selected_level = Level_ID(sel)

	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE) {
		if game.levels[game.selected_level].unlocked {
			game_enter_level(game, game.selected_level)
		} else {
			locked_flash = 1.2
		}
	}

	if rl.IsKeyPressed(.D) {
		briefing_toggle()
	}

	if rl.IsKeyPressed(.I) {
		about_toggle()
	}

	if rl.IsKeyPressed(.ESCAPE) {
		popup_show(game, .Confirm_Quit_Game)
	}

	if rl.IsKeyPressed(.R) {
		popup_show(game, .Confirm_Reset)
	}
}

level_select_draw :: proc(game: ^Game_State) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	margin: f32 = 20

	// Layout: left panel takes ~45%, right panel takes ~55%
	divider_x := sw * 0.42
	right_x := divider_x + margin

	// Title — centered over left panel
	title :: "EVOLVING SENSORS"
	title_size: i32 = 40
	left_center := divider_x / 2
	tw := rl.MeasureText(title, title_size)
	rl.DrawText(title, i32(left_center) - tw / 2, 20, title_size, Color{100, 180, 255, 255})

	subtitle :: "A Thousand Brains Journey"
	rl.DrawText(subtitle, i32(left_center) - rl.MeasureText(subtitle, 16) / 2, 65, 16, Color{80, 120, 180, 180})

	// Left panel — node path
	left_x: f32 = margin + 30
	start_y: f32 = 100
	step_y: f32 = (sh - start_y - 60) / f32(LEVEL_COUNT)

	for i in 0..<LEVEL_COUNT {
		level := Level_ID(i)
		info := game.levels[level]
		y := start_y + f32(i) * step_y
		is_selected := level == game.selected_level

		// Vertical connector line
		if i < LEVEL_COUNT - 1 {
			line_color: Color = info.unlocked ? {60, 100, 160, 200} : {30, 30, 50, 100}
			rl.DrawLineEx({left_x, y + 12}, {left_x, y + step_y}, 2, line_color)
		}

		// Node circle
		radius: f32 = is_selected ? 10 : 7
		if info.completed {
			rl.DrawCircleV({left_x, y}, radius, Color{100, 220, 100, 255})
		} else if info.unlocked {
			pulse := is_selected ? u8(180 + 75 * math.sin(select_anim_t * 3)) : 180
			rl.DrawCircleV({left_x, y}, radius, Color{100, 180, 255, pulse})
		} else {
			rl.DrawCircleV({left_x, y}, radius, Color{40, 40, 60, 150})
		}
		rl.DrawCircleLinesV({left_x, y}, radius, Color{150, 200, 255, 100})

		// Level name
		name_color: Color = is_selected ? {255, 255, 255, 255} : info.unlocked ? {160, 180, 220, 200} : {60, 60, 80, 150}
		font_size: i32 = is_selected ? 22 : 18
		rl.DrawText(info.name, i32(left_x) + 24, i32(y) - font_size / 2, font_size, name_color)

		// Sensor tag
		if info.sensor_name != nil {
			tag_x := i32(left_x) + 24 + rl.MeasureText(info.name, font_size) + 12
			tag_color: Color = info.unlocked ? {80, 200, 150, 180} : {40, 60, 50, 100}
			rl.DrawText(info.sensor_name, tag_x, i32(y) - font_size / 2 + 2, 14, tag_color)
		}

		// Selection indicator
		if is_selected {
			rl.DrawTriangle(
				{left_x - 22, y},
				{left_x - 30, y - 6},
				{left_x - 30, y + 6},
				Color{100, 180, 255, 255},
			)
		}
	}

	// Divider line
	rl.DrawLineEx({divider_x, margin}, {divider_x, sh - margin}, 1, Color{40, 50, 70, 100})

	// Right panel — ship preview area (fills top half of right side)
	preview_x := right_x
	preview_y: f32 = margin
	preview_w := sw - right_x - margin
	preview_h := sh * 0.4

	rl.DrawRectangleLinesEx({preview_x, preview_y, preview_w, preview_h}, 1, Color{60, 80, 120, 100})
	rl.DrawText("[ MOTHERSHIP ]", i32(preview_x) + 10, i32(preview_y) + 10, 16, Color{80, 120, 180, 180})

	// Draw a simple top-down ship schematic
	draw_ship_schematic(game, preview_x + preview_w / 2, preview_y + preview_h / 2, select_anim_t)

	// Right panel — description (fills bottom half of right side)
	desc_y := preview_y + preview_h + 20
	selected_info := game.levels[game.selected_level]
	rl.DrawText(selected_info.name, i32(preview_x), i32(desc_y), 28, Color{255, 255, 255, 255})
	rl.DrawLine(i32(preview_x), i32(desc_y) + 34, i32(preview_x + preview_w), i32(desc_y) + 34, Color{60, 80, 120, 100})

	if selected_info.description != nil {
		rl.DrawText(selected_info.description, i32(preview_x), i32(desc_y) + 44, 18, Color{160, 180, 220, 220})
	}

	// [D] for briefing
	rl.DrawText("press [D] for a full briefing", i32(preview_x),
		i32(desc_y) + 86, 13, Color{120, 180, 255, 200})

	// Locked state indicator
	if !selected_info.unlocked {
		flash_alpha: u8 = locked_flash > 0 ? u8(min(locked_flash, 1) * 255) : 100
		rl.DrawText("LOCKED — complete previous levels first", i32(preview_x),
			i32(desc_y) + 110, 16, Color{255, 120, 120, flash_alpha})
	}

	// Monty concept hint
	concept := monty_concept_for_level(game.selected_level)
	if concept != nil {
		concept_y := desc_y + 130
		rl.DrawText("Monty concept:", i32(preview_x), i32(concept_y), 14, Color{80, 200, 150, 180})
		rl.DrawText(concept, i32(preview_x), i32(concept_y) + 20, 16, Color{80, 200, 150, 220})
	}

	// Controls hint
	rl.DrawText("[UP/DOWN] Select  [ENTER] Launch  [D] Briefing  [I] About  [R] Reset  [ESC] Quit",
		i32(sw / 2) - 360, i32(sh) - 30, 15, Color{80, 100, 140, 150})

	// Attribution — bottom right corner
	credit :: "designed by Dash  ·  Built by Opus 4.7"
	credit_w := rl.MeasureText(credit, 13)
	rl.DrawText(credit, i32(sw) - credit_w - 16, i32(sh) - 52, 13,
		Color{80, 100, 140, 160})

	// Briefing overlay (drawn last so it covers the selector)
	briefing_draw(game)
	// About overlay drawn after briefing — opening either while the other is
	// open isn't allowed by the input handler, but order matters if both were
	// somehow active
	about_draw()
}

draw_ship_schematic :: proc(game: ^Game_State, cx, cy: f32, t: f32) {
	// Simple top-down ship shape
	scale: f32 = 2.5

	// Hull — elongated diamond
	rl.DrawTriangle(
		{cx, cy - 30 * scale},         // nose
		{cx - 12 * scale, cy + 5 * scale},
		{cx + 12 * scale, cy + 5 * scale},
		Color{40, 60, 100, 200},
	)
	rl.DrawTriangle(
		{cx - 12 * scale, cy + 5 * scale},
		{cx, cy + 20 * scale},          // tail
		{cx + 12 * scale, cy + 5 * scale},
		Color{30, 45, 80, 200},
	)

	// Outline
	rl.DrawTriangleLines(
		{cx, cy - 30 * scale},
		{cx - 12 * scale, cy + 5 * scale},
		{cx + 12 * scale, cy + 5 * scale},
		Color{100, 160, 240, 150},
	)

	// Show sensors earned so far (up to selected level)
	sensor_y := cy - 10 * scale
	sensors := game.ship.sensors

	if .Proprioception in sensors {
		// Gyroscope indicator — spinning ring
		rl.DrawCircleLinesV({cx, cy}, 8, Color{100, 180, 255, 150})
		angle := t * 2
		gx := cx + 8 * math.cos(angle)
		gy := cy + 8 * math.sin(angle)
		rl.DrawCircleV({gx, gy}, 2, Color{100, 180, 255, 255})
	}

	if .Chemical in sensors {
		// Nose — small antenna at front
		rl.DrawLineEx({cx, cy - 30 * scale}, {cx, cy - 36 * scale}, 2, Color{200, 150, 50, 200})
		rl.DrawCircleV({cx, cy - 36 * scale}, 3, Color{200, 150, 50, u8(150 + 80 * math.sin(t * 4))})
	}
}

monty_concept_for_level :: proc(level: Level_ID) -> cstring {
	switch level {
	case .Motion:  return "Motor system — displacement tracking"
	case .Smell:   return "Sensation requires movement"
	case .Light:   return "Features at a pose (CMP message)"
	case .Touch:   return "Learning Module — object graphs"
	case .Drones:  return "Multi-column voting & consensus"
	case .Range:   return "Model-based action policies"
	case .Eye:     return "Thousand brains — SDR representation"
	case .Sonar:   return "Cross-modal CMP integration"
	case .Fleet:   return "Hierarchical composition"
	case .Sandbox: return "Free play — every sensor, infinite world"
	}
	return nil
}
