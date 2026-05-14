package monty

import rl "vendor:raylib"
import "core:math"
import "core:math/linalg"
import "core:fmt"

// Level 5 — Laser Rangefinder (Model-Based Action Policy)
//
// A long-range probe: aim, pulse, get a CMP message back.
// One LM runs inference live as you collect observations.
//
// New idea on top of Touch / Drones: the system isn't just passive.
// After each pulse, it picks where the NEXT probe should aim to best
// disambiguate the top-two candidate objects — the "curiosity hint",
// shown as a glowing sphere in the world.
//
// Monty concept: model-based goal generation / action policy.
// The LM's job isn't only to score observations — it can also
// propose actions that resolve uncertainty fastest.
//
// Objective: identify 3 objects.

LASER_MAX_RANGE       :: 35.0
LASER_COOLDOWN        :: 0.15
RANGE_TARGETS_TO_WIN  :: 3

@(private = "file")
L5_State :: struct {
	identified:       [16]bool,
	unique_ids:       int,
	current_wobj:     int,        // which world object we're currently probing (-1 = none)

	// Last laser pulse
	cooldown:         f32,
	pulse_anim:       f32,
	last_cmp:         CMP_Message,
	last_cmp_obj:     cstring,
	last_cmp_world:   Vec3,
	last_cmp_valid:   bool,

	// Curiosity hint (model-based goal)
	hint_valid:       bool,
	hint_pos:         Vec3,
	hint_obj_a:       int,        // top hypothesis object
	hint_obj_b:       int,        // runner-up hypothesis object
	hint_score:       f32,        // expected disambiguation

	// Probe counter (also: probes for the current object)
	probes_current:   int,

	completed:        bool,
	message:          cstring,
	message_timer:    f32,
	show_help:        bool,
}

@(private = "file")
l5: L5_State

l5_range_vtable :: proc() -> Level_Vtable {
	return {
		init    = l5_range_init,
		update  = l5_range_update,
		draw    = l5_range_draw,
		draw_ui = l5_range_draw_ui,
		cleanup = l5_range_cleanup,
	}
}

l5_range_init :: proc(game: ^Game_State) {
	l5 = {}
	l5.current_wobj  = -1
	l5.show_help     = true
	l5.message       = "Laser rangefinder online. Aim with the ship, [F] to pulse.\nThe glowing sphere shows where the next probe would\nbest disambiguate the top two candidates."
	l5.message_timer = 8

	game.ship.pos     = {0, 0, -8}
	game.ship.heading = 0
	game.ship.vel     = {0, 0, 0}
	game.ship.speed   = 0
	clear(&game.ship.trail)

	seed_world_objects(&game.model_db, &game.world)

	lm_init(&game.lms[0], 0)
	lm_start_inference(&game.lms[0], &game.model_db)

	game.camera = rl.Camera3D{
		position   = {0, 22, 18},
		target     = {0, 0, 0},
		up         = {0, 1, 0},
		fovy       = 60,
		projection = .PERSPECTIVE,
	}
}

// Ray vs world object using bounding sphere (good enough at our scale)
@(private = "file")
l5_raycast :: proc(world: ^World, origin, dir: Vec3) -> (idx: int, hit: Vec3, normal: Vec3, dist: f32) {
	idx = -1
	dist = LASER_MAX_RANGE + 1
	for i in 0..<len(world.objects) {
		obj := &world.objects[i]
		r := obj.size.x
		if obj.size.y > r do r = obj.size.y
		if obj.size.z > r do r = obj.size.z
		t, h := ray_sphere(origin, dir, obj.pos, r)
		if h && t < dist {
			dist = t
			idx  = i
		}
	}
	if idx < 0 || dist > LASER_MAX_RANGE {
		return -1, origin + dir * LASER_MAX_RANGE, dir, LASER_MAX_RANGE
	}
	hit = origin + dir * dist
	normal = linalg.normalize(hit - world.objects[idx].pos)
	return
}

