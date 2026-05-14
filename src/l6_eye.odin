package monty

import rl "vendor:raylib"
import "core:math"
import "core:math/linalg"
import "core:fmt"

// Level 6 — Sensor Array (The Eye)
//
// The mothership grows an "optic patch" — a 3x3 grid of receptors, each
// one its own Learning Module running inference in parallel. When you
// pulse, all 9 cells fire simultaneously, each picking up a slightly
// different surface point. The 9 LMs vote with each other after every
// pulse.
//
// This is the canonical Thousand Brains moment: many partial views
// stitched together by lateral voting beats a single column doing
// careful sequential exploration.
//
// SDR PANEL: a 2D grid representing the union of all 9 LMs' active
// hypotheses, indexed (object, rotation). Watch it light up wide at
// first, then collapse as voting converges everyone toward a single
// (object, pose) cell. That collapse is the "thousand brains" in
// action.
//
// Objective: identify 3 objects (any 2+ LMs converge on the same one).

NUM_SM_CELLS    :: 9
EYE_TARGETS     :: 3
EYE_COOLDOWN    :: 0.20
EYE_PATCH_HALF  :: 0.45   // body-frame half-extent of the patch

@(private = "file")
Cell_Hit :: struct {
	hit:   bool,
	world: Vec3,
	normal: Vec3,
	wobj:  int,
}

@(private = "file")
L6_State :: struct {
	cell_body_offsets: [NUM_SM_CELLS]Vec3,
	cell_dir_offsets:  [NUM_SM_CELLS]Vec3,   // slight angular fan
	hits:              [NUM_SM_CELLS]Cell_Hit,
	prev_pos:          [NUM_SM_CELLS]Vec3,
	probed_once:       [NUM_SM_CELLS]bool,

	cooldown:          f32,
	pulse_anim:        f32,

	identified:        [16]bool,
	unique_ids:        int,

	completed:         bool,
	message:           cstring,
	message_timer:     f32,
	show_help:         bool,
}

@(private = "file")
l6: L6_State

l6_eye_vtable :: proc() -> Level_Vtable {
	return {
		init    = l6_eye_init,
		update  = l6_eye_update,
		draw    = l6_eye_draw,
		draw_ui = l6_eye_draw_ui,
		cleanup = l6_eye_cleanup,
	}
}

l6_eye_init :: proc(game: ^Game_State) {
	l6 = {}
	l6.show_help     = true
	l6.message       = "Optic array online — 9 receptors firing in parallel.\nEach is its own Learning Module. They vote with each other.\nWatch the SDR collapse. This is the Thousand Brains moment."
	l6.message_timer = 10

	game.ship.pos     = {0, 0, -8}
	game.ship.heading = 0
	game.ship.vel     = {0, 0, 0}
	game.ship.speed   = 0
	clear(&game.ship.trail)

	// 3x3 patch — body-frame offsets in the ship's XY plane (forward = +Z)
	for r in 0..<3 {
		for c in 0..<3 {
			i := r * 3 + c
			fx := f32(c - 1)
			fy := f32(r - 1)
			// position offset on a small patch
			l6.cell_body_offsets[i] = Vec3{fx * EYE_PATCH_HALF, fy * EYE_PATCH_HALF, 0}
			// slight angular fan — cells away from center aim outward
			l6.cell_dir_offsets[i] = Vec3{fx * 0.04, fy * 0.04, 0}
		}
	}

	// Pre-load object models
	seed_world_objects(&game.model_db, &game.world)

	// Initialize all 9 LMs in inference mode
	for i in 0..<NUM_SM_CELLS {
		lm_init(&game.lms[i], i)
		lm_start_inference(&game.lms[i], &game.model_db)
		l6.probed_once[i] = false
	}

	game.camera = rl.Camera3D{
		position   = {0, 22, 18},
		target     = {0, 0, 0},
		up         = {0, 1, 0},
		fovy       = 60,
		projection = .PERSPECTIVE,
	}
}

