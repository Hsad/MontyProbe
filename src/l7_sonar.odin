package monty

import rl "vendor:raylib"
import "core:math"
import "core:math/linalg"
import "core:fmt"

// Level 7 — Echo Sonar (Cross-modal CMP)
//
// Two sensors fire simultaneously, producing CMP messages with
// COMPLETELY DIFFERENT feature sets:
//
//   OPTIC pulse → CMP { color, roughness }                   (LM 0)
//   SONAR ping  → CMP { resonance }                          (LM 1)
//
// Each modality drives its own Learning Module. After every pulse,
// the two LMs vote with each other via the CMP protocol — and
// because CMP only cares about "features at a pose," not which
// specific feature fields are populated, the votes work cleanly.
//
// Monty concept: the Cortical Messaging Protocol is modality-
// agnostic. Vision and hearing columns can collaborate identically
// to two vision columns because the protocol abstracts the modality
// away. This is how the brain integrates senses without a special
// "fusion" stage.
//
// Objective: identify 3 objects with cross-modal voting.

SONAR_TARGETS  :: 3
SONAR_COOLDOWN :: 0.18

@(private = "file")
L7_State :: struct {
	cooldown:        f32,
	pulse_anim:      f32,

	last_optic_cmp:  CMP_Message,
	last_sonar_cmp:  CMP_Message,
	last_obj_idx:    int,
	last_valid:      bool,

	prev_pos:        Vec3,
	probed_once:     bool,

	identified:      [16]bool,
	unique_ids:      int,

	completed:       bool,
	message:         cstring,
	message_timer:   f32,
	show_help:       bool,
}

@(private = "file")
l7: L7_State

l7_sonar_vtable :: proc() -> Level_Vtable {
	return {
		init    = l7_sonar_init,
		update  = l7_sonar_update,
		draw    = l7_sonar_draw,
		draw_ui = l7_sonar_draw_ui,
		cleanup = l7_sonar_cleanup,
	}
}

l7_sonar_init :: proc(game: ^Game_State) {
	l7 = {}
	l7.show_help     = true
	l7.last_obj_idx  = -1
	l7.message       = "Sonar online. [F] fires optic + sonar TOGETHER.\nOptic CMP: color + roughness.   Sonar CMP: resonance only.\nDifferent modalities — same CMP protocol — they vote together."
	l7.message_timer = 10

	game.ship.pos     = {0, 0, -8}
	game.ship.heading = 0
	game.ship.vel     = {0, 0, 0}
	game.ship.speed   = 0
	clear(&game.ship.trail)

	seed_world_objects(&game.model_db, &game.world)

	// LM 0 = optic, LM 1 = sonar
	for i in 0..<2 {
		lm_init(&game.lms[i], i)
		lm_start_inference(&game.lms[i], &game.model_db)
	}

	game.camera = rl.Camera3D{
		position   = {0, 22, 18},
		target     = {0, 0, 0},
		up         = {0, 1, 0},
		fovy       = 60,
		projection = .PERSPECTIVE,
	}
}

// Reuses ray_sphere from l2_light; just find first hit
@(private = "file")
l7_raycast :: proc(world: ^World, origin, dir: Vec3) -> (idx: int, hit: Vec3, normal: Vec3) {
	best := -1
	best_t: f32 = LASER_MAX_RANGE + 1
	for i in 0..<len(world.objects) {
		obj := &world.objects[i]
		r := obj.size.x
		if obj.size.y > r do r = obj.size.y
		if obj.size.z > r do r = obj.size.z
		t, h := ray_sphere(origin, dir, obj.pos, r)
		if h && t < best_t {
			best_t = t
			best = i
		}
	}
	if best < 0 || best_t > LASER_MAX_RANGE {
		return -1, origin + dir * LASER_MAX_RANGE, dir
	}
	hit = origin + dir * best_t
	normal = linalg.normalize(hit - world.objects[best].pos)
	idx = best
	return
}

