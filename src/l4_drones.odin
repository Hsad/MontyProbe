package monty

import rl "vendor:raylib"
import "core:math"
import "core:math/linalg"
import "core:fmt"

// Level 4 — Drone Fleet (Multi-LM Voting)
//
// 3 drones orbit the mothership. They probe whichever world object
// is closest to the mothership — so you steer attention by flying.
// Drones 0+1 share votes laterally; drone 2 is the solo control.
//
// Objective: identify 3 unique objects.
//
// Watch the voter pair converge in fewer probes than the solo drone
// on every target. Move on to the next object once voters converge.

NUM_DRONES         :: 3
DRONE_PROBE_PERIOD :: 0.42
DRONE_ORBIT_R      :: 3.5     // around mothership
PROBE_REACH        :: 11.0    // drone-to-target reach
TARGET_LOCK_RANGE  :: 9.0     // mothership-to-object range to lock target
TARGET_UNLOCK_DIST :: 14.0    // hysteresis — must move this far to drop target
UNIQUE_TO_WIN      :: 3

drone_palette := [NUM_DRONES]Color{
	{255, 140,  80, 255},   // voter A
	{120, 220, 180, 255},   // voter B
	{200, 140, 255, 255},   // solo control
}

@(private = "file")
L4_State :: struct {
	current_target:   int,         // world object idx (-1 = none locked)
	prev_target:      int,
	identified:       [16]bool,    // which world objects ID'd in this play session
	unique_ids:       int,
	converged_step:   [NUM_DRONES]int,
	last_vote_at:     f32,
	vote_pulse_t:     f32,
	completed:        bool,
	message:          cstring,
	message_timer:    f32,
	show_help:        bool,

	// Mode + per-mode performance tracking
	all_voting:           bool,     // true = drones share, false = all solo
	last_voting_steps:    f32,      // avg steps to converge during last voting run
	last_solo_steps:      f32,      // avg steps to converge during last solo run
}

@(private = "file")
l4: L4_State

l4_drones_vtable :: proc() -> Level_Vtable {
	return {
		init    = l4_init,
		update  = l4_update,
		draw    = l4_draw,
		draw_ui = l4_draw_ui,
		cleanup = l4_cleanup,
	}
}

l4_init :: proc(game: ^Game_State) {
	l4 = {}
	l4.current_target = -1
	l4.prev_target    = -1
	l4.all_voting     = true
	for i in 0..<NUM_DRONES { l4.converged_step[i] = -1 }
	l4.show_help     = true
	l4.message       = "Fly near an object — drones probe whatever is closest.\nAll three drones SHARING VOTES. LMs accumulate across all probes.\n[SPACE] toggle voting/solo   [N] new episode (reset LMs)"
	l4.message_timer = 10

	// Reset mothership at origin
	game.ship.pos     = {0, 0, 0}
	game.ship.vel     = {0, 0, 0}
	game.ship.heading = 0
	game.ship.speed   = 0
	clear(&game.ship.trail)

	// Pre-load object models (ideal learning from ground truth)
	seed_world_objects(&game.model_db, &game.world)

	// Reset all LMs but DON'T start inference yet — we wait for a target
	for i in 0..<NUM_DRONES {
		lm_init(&game.lms[i + 1], i + 1)
	}

	// Spawn drones around mothership
	game.ship.drone_count = NUM_DRONES
	for i in 0..<NUM_DRONES {
		drone := &game.ship.drones[i]
		drone^ = {}
		drone.active       = true
		drone.color        = drone_palette[i]
		drone.target_wobj  = -1
		drone.orbit_phase  = f32(i) * (2 * math.PI / NUM_DRONES)
		drone.orbit_radius = DRONE_ORBIT_R
		drone.probe_timer  = 0
		drone.use_voting   = l4.all_voting

		pos := game.ship.pos + Vec3{
			math.cos(drone.orbit_phase) * DRONE_ORBIT_R,
			f32(i - 1) * 0.5,
			math.sin(drone.orbit_phase) * DRONE_ORBIT_R,
		}
		drone.pos      = pos
		drone.prev_pos = pos
	}

	// Standard follow camera
	game.camera = rl.Camera3D{
		position   = {0, 18, 16},
		target     = {0, 0, 0},
		up         = {0, 1, 0},
		fovy       = 60,
		projection = .PERSPECTIVE,
	}
}

