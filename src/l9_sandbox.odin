package monty

import rl "vendor:raylib"
import "core:math"
import "core:math/linalg"
import "core:fmt"

// Level 9 — Sandbox
//
// An infinite procedurally-generated world (see world_proc.odin) with
// six object archetypes scattered on a deterministic hash grid. The
// model database is pre-loaded with all six archetypes, so the LM can
// recognise anything you encounter — the question is which sensor
// modality you want to use.
//
// Modes (cycle with [TAB]):
//   - SINGLE LASER : one forward beam, one LM. Aim and pulse.
//   - OPTIC ARRAY  : 3x3 patch of receptors, 9 parallel LMs voting.
//
// Free exploration — no win condition. Identify whatever you like;
// the running tallies per archetype give a sense of what's out there.

SANDBOX_RANGE         :: 35.0
SANDBOX_COOLDOWN      :: 0.15
SANDBOX_PATCH_HALF    :: 0.45
SANDBOX_PATCH_CELLS   :: 9

Sandbox_Mode :: enum { Single_Laser, Optic_Array }

@(private = "file")
L9_State :: struct {
	mode:               Sandbox_Mode,
	cooldown:           f32,
	pulse_anim:         f32,

	// Single-laser bookkeeping
	last_cmp:           CMP_Message,
	last_cmp_obj:       cstring,
	last_cmp_world:     Vec3,
	last_cmp_valid:     bool,
	probes_total:       int,
	prev_pos:           Vec3,
	probed_once:        bool,

	// Optic-array bookkeeping (per-cell)
	cell_origins:       [SANDBOX_PATCH_CELLS]Vec3,
	cell_hits:          [SANDBOX_PATCH_CELLS]bool,
	cell_hit_pos:       [SANDBOX_PATCH_CELLS]Vec3,

	// Identifications per archetype
	id_count:           [len(proc_archetypes)]int,

	message:            cstring,
	message_timer:      f32,
	show_help:          bool,
}

@(private = "file")
l9: L9_State

l9_sandbox_vtable :: proc() -> Level_Vtable {
	return {
		init    = l9_sandbox_init,
		update  = l9_sandbox_update,
		draw    = l9_sandbox_draw,
		draw_ui = l9_sandbox_draw_ui,
		cleanup = l9_sandbox_cleanup,
	}
}

l9_sandbox_init :: proc(game: ^Game_State) {
	l9 = {}
	l9.mode          = .Single_Laser
	l9.show_help     = true
	l9.message       = "Sandbox: infinite procedural world.\n[TAB] toggle sensor mode   [F] pulse   [N] new episode"
	l9.message_timer = 8

	game.ship.pos     = {0, 0, 0}
	game.ship.heading = 0
	game.ship.vel     = {0, 0, 0}
	game.ship.speed   = 0
	clear(&game.ship.trail)

	// Pre-load archetypes — six target objects the LM can recognise
	seed_proc_archetypes(&game.model_db)

	// Fresh inference on all LMs (we'll use 1 or 9 depending on mode)
	for i in 0..<MAX_LMS {
		lm_init(&game.lms[i], i)
		lm_start_inference(&game.lms[i], &game.model_db)
	}

	// Initial streaming pass so there are objects to see immediately
	clear(&game.world.objects)
	world_proc_update(&game.world, game.ship.pos)

	game.camera = rl.Camera3D{
		position   = {0, 22, 18},
		target     = {0, 0, 0},
		up         = {0, 1, 0},
		fovy       = 60,
		projection = .PERSPECTIVE,
	}
}

@(private = "file")
l9_raycast :: proc(world: ^World, origin, dir: Vec3) -> (idx: int, hit: Vec3, normal: Vec3) {
	idx = -1
	best_t: f32 = SANDBOX_RANGE + 1
	for i in 0..<len(world.objects) {
		obj := &world.objects[i]
		r := obj.size.x
		if obj.size.y > r do r = obj.size.y
		if obj.size.z > r do r = obj.size.z
		t, h := ray_sphere(origin, dir, obj.pos, r)
		if h && t < best_t {
			best_t = t
			idx = i
		}
	}
	if idx < 0 || best_t > SANDBOX_RANGE {
		return -1, origin + dir * SANDBOX_RANGE, dir
	}
	hit = origin + dir * best_t
	normal = linalg.normalize(hit - world.objects[idx].pos)
	return
}

