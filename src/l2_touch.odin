package monty

import rl "vendor:raylib"
import "core:math"
import "core:math/linalg"
import "core:fmt"

// Level 2: Contact Scanner (Touch)
//
// The hull probe fires when you fly close to a surface and press [F].
// Each contact is a CMP message: location + surface normal + roughness + temperature.
// These observations feed directly into the real Learning Module.
//
// Phase 1 — LEARN: Fly close to objects and probe them. Watch the object
//   graph grow node by node. Learn at least 2 objects.
//
// Phase 2 — INFER: The LM is seeded with all hypotheses. As you probe an
//   unknown object, watch the hypothesis bars collapse toward one winner.
//
// Under the hood panel (right side) shows in real time:
//   - The graph nodes accumulated on each learned object
//   - Per-object evidence bars during inference
//   - Active hypothesis count (starts high, crashes toward 1)
//   - The most-likely hypothesis (object + pose)
//   - Which graph node was matched, and its scores

TOUCH_PROBE_RANGE    :: 3.2
TOUCH_PHASE_LEARN    :: 0
TOUCH_PHASE_INFER    :: 1
LEARN_NODES_REQUIRED :: 8   // minimum nodes before an object can be "committed"
OBJECTS_TO_LEARN     :: 3

@(private = "file")
L2_State :: struct {
	phase:           int,
	learned_objects: int,         // how many objects fully committed
	active_learn:    int,         // model_db object_idx we're currently building (-1 = none)
	active_learn_wp: int,         // world object idx we're learning
	infer_started:   bool,

	prev_pos:        Vec3,        // for displacement computation
	prev_probed:     bool,

	// Which world objects we've already learned (by world obj idx)
	learned_wobj:    [8]bool,

	message:         cstring,
	message_timer:   f32,
	show_help:       bool,
}

@(private = "file")
l2: L2_State

l2_touch_vtable :: proc() -> Level_Vtable {
	return {
		init    = l2_init,
		update  = l2_update,
		draw    = l2_draw,
		draw_ui = l2_draw_ui,
		cleanup = l2_cleanup,
	}
}

l2_init :: proc(game: ^Game_State) {
	l2 = {}
	l2.phase       = TOUCH_PHASE_LEARN
	l2.active_learn = -1
	l2.active_learn_wp = -1
	l2.show_help   = true
	l2.message     = "Hull probe online. Fly close to an object\nand press [F] to take a surface reading.\nLearn each object by probing multiple spots."
	l2.message_timer = 7

	game.ship.pos     = {0, 0, 0}
	game.ship.vel     = {0, 0, 0}
	game.ship.heading = 0
	game.ship.speed   = 0
	clear(&game.ship.trail)

	// Reset the LM and model_db for a clean lesson
	model_db_init(&game.model_db)
	lm_init(&game.lms[0], 0)
	l2.prev_pos    = game.ship.pos
	l2.prev_probed = false

	game.camera = rl.Camera3D{
		position   = {0, 22, 28},
		target     = {0, 0, 0},
		up         = {0, 1, 0},
		fovy       = 60,
		projection = .PERSPECTIVE,
	}
}

// Find the nearest world object within probe range, return index or -1
l2_nearest_in_range :: proc(game: ^Game_State) -> (int, f32) {
	best := -1
	best_d: f32 = TOUCH_PROBE_RANGE + 1
	for i in 0..<len(game.world.objects) {
		d := linalg.distance(game.ship.pos, game.world.objects[i].pos)
		// account for object radius
		d -= game.world.objects[i].size.x
		if d < best_d {
			best_d = d
			best = i
		}
	}
	return best, best_d
}