// Compute the world-space origin and direction for cell i, given ship state
@(private = "file")
l6_cell_ray :: proc(game: ^Game_State, i: int) -> (origin, dir: Vec3) {
	ship := &game.ship
	fwd := ship_forward(ship)
	// Build a body-frame basis: forward = fwd, right = -ship_yaw_left, up = world up (approx)
	world_up := Vec3{0, 1, 0}
	right := linalg.normalize(linalg.cross(world_up, fwd))
	up := linalg.normalize(linalg.cross(fwd, right))

	off := l6.cell_body_offsets[i]
	doff := l6.cell_dir_offsets[i]

	origin = ship.pos + right * off.x + up * off.y + fwd * 0.4
	dir = linalg.normalize(fwd + right * doff.x + up * doff.y)
	return
}

@(private = "file")
l6_pulse_all :: proc(game: ^Game_State) {
	l6.pulse_anim = 1.0

	// First pass: raycast all cells and build CMP messages
	cmps: [NUM_SM_CELLS]CMP_Message
	valid: [NUM_SM_CELLS]bool
	disps: [NUM_SM_CELLS]Vec3

	for i in 0..<NUM_SM_CELLS {
		origin, dir := l6_cell_ray(game, i)
		idx, hit, normal, _ := l6_raycast_ranged(&game.world, origin, dir, LASER_MAX_RANGE)
		if idx < 0 {
			l6.hits[i] = Cell_Hit{ hit = false }
			valid[i] = false
			continue
		}
		obj := &game.world.objects[idx]
		l6.hits[i] = Cell_Hit{
			hit    = true,
			world  = hit,
			normal = normal,
			wobj   = idx,
		}
		cmps[i] = CMP_Message{
			location    = hit,
			orientation = normal,
			features    = Features{
				roughness   = obj.material.roughness,
				temperature = obj.material.temperature,
				color       = obj.material.color,
			},
			confidence  = 1.0,
		}
		valid[i] = true
		// Displacement for this cell = movement since its last pulse
		disps[i] = l6.probed_once[i] ? origin - l6.prev_pos[i] : Vec3{0, 0, 0}
		l6.prev_pos[i] = origin
		l6.probed_once[i] = true
	}

	// Second pass: lm_step each LM with its own CMP
	for i in 0..<NUM_SM_CELLS {
		if !valid[i] do continue
		lm_step(&game.lms[i], cmps[i], disps[i], &game.model_db)
	}

	// Third pass: lateral voting — every LM broadcasts to every other LM,
	// using the world-frame offset between their sensor positions
	for sender in 0..<NUM_SM_CELLS {
		if !valid[sender] do continue
		vote, ok := lm_generate_vote(&game.lms[sender])
		if !ok do continue
		for receiver in 0..<NUM_SM_CELLS {
			if receiver == sender do continue
			if game.lms[receiver].converged do continue
			offset := l6.prev_pos[receiver] - l6.prev_pos[sender]
			lm_receive_vote(&game.lms[receiver], vote, offset, &game.model_db)
		}
	}
}

// Reuse the level-5 sphere raycast logic but with explicit range arg
@(private = "file")
l6_raycast_ranged :: proc(world: ^World, origin, dir: Vec3, max_range: f32) -> (idx: int, hit: Vec3, normal: Vec3, dist: f32) {
	idx = -1
	dist = max_range + 1
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
	if idx < 0 || dist > max_range {
		return -1, origin + dir * max_range, dir, max_range
	}
	hit = origin + dir * dist
	normal = linalg.normalize(hit - world.objects[idx].pos)
	return
}

