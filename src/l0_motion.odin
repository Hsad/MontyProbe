package monty

import rl "vendor:raylib"
import "core:math"
import "core:math/linalg"
import "core:fmt"

// Level 0: Self-Motion
// You fly blind — no external sensors. Objects exist but are invisible.
// You can only track your own displacement (proprioception).
//
// Monty concept: The motor system. Before any sensing, you need to know
// where you've been. Displacement between poses is fundamental to everything
// Monty does — it's how object graphs get their edges.
//
// Objective: Navigate to waypoints using only your displacement trail
// and a compass heading. Discover that without external sensing,
// you can map your path but not the world.

@(private = "file")
L0_State :: struct {
	waypoints:       [4]Vec3,
	current_wp:      int,
	wp_reached:      [4]bool,
	total_distance:  f32,
	message:         cstring,
	message_timer:   f32,
	show_help:       bool,
}

@(private = "file")
l0: L0_State

l0_motion_vtable :: proc() -> Level_Vtable {
	return {
		init    = l0_init,
		update  = l0_update,
		draw    = l0_draw,
		draw_ui = l0_draw_ui,
		cleanup = l0_cleanup,
	}
}

l0_init :: proc(game: ^Game_State) {
	l0 = {}

	// Place waypoints — the ship can sense these via proximity beep
	// (proprioception only — "you've arrived" when close enough)
	l0.waypoints = {
		{10, 0, 10},
		{-8, 0, 15},
		{-12, 0, -5},
		{5, 0, -10},
	}
	l0.current_wp = 0
	l0.show_help = true
	l0.message = "Fly blind. Find the waypoints.\nYou can only feel your own motion."
	l0.message_timer = 5

	game.ship.pos = {0, 0, 0}
	game.ship.vel = {0, 0, 0}
	game.ship.heading = 0
	game.ship.pitch = 0
	game.ship.speed = 0
	clear(&game.ship.trail)

	game.camera = rl.Camera3D {
		position   = {0, 25, 30},
		target     = {0, 0, 0},
		up         = {0, 1, 0},
		fovy       = 60,
		projection = .PERSPECTIVE,
	}
}

l0_update :: proc(game: ^Game_State, dt: f32) {
	ship := &game.ship

	// Steering
	turn_rate: f32 = 2.0
	if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) {
		ship.heading += turn_rate * dt
	}
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) {
		ship.heading -= turn_rate * dt
	}

	// Throttle
	accel: f32 = 8.0
	drag: f32 = 2.0
	if rl.IsKeyDown(.UP) || rl.IsKeyDown(.W) {
		ship.speed += accel * dt
	} else if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S) {
		ship.speed -= accel * dt
	} else {
		ship.speed *= (1 - drag * dt)
	}
	ship.speed = clamp(ship.speed, -5, 15)

	old_pos := ship.pos
	ship_update(ship, dt)
	l0.total_distance += linalg.distance(old_pos, ship.pos)

	// Check waypoint proximity — this is "proprioceptive" sensing:
	// the ship knows its own coordinates and can check if it's near a target
	if l0.current_wp < len(l0.waypoints) {
		wp := l0.waypoints[l0.current_wp]
		dist := linalg.distance(ship.pos, wp)
		if dist < 2.5 {
			l0.wp_reached[l0.current_wp] = true
			l0.current_wp += 1
			if l0.current_wp >= len(l0.waypoints) {
				// Mark level complete, unlock next
				game.levels[Level_ID.Motion].completed = true
				game.levels[Level_ID.Smell].unlocked = true
				game.ship.sensors += {.Chemical}
				popup_show_delayed(game, .Level_Complete, 1.5)
			} else {
				l0.message = "Waypoint reached! Next bearing updated."
				l0.message_timer = 3
			}
		}
	}

	// Camera follows ship from above-behind
	fwd := ship_forward(ship)
	cam_target := ship.pos
	cam_offset := Vec3{0, 18, 0} - fwd * 12
	game.camera.position = ship.pos + cam_offset
	game.camera.target = cam_target

	// Message timer
	if l0.message_timer > 0 {
		l0.message_timer -= dt
	}

	// Toggle help
	if rl.IsKeyPressed(.H) {
		l0.show_help = !l0.show_help
	}

	// Escape — confirm leave
	if rl.IsKeyPressed(.ESCAPE) {
		popup_show(game, .Confirm_Leave_Level)
	}
}