// Build CMP from a hit and feed to LM
@(private = "file")
l5_register_pulse :: proc(game: ^Game_State, wobj_idx: int, hit, normal: Vec3, prev_ship_pos: Vec3) {
	obj := &game.world.objects[wobj_idx]
	cmp := CMP_Message{
		location    = hit,
		orientation = normal,
		features    = Features{
			roughness   = obj.material.roughness,
			temperature = obj.material.temperature,
			color       = obj.material.color,
		},
		confidence  = 1.0,
	}
	l5.last_cmp       = cmp
	l5.last_cmp_obj   = obj.name
	l5.last_cmp_world = hit
	l5.last_cmp_valid = true
	l5.pulse_anim     = 1.0

	// Switched object? Reset inference episode.
	if wobj_idx != l5.current_wobj {
		l5.current_wobj   = wobj_idx
		l5.probes_current = 0
		lm_init(&game.lms[0], 0)
		lm_start_inference(&game.lms[0], &game.model_db)
	}

	disp: Vec3 = {0, 0, 0}
	if l5.probes_current > 0 do disp = game.ship.pos - prev_ship_pos
	lm_step(&game.lms[0], cmp, disp, &game.model_db)
	l5.probes_current += 1
}

// Compute the curiosity hint: world-space position where a pulse would best
// distinguish the top two candidate objects.
//
// Approach: take the top-2 active hypotheses (with different object_idx).
// For each graph node on object A, project it into world space using A's
// pose. Translate that world location into B's object frame via B's pose.
// Find the nearest node on B at that location. Compare features. The
// node with maximum predicted dissimilarity is the most discriminating
// place to look next.
@(private = "file")
l5_recompute_hint :: proc(game: ^Game_State) {
	l5.hint_valid = false
	lm := &game.lms[0]
	db := &game.model_db
	if lm.mode != .Inferring || lm.converged do return
	if lm.hyp_count == 0 do return

	// Best hypothesis per object
	best_idx := [MAX_OBJECTS]int{}
	best_evd := [MAX_OBJECTS]f32{}
	for i in 0..<MAX_OBJECTS do best_idx[i] = -1
	for i in 0..<lm.hyp_count {
		h := &lm.hypotheses[i]
		if !h.active do continue
		if best_idx[h.object_idx] < 0 || h.evidence > best_evd[h.object_idx] {
			best_evd[h.object_idx] = h.evidence
			best_idx[h.object_idx] = i
		}
	}

	// Top two different objects
	top_a, top_b := -1, -1
	top_a_e: f32 = -99999
	top_b_e: f32 = -99999
	for oi in 0..<db.object_count {
		if best_idx[oi] < 0 do continue
		e := best_evd[oi]
		if e > top_a_e { top_b = top_a; top_b_e = top_a_e; top_a = oi; top_a_e = e }
		else if e > top_b_e { top_b = oi; top_b_e = e }
	}
	if top_a < 0 || top_b < 0 do return

	hyp_a := &lm.hypotheses[best_idx[top_a]]
	hyp_b := &lm.hypotheses[best_idx[top_b]]
	obj_a := &db.objects[top_a]
	obj_b := &db.objects[top_b]

	best_score: f32 = -1
	best_world_pos := Vec3{0, 0, 0}

	for ni in 0..<obj_a.node_count {
		node_a := &obj_a.nodes[ni]
		// A's object frame → body frame
		disp_obj_a := node_a.location - hyp_a.location
		disp_body  := hyp_a.rotation * disp_obj_a
		// Anchor world location near the actual world object so the hint
		// appears on a visible body, not on a phantom
		world_pos  := game.world.objects[top_a].pos + disp_body

		// Same body delta in B's object frame
		node_b_loc := hyp_b.location + linalg.transpose(hyp_b.rotation) * disp_body

		// Nearest stored node on B at that location
		nb_idx, _ := model_nearest_node(obj_b, node_b_loc, 2.0)
		score: f32

		if nb_idx < 0 {
			// B doesn't have geometry there — strong discriminator
			score = 1.0
		} else {
			nb := &obj_b.nodes[nb_idx]
			color_d := linalg.distance(node_a.features.color, nb.features.color)
			rough_d := abs(node_a.features.roughness   - nb.features.roughness)
			temp_d  := abs(node_a.features.temperature - nb.features.temperature)
			score = color_d * 1.5 + rough_d + temp_d
		}

		if score > best_score {
			best_score = score
			best_world_pos = world_pos
		}
	}

	if best_score > 0.05 {
		l5.hint_valid = true
		l5.hint_pos   = best_world_pos
		l5.hint_obj_a = top_a
		l5.hint_obj_b = top_b
		l5.hint_score = best_score
	}
}