l6_eye_update :: proc(game: ^Game_State, dt: f32) {
	if rl.IsKeyPressed(.ESCAPE) { popup_show(game, .Confirm_Leave_Level); return }
	if rl.IsKeyPressed(.H)      { l6.show_help = !l6.show_help }

	if rl.IsKeyPressed(.N) {
		for i in 0..<NUM_SM_CELLS {
			lm_init(&game.lms[i], i)
			lm_start_inference(&game.lms[i], &game.model_db)
			l6.probed_once[i] = false
		}
		l6.message       = "NEW EPISODE — all 9 LMs reset."
		l6.message_timer = 2
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

	if l6.cooldown > 0   do l6.cooldown -= dt
	if l6.pulse_anim > 0 do l6.pulse_anim -= dt * 2

	if (rl.IsKeyPressed(.F) || (rl.IsKeyDown(.SPACE) && l6.cooldown <= 0)) && !l6.completed {
		l6_pulse_all(game)
		l6.cooldown = EYE_COOLDOWN
	}

	// Identification: count distinct objects ≥2 LMs converged on
	winner_votes := [MAX_OBJECTS]int{}
	for i in 0..<NUM_SM_CELLS {
		lm := &game.lms[i]
		if lm.converged && lm.winner_obj >= 0 && lm.winner_obj < MAX_OBJECTS {
			winner_votes[lm.winner_obj] += 1
		}
	}
	for oi in 0..<game.model_db.object_count {
		if winner_votes[oi] >= 2 && oi < len(l6.identified) && !l6.identified[oi] {
			l6.identified[oi] = true
			l6.unique_ids += 1
			name := game.model_db.objects[oi].name
			l6.message = fmt.ctprintf("Identified: %s  (%d/%d)\n[N] for new episode and aim elsewhere.",
				name, l6.unique_ids, EYE_TARGETS)
			l6.message_timer = 4

			if l6.unique_ids >= EYE_TARGETS && !l6.completed {
				l6.completed = true
				game.levels[Level_ID.Eye].completed = true
				game.levels[Level_ID.Sonar].unlocked = true
				save_write(game)
				popup_show_delayed(game, .Level_Complete, 1.5)
			}
		}
	}

	// follow camera
	fwd := ship_forward(ship)
	game.camera.position = ship.pos + Vec3{0, 18, 0} - fwd * 12
	game.camera.target   = ship.pos + fwd * 4

	if l6.message_timer > 0 do l6.message_timer -= dt
}

// ── 3D draw ─────────────────────────────────────────────────────────────────

l6_eye_draw :: proc(game: ^Game_State) {
	rl.BeginMode3D(game.camera)
	world_draw(&game.world, true)
	ship_draw(&game.ship)
	ship_draw_trail(&game.ship)

	// Identified halos
	for i in 0..<len(game.world.objects) {
		if !l6.identified[i] do continue
		obj := &game.world.objects[i]
		rl.DrawSphereWires(obj.pos, obj.size.x + 0.3, 10, 10, Color{120, 255, 160, 180})
	}

	// Draw all 9 sensor cells: small dots on the ship nose, with their beams
	for i in 0..<NUM_SM_CELLS {
		origin, dir := l6_cell_ray(game, i)
		// Cell dot
		rl.DrawSphere(origin, 0.08, Color{180, 220, 255, 220})

		// Beam — bright on pulse, faint otherwise
		idx, hit, normal, _ := l6_raycast_ranged(&game.world, origin, dir, LASER_MAX_RANGE)
		end := idx >= 0 ? hit : origin + dir * LASER_MAX_RANGE
		beam_alpha: u8 = u8(40 + l6.pulse_anim * 200)
		rl.DrawLine3D(origin, end, Color{120, 200, 255, beam_alpha})

		// Hit marker
		if idx >= 0 && l6.pulse_anim > 0 {
			c := Color{120, 220, 255, u8(l6.pulse_anim * 200)}
			rl.DrawSphere(hit, 0.12 + (1 - l6.pulse_anim) * 0.2, c)
			rl.DrawLine3D(hit, hit + normal * 0.6, Color{180, 240, 255, beam_alpha})
		}
	}

	rl.EndMode3D()
}

// ── HUD ─────────────────────────────────────────────────────────────────────

l6_eye_draw_ui :: proc(game: ^Game_State) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	db := &game.model_db

	// ── Top-left status ──────────────────────────────────────────────────
	pw, ph: f32 = 320, 110
	rl.DrawRectangle(10, 10, i32(pw), i32(ph), Color{0, 0, 0, 150})
	rl.DrawRectangleLinesEx({10, 10, pw, ph}, 1, Color{60, 80, 120, 150})
	rl.DrawText("OPTIC ARRAY  —  9 LMs", 20, 18, 14, Color{180, 220, 255, 230})
	rl.DrawText(fmt.ctprintf("Identified: %d / %d", l6.unique_ids, EYE_TARGETS),
		20, 38, 16, Color{120, 255, 160, 220})

	// Count converged LMs
	conv := 0
	hit_count := 0
	for i in 0..<NUM_SM_CELLS {
		if game.lms[i].converged do conv += 1
		if l6.hits[i].hit         do hit_count += 1
	}
	rl.DrawText(fmt.ctprintf("Converged LMs: %d / %d", conv, NUM_SM_CELLS),
		20, 60, 14, Color{200, 220, 240, 220})
	rl.DrawText(fmt.ctprintf("Last pulse: %d / %d hit", hit_count, NUM_SM_CELLS),
		20, 80, 14, Color{200, 220, 240, 200})

	// ── Per-cell mini-grid (left side, below status) ─────────────────────
	grid_x: f32 = 10
	grid_y: f32 = f32(ph) + 28
	cell_w: f32 = 100
	cell_h: f32 = 70
	gap:    f32 = 4

	rl.DrawText("CELL STATUS (3x3 patch)", i32(grid_x), i32(grid_y) - 18, 13,
		Color{150, 170, 200, 200})

	for r in 0..<3 {
		for c in 0..<3 {
			i := r * 3 + c
			cx := grid_x + f32(c) * (cell_w + gap)
			cy := grid_y + f32(r) * (cell_h + gap)
			lm := &game.lms[i]

			// Background
			rl.DrawRectangle(i32(cx), i32(cy), i32(cell_w), i32(cell_h),
				Color{0, 0, 0, 150})
			border := Color{60, 80, 120, 180}
			if lm.converged do border = Color{120, 255, 160, 220}
			rl.DrawRectangleLines(i32(cx), i32(cy), i32(cell_w), i32(cell_h), border)

			// Cell ID
			rl.DrawText(fmt.ctprintf("LM%d", i), i32(cx) + 4, i32(cy) + 3, 11,
				Color{180, 200, 220, 200})

			// Active hypotheses fraction
			active := lm_active_count(lm)
			total  := lm.hyp_count
			frac   := total > 0 ? f32(active) / f32(total) : 0
			rl.DrawRectangle(i32(cx) + 4, i32(cy) + 18, i32(cell_w) - 8, 8,
				Color{25, 25, 35, 200})
			rl.DrawRectangle(i32(cx) + 4, i32(cy) + 18, i32((cell_w - 8) * frac), 8,
				Color{120, 200, 255, 200})
			rl.DrawText(fmt.ctprintf("%d/%d", active, total),
				i32(cx) + 4, i32(cy) + 30, 10, Color{160, 180, 200, 200})

			// MLH name (if any)
			if lm.mlh_idx >= 0 && lm.mlh_idx < lm.hyp_count {
				mlh := &lm.hypotheses[lm.mlh_idx]
				if mlh.object_idx < db.object_count {
					rl.DrawText(db.objects[mlh.object_idx].name,
						i32(cx) + 4, i32(cy) + 44, 10, Color{255, 220, 100, 220})
				}
			}

			// Convergence pip
			if lm.converged {
				rl.DrawText("✓", i32(cx) + i32(cell_w) - 14, i32(cy) + 3, 13,
					Color{120, 255, 160, 230})
			}
		}
	}

	// ── SDR union panel (right side) ─────────────────────────────────────
	sdr_x := sw - 410
	sdr_y: f32 = 10
	sdr_w: f32 = 400
	sdr_h: f32 = 320
	rl.DrawRectangle(i32(sdr_x), i32(sdr_y), i32(sdr_w), i32(sdr_h),
		Color{0, 0, 0, 180})
	rl.DrawRectangleLinesEx({sdr_x, sdr_y, sdr_w, sdr_h}, 1,
		Color{100, 160, 220, 180})
	rl.DrawText("SDR — UNION OF ACTIVE HYPOTHESES", i32(sdr_x) + 10, i32(sdr_y) + 8, 13,
		Color{120, 180, 255, 220})
	rl.DrawText("rows = object   cols = rotation bucket   intensity = #LMs voting",
		i32(sdr_x) + 10, i32(sdr_y) + 26, 11, Color{140, 160, 190, 180})

	// Build the union: for each (object, rotation_bucket), how many LMs have
	// an active hypothesis there
	n_rot := N_INIT_ROTS
	union_grid := make([dynamic]int, db.object_count * n_rot, allocator = context.temp_allocator)
	defer delete(union_grid)

	for lm_i in 0..<NUM_SM_CELLS {
		lm := &game.lms[lm_i]
		// Per-LM, mark which (obj, rot) buckets have at least one active hyp
		seen := make([]bool, db.object_count * n_rot, allocator = context.temp_allocator)
		defer delete(seen)
		for hi in 0..<lm.hyp_count {
			h := &lm.hypotheses[hi]
			if !h.active do continue
			// Rotation bucket — derived from index since we seeded N_INIT_ROTS per node
			rot_b := hi % n_rot
			cell  := h.object_idx * n_rot + rot_b
			if cell >= 0 && cell < len(seen) && !seen[cell] {
				seen[cell] = true
				union_grid[cell] += 1
			}
		}
	}

	// Draw the SDR
	cells_x := i32(sdr_x) + 20
	cells_y := i32(sdr_y) + 50
	cell_px: i32 = 22
	cell_gap: i32 = 3
	for oi in 0..<db.object_count {
		// Row label
		rl.DrawText(db.objects[oi].name, cells_x - 12, cells_y + i32(oi) * (cell_px + cell_gap), 10,
			Color{180, 200, 220, 200})
		// (label drawn before cells so it appears on the left)
	}
	cells_x += 92 // shift right to make room for row labels

	for oi in 0..<db.object_count {
		for ri in 0..<n_rot {
			cell := oi * n_rot + ri
			x := cells_x + i32(ri) * (cell_px + cell_gap)
			y := cells_y + i32(oi) * (cell_px + cell_gap)
			intensity := f32(union_grid[cell]) / f32(NUM_SM_CELLS)
			if union_grid[cell] == 0 {
				rl.DrawRectangle(x, y, cell_px, cell_px, Color{25, 25, 35, 200})
			} else {
				rl.DrawRectangle(x, y, cell_px, cell_px,
					Color{u8(80 + intensity * 175), u8(160 + intensity * 95), 255, 255})
			}
			rl.DrawRectangleLines(x, y, cell_px, cell_px, Color{60, 80, 100, 150})
		}
	}

	// SDR stats
	total_active := 0
	for v in union_grid do total_active += v > 0 ? 1 : 0
	max_cells := db.object_count * n_rot
	stats_y := i32(sdr_y) + i32(sdr_h) - 30
	rl.DrawText(fmt.ctprintf("Union sparsity: %d / %d cells lit  (%.0f%%)",
			total_active, max_cells, 100 * f32(total_active) / f32(max_cells)),
		i32(sdr_x) + 10, stats_y, 13, Color{180, 200, 230, 200})

	// ── Message overlay ──────────────────────────────────────────────────
	if l6.message_timer > 0 && l6.message != nil {
		alpha := u8(min(l6.message_timer * 1.5, 1) * 255)
		msg_w := rl.MeasureText(l6.message, 18)
		mx := i32(sw / 2) - msg_w / 2 - 200
		my := i32(sh) - 100
		rl.DrawRectangle(mx - 14, my - 8, msg_w + 28, 60, Color{0, 0, 0, alpha / 2})
		rl.DrawText(l6.message, mx, my, 18, Color{255, 255, 255, alpha})
	}

	if l6.show_help {
		rl.DrawText("[WASD] Fly   [F] Pulse all 9 cells   [SPACE] Auto-pulse   [N] New episode   [H] Help   [ESC] Back",
			10, i32(sh) - 28, 13, Color{80, 100, 140, 150})
	}

	rl.DrawText("LEVEL 6: SENSOR ARRAY", i32(sw) - 240, i32(sh) - 28, 16,
		Color{180, 220, 255, 200})
}

l6_eye_cleanup :: proc(game: ^Game_State) {}