// Build a CMP message for contact with a world object at current ship pos
l2_make_cmp :: proc(game: ^Game_State, wobj_idx: int) -> CMP_Message {
	obj := &game.world.objects[wobj_idx]

	// Surface normal: direction from object center to ship
	diff := game.ship.pos - obj.pos
	normal := linalg.length(diff) > 0.001 ? linalg.normalize(diff) : Vec3{0, 1, 0}

	// Contact point: on the surface of the object
	contact := obj.pos + normal * obj.size.x

	return CMP_Message{
		location    = contact,
		orientation = normal,
		features    = Features{
			roughness    = obj.material.roughness,
			temperature  = obj.material.temperature,
			color        = obj.material.color,
		},
		confidence  = 1.0,
	}
}

l2_update :: proc(game: ^Game_State, dt: f32) {
	ship := &game.ship

	// --- flight ---
	turn_rate: f32 = 2.0
	if rl.IsKeyDown(.LEFT)  || rl.IsKeyDown(.A) { ship.heading += turn_rate * dt }
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) { ship.heading -= turn_rate * dt }

	accel: f32 = 8.0
	drag:  f32 = 2.0
	if rl.IsKeyDown(.UP)   || rl.IsKeyDown(.W) {
		ship.speed += accel * dt
	} else if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S) {
		ship.speed -= accel * dt
	} else {
		ship.speed *= (1 - drag * dt)
	}
	ship.speed = clamp(ship.speed, -5, 15)
	ship_update(ship, dt)

	disp := ship.pos - l2.prev_pos

	wobj_idx, wobj_dist := l2_nearest_in_range(game)

	// --- probe key ---
	if rl.IsKeyPressed(.F) && wobj_idx >= 0 {
		cmp := l2_make_cmp(game, wobj_idx)

		switch l2.phase {
		case TOUCH_PHASE_LEARN:
			l2_probe_learn(game, wobj_idx, cmp, disp)
		case TOUCH_PHASE_INFER:
			l2_probe_infer(game, wobj_idx, cmp, disp)
		}
	}

	// --- commit current object if we move away ---
	if l2.phase == TOUCH_PHASE_LEARN && l2.active_learn >= 0 {
		if wobj_idx != l2.active_learn_wp && wobj_idx != l2.active_learn_wp {
			l2_try_commit(game)
		}
	}

	// --- switch to infer ---
	if rl.IsKeyPressed(.I) && l2.phase == TOUCH_PHASE_LEARN && l2.learned_objects >= 2 {
		l2_try_commit(game)  // commit any in-progress object
		l2.phase = TOUCH_PHASE_INFER
		lm_start_inference(&game.lms[0], &game.model_db)
		l2.infer_started = true
		l2.prev_probed = false
		l2.message = fmt.ctprintf("Inference mode. %d objects learned.\nProbe objects — watch the hypotheses collapse.", l2.learned_objects)
		l2.message_timer = 5
	}

	// camera
	fwd := ship_forward(ship)
	game.camera.position = ship.pos + Vec3{0, 18, 0} - fwd * 12
	game.camera.target   = ship.pos

	l2.prev_pos = ship.pos
	if l2.message_timer > 0 { l2.message_timer -= dt }
	if rl.IsKeyPressed(.H) { l2.show_help = !l2.show_help }
	if rl.IsKeyPressed(.ESCAPE) { popup_show(game, .Confirm_Leave_Level) }
}

l2_probe_learn :: proc(game: ^Game_State, wobj_idx: int, cmp: CMP_Message, disp: Vec3) {
	lm := &game.lms[0]

	if l2.active_learn_wp != wobj_idx {
		// Moved to a new object — commit previous if enough nodes
		l2_try_commit(game)

		// Start learning a new object
		if !l2.learned_wobj[wobj_idx] {
			lm_start_learning(lm, game.ship.pos)
			l2.active_learn_wp = wobj_idx
			obj_name := game.world.objects[wobj_idx].name
			l2.message = fmt.ctprintf("Learning: %s\nKeep probing different spots.", obj_name)
			l2.message_timer = 3
		} else {
			l2.message = "Already learned that object."
			l2.message_timer = 2
			return
		}
	}

	if lm.mode != .Learning do return

	lm_learn_step(lm, cmp, disp)
	l2.prev_probed = true

	node_count := lm.learn_count
	l2.message = fmt.ctprintf("Learning %s: %d nodes", game.world.objects[wobj_idx].name, node_count)
	l2.message_timer = 1.5
}