l0_draw :: proc(game: ^Game_State) {
	rl.BeginMode3D(game.camera)

	// World objects are INVISIBLE in level 0 — that's the point
	world_draw(&game.world, false)

	// Draw ship
	ship_draw(&game.ship)
	ship_draw_trail(&game.ship)

	// Draw waypoint indicators — faint directional hint
	if l0.current_wp < len(l0.waypoints) {
		wp := l0.waypoints[l0.current_wp]
		// Pulsing ring at waypoint (you can "hear" it — proximity beacon)
		pulse := 0.5 + 0.5 * math.sin(f32(rl.GetTime()) * 3)
		rl.DrawCircle3D(wp, 2.5, {1, 0, 0}, 90, Color{100, 255, 150, u8(pulse * 100)})
	}

	// Draw reached waypoints as small markers
	for i in 0..<len(l0.waypoints) {
		if l0.wp_reached[i] {
			rl.DrawSphere(l0.waypoints[i], 0.3, Color{100, 255, 150, 150})
		}
	}

	rl.EndMode3D()
}

l0_draw_ui :: proc(game: ^Game_State) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())

	// HUD — displacement info (proprioception readout)
	ship := &game.ship
	rl.DrawRectangle(10, 10, 280, 100, Color{0, 0, 0, 150})
	rl.DrawRectangleLinesEx({10, 10, 280, 100}, 1, Color{60, 80, 120, 150})

	rl.DrawText("PROPRIOCEPTION", 20, 18, 14, Color{80, 200, 150, 200})

	rl.DrawText(fmt.ctprintf("POS  x:%.1f  z:%.1f", ship.pos.x, ship.pos.z), 20, 38, 16, Color{180, 200, 240, 220})

	hdg_deg := ship.heading * 180 / 3.14159
	rl.DrawText(fmt.ctprintf("HDG  %.0f deg", hdg_deg), 20, 58, 16, Color{180, 200, 240, 220})

	rl.DrawText(fmt.ctprintf("SPD  %.1f", ship.speed), 20, 78, 16, Color{180, 200, 240, 220})

	// Waypoint bearing indicator
	if l0.current_wp < len(l0.waypoints) {
		wp := l0.waypoints[l0.current_wp]
		diff := wp - ship.pos
		dist := linalg.length(diff)
		bearing := linalg.atan2(diff.x, diff.z)

		rl.DrawRectangle(10, 120, 280, 50, Color{0, 0, 0, 150})
		rl.DrawRectangleLinesEx({10, 120, 280, 50}, 1, Color{60, 80, 120, 150})

		rl.DrawText(fmt.ctprintf("WP%d  dist:%.1f  bearing:%.0f deg", l0.current_wp + 1, dist, bearing * 180 / 3.14159), 20, 128, 16, Color{100, 255, 150, 220})

		rl.DrawText(fmt.ctprintf("Progress: %d / %d", l0.current_wp, len(l0.waypoints)), 20, 148, 14, Color{160, 180, 220, 180})
	}

	// Message overlay
	if l0.message_timer > 0 && l0.message != nil {
		alpha := u8(min(l0.message_timer * 2, 1) * 255)
		msg_w := rl.MeasureText(l0.message, 20)
		mx := i32(sw / 2) - msg_w / 2
		my := i32(sh * 0.75)
		rl.DrawRectangle(mx - 15, my - 10, msg_w + 30, 60, Color{0, 0, 0, alpha / 2})
		rl.DrawText(l0.message, mx, my, 20, Color{255, 255, 255, alpha})
	}

	// Help
	if l0.show_help {
		help_y := i32(sh) - 60
		rl.DrawText("[WASD/Arrows] Fly  [H] Toggle help  [ESC] Back", 10, help_y, 14, Color{80, 100, 140, 150})
	}

	// Level title
	rl.DrawText("LEVEL 0: SELF-MOTION", i32(sw) - 240, 15, 18, Color{80, 120, 180, 180})
}

l0_cleanup :: proc(game: ^Game_State) {
	// Nothing dynamic to clean up beyond what ship handles
}