@(private = "file")
l7_pulse :: proc(game: ^Game_State) {
	ship := &game.ship
	fwd := ship_forward(ship)
	idx, hit, normal := l7_raycast(&game.world, ship.pos, fwd)
	if idx < 0 {
		l7.last_valid    = false
		l7.message       = "Both pulses missed — empty space."
		l7.message_timer = 1.2
		return
	}

	obj := &game.world.objects[idx]

	// Optic CMP — color + roughness only (no resonance)
	optic_cmp := CMP_Message{
		location    = hit,
		orientation = normal,
		features    = Features{
			color     = obj.material.color,
			roughness = obj.material.roughness,
		},
		confidence  = 1.0,
	}
	// Sonar CMP — resonance only (no color, no roughness)
	sonar_cmp := CMP_Message{
		location    = hit,
		orientation = normal,
		features    = Features{
			resonance = obj.material.resonance,
		},
		confidence  = 1.0,
	}

	l7.last_optic_cmp = optic_cmp
	l7.last_sonar_cmp = sonar_cmp
	l7.last_obj_idx   = idx
	l7.last_valid     = true
	l7.pulse_anim     = 1.0

	disp: Vec3 = l7.probed_once ? ship.pos - l7.prev_pos : Vec3{0, 0, 0}
	l7.prev_pos    = ship.pos
	l7.probed_once = true

	lm_step(&game.lms[0], optic_cmp, disp, &game.model_db)
	lm_step(&game.lms[1], sonar_cmp, disp, &game.model_db)

	// Cross-modal voting — each LM sends its MLH to the other
	for sender in 0..<2 {
		vote, ok := lm_generate_vote(&game.lms[sender])
		if !ok do continue
		for receiver in 0..<2 {
			if receiver == sender do continue
			if game.lms[receiver].converged do continue
			lm_receive_vote(&game.lms[receiver], vote, Vec3{0,0,0}, &game.model_db)
		}
	}
}

l7_sonar_update :: proc(game: ^Game_State, dt: f32) {
	if rl.IsKeyPressed(.ESCAPE) { popup_show(game, .Confirm_Leave_Level); return }
	if rl.IsKeyPressed(.H)      { l7.show_help = !l7.show_help }
	if rl.IsKeyPressed(.N) {
		for i in 0..<2 {
			lm_init(&game.lms[i], i)
			lm_start_inference(&game.lms[i], &game.model_db)
		}
		l7.probed_once   = false
		l7.message       = "NEW EPISODE — both LMs reset."
		l7.message_timer = 2
	}

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
	ship_update(ship, dt)

	if l7.cooldown > 0   do l7.cooldown -= dt
	if l7.pulse_anim > 0 do l7.pulse_anim -= dt * 2

	if (rl.IsKeyPressed(.F) || (rl.IsKeyDown(.SPACE) && l7.cooldown <= 0)) && !l7.completed {
		l7_pulse(game)
		l7.cooldown = SONAR_COOLDOWN
	}

	// Identification — either LM converges (cross-modal voting confirms)
	for lm_i in 0..<2 {
		lm := &game.lms[lm_i]
		if lm.converged && lm.winner_obj >= 0 && lm.winner_obj < len(l7.identified) &&
		   !l7.identified[lm.winner_obj] {
			l7.identified[lm.winner_obj] = true
			l7.unique_ids += 1
			name := game.model_db.objects[lm.winner_obj].name
			l7.message = fmt.ctprintf("Identified: %s  (%d/%d)\n[N] for new episode then aim elsewhere.",
				name, l7.unique_ids, SONAR_TARGETS)
			l7.message_timer = 4

			if l7.unique_ids >= SONAR_TARGETS && !l7.completed {
				l7.completed = true
				game.levels[Level_ID.Sonar].completed = true
				game.levels[Level_ID.Fleet].unlocked  = true
				save_write(game)
				popup_show_delayed(game, .Level_Complete, 1.5)
			}
		}
	}

	// follow camera
	fwd := ship_forward(ship)
	game.camera.position = ship.pos + Vec3{0, 18, 0} - fwd * 12
	game.camera.target   = ship.pos + fwd * 4

	if l7.message_timer > 0 do l7.message_timer -= dt
}

// ── 3D draw ─────────────────────────────────────────────────────────────────