l2_try_commit :: proc(game: ^Game_State) {
	lm := &game.lms[0]
	if lm.mode != .Learning || lm.learn_count < LEARN_NODES_REQUIRED do return

	wp := l2.active_learn_wp
	name := game.world.objects[wp].name
	idx := lm_commit(lm, &game.model_db, name)
	if idx >= 0 {
		l2.learned_wobj[wp] = true
		l2.learned_objects += 1
		l2.active_learn    = -1
		l2.active_learn_wp = -1
		l2.message = fmt.ctprintf("Object committed: %s (%d nodes)\n%d/%d objects learned.",
			name, game.model_db.objects[idx].node_count, l2.learned_objects, OBJECTS_TO_LEARN)
		l2.message_timer = 4

		if l2.learned_objects >= OBJECTS_TO_LEARN {
			l2.message = fmt.ctprintf("All %d objects learned!\nPress [I] to switch to inference mode.", OBJECTS_TO_LEARN)
			l2.message_timer = 8
		}
	}
}

l2_probe_infer :: proc(game: ^Game_State, wobj_idx: int, cmp: CMP_Message, disp: Vec3) {
	lm := &game.lms[0]
	if lm.mode != .Inferring do return

	effective_disp := l2.prev_probed ? disp : Vec3{0, 0, 0}
	lm_step(lm, cmp, effective_disp, &game.model_db)
	l2.prev_probed = true

	if lm.converged {
		winner_name := game.model_db.objects[lm.winner_obj].name
		l2.message = fmt.ctprintf("IDENTIFIED: %s\nEvidence: %.1f", winner_name, lm.hypotheses[lm.mlh_idx].evidence)
		l2.message_timer = 5

		if lm.winner_obj >= 0 {
			game.levels[Level_ID.Touch].completed = true
			game.levels[Level_ID.Drones].unlocked = true
			popup_show_delayed(game, .Level_Complete, 1.5)
		}
	} else {
		active := lm_active_count(lm)
		l2.message = fmt.ctprintf("Step %d — %d hypotheses remain", lm.step_count, active)
		l2.message_timer = 1.2
	}
}

// ── Draw 3D ──────────────────────────────────────────────────────────────────