@(private = "file")
l9_record_id :: proc(game: ^Game_State, lm: ^Learning_Module) {
	if !lm.converged || lm.winner_obj < 0 do return
	if lm.winner_obj >= game.model_db.object_count do return
	name := game.model_db.objects[lm.winner_obj].name
	idx := proc_archetype_index(name)
	if idx < 0 do return
	l9.id_count[idx] += 1
}

@(private = "file")
l9_pulse_single :: proc(game: ^Game_State) {
	ship := &game.ship
	fwd := ship_forward(ship)
	idx, hit, normal := l9_raycast(&game.world, ship.pos, fwd)
	if idx < 0 {
		l9.last_cmp_valid = false
		l9.message       = "Laser missed."
		l9.message_timer = 1.0
		return
	}
	obj := &game.world.objects[idx]
	cmp := CMP_Message{
		location    = hit,
		orientation = normal,
		features    = Features{
			roughness   = obj.material.roughness,
			temperature = obj.material.temperature,
			color       = obj.material.color,
			resonance   = obj.material.resonance,
		},
		confidence  = 1.0,
	}
	l9.last_cmp       = cmp
	l9.last_cmp_obj   = obj.name
	l9.last_cmp_world = hit
	l9.last_cmp_valid = true
	l9.pulse_anim     = 1.0
	l9.probes_total  += 1

	disp: Vec3 = l9.probed_once ? ship.pos - l9.prev_pos : Vec3{0, 0, 0}
	l9.prev_pos       = ship.pos
	l9.probed_once    = true

	lm := &game.lms[0]
	was_converged := lm.converged
	lm_step(lm, cmp, disp, &game.model_db)
	if lm.converged && !was_converged {
		l9_record_id(game, lm)
	}
}

@(private = "file")
l9_cell_ray :: proc(game: ^Game_State, i: int) -> (origin, dir: Vec3) {
	ship := &game.ship
	fwd := ship_forward(ship)
	world_up := Vec3{0, 1, 0}
	right := linalg.normalize(linalg.cross(world_up, fwd))
	up := linalg.normalize(linalg.cross(fwd, right))

	r := i / 3
	c := i % 3
	fx := f32(c - 1)
	fy := f32(r - 1)

	origin = ship.pos + right * fx * SANDBOX_PATCH_HALF + up * fy * SANDBOX_PATCH_HALF + fwd * 0.4
	dir = linalg.normalize(fwd + right * fx * 0.04 + up * fy * 0.04)
	return
}