l5_range_update :: proc(game: ^Game_State, dt: f32) {
	if rl.IsKeyPressed(.ESCAPE) { popup_show(game, .Confirm_Leave_Level); return }
	if rl.IsKeyPressed(.H)      { l5.show_help = !l5.show_help }

	ship := &game.ship
	turn_rate: f32 = 2.0
	if rl.IsKeyDown(.LEFT)  || rl.IsKeyDown(.A) { ship.heading += turn_rate * dt }
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) { ship.heading -= turn_rate * dt }
	accel: f32 = 8.0
	drag:  f32 = 2.0
	if rl.IsKeyDown(.UP)   || rl.IsKeyDown(.W) { ship.speed += accel * dt }
	else if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S) { ship.speed -= accel * dt }
	else { ship.speed *= (1 - drag * dt) }
	ship.speed = clamp(ship.speed, -5, 15)

	prev_pos := ship.pos
	ship_update(ship, dt)

	if l5.cooldown > 0   do l5.cooldown -= dt
	if l5.pulse_anim > 0 do l5.pulse_anim -= dt * 2

	if (rl.IsKeyPressed(.F) || (rl.IsKeyDown(.SPACE) && l5.cooldown <= 0)) && !l5.completed {
		fwd := ship_forward(ship)
		idx, hit, normal, _ := l5_raycast(&game.world, ship.pos, fwd)
		if idx >= 0 {
			l5_register_pulse(game, idx, hit, normal, prev_pos)
			l5_recompute_hint(game)
		} else {
			l5.last_cmp_valid = false
			l5.message       = "Laser missed — empty space."
			l5.message_timer = 1.2
		}
		l5.cooldown = LASER_COOLDOWN
	}

	// Check for convergence on a new object
	lm := &game.lms[0]
	if lm.converged && lm.winner_obj >= 0 && l5.current_wobj >= 0 {
		if lm.winner_obj == l5.current_wobj && !l5.identified[l5.current_wobj] {
			l5.identified[l5.current_wobj] = true
			l5.unique_ids += 1
			name := game.world.objects[l5.current_wobj].name
			l5.message = fmt.ctprintf("Identified: %s in %d probes  (%d/%d)\nAim at another object.",
				name, l5.probes_current, l5.unique_ids, RANGE_TARGETS_TO_WIN)
			l5.message_timer = 4

			if l5.unique_ids >= RANGE_TARGETS_TO_WIN && !l5.completed {
				l5.completed = true
				game.levels[Level_ID.Range].completed = true
				game.levels[Level_ID.Eye].unlocked    = true
				save_write(game)
				popup_show_delayed(game, .Level_Complete, 1.5)
			}
		}
	}

	// Standard follow camera (above-behind)
	fwd := ship_forward(ship)
	game.camera.position = ship.pos + Vec3{0, 18, 0} - fwd * 12
	game.camera.target   = ship.pos + fwd * 4

	if l5.message_timer > 0 do l5.message_timer -= dt
}

// ── 3D draw ─────────────────────────────────────────────────────────────────

l5_range_draw :: proc(game: ^Game_State) {
	rl.BeginMode3D(game.camera)
	world_draw(&game.world, true)
	ship_draw(&game.ship)
	ship_draw_trail(&game.ship)

	// Aim beam (preview where the laser would hit)
	fwd := ship_forward(&game.ship)
	idx, hit, normal, _ := l5_raycast(&game.world, game.ship.pos, fwd)
	beam_end := idx >= 0 ? hit : game.ship.pos + fwd * LASER_MAX_RANGE
	idle_a: u8 = u8(60 + l5.pulse_anim * 180)
	rl.DrawLine3D(game.ship.pos, beam_end, Color{255, 100, 100, idle_a})

	if idx >= 0 {
		rl.DrawCircle3D(hit, 0.35, normal, 0,
			Color{255, 120, 120, u8(140 + l5.pulse_anim * 100)})
		rl.DrawLine3D(hit, hit + normal * 1.0, Color{255, 200, 200, 160})
	}

	// Pulse flash
	if l5.pulse_anim > 0 && l5.last_cmp_valid {
		rl.DrawSphere(l5.last_cmp_world, 0.25 + (1 - l5.pulse_anim) * 1.4,
			Color{255, 200, 150, u8(l5.pulse_anim * 220)})
	}

	// Identified objects: green wireframe halo
	for i in 0..<len(game.world.objects) {
		if !l5.identified[i] do continue
		obj := &game.world.objects[i]
		rl.DrawSphereWires(obj.pos, obj.size.x + 0.3, 10, 10, Color{120, 255, 160, 180})
	}

	// Curiosity hint — pulsing sphere at the "best next probe" location
	if l5.hint_valid && !l5.completed {
		t := f32(rl.GetTime())
		pulse := 0.5 + 0.5 * math.sin(t * 4)
		r := 0.5 + 0.2 * pulse
		rl.DrawSphereWires(l5.hint_pos, r, 8, 8, Color{120, 220, 255, u8(180 + pulse * 60)})
		rl.DrawSphere(l5.hint_pos, 0.12, Color{120, 220, 255, 220})
		// thin line from ship toward hint
		rl.DrawLine3D(game.ship.pos, l5.hint_pos, Color{120, 220, 255, 80})
	}

	rl.EndMode3D()
}

