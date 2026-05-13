package monty

import rl "vendor:raylib"
import "core:math"
import "core:math/linalg"
import "core:fmt"

// Level 4 — Drone Fleet (Multi-LM Voting)
//
// Multiple drones, each running an independent Learning Module.
// The mothership has pre-loaded models for every object in the world
// (analytical seed — equivalent to having completed the Touch level).
//
// Demonstrates the central Thousand Brains claim:
//   "Five fingers touching a mug converge faster than one finger
//    sequentially exploring it" — multi-column voting.
//
// Setup:
//   - 3 drones fly out and probe a chosen object simultaneously
//   - Drones 0,1 share votes via lateral connections (lm_*_vote)
//   - Drone 2 runs solo (no voting) — acts as the control
// Watch:
//   - Voters' hypothesis funnel collapses much faster than the solo drone
//   - Convergence step counts shown side by side
//   - Vote messages animate as flashes between drones

NUM_DRONES         :: 3
DRONE_PROBE_PERIOD :: 0.45   // seconds between probes
DRONE_ORBIT_R      :: 5.0
DRONE_LAUNCH_TIME  :: 1.6    // seconds to fly out to first target

drone_palette := [NUM_DRONES]Color{
	{255, 140,  80, 255},
	{120, 220, 180, 255},
	{200, 140, 255, 255},
}

@(private = "file")
L4_State :: struct {
	target_wobj:    int,          // which world object the fleet is investigating
	launched:       bool,
	launch_timer:   f32,
	last_vote_at:   f32,
	vote_pulse_t:   f32,          // for animating recent votes
	converged_step: [NUM_DRONES]int,
	completed:      bool,
	message:        cstring,
	message_timer:  f32,
	show_help:      bool,
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
	l4.target_wobj   = 0
	l4.show_help     = true
	l4.message       = "Three drones, three Learning Modules.\nDrones 0+1 share votes; drone 2 is solo.\nWatch which one converges first."
	l4.message_timer = 7
	for i in 0..<NUM_DRONES { l4.converged_step[i] = -1 }

	// Mothership stays put, hovering
	game.ship.pos     = {0, 4, 0}
	game.ship.speed   = 0
	game.ship.heading = 0
	clear(&game.ship.trail)

	// Pre-load object models analytically
	seed_world_objects(&game.model_db, &game.world)

	// Initialise drone LMs and put each in inference mode
	for i in 0..<NUM_DRONES {
		lm := &game.lms[i + 1]
		lm_init(lm, i + 1)
		lm_start_inference(lm, &game.model_db)
	}

	// Spawn drones at the mothership
	game.ship.drone_count = NUM_DRONES
	for i in 0..<NUM_DRONES {
		drone := &game.ship.drones[i]
		drone^ = {}
		drone.active       = true
		drone.pos          = game.ship.pos + Vec3{f32(i) * 0.6 - 0.6, 0, 0}
		drone.prev_pos     = drone.pos
		drone.color        = drone_palette[i]
		drone.target_wobj  = l4.target_wobj
		drone.orbit_phase  = f32(i) * (2 * math.PI / NUM_DRONES)
		drone.orbit_radius = DRONE_ORBIT_R
		drone.probe_timer  = DRONE_LAUNCH_TIME + f32(i) * 0.1
		drone.use_voting   = i < 2  // first two cooperate; last one is the solo control
	}

	game.camera = rl.Camera3D{
		position   = {0, 22, 26},
		target     = game.world.objects[l4.target_wobj].pos,
		up         = {0, 1, 0},
		fovy       = 60,
		projection = .PERSPECTIVE,
	}
}