@(private = "file")
l9_pulse_array :: proc(game: ^Game_State) {
	l9.pulse_anim = 1.0
	cmps:  [SANDBOX_PATCH_CELLS]CMP_Message
	disps: [SANDBOX_PATCH_CELLS]Vec3
	valid: [SANDBOX_PATCH_CELLS]bool

	for i in 0..<SANDBOX_PATCH_CELLS {
		origin, dir := l9_cell_ray(game, i)
		l9.cell_origins[i] = origin
		idx, hit, normal := l9_raycast(&game.world, origin, dir)
		if idx < 0 {
			l9.cell_hits[i] = false
			valid[i] = false
			continue
		}
		obj := &game.world.objects[idx]
		l9.cell_hits[i] = true
		l9.cell_hit_pos[i] = hit
		cmps[i] = CMP_Message{
			location    = hit,
			orientation = normal,
			features    = Features{
				roughness   = obj.material.roughness,
				temperature = obj.material.temperature,
				color       = obj.material.color,
				resonance   = obj.material.resonance,
			},
			confidence  = 1.0,
		}
		valid[i] = true
		disps[i] = Vec3{0, 0, 0} // first probe per cell; movement handled coarsely
	}

	// Step each LM
	prev_converged: [SANDBOX_PATCH_CELLS]bool
	for i in 0..<SANDBOX_PATCH_CELLS {
		prev_converged[i] = game.lms[i].converged
	}
	for i in 0..<SANDBOX_PATCH_CELLS {
		if !valid[i] do continue
		lm_step(&game.lms[i], cmps[i], disps[i], &game.model_db)
	}

	// Lateral voting — every LM broadcasts to every other LM
	for sender in 0..<SANDBOX_PATCH_CELLS {
		if !valid[sender] do continue
		vote, ok := lm_generate_vote(&game.lms[sender])
		if !ok do continue
		for receiver in 0..<SANDBOX_PATCH_CELLS {
			if receiver == sender do continue
			if game.lms[receiver].converged do continue
			offset := l9.cell_origins[receiver] - l9.cell_origins[sender]
			lm_receive_vote(&game.lms[receiver], vote, offset, &game.model_db)
		}
	}

	// Record IDs on freshly converged LMs (de-dup: at most one per archetype per pulse)
	recorded_arch: [len(proc_archetypes)]bool
	for i in 0..<SANDBOX_PATCH_CELLS {
		lm := &game.lms[i]
		if lm.converged && !prev_converged[i] && lm.winner_obj >= 0 &&
		   lm.winner_obj < game.model_db.object_count {
			name := game.model_db.objects[lm.winner_obj].name
			a := proc_archetype_index(name)
			if a >= 0 && !recorded_arch[a] {
				recorded_arch[a] = true
				l9.id_count[a] += 1
			}
		}
	}
}

@(private = "file")
l9_reset_lms :: proc(game: ^Game_State) {
	for i in 0..<MAX_LMS {
		lm_init(&game.lms[i], i)
		lm_start_inference(&game.lms[i], &game.model_db)
	}
	l9.probed_once = false
}