// Record this run's average converged-step into the appropriate mode slot.
// Only counts if at least one drone actually converged.
l4_capture_run_avg :: proc(game: ^Game_State) {
	sum: f32 = 0
	n:   f32 = 0
	for i in 0..<NUM_DRONES {
		if l4.converged_step[i] > 0 {
			sum += f32(l4.converged_step[i])
			n   += 1
		}
	}
	if n <= 0 do return
	avg := sum / n
	if l4.all_voting {
		l4.last_voting_steps = avg
	} else {
		l4.last_solo_steps = avg
	}
}

l4_reset_drone_lms :: proc(game: ^Game_State, new_target: int) {
	for i in 0..<NUM_DRONES {
		lm := &game.lms[i + 1]
		lm_init(lm, i + 1)
		if new_target >= 0 {
			lm_start_inference(lm, &game.model_db)
		}
		drone := &game.ship.drones[i]
		drone.target_wobj = new_target
		drone.probe_count = 0
		drone.probe_timer = f32(i) * 0.15
		l4.converged_step[i] = -1
	}
}

// surface distance from ship to object (ignores object radius)
l4_surface_dist :: proc(ship_pos: Vec3, obj: ^World_Object) -> f32 {
	d := linalg.distance(ship_pos, obj.pos) - obj.size.x
	if d < 0 do d = 0
	return d
}

l4_pick_target :: proc(game: ^Game_State) -> int {
	closest := -1
	best: f32 = TARGET_LOCK_RANGE
	for i in 0..<len(game.world.objects) {
		d := l4_surface_dist(game.ship.pos, &game.world.objects[i])
		if d < best {
			best = d
			closest = i
		}
	}
	return closest
}