l2_draw :: proc(game: ^Game_State) {
	rl.BeginMode3D(game.camera)

	// Objects are visible in this level — you can see what you're touching
	world_draw(&game.world, true)
	ship_draw(&game.ship)
	ship_draw_trail(&game.ship)

	// Probe range ring around ship
	wobj_idx, wobj_dist := l2_nearest_in_range(game)
	if wobj_idx >= 0 {
		pulse := 0.5 + 0.5 * math.sin(f32(rl.GetTime()) * 4)
		rl.DrawCircle3D(game.ship.pos, TOUCH_PROBE_RANGE, {0, 1, 0}, 0,
			Color{100, 255, 200, u8(pulse * 80)})
		// Line to contact point
		obj := &game.world.objects[wobj_idx]
		diff := game.ship.pos - obj.pos
		if linalg.length(diff) > 0.001 {
			contact := obj.pos + linalg.normalize(diff) * obj.size.x
			rl.DrawLine3D(game.ship.pos, contact, Color{100, 255, 200, 180})
			rl.DrawSphere(contact, 0.2, Color{100, 255, 200, 220})
		}
	}

	// Draw learned graph nodes in 3D (in world space via object positions)
	db := &game.model_db
	obj_colors := [8]Color{
		{255, 120, 80,  200},
		{80,  220, 120, 200},
		{80,  120, 255, 200},
		{220, 200, 80,  200},
		{200, 80,  220, 200},
		{220, 180, 100, 200},
		{100, 220, 220, 200},
		{220, 100, 180, 200},
	}
	for oi in 0..<db.object_count {
		obj_graph := &db.objects[oi]
		// Find the world object this model corresponds to
		wpos: Vec3
		for wi in 0..<len(game.world.objects) {
			if game.world.objects[wi].name == obj_graph.name {
				wpos = game.world.objects[wi].pos
				break
			}
		}
		c := obj_colors[oi % len(obj_colors)]
		for ni in 0..<obj_graph.node_count {
			node := &obj_graph.nodes[ni]
			world_node_pos := wpos + node.location
			rl.DrawSphere(world_node_pos, 0.12, c)
			// Normal arrow
			rl.DrawLine3D(world_node_pos, world_node_pos + node.normal * 0.35,
				Color{c.r, c.g, c.b, 120})
		}
	}

	// Draw current learn buffer (in-progress nodes, before commit)
	lm := &game.lms[0]
	if lm.mode == .Learning && l2.active_learn_wp >= 0 {
		wpos := game.world.objects[l2.active_learn_wp].pos
		for ni in 0..<lm.learn_count {
			node := &lm.learn_buffer[ni]
			world_node_pos := wpos + node.location
			rl.DrawSphere(world_node_pos, 0.15, Color{255, 255, 100, 180})
		}
	}

	// During inference: highlight matched node on MLH object
	if l2.phase == TOUCH_PHASE_INFER && lm.mlh_idx >= 0 && lm.mlh_idx < lm.hyp_count {
		mlh := &lm.hypotheses[lm.mlh_idx]
		if mlh.active && mlh.object_idx < db.object_count {
			obj_graph := &db.objects[mlh.object_idx]
			wpos: Vec3
			for wi in 0..<len(game.world.objects) {
				if cstring(game.world.objects[wi].name) == obj_graph.name {
					wpos = game.world.objects[wi].pos
					break
				}
			}
			matched_world := wpos + mlh.location
			rl.DrawSphere(matched_world, 0.3, Color{255, 255, 255, 200})
		}
	}

	rl.EndMode3D()
}

// ── Draw UI ───────────────────────────────────────────────────────────────────