l4_update :: proc(game: ^Game_State, dt: f32) {
	if rl.IsKeyPressed(.ESCAPE) { popup_show(game, .Confirm_Leave_Level); return }
	if rl.IsKeyPressed(.H)      { l4.show_help = !l4.show_help }
	if rl.IsKeyPressed(.R)      { l4_init(game); return }
	if rl.IsKeyPressed(.SPACE)  {
		// Pick the next object as new target
		l4.target_wobj = (l4.target_wobj + 1) % len(game.world.objects)
		for i in 0..<NUM_DRONES {
			lm_init(&game.lms[i+1], i+1)
			lm_start_inference(&game.lms[i+1], &game.model_db)
			d := &game.ship.drones[i]
			d.target_wobj  = l4.target_wobj
			d.probe_count  = 0
			d.probe_timer  = 0.2 + f32(i) * 0.1
			l4.converged_step[i] = -1
		}
		l4.completed = false
		game.camera.target = game.world.objects[l4.target_wobj].pos
	}

	target_pos := game.world.objects[l4.target_wobj].pos

	// camera slowly orbits the target
	t := f32(rl.GetTime()) * 0.15
	game.camera.position = target_pos + Vec3{math.sin(t) * 22, 16, math.cos(t) * 22}
	game.camera.target   = target_pos

	any_active_voter := false

	// drone behaviour
	for di in 0..<NUM_DRONES {
		drone := &game.ship.drones[di]
		lm    := &game.lms[di + 1]
		if !drone.active do continue

		// orbit around target
		drone.orbit_phase += dt * 0.7
		desired_pos := target_pos + Vec3{
			math.cos(drone.orbit_phase) * drone.orbit_radius,
			f32(di - 1) * 1.0,
			math.sin(drone.orbit_phase) * drone.orbit_radius,
		}
		drone.prev_pos = drone.pos
		drone.pos += (desired_pos - drone.pos) * dt * 3

		// probe periodically
		drone.probe_timer -= dt
		if drone.probe_timer <= 0 && !lm.converged {
			drone.probe_timer = DRONE_PROBE_PERIOD

			cmp := l4_make_cmp_for_drone(game, drone)
			disp: Vec3 = drone.probe_count == 0 ? Vec3{0, 0, 0} : drone.pos - drone.prev_pos
			lm_step(lm, cmp, disp, &game.model_db)
			drone.probe_count += 1

			if lm.converged && l4.converged_step[di] < 0 {
				l4.converged_step[di] = lm.step_count
			}
		}

		// Voting between voter drones (after each one's step)
		if drone.use_voting && lm.mlh_idx >= 0 {
			vote, ok := lm_generate_vote(lm)
			if ok {
				for other_i in 0..<NUM_DRONES {
					if other_i == di do continue
					other_drone := &game.ship.drones[other_i]
					if !other_drone.use_voting do continue
					other_lm := &game.lms[other_i + 1]
					offset := other_drone.pos - drone.pos
					lm_receive_vote(other_lm, vote, offset, &game.model_db)
					l4.last_vote_at = f32(rl.GetTime())
				}
			}
		}

		if drone.use_voting && !lm.converged { any_active_voter = true }
	}

	l4.vote_pulse_t = f32(rl.GetTime()) - l4.last_vote_at

	// Completion: all three drones have converged (or at least the voters)
	voters_done := l4.converged_step[0] > 0 && l4.converged_step[1] > 0
	if voters_done && !l4.completed {
		l4.completed = true
		l4.message       = "Voters converged. The solo drone is still trying.\n[SPACE] for next object, or [ESC] to finish."
		l4.message_timer = 6
		game.levels[Level_ID.Drones].completed = true
		game.levels[Level_ID.Range].unlocked   = true
		save_write(game)
	}

	if l4.message_timer > 0 do l4.message_timer -= dt
}

// Build a CMP message representing a contact between a drone and its target
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

// ─── 3D draw ─────────────────────────────────────────────────────────────────