l4_update :: proc(game: ^Game_State, dt: f32) {
	if rl.IsKeyPressed(.ESCAPE) { popup_show(game, .Confirm_Leave_Level); return }
	if rl.IsKeyPressed(.H)      { l4.show_help = !l4.show_help }

	// Toggle voting mode — record the run that just ended, then flip every drone
	if rl.IsKeyPressed(.SPACE) {
		// Capture the current run's avg-converged-step before clearing
		l4_capture_run_avg(game)

		l4.all_voting = !l4.all_voting
		for i in 0..<NUM_DRONES {
			game.ship.drones[i].use_voting = l4.all_voting
		}
		// Reset LMs for the current target so the comparison is clean
		if l4.current_target >= 0 {
			l4_reset_drone_lms(game, l4.current_target)
		}

		mode_msg: cstring = "MODE: SOLO — each drone runs alone"
		if l4.all_voting {
			mode_msg = "MODE: VOTING — all drones share hypotheses"
		}
		l4.message       = mode_msg
		l4.message_timer = 3
	}

	// [N] — explicit new episode for all drones
	if rl.IsKeyPressed(.N) {
		l4_capture_run_avg(game)
		l4_reset_drone_lms(game, l4.current_target)
		l4.message       = "NEW EPISODE — all drone LMs reset."
		l4.message_timer = 2
	}

	ship := &game.ship

	// flight (same as other levels)
	turn_rate: f32 = 2.0
	if rl.IsKeyDown(.LEFT)  || rl.IsKeyDown(.A) { ship.heading += turn_rate * dt }
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) { ship.heading -= turn_rate * dt }
	accel: f32 = 8.0
	drag:  f32 = 2.0
	if rl.IsKeyDown(.UP)   || rl.IsKeyDown(.W) { ship.speed += accel * dt }
	else if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S) { ship.speed -= accel * dt }
	else { ship.speed *= (1 - drag * dt) }
	ship.speed = clamp(ship.speed, -5, 15)
	ship_update(ship, dt)

	// target selection with hysteresis
	new_target := l4.current_target

	if l4.current_target >= 0 {
		// keep current target if still in range; drop if too far
		d := l4_surface_dist(ship.pos, &game.world.objects[l4.current_target])
		if d > TARGET_UNLOCK_DIST {
			new_target = -1
		}
	}

	if new_target < 0 {
		// search for a fresh target
		new_target = l4_pick_target(game)
	} else {
		// also check if something much closer appeared (allow switching)
		closer := l4_pick_target(game)
		if closer >= 0 && closer != l4.current_target {
			d_cur  := l4_surface_dist(ship.pos, &game.world.objects[l4.current_target])
			d_new  := l4_surface_dist(ship.pos, &game.world.objects[closer])
			if d_new < d_cur - 2.5 do new_target = closer
		}
	}

	// Target changed — update tracking only; LMs keep accumulating.
	// Pressing [N] starts a fresh inference episode explicitly.
	if new_target != l4.current_target {
		l4_capture_run_avg(game)
		l4.prev_target    = l4.current_target
		l4.current_target = new_target
		// Drones need a target_wobj to know what to probe, but LMs are NOT reset
		for di in 0..<NUM_DRONES {
			game.ship.drones[di].target_wobj = new_target
		}
	}

	// drone behaviour: orbit mothership; lean toward target when locked
	for di in 0..<NUM_DRONES {
		drone := &game.ship.drones[di]
		lm    := &game.lms[di + 1]
		if !drone.active do continue

		drone.orbit_phase += dt * 0.9
		base_offset := Vec3{
			math.cos(drone.orbit_phase) * DRONE_ORBIT_R,
			f32(di - 1) * 0.6,
			math.sin(drone.orbit_phase) * DRONE_ORBIT_R,
		}
		desired_pos := ship.pos + base_offset

		// Lean toward target a bit so it visually "engages"
		if l4.current_target >= 0 {
			obj_pos := game.world.objects[l4.current_target].pos
			lean := (obj_pos - ship.pos) * 0.25
			desired_pos += lean
		}

		drone.prev_pos = drone.pos
		drone.pos += (desired_pos - drone.pos) * dt * 4

		// probing — only if we have a target and we're close enough to it
		if l4.current_target >= 0 && !lm.converged {
			target_obj := &game.world.objects[l4.current_target]
			d_to_target := linalg.distance(drone.pos, target_obj.pos)
			if d_to_target < PROBE_REACH {
				drone.probe_timer -= dt
				if drone.probe_timer <= 0 {
					drone.probe_timer = DRONE_PROBE_PERIOD
					cmp := l4_make_cmp_for_drone(game, drone)
					disp: Vec3 = drone.probe_count == 0 ? Vec3{0,0,0} : drone.pos - drone.prev_pos
					lm_step(lm, cmp, disp, &game.model_db)
					drone.probe_count += 1
					if lm.converged && l4.converged_step[di] < 0 {
						l4.converged_step[di] = lm.step_count
					}
				}
			}
		}

		// voting — voters share their MLH; receivers prune inconsistent hypotheses
		if drone.use_voting && lm.mlh_idx >= 0 {
			vote, ok := lm_generate_vote(lm)
			if ok {
				for other_i in 0..<NUM_DRONES {
					if other_i == di do continue
					if !game.ship.drones[other_i].use_voting do continue
					other_lm := &game.lms[other_i + 1]
					if other_lm.converged do continue
					offset := game.ship.drones[other_i].pos - drone.pos
					lm_receive_vote(other_lm, vote, offset, &game.model_db)
					l4.last_vote_at = f32(rl.GetTime())
				}
			}
		}
	}

	// Identification: count distinct objects that ≥2 drones independently
	// converged on (no ground-truth target check — purely the LMs' opinion)
	winner_votes := [MAX_OBJECTS]int{}
	for i in 0..<NUM_DRONES {
		lm := &game.lms[i + 1]
		if lm.converged && lm.winner_obj >= 0 && lm.winner_obj < MAX_OBJECTS {
			winner_votes[lm.winner_obj] += 1
		}
	}
	for oi in 0..<game.model_db.object_count {
		if winner_votes[oi] >= 2 && oi < len(l4.identified) && !l4.identified[oi] {
			l4.identified[oi] = true
			l4.unique_ids += 1
			name := game.model_db.objects[oi].name
			l4.message       = fmt.ctprintf("Identified: %s  (%d/%d)\n[N] for new episode then fly to another object.", name, l4.unique_ids, UNIQUE_TO_WIN)
			l4.message_timer = 5

			if l4.unique_ids >= UNIQUE_TO_WIN && !l4.completed {
				l4.completed = true
				game.levels[Level_ID.Drones].completed = true
				game.levels[Level_ID.Range].unlocked   = true
				save_write(game)
				popup_show_delayed(game, .Level_Complete, 1.5)
			}
		}
	}

	l4.vote_pulse_t = f32(rl.GetTime()) - l4.last_vote_at

	// follow camera (like other levels)
	fwd := ship_forward(ship)
	game.camera.position = ship.pos + Vec3{0, 16, 0} - fwd * 12
	game.camera.target   = ship.pos + fwd * 3

	if l4.message_timer > 0 do l4.message_timer -= dt
}