l7_sonar_draw :: proc(game: ^Game_State) {
	rl.BeginMode3D(game.camera)
	world_draw(&game.world, true)
	ship_draw(&game.ship)
	ship_draw_trail(&game.ship)

	// Identified halos
	for i in 0..<len(game.world.objects) {
		if !l7.identified[i] do continue
		obj := &game.world.objects[i]
		rl.DrawSphereWires(obj.pos, obj.size.x + 0.3, 10, 10, Color{120, 255, 160, 180})
	}

	// Aim beams
	fwd := ship_forward(&game.ship)
	idx, hit, normal := l7_raycast(&game.world, game.ship.pos, fwd)
	end := idx >= 0 ? hit : game.ship.pos + fwd * LASER_MAX_RANGE

	// Optic beam — blue, slightly offset left of ship axis
	left_off := linalg.normalize(linalg.cross(Vec3{0, 1, 0}, fwd)) * 0.2
	rl.DrawLine3D(game.ship.pos + left_off, end + left_off,
		Color{100, 180, 255, u8(80 + l7.pulse_anim * 175)})
	rl.DrawLine3D(game.ship.pos + left_off * 0.5, end + left_off * 0.5,
		Color{100, 180, 255, u8(40 + l7.pulse_anim * 120)})

	// Sonar "ping" — magenta thicker beam offset right, plus an expanding ring on pulse
	right_off := -left_off
	rl.DrawLine3D(game.ship.pos + right_off, end + right_off,
		Color{220, 120, 220, u8(80 + l7.pulse_anim * 175)})
	rl.DrawLine3D(game.ship.pos + right_off * 0.5, end + right_off * 0.5,
		Color{220, 120, 220, u8(40 + l7.pulse_anim * 120)})

	if idx >= 0 {
		// Reticle
		rl.DrawCircle3D(hit, 0.35, normal, 0, Color{200, 200, 255, 140})

		if l7.pulse_anim > 0 {
			// Optic flash — small blue burst
			rl.DrawSphere(hit, 0.18 + (1 - l7.pulse_anim) * 0.3,
				Color{100, 180, 255, u8(l7.pulse_anim * 200)})
			// Sonar ring expanding outward — concentric circles in surface plane
			ring_r := (1 - l7.pulse_anim) * 2.0
			rl.DrawCircle3D(hit, ring_r,        normal, 0, Color{220, 120, 220, u8(l7.pulse_anim * 200)})
			rl.DrawCircle3D(hit, ring_r * 0.6,  normal, 0, Color{220, 120, 220, u8(l7.pulse_anim * 140)})
		}
	}

	rl.EndMode3D()
}

// ── HUD ─────────────────────────────────────────────────────────────────────