l4_draw :: proc(game: ^Game_State) {
	rl.BeginMode3D(game.camera)
	world_draw(&game.world, true)
	ship_draw(&game.ship)

	target := &game.world.objects[l4.target_wobj]
	// Target halo
	pulse := 0.5 + 0.5 * math.sin(f32(rl.GetTime()) * 2)
	rl.DrawCircle3D(target.pos, target.size.x + 0.5, {0, 1, 0}, 0,
		Color{255, 220, 100, u8(pulse * 120)})

	// Draw drones
	for di in 0..<NUM_DRONES {
		drone := &game.ship.drones[di]
		if !drone.active do continue
		c := drone.color

		rl.DrawSphere(drone.pos, 0.5, c)
		rl.DrawSphereWires(drone.pos, 0.6, 6, 6, Color{c.r, c.g, c.b, 120})

		// Probe beam to target surface
		diff := drone.pos - target.pos
		d := linalg.length(diff)
		if d > 0.001 {
			n := diff / d
			contact := target.pos + n * target.size.x
			beam_c := drone.use_voting ? c : Color{180, 180, 180, 200}
			rl.DrawLine3D(drone.pos, contact, Color{beam_c.r, beam_c.g, beam_c.b, 160})
			rl.DrawSphere(contact, 0.18, beam_c)
		}

		// "no voting" indicator: dimmer
		if !drone.use_voting {
			rl.DrawCubeWires(drone.pos + Vec3{0, 1.2, 0}, 0.3, 0.3, 0.3, Color{180, 180, 180, 180})
		}
	}

	// Animate vote lines between voter drones (recent)
	if l4.vote_pulse_t < 0.4 {
		alpha := u8((1 - l4.vote_pulse_t / 0.4) * 200)
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

// ─── HUD / under-the-hood ───────────────────────────────────────────────────

l4_draw_ui :: proc(game: ^Game_State) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	db := &game.model_db

	// Top title bar
	target_name := game.world.objects[l4.target_wobj].name
	rl.DrawText(fmt.ctprintf("TARGET: %s", target_name), 14, 12, 18, Color{255, 220, 100, 220})
	rl.DrawText("LEVEL 3: DRONE FLEET", i32(sw) - 240, 12, 16, Color{200, 140, 255, 200})

	// Per-drone panels along the right side
	panel_w: f32 = 320
	panel_h: f32 = (sh - 60) / f32(NUM_DRONES) - 8
	panel_x := sw - panel_w - 10
	for di in 0..<NUM_DRONES {
		drone := &game.ship.drones[di]
		lm    := &game.lms[di + 1]
		py    := 40 + f32(di) * (panel_h + 8)
		c     := drone.color

		// Panel
		rl.DrawRectangle(i32(panel_x), i32(py), i32(panel_w), i32(panel_h), Color{0, 0, 0, 150})
		rl.DrawRectangleLinesEx({panel_x, py, panel_w, panel_h}, 1,
			Color{c.r, c.g, c.b, 180})

		// Header
		mode_str: cstring = drone.use_voting ? "VOTING" : "SOLO"
		rl.DrawText(fmt.ctprintf("DRONE %d  (%s)", di, mode_str),
			i32(panel_x) + 10, i32(py) + 8, 15, Color{c.r, c.g, c.b, 240})
		rl.DrawText(fmt.ctprintf("probes: %d", drone.probe_count),
			i32(panel_x) + 180, i32(py) + 8, 13, Color{200, 200, 220, 180})

		// Hypothesis funnel
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

		// Sort object indices by evidence (top 3)
		top: [3]int = {-1, -1, -1}
		topv: [3]f32 = {-99999, -99999, -99999}
		for oi in 0..<db.object_count {
			v := best_evid[oi]
			if v > topv[0]      { topv[2] = topv[1]; top[2] = top[1]; topv[1] = topv[0]; top[1] = top[0]; topv[0] = v; top[0] = oi }
			else if v > topv[1] { topv[2] = topv[1]; top[2] = top[1]; topv[1] = v; top[1] = oi }
			else if v > topv[2] { topv[2] = v; top[2] = oi }
		}

		by := fy + 50
		rl.DrawText("top hypotheses (object : evidence)", i32(panel_x) + 10, i32(by), 12,
			Color{160, 180, 200, 180})
		by += 16
		for k in 0..<3 {
			if top[k] < 0 do continue
			fill := i32(clamp(topv[k] / max_evid, 0, 1) * 200)
			row_y := by + f32(k) * 16
			rl.DrawRectangle(i32(panel_x) + 10, i32(row_y), 200, 12, Color{25, 25, 35, 200})
			row_c := top[k] == lm.hypotheses[lm.mlh_idx].object_idx ? Color{c.r, c.g, c.b, 220} : Color{120, 140, 170, 180}
			if fill > 0 do rl.DrawRectangle(i32(panel_x) + 10, i32(row_y), fill, 12, row_c)
			rl.DrawText(fmt.ctprintf("%s  %.1f", db.objects[top[k]].name, topv[k]),
				i32(panel_x) + 220, i32(row_y), 11, Color{200, 210, 230, 200})
		}

		// Status
		status_y := py + panel_h - 24
		if lm.converged {
			winner := db.objects[lm.winner_obj].name
			rl.DrawText(fmt.ctprintf("CONVERGED  %s  in %d steps", winner, l4.converged_step[di]),
				i32(panel_x) + 10, i32(status_y), 13, Color{120, 255, 160, 230})
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
		rl.DrawText("[SPACE] next target   [R] restart   [H] help   [ESC] back",
			10, i32(sh) - 28, 13, Color{80, 100, 140, 150})
	}

	// Speedup comparison footer (if solo has also converged or far behind)
	if l4.converged_step[0] > 0 && l4.converged_step[1] > 0 {
		v_avg := f32(l4.converged_step[0] + l4.converged_step[1]) / 2
		solo_steps := l4.converged_step[2] > 0 ? f32(l4.converged_step[2]) : f32(game.ship.drones[2].probe_count)
		solo_label: cstring = l4.converged_step[2] > 0 ? "solo converged" : "solo still running"
		ratio := solo_steps / max(v_avg, 0.001)
		rl.DrawText(fmt.ctprintf("VOTING ~%.1fx FASTER  (voters: ~%.0f steps   %s: %.0f)",
			ratio, v_avg, solo_label, solo_steps),
			10, i32(sh) - 56, 14, Color{180, 220, 255, 200})
	}
}

l4_cleanup :: proc(game: ^Game_State) {
	game.ship.drone_count = 0
	for i in 0..<NUM_DRONES {
		game.ship.drones[i].active = false
	}
}