l4_make_cmp_for_drone :: proc(game: ^Game_State, drone: ^Drone) -> CMP_Message {
	obj := &game.world.objects[drone.target_wobj]
	diff := drone.pos - obj.pos
	d := linalg.length(diff)
	normal := d > 0.001 ? diff / d : Vec3{0, 1, 0}
	contact := obj.pos + normal * obj.size.x
	return CMP_Message{
		location    = contact,
		orientation = normal,
		features    = Features{
			roughness   = obj.material.roughness,
			temperature = obj.material.temperature,
			color       = obj.material.color,
		},
		confidence  = 1.0,
	}
}

// ── 3D draw ─────────────────────────────────────────────────────────────────

l4_draw :: proc(game: ^Game_State) {
	rl.BeginMode3D(game.camera)
	world_draw(&game.world, true)
	ship_draw(&game.ship)
	ship_draw_trail(&game.ship)

	// Highlight identified objects with a green wireframe
	for i in 0..<len(game.world.objects) {
		if !l4.identified[i] do continue
		obj := &game.world.objects[i]
		rl.DrawSphereWires(obj.pos, obj.size.x + 0.3, 10, 10, Color{120, 255, 160, 180})
	}

	// Target halo around the currently locked object
	if l4.current_target >= 0 {
		target := &game.world.objects[l4.current_target]
		pulse := 0.5 + 0.5 * math.sin(f32(rl.GetTime()) * 3)
		rl.DrawCircle3D(target.pos, target.size.x + 0.6, {0, 1, 0}, 0,
			Color{255, 220, 100, u8(pulse * 140)})
	}

	// Probe range circle around mothership (faint reference)
	pr_alpha: u8 = l4.current_target < 0 ? 80 : 30
	rl.DrawCircle3D(game.ship.pos, TARGET_LOCK_RANGE, {0, 1, 0}, 0,
		Color{100, 160, 220, pr_alpha})

	// Draw drones
	for di in 0..<NUM_DRONES {
		drone := &game.ship.drones[di]
		if !drone.active do continue
		c := drone.color

		rl.DrawSphere(drone.pos, 0.45, c)
		rl.DrawSphereWires(drone.pos, 0.55, 6, 6, Color{c.r, c.g, c.b, 120})

		// Indicator: small cube above for non-voter (solo)
		if !drone.use_voting {
			rl.DrawCubeWires(drone.pos + Vec3{0, 1.1, 0}, 0.25, 0.25, 0.25, Color{200, 200, 200, 200})
		}

		// Probe beam to target surface (only when actually probing)
		if l4.current_target >= 0 {
			target := &game.world.objects[l4.current_target]
			diff := drone.pos - target.pos
			d := linalg.length(diff)
			if d > 0.001 && d < PROBE_REACH * 1.2 {
				n := diff / d
				contact := target.pos + n * target.size.x
				beam_c := drone.use_voting ? c : Color{180, 180, 180, 220}
				rl.DrawLine3D(drone.pos, contact, Color{beam_c.r, beam_c.g, beam_c.b, 160})
				rl.DrawSphere(contact, 0.16, beam_c)
			}
		}
	}

	// Vote pulse: animate lines between voter drones briefly after each vote
	if l4.vote_pulse_t < 0.35 {
		alpha := u8((1 - l4.vote_pulse_t / 0.35) * 200)
		for a in 0..<NUM_DRONES {
			if !game.ship.drones[a].use_voting do continue
			for b in 0..<NUM_DRONES {
				if b <= a do continue
				if !game.ship.drones[b].use_voting do continue
				rl.DrawLine3D(game.ship.drones[a].pos, game.ship.drones[b].pos,
					Color{200, 220, 255, alpha})
			}
		}
	}

	rl.EndMode3D()
}