l7_sonar_draw_ui :: proc(game: ^Game_State) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	db := &game.model_db

	// Title
	rl.DrawText(fmt.ctprintf("Identified: %d / %d", l7.unique_ids, SONAR_TARGETS),
		14, 12, 18, Color{120, 255, 160, 220})
	rl.DrawText("LEVEL 7: ECHO SONAR (cross-modal CMP)",
		i32(sw) - 400, 12, 16, Color{220, 120, 220, 220})

	// Cross-modal agreement banner
	lm_optic := &game.lms[0]
	lm_sonar := &game.lms[1]
	agree_color := Color{120, 130, 160, 200}
	agree_text: cstring = "(waiting for evidence)"
	if lm_optic.mlh_idx >= 0 && lm_sonar.mlh_idx >= 0 {
		o_obj := lm_optic.hypotheses[lm_optic.mlh_idx].object_idx
		s_obj := lm_sonar.hypotheses[lm_sonar.mlh_idx].object_idx
		if o_obj == s_obj && o_obj >= 0 && o_obj < db.object_count {
			agree_color = Color{120, 255, 160, 230}
			agree_text  = fmt.ctprintf("CROSS-MODAL AGREEMENT: both LMs → %s", db.objects[o_obj].name)
		} else if o_obj >= 0 && s_obj >= 0 && o_obj < db.object_count && s_obj < db.object_count {
			agree_color = Color{255, 200, 100, 230}
			agree_text  = fmt.ctprintf("DISAGREEMENT: optic→%s   sonar→%s",
				db.objects[o_obj].name, db.objects[s_obj].name)
		}
	}
	rl.DrawText(agree_text, 14, 38, 14, agree_color)

	// Compact stacked panels on the right side
	panel_w: f32 = 280
	panel_h: f32 = 230
	panel_x: f32 = sw - panel_w - 10
	gap:     f32 = 8
	panel_y_optic: f32 = 60
	panel_y_sonar: f32 = panel_y_optic + panel_h + gap

	draw_lm_panel :: proc(game: ^Game_State, lm: ^Learning_Module, x, y, w, h: f32,
	                     title: cstring, panel_color: Color, features_shown: cstring,
	                     cmp: ^CMP_Message, last_valid: bool) {
		db := &game.model_db
		rl.DrawRectangle(i32(x), i32(y), i32(w), i32(h), Color{0, 0, 0, 170})
		rl.DrawRectangleLinesEx({x, y, w, h}, 2, panel_color)

		// Header
		rl.DrawText(title, i32(x) + 8, i32(y) + 6, 14, panel_color)
		rl.DrawText(features_shown, i32(x) + 8, i32(y) + 22, 11, Color{180, 200, 220, 200})

		// Hypothesis funnel — slim bar
		active := lm_active_count(lm)
		total  := lm.hyp_count
		frac   := total > 0 ? f32(active) / f32(total) : 0
		hy := i32(y) + 40
		rl.DrawRectangle(i32(x) + 8, hy, i32(w) - 16, 8, Color{25, 25, 35, 200})
		rl.DrawRectangle(i32(x) + 8, hy, i32(f32(int(w) - 16) * frac), 8, panel_color)
		rl.DrawText(fmt.ctprintf("hyps: %d / %d", active, total),
			i32(x) + 8, hy + 10, 10, Color{160, 180, 200, 200})

		// Compact evidence bars
		best_evid := [MAX_OBJECTS]f32{}
		lm_best_evidence_per_object(lm, db, best_evid[:])
		max_evid: f32 = 0.001
		for oi in 0..<db.object_count {
			if best_evid[oi] > max_evid do max_evid = best_evid[oi]
		}
		mlh_obj := -1
		if lm.mlh_idx >= 0 && lm.mlh_idx < lm.hyp_count {
			mlh_obj = lm.hypotheses[lm.mlh_idx].object_idx
		}
		by := hy + 26
		bar_x_off: i32 = 90
		bar_w := i32(w) - bar_x_off - 38
		for oi in 0..<db.object_count {
			c := Color{180, 200, 240, 220}
			if oi == mlh_obj do c = panel_color
			rl.DrawText(db.objects[oi].name, i32(x) + 8, by, 10, c)
			rl.DrawRectangle(i32(x) + bar_x_off, by, bar_w, 8, Color{25, 25, 35, 200})
			fill := i32(clamp(best_evid[oi] / max_evid, 0, 1) * f32(bar_w))
			if fill > 0 do rl.DrawRectangle(i32(x) + bar_x_off, by, fill, 8, Color{c.r, c.g, c.b, 180})
			rl.DrawText(fmt.ctprintf("%.1f", best_evid[oi]),
				i32(x) + bar_x_off + bar_w + 4, by - 1, 10, Color{180, 200, 220, 200})
			by += 13
		}

		// Latest CMP features — one compact line
		fy := by + 4
		rl.DrawText("CMP:", i32(x) + 8, fy, 10, Color{160, 180, 200, 180})
		fx: i32 = 42
		if last_valid {
			if c, ok := cmp.features.color.?; ok {
				rl.DrawRectangle(i32(x) + fx, fy, 14, 10,
					Color{u8(c.x * 255), u8(c.y * 255), u8(c.z * 255), 255})
				fx += 18
				rl.DrawText("color", i32(x) + fx, fy, 10, Color{200, 220, 240, 200})
				fx += 36
			}
			if r, ok := cmp.features.roughness.?; ok {
				rl.DrawText(fmt.ctprintf("rough %.2f", r), i32(x) + fx, fy, 10, Color{200, 220, 240, 200})
				fx += 70
			}
			if r, ok := cmp.features.resonance.?; ok {
				rl.DrawText(fmt.ctprintf("reson %.2f", r), i32(x) + fx, fy, 10, Color{200, 220, 240, 200})
			}
		} else {
			rl.DrawText("(no pulse)", i32(x) + fx, fy, 10, Color{140, 160, 180, 180})
		}

		// Inline convergence pills at bottom
		lm_draw_convergence_inline(lm, i32(x) + 8, i32(y) + i32(h) - 18)
	}

	draw_lm_panel(game, lm_optic, panel_x, panel_y_optic, panel_w, panel_h,
		"OPTIC LM", Color{100, 180, 255, 240}, "color + roughness",
		&l7.last_optic_cmp, l7.last_valid)
	draw_lm_panel(game, lm_sonar, panel_x, panel_y_sonar, panel_w, panel_h,
		"SONAR LM", Color{220, 120, 220, 240}, "resonance only",
		&l7.last_sonar_cmp, l7.last_valid)

	// Message overlay
	if l7.message_timer > 0 && l7.message != nil {
		alpha := u8(min(l7.message_timer * 1.5, 1) * 255)
		msg_w := rl.MeasureText(l7.message, 18)
		mx := i32(sw / 2) - msg_w / 2 - 200
		my := i32(sh) - 80
		rl.DrawRectangle(mx - 14, my - 8, msg_w + 28, 60, Color{0, 0, 0, alpha / 2})
		rl.DrawText(l7.message, mx, my, 18, Color{255, 255, 255, alpha})
	}

	if l7.show_help {
		rl.DrawText("[WASD] Fly   [F] Fire both   [SPACE] Auto-pulse   [N] New episode   [H] Help   [ESC] Back",
			10, i32(sh) - 28, 13, Color{80, 100, 140, 150})
	}
}

l7_sonar_cleanup :: proc(game: ^Game_State) {}