l2_draw_ui :: proc(game: ^Game_State) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	lm := &game.lms[0]
	db := &game.model_db

	// ── Left panel: probe status ──────────────────────────────────────────
	panel_w: f32 = 280
	panel_h: f32 = 130
	rl.DrawRectangle(10, 10, i32(panel_w), i32(panel_h), Color{0, 0, 0, 150})
	rl.DrawRectangleLinesEx({10, 10, panel_w, panel_h}, 1, Color{60, 80, 120, 150})

	phase_label: cstring = l2.phase == TOUCH_PHASE_LEARN ? "CONTACT SCANNER — LEARN" : "CONTACT SCANNER — INFER"
	phase_color: Color   = l2.phase == TOUCH_PHASE_LEARN ? {100, 220, 150, 220} : {100, 180, 255, 220}
	rl.DrawText(phase_label, 20, 18, 13, phase_color)

	wobj_idx, wobj_dist := l2_nearest_in_range(game)
	if wobj_idx >= 0 {
		obj := &game.world.objects[wobj_idx]
		rl.DrawText(fmt.ctprintf("In range: %s (%.1f)", obj.name, wobj_dist), 20, 38, 15, Color{200, 255, 200, 230})
		rl.DrawText("[F] to probe", 20, 58, 14, Color{150, 220, 150, 180})
	} else {
		rl.DrawText("No object in range", 20, 38, 15, Color{150, 150, 170, 180})
	}

	if l2.phase == TOUCH_PHASE_LEARN {
		rl.DrawText(fmt.ctprintf("Objects learned: %d / %d", l2.learned_objects, OBJECTS_TO_LEARN),
			20, 80, 15, Color{180, 200, 240, 220})
		if l2.active_learn_wp >= 0 {
			rl.DrawText(fmt.ctprintf("Building: %d nodes (need %d)",
				lm.learn_count, LEARN_NODES_REQUIRED), 20, 100, 14, Color{255, 220, 100, 200})
		}
		if l2.learned_objects >= 2 {
			rl.DrawText("[I] — Switch to inference", 20, 118, 13, Color{100, 255, 200, 220})
		}
	} else {
		rl.DrawText(fmt.ctprintf("Step: %d  Active hyps: %d", lm.step_count, lm_active_count(lm)),
			20, 78, 15, Color{180, 200, 240, 220})
		if lm.mlh_idx >= 0 && lm.mlh_idx < lm.hyp_count {
			mlh := &lm.hypotheses[lm.mlh_idx]
			if mlh.active && mlh.object_idx < db.object_count {
				rl.DrawText(fmt.ctprintf("MLH: %s  evid: %.2f",
					db.objects[mlh.object_idx].name, mlh.evidence),
					20, 100, 14, Color{255, 220, 100, 220})
			}
		}
	}

	// ── Right panel: under the hood ───────────────────────────────────────
	panel_x := sw - 300
	rl.DrawRectangle(i32(panel_x), 10, 290, i32(sh * 0.70), Color{0, 0, 0, 150})
	rl.DrawRectangleLinesEx({panel_x, 10, 290, sh * 0.70}, 1, Color{60, 80, 120, 150})
	rl.DrawText("UNDER THE HOOD — LEARNING MODULE", i32(panel_x) + 8, 18, 12, Color{100, 160, 255, 180})

	obj_colors := [8]Color{
		{255, 120, 80,  255},
		{80,  220, 120, 255},
		{80,  120, 255, 255},
		{220, 200, 80,  255},
		{200, 80,  220, 255},
		{220, 180, 100, 255},
		{100, 220, 220, 255},
		{220, 100, 180, 255},
	}

	y: f32 = 40

	// Object models section
	rl.DrawText("OBJECT GRAPHS", i32(panel_x) + 8, i32(y), 12, Color{150, 170, 200, 160})
	y += 18

	for oi in 0..<db.object_count {
		og := &db.objects[oi]
		c := obj_colors[oi % len(obj_colors)]
		rl.DrawRectangle(i32(panel_x) + 8, i32(y), 8, 8, c)
		rl.DrawText(fmt.ctprintf("%s: %d nodes", og.name, og.node_count),
			i32(panel_x) + 22, i32(y), 14, Color{200, 210, 230, 220})
		y += 20
	}

	// In-progress learning buffer
	if lm.mode == .Learning && lm.learn_count > 0 {
		rl.DrawRectangle(i32(panel_x) + 8, i32(y), 8, 8, Color{255, 255, 100, 200})
		rl.DrawText(fmt.ctprintf("(building): %d / %d nodes", lm.learn_count, LEARN_NODES_REQUIRED),
			i32(panel_x) + 22, i32(y), 14, Color{255, 255, 100, 200})
		y += 20
	}
	y += 10

	// Evidence bars section (inference mode only)
	if l2.phase == TOUCH_PHASE_INFER && db.object_count > 0 {
		rl.DrawText("EVIDENCE PER OBJECT", i32(panel_x) + 8, i32(y), 12, Color{150, 170, 200, 160})
		y += 18

		best_evid := [MAX_OBJECTS]f32{}
		active_cnt := [MAX_OBJECTS]int{}
		lm_best_evidence_per_object(lm, db, best_evid[:])
		lm_active_per_object(lm, db, active_cnt[:])

		max_evid: f32 = 0.001
		for oi in 0..<db.object_count {
			if best_evid[oi] > max_evid { max_evid = best_evid[oi] }
		}

		bar_w: f32 = 200
		for oi in 0..<db.object_count {
			c := obj_colors[oi % len(obj_colors)]
			rl.DrawText(cstring(db.objects[oi].name), i32(panel_x) + 8, i32(y), 13,
				Color{c.r, c.g, c.b, 200})
			y += 16
			// Evidence bar
			ev_fill := i32(clamp(best_evid[oi] / max_evid, 0, 1) * bar_w)
			rl.DrawRectangle(i32(panel_x) + 8, i32(y), i32(bar_w), 14, Color{25, 25, 35, 200})
			if ev_fill > 0 {
				rl.DrawRectangle(i32(panel_x) + 8, i32(y), ev_fill, 14, Color{c.r, c.g, c.b, 200})
			}
			rl.DrawText(fmt.ctprintf("%.1f  (%d hyps)", best_evid[oi], active_cnt[oi]),
				i32(panel_x) + i32(bar_w) + 14, i32(y), 12, Color{180, 190, 210, 180})
			y += 20
		}
		y += 8

		// Hypothesis funnel
		total_hyps := lm.hyp_count
		active_total := lm_active_count(lm)
		rl.DrawText("HYPOTHESIS FUNNEL", i32(panel_x) + 8, i32(y), 12, Color{150, 170, 200, 160})
		y += 18
		funnel_w: f32 = 240
		funnel_frac := total_hyps > 0 ? f32(active_total) / f32(total_hyps) : 0
		rl.DrawRectangle(i32(panel_x) + 8, i32(y), i32(funnel_w), 16, Color{25, 25, 35, 200})
		rl.DrawRectangle(i32(panel_x) + 8, i32(y), i32(funnel_frac * funnel_w), 16,
			Color{100, 180, 255, 180})
		rl.DrawText(fmt.ctprintf("%d / %d active", active_total, total_hyps),
			i32(panel_x) + 8, i32(y) + 20, 13, Color{160, 180, 220, 200})
		y += 40

		// Last step scores
		if lm.mlh_idx >= 0 && lm.mlh_idx < lm.hyp_count && lm.step_count > 0 {
			info := &lm.step_info[lm.mlh_idx]
			rl.DrawText("LAST STEP (MLH)", i32(panel_x) + 8, i32(y), 12, Color{150, 170, 200, 160})
			y += 18
			if info.node_idx >= 0 {
				rl.DrawText(fmt.ctprintf("  node: %d  dist: %.2f", info.node_idx, info.node_dist),
					i32(panel_x) + 8, i32(y), 13, Color{180, 200, 220, 200})
				y += 16
				rl.DrawText(fmt.ctprintf("  morph: %+.2f  feat: %.2f  Δ: %+.2f",
					info.morphology_score, info.feature_score, info.delta),
					i32(panel_x) + 8, i32(y), 13, Color{180, 200, 220, 200})
			} else {
				rl.DrawText("  no match — penalised", i32(panel_x) + 8, i32(y), 13,
					Color{220, 120, 80, 200})
			}
		}
	}

	// ── Message overlay ───────────────────────────────────────────────────
	if l2.message_timer > 0 && l2.message != nil {
		alpha := u8(min(l2.message_timer * 2, 1) * 255)
		msg_w := rl.MeasureText(l2.message, 19)
		mx := i32(sw / 2) - msg_w / 2
		rl.DrawRectangle(mx - 15, i32(sh * 0.78) - 10, msg_w + 30, 50, Color{0, 0, 0, alpha / 2})
		rl.DrawText(l2.message, mx, i32(sh * 0.78), 19, Color{255, 255, 255, alpha})
	}

	if l2.show_help {
		help: cstring = "[WASD] Fly  [F] Probe  [H] Help  [ESC] Back"
		if l2.phase == TOUCH_PHASE_LEARN {
			help = "[WASD] Fly  [F] Probe  [I] Infer (needs 2+ objects)  [H] Help  [ESC] Back"
		}
		rl.DrawText(help, 10, i32(sh) - 28, 13, Color{80, 100, 140, 150})
	}

	rl.DrawText("LEVEL 3: CONTACT SCANNER", i32(sw) - 300, i32(sh) - 28, 16,
		Color{100, 220, 150, 180})
}

l2_cleanup :: proc(game: ^Game_State) {}