// ── HUD / under-the-hood ───────────────────────────────────────────────────

l4_draw_ui :: proc(game: ^Game_State) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	db := &game.model_db

	// Top title bar
	target_name: cstring = l4.current_target >= 0 ? game.world.objects[l4.current_target].name : "(none — fly closer)"
	rl.DrawText(fmt.ctprintf("TARGET: %s", target_name), 14, 12, 18, Color{255, 220, 100, 220})
	rl.DrawText(fmt.ctprintf("Identified: %d / %d", l4.unique_ids, UNIQUE_TO_WIN),
		14, 36, 16, Color{120, 255, 160, 220})

	mode_label:    cstring = l4.all_voting ? "MODE: VOTING (sharing)" : "MODE: SOLO (no sharing)"
	mode_color:    Color   = l4.all_voting ? Color{120, 220, 255, 230} : Color{255, 180, 120, 230}
	rl.DrawText(mode_label, 14, 60, 16, mode_color)
	rl.DrawText("[SPACE] toggle", 14, 80, 12, Color{120, 140, 170, 180})

	rl.DrawText("LEVEL 4: DRONE FLEET", i32(sw) - 240, 12, 16, Color{200, 140, 255, 200})

	// Per-drone panels along the right side
	panel_w: f32 = 320
	panel_h: f32 = (sh - 60) / f32(NUM_DRONES) - 8
	panel_x := sw - panel_w - 10
	for di in 0..<NUM_DRONES {
		drone := &game.ship.drones[di]
		lm    := &game.lms[di + 1]
		py    := 40 + f32(di) * (panel_h + 8)
		c     := drone.color

		rl.DrawRectangle(i32(panel_x), i32(py), i32(panel_w), i32(panel_h), Color{0, 0, 0, 150})
		rl.DrawRectangleLinesEx({panel_x, py, panel_w, panel_h}, 1,
			Color{c.r, c.g, c.b, 180})

		rl.DrawText(fmt.ctprintf("DRONE %d", di),
			i32(panel_x) + 10, i32(py) + 8, 15, Color{c.r, c.g, c.b, 240})
		rl.DrawText(fmt.ctprintf("probes: %d", drone.probe_count),
			i32(panel_x) + 180, i32(py) + 8, 13, Color{200, 200, 220, 180})

		active := lm_active_count(lm)
		total  := lm.hyp_count
		frac   := total > 0 ? f32(active) / f32(total) : 0
		fy := py + 32
		rl.DrawText("hypotheses", i32(panel_x) + 10, i32(fy), 12, Color{160, 180, 200, 180})
		rl.DrawRectangle(i32(panel_x) + 10, i32(fy) + 16, 280, 12, Color{25, 25, 35, 200})
		rl.DrawRectangle(i32(panel_x) + 10, i32(fy) + 16, i32(frac * 280), 12,
			Color{c.r, c.g, c.b, 200})
		rl.DrawText(fmt.ctprintf("%d / %d", active, total),
			i32(panel_x) + 10, i32(fy) + 30, 12, Color{200, 210, 230, 200})

		// Top-3 evidence bars
		best_evid := [MAX_OBJECTS]f32{}
		lm_best_evidence_per_object(lm, db, best_evid[:])
		max_evid: f32 = 0.001
		for oi in 0..<db.object_count {
			if best_evid[oi] > max_evid { max_evid = best_evid[oi] }
		}
		top: [3]int = {-1, -1, -1}
		topv: [3]f32 = {-99999, -99999, -99999}
		for oi in 0..<db.object_count {
			v := best_evid[oi]
			if v > topv[0]      { topv[2] = topv[1]; top[2] = top[1]; topv[1] = topv[0]; top[1] = top[0]; topv[0] = v; top[0] = oi }
			else if v > topv[1] { topv[2] = topv[1]; top[2] = top[1]; topv[1] = v; top[1] = oi }
			else if v > topv[2] { topv[2] = v; top[2] = oi }
		}

		by := fy + 50
		rl.DrawText("top hypotheses", i32(panel_x) + 10, i32(by), 12, Color{160, 180, 200, 180})
		by += 16
		mlh_obj := -1
		if lm.mlh_idx >= 0 && lm.mlh_idx < lm.hyp_count {
			mlh_obj = lm.hypotheses[lm.mlh_idx].object_idx
		}
		for k in 0..<3 {
			if top[k] < 0 do continue
			fill := i32(clamp(topv[k] / max_evid, 0, 1) * 200)
			row_y := by + f32(k) * 16
			rl.DrawRectangle(i32(panel_x) + 10, i32(row_y), 200, 12, Color{25, 25, 35, 200})
			row_c := top[k] == mlh_obj ? Color{c.r, c.g, c.b, 220} : Color{120, 140, 170, 180}
			if fill > 0 do rl.DrawRectangle(i32(panel_x) + 10, i32(row_y), fill, 12, row_c)
			rl.DrawText(fmt.ctprintf("%s  %.1f", db.objects[top[k]].name, topv[k]),
				i32(panel_x) + 220, i32(row_y), 11, Color{200, 210, 230, 200})
		}

		// Inline convergence checklist (E / M / P)
		lm_draw_convergence_inline(lm, i32(panel_x) + 10, i32(py + panel_h - 46))

		// Status
		status_y := py + panel_h - 24
		if lm.converged && lm.winner_obj >= 0 {
			winner := db.objects[lm.winner_obj].name
			rl.DrawText(fmt.ctprintf("CONVERGED  %s  (%d steps)", winner, l4.converged_step[di]),
				i32(panel_x) + 10, i32(status_y), 13, Color{120, 255, 160, 230})
		} else if l4.current_target < 0 {
			rl.DrawText("idle — no target", i32(panel_x) + 10, i32(status_y), 13,
				Color{140, 140, 170, 180})
		} else {
			rl.DrawText("...accumulating", i32(panel_x) + 10, i32(status_y), 13,
				Color{180, 180, 200, 180})
		}
	}

	// Bottom message
	if l4.message_timer > 0 && l4.message != nil {
		alpha := u8(min(l4.message_timer * 1.5, 1) * 255)
		msg_w := rl.MeasureText(l4.message, 18)
		mx := i32(sw / 2) - msg_w / 2 - 200
		my := i32(sh) - 90
		rl.DrawRectangle(mx - 14, my - 8, msg_w + 28, 50, Color{0, 0, 0, alpha / 2})
		rl.DrawText(l4.message, mx, my, 18, Color{255, 255, 255, alpha})
	}

	// Help bar
	if l4.show_help {
		rl.DrawText("[WASD] Fly   [SPACE] toggle voting/solo   [N] new episode   [H] help   [ESC] back",
			10, i32(sh) - 28, 13, Color{80, 100, 140, 150})
	}

	// Head-to-head comparison — uses the most recent completed run of each mode
	if l4.last_voting_steps > 0 || l4.last_solo_steps > 0 {
		voting_label: cstring = "voting: —"
		if l4.last_voting_steps > 0 {
			voting_label = fmt.ctprintf("voting: %.1f steps", l4.last_voting_steps)
		}
		solo_label: cstring = "solo: —"
		if l4.last_solo_steps > 0 {
			solo_label = fmt.ctprintf("solo: %.1f steps", l4.last_solo_steps)
		}
		ratio_label: cstring = ""
		if l4.last_voting_steps > 0 && l4.last_solo_steps > 0 {
			ratio := l4.last_solo_steps / l4.last_voting_steps
			ratio_label = fmt.ctprintf("   →   voting ~%.1fx faster", ratio)
		}
		rl.DrawText(fmt.ctprintf("RECENT RUNS — %s  |  %s%s",
				voting_label, solo_label, ratio_label),
			10, i32(sh) - 56, 14, Color{180, 220, 255, 200})
	}
}

l4_cleanup :: proc(game: ^Game_State) {
	game.ship.drone_count = 0
	for i in 0..<NUM_DRONES {
		game.ship.drones[i].active = false
	}
}