l9_sandbox_update :: proc(game: ^Game_State, dt: f32) {
	if rl.IsKeyPressed(.ESCAPE) { popup_show(game, .Confirm_Leave_Level); return }
	if rl.IsKeyPressed(.H)      { l9.show_help = !l9.show_help }
	if rl.IsKeyPressed(.N) {
		l9_reset_lms(game)
		l9.message       = "NEW EPISODE — LMs reset (identification counts kept)."
		l9.message_timer = 2.5
	}
	if rl.IsKeyPressed(.TAB) {
		l9.mode = l9.mode == .Single_Laser ? .Optic_Array : .Single_Laser
		l9_reset_lms(game)
		mm: cstring = "SINGLE LASER mode"
		if l9.mode == .Optic_Array do mm = "OPTIC ARRAY mode (9 LMs)"
		l9.message       = mm
		l9.message_timer = 2.0
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
	ship.speed = clamp(ship.speed, -8, 18)
	ship_update(ship, dt)

	// Stream procedural world around the ship
	world_proc_update(&game.world, ship.pos)

	if l9.cooldown > 0   do l9.cooldown -= dt
	if l9.pulse_anim > 0 do l9.pulse_anim -= dt * 2

	if (rl.IsKeyPressed(.F) || (rl.IsKeyDown(.SPACE) && l9.cooldown <= 0)) {
		switch l9.mode {
		case .Single_Laser: l9_pulse_single(game)
		case .Optic_Array:  l9_pulse_array(game)
		}
		l9.cooldown = SANDBOX_COOLDOWN
	}

	// Follow camera
	fwd := ship_forward(ship)
	game.camera.position = ship.pos + Vec3{0, 18, 0} - fwd * 12
	game.camera.target   = ship.pos + fwd * 4

	if l9.message_timer > 0 do l9.message_timer -= dt
}

// ── 3D draw ─────────────────────────────────────────────────────────────────

l9_sandbox_draw :: proc(game: ^Game_State) {
	rl.BeginMode3D(game.camera)
	world_draw(&game.world, true)
	ship_draw(&game.ship)
	ship_draw_trail(&game.ship)

	fwd := ship_forward(&game.ship)
	switch l9.mode {
	case .Single_Laser:
		// Aim beam + pulse flash
		idx, hit, normal := l9_raycast(&game.world, game.ship.pos, fwd)
		end := idx >= 0 ? hit : game.ship.pos + fwd * SANDBOX_RANGE
		idle_a: u8 = u8(60 + l9.pulse_anim * 180)
		rl.DrawLine3D(game.ship.pos, end, Color{255, 120, 120, idle_a})
		if idx >= 0 {
			rl.DrawCircle3D(hit, 0.35, normal, 0,
				Color{255, 140, 140, u8(140 + l9.pulse_anim * 100)})
		}
		if l9.pulse_anim > 0 && l9.last_cmp_valid {
			rl.DrawSphere(l9.last_cmp_world, 0.25 + (1 - l9.pulse_anim) * 1.3,
				Color{255, 200, 150, u8(l9.pulse_anim * 220)})
		}

	case .Optic_Array:
		// Draw the 9 cells + beams
		for i in 0..<SANDBOX_PATCH_CELLS {
			origin, dir := l9_cell_ray(game, i)
			rl.DrawSphere(origin, 0.08, Color{180, 220, 255, 220})
			idx, hit, _ := l9_raycast(&game.world, origin, dir)
			end := idx >= 0 ? hit : origin + dir * SANDBOX_RANGE
			beam_a: u8 = u8(40 + l9.pulse_anim * 200)
			rl.DrawLine3D(origin, end, Color{120, 200, 255, beam_a})
			if idx >= 0 && l9.pulse_anim > 0 {
				rl.DrawSphere(hit, 0.12 + (1 - l9.pulse_anim) * 0.2,
					Color{120, 220, 255, u8(l9.pulse_anim * 200)})
			}
		}
	}

	rl.EndMode3D()
}

// ── HUD ─────────────────────────────────────────────────────────────────────

l9_sandbox_draw_ui :: proc(game: ^Game_State) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	db := &game.model_db

	// Top-left status
	pw, ph: f32 = 320, 130
	rl.DrawRectangle(10, 10, i32(pw), i32(ph), Color{0, 0, 0, 150})
	rl.DrawRectangleLinesEx({10, 10, pw, ph}, 1, Color{60, 80, 120, 150})

	mode_label: cstring = "SINGLE LASER"
	mode_c := Color{255, 140, 140, 220}
	if l9.mode == .Optic_Array {
		mode_label = "OPTIC ARRAY (9 LMs)"
		mode_c = Color{180, 220, 255, 230}
	}
	rl.DrawText(mode_label, 20, 18, 16, mode_c)
	rl.DrawText("[TAB] cycle mode", 20, 40, 13, Color{120, 140, 170, 200})

	rl.DrawText(fmt.ctprintf("Position  x:%.0f  z:%.0f", game.ship.pos.x, game.ship.pos.z),
		20, 64, 14, Color{200, 220, 240, 220})
	rl.DrawText(fmt.ctprintf("Objects in view: %d", len(game.world.objects)),
		20, 84, 14, Color{200, 220, 240, 220})

	// Active LM funnel summary
	active_lms := 1
	if l9.mode == .Optic_Array do active_lms = SANDBOX_PATCH_CELLS
	total_hyps := 0
	total_active := 0
	conv := 0
	for i in 0..<active_lms {
		lm := &game.lms[i]
		total_hyps   += lm.hyp_count
		total_active += lm_active_count(lm)
		if lm.converged do conv += 1
	}
	rl.DrawText(fmt.ctprintf("LMs converged: %d / %d", conv, active_lms),
		20, 104, 14, Color{120, 255, 160, 220})

	// Right-side archetype tally
	right_x := sw - 360
	right_y: f32 = 10
	right_w: f32 = 350
	right_h: f32 = 50 + f32(len(proc_archetypes)) * 30
	rl.DrawRectangle(i32(right_x), i32(right_y), i32(right_w), i32(right_h),
		Color{0, 0, 0, 170})
	rl.DrawRectangleLinesEx({right_x, right_y, right_w, right_h}, 1,
		Color{100, 160, 220, 180})
	rl.DrawText("ARCHETYPES IDENTIFIED", i32(right_x) + 10, i32(right_y) + 8, 14,
		Color{120, 180, 255, 220})

	for ai in 0..<len(proc_archetypes) {
		arch := &proc_archetypes[ai]
		y := i32(right_y) + 34 + i32(ai) * 28
		// Swatch
		c := Color{u8(arch.material.color.x * 255),
		           u8(arch.material.color.y * 255),
		           u8(arch.material.color.z * 255), 255}
		rl.DrawRectangle(i32(right_x) + 10, y + 2, 20, 16, c)
		rl.DrawRectangleLines(i32(right_x) + 10, y + 2, 20, 16, Color{180, 200, 230, 200})
		// Name
		rl.DrawText(arch.name, i32(right_x) + 38, y + 2, 14,
			l9.id_count[ai] > 0 ? Color{220, 240, 255, 230} : Color{140, 160, 190, 200})
		// Count
		count_text: cstring = fmt.ctprintf("× %d", l9.id_count[ai])
		count_c := l9.id_count[ai] > 0 ? Color{120, 255, 160, 230} : Color{100, 110, 130, 180}
		rl.DrawText(count_text, i32(right_x) + i32(right_w) - 80, y + 2, 14, count_c)
	}

	// Compact hypothesis funnel for the primary LM (lms[0])
	lm0 := &game.lms[0]
	if lm0.hyp_count > 0 {
		fy := i32(right_y + right_h) + 14
		rl.DrawText("LM 0 hypotheses", i32(right_x) + 10, fy, 12, Color{160, 180, 200, 200})
		rl.DrawRectangle(i32(right_x) + 10, fy + 16, i32(right_w) - 20, 10,
			Color{25, 25, 35, 200})
		af := f32(lm_active_count(lm0)) / f32(lm0.hyp_count)
		rl.DrawRectangle(i32(right_x) + 10, fy + 16,
			i32(af * f32(int(right_w) - 20)), 10, mode_c)
		mlh: cstring = "—"
		if lm0.mlh_idx >= 0 && lm0.mlh_idx < lm0.hyp_count {
			mlh_obj := lm0.hypotheses[lm0.mlh_idx].object_idx
			if mlh_obj >= 0 && mlh_obj < db.object_count {
				mlh = db.objects[mlh_obj].name
			}
		}
		rl.DrawText(fmt.ctprintf("MLH: %s", mlh), i32(right_x) + 10, fy + 30, 13,
			Color{255, 220, 100, 220})
		lm_draw_convergence_inline(lm0, i32(right_x) + 10, fy + 52)
	}

	// Message overlay
	if l9.message_timer > 0 && l9.message != nil {
		alpha := u8(min(l9.message_timer * 1.5, 1) * 255)
		msg_w := rl.MeasureText(l9.message, 18)
		mx := i32(sw / 2) - msg_w / 2 - 100
		my := i32(sh) - 80
		rl.DrawRectangle(mx - 14, my - 8, msg_w + 28, 50, Color{0, 0, 0, alpha / 2})
		rl.DrawText(l9.message, mx, my, 18, Color{255, 255, 255, alpha})
	}

	if l9.show_help {
		rl.DrawText("[WASD] Fly  [F] Pulse  [SPACE] Auto-pulse  [TAB] Mode  [N] New episode  [H] Help  [ESC] Back",
			10, i32(sh) - 28, 13, Color{80, 100, 140, 150})
	}

	rl.DrawText("SANDBOX — INFINITE WORLD", i32(sw) - 300, i32(sh) - 28, 16,
		Color{220, 200, 120, 200})
}

l9_sandbox_cleanup :: proc(game: ^Game_State) {
	// Wipe the procedural world so we don't leak streaming state into other levels
	clear(&game.world.objects)
	// Restore the fixed world for other levels
	world_cleanup(&game.world)
	world_init(&game.world)
}