// ── HUD ─────────────────────────────────────────────────────────────────────

l5_range_draw_ui :: proc(game: ^Game_State) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	lm := &game.lms[0]
	db := &game.model_db

	// Top-left: status panel
	pw, ph: f32 = 300, 130
	rl.DrawRectangle(10, 10, i32(pw), i32(ph), Color{0, 0, 0, 150})
	rl.DrawRectangleLinesEx({10, 10, pw, ph}, 1, Color{60, 80, 120, 150})
	rl.DrawText("LASER RANGEFINDER", 20, 18, 14, Color{255, 140, 140, 220})
	rl.DrawText(fmt.ctprintf("Identified: %d / %d", l5.unique_ids, RANGE_TARGETS_TO_WIN),
		20, 38, 16, Color{120, 255, 160, 220})

	if l5.current_wobj >= 0 {
		rl.DrawText(fmt.ctprintf("Probing: %s  (%d probes)",
			game.world.objects[l5.current_wobj].name, l5.probes_current),
			20, 60, 14, Color{200, 220, 240, 220})
	} else {
		rl.DrawText("Aim at an object and pulse to begin",
			20, 60, 14, Color{160, 180, 200, 200})
	}

	// Hypothesis funnel
	if lm.hyp_count > 0 {
		active := lm_active_count(lm)
		frac   := f32(active) / f32(lm.hyp_count)
		rl.DrawText("hypotheses", 20, 84, 12, Color{160, 180, 200, 180})
		rl.DrawRectangle(20, 100, 260, 12, Color{25, 25, 35, 200})
		rl.DrawRectangle(20, 100, i32(frac * 260), 12, Color{255, 140, 140, 200})
		rl.DrawText(fmt.ctprintf("%d / %d", active, lm.hyp_count),
			20, 114, 12, Color{200, 210, 230, 200})
	}

	// Right: CMP + hint panel
	right_x := sw - 360
	right_y: f32 = 10
	right_w: f32 = 350
	right_h: f32 = 250
	rl.DrawRectangle(i32(right_x), i32(right_y), i32(right_w), i32(right_h), Color{0, 0, 0, 180})
	rl.DrawRectangleLinesEx({right_x, right_y, right_w, right_h}, 1, Color{100, 160, 220, 180})
	rl.DrawText("LATEST PULSE — CMP MESSAGE", i32(right_x) + 10, i32(right_y) + 8, 13,
		Color{120, 180, 255, 220})

	ty := i32(right_y) + 32
	if l5.last_cmp_valid {
		c := &l5.last_cmp
		rl.DrawText(fmt.ctprintf("  target: %s", l5.last_cmp_obj), i32(right_x) + 10, ty, 14,
			Color{255, 220, 100, 230})
		rl.DrawText(fmt.ctprintf("  loc:  (%.1f, %.1f, %.1f)", c.location.x, c.location.y, c.location.z),
			i32(right_x) + 10, ty + 20, 13, Color{180, 200, 220, 200})
		rl.DrawText(fmt.ctprintf("  norm: (%.2f, %.2f, %.2f)", c.orientation.x, c.orientation.y, c.orientation.z),
			i32(right_x) + 10, ty + 38, 13, Color{180, 200, 220, 200})
		r := c.features.roughness.?   or_else 0
		t := c.features.temperature.? or_else 0
		rl.DrawText(fmt.ctprintf("  roughness: %.2f   temp: %.2f", r, t),
			i32(right_x) + 10, ty + 56, 13, Color{200, 220, 240, 220})
	} else {
		rl.DrawText("  (no pulse yet — press [F])", i32(right_x) + 10, ty, 14,
			Color{120, 140, 170, 180})
	}

	// Curiosity hint readout
	hint_y := ty + 88
	rl.DrawText("CURIOSITY (model-based action policy)", i32(right_x) + 10, hint_y, 13,
		Color{120, 220, 255, 220})
	if l5.hint_valid && !l5.completed {
		rl.DrawText("  Aim at the cyan sphere — it will best", i32(right_x) + 10, hint_y + 18, 13,
			Color{200, 230, 255, 220})
		rl.DrawText("  separate the top two candidates:", i32(right_x) + 10, hint_y + 34, 13,
			Color{200, 230, 255, 220})
		if l5.hint_obj_a >= 0 && l5.hint_obj_b >= 0 {
			rl.DrawText(fmt.ctprintf("    %s  vs.  %s",
				db.objects[l5.hint_obj_a].name, db.objects[l5.hint_obj_b].name),
				i32(right_x) + 10, hint_y + 52, 13, Color{255, 220, 100, 220})
		}
		rl.DrawText(fmt.ctprintf("    expected discrimination: %.2f", l5.hint_score),
			i32(right_x) + 10, hint_y + 72, 12, Color{160, 200, 230, 180})
	} else if lm.converged {
		rl.DrawText("  Converged — no hint needed.", i32(right_x) + 10, hint_y + 18, 13,
			Color{160, 220, 180, 200})
	} else {
		rl.DrawText("  (collecting evidence...)", i32(right_x) + 10, hint_y + 18, 13,
			Color{160, 180, 200, 180})
	}

	// Per-object evidence bars (top of remaining real estate)
	bars_y: f32 = f32(ph) + 30
	rl.DrawText("EVIDENCE PER OBJECT", 10, i32(bars_y), 13, Color{150, 170, 200, 200})
	bars_y += 20

	best_evid := [MAX_OBJECTS]f32{}
	lm_best_evidence_per_object(lm, db, best_evid[:])
	max_evid: f32 = 0.001
	for oi in 0..<db.object_count {
		if best_evid[oi] > max_evid do max_evid = best_evid[oi]
	}
	for oi in 0..<db.object_count {
		c := Color{180, 200, 240, 220}
		if oi == l5.hint_obj_a do c = Color{255, 220, 100, 240}
		if oi == l5.hint_obj_b do c = Color{120, 220, 255, 220}
		fill := i32(clamp(best_evid[oi] / max_evid, 0, 1) * 200)
		rl.DrawText(fmt.ctprintf("%s", db.objects[oi].name),
			10, i32(bars_y), 13, c)
		rl.DrawRectangle(150, i32(bars_y), 200, 12, Color{25, 25, 35, 200})
		if fill > 0 do rl.DrawRectangle(150, i32(bars_y), fill, 12, Color{c.r, c.g, c.b, 200})
		rl.DrawText(fmt.ctprintf("%.1f", best_evid[oi]),
			360, i32(bars_y), 12, Color{180, 200, 220, 200})
		bars_y += 16
	}

	// Message overlay
	if l5.message_timer > 0 && l5.message != nil {
		alpha := u8(min(l5.message_timer * 1.5, 1) * 255)
		msg_w := rl.MeasureText(l5.message, 18)
		mx := i32(sw / 2) - msg_w / 2 - 100
		my := i32(sh * 0.80)
		rl.DrawRectangle(mx - 14, my - 8, msg_w + 28, 50, Color{0, 0, 0, alpha / 2})
		rl.DrawText(l5.message, mx, my, 18, Color{255, 255, 255, alpha})
	}

	if l5.show_help {
		rl.DrawText("[WASD] Fly  [F] Pulse  [SPACE] Auto-pulse  [H] Help  [ESC] Back",
			10, i32(sh) - 28, 13, Color{80, 100, 140, 150})
	}

	rl.DrawText("LEVEL 5: LASER RANGEFINDER", i32(sw) - 280, i32(sh) - 28, 16,
		Color{255, 140, 140, 200})
}

l5_range_cleanup :: proc(game: ^Game_State) {}
