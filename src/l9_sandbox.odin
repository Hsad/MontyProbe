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
SANDBOX_CMP_LOG       :: 10

Sandbox_Mode :: enum { Single_Laser, Optic_Array }

@(private = "file")
Cmp_Log_Entry :: struct {
	t:          f32,        // GetTime() at pulse
	valid:      bool,       // false = "miss"
	cell_idx:   int,        // -1 for single laser, 0..8 for array
	obj_name:   cstring,
	cmp:        CMP_Message,
}

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

	// CMP message log (ring buffer) — every probe appends here
	cmp_log:            [SANDBOX_CMP_LOG]Cmp_Log_Entry,
	cmp_log_head:       int,
	cmp_log_count:      int,

	// Step diagnostics for LM 0 (the "deep view" focus)
	last_active:        int,
	pruned_last_step:   int,
	mlh_evidence_prev:  f32,
	pulses_total:       int,

	// Time when LM 0 most recently converged (for the "time to convergence" stat)
	converge_time:      f32,
	converge_steps:     int,

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
log_append :: proc(entry: Cmp_Log_Entry) {
	l9.cmp_log[l9.cmp_log_head] = entry
	l9.cmp_log_head = (l9.cmp_log_head + 1) % SANDBOX_CMP_LOG
	if l9.cmp_log_count < SANDBOX_CMP_LOG do l9.cmp_log_count += 1
}

// Capture LM 0 state before lm_step so we can show what changed
@(private = "file")
diag_pre :: proc(game: ^Game_State) {
	lm := &game.lms[0]
	l9.last_active        = lm_active_count(lm)
	l9.mlh_evidence_prev  = 0
	if lm.mlh_idx >= 0 && lm.mlh_idx < lm.hyp_count {
		l9.mlh_evidence_prev = lm.hypotheses[lm.mlh_idx].evidence
	}
}

@(private = "file")
diag_post :: proc(game: ^Game_State) {
	lm := &game.lms[0]
	now_active := lm_active_count(lm)
	if l9.last_active > now_active {
		l9.pruned_last_step = l9.last_active - now_active
	} else {
		l9.pruned_last_step = 0
	}
	// Mark convergence time on the transition
	if lm.converged && l9.converge_time == 0 {
		l9.converge_time  = f32(rl.GetTime())
		l9.converge_steps = lm.step_count
	}
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
	l9.pulses_total += 1
	now := f32(rl.GetTime())

	if idx < 0 {
		l9.last_cmp_valid = false
		l9.message       = "Laser missed."
		l9.message_timer = 1.0
		log_append({t = now, valid = false})
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
	diag_pre(game)
	lm_step(lm, cmp, disp, &game.model_db)
	diag_post(game)
	if lm.converged && !was_converged {
		l9_record_id(game, lm)
	}
	log_append({t = now, valid = true, cell_idx = -1, obj_name = obj.name, cmp = cmp})
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
	l9.pulses_total += 1
	now := f32(rl.GetTime())
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
			log_append({t = now, valid = false, cell_idx = i})
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
		disps[i] = Vec3{0, 0, 0}
		log_append({t = now, valid = true, cell_idx = i, obj_name = obj.name, cmp = cmps[i]})
	}

	// Step each LM (capture diag around LM 0 only)
	prev_converged: [SANDBOX_PATCH_CELLS]bool
	for i in 0..<SANDBOX_PATCH_CELLS {
		prev_converged[i] = game.lms[i].converged
	}
	diag_pre(game)
	for i in 0..<SANDBOX_PATCH_CELLS {
		if !valid[i] do continue
		lm_step(&game.lms[i], cmps[i], disps[i], &game.model_db)
	}
	diag_post(game)

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
	l9.probed_once       = false
	l9.last_active       = 0
	l9.pruned_last_step  = 0
	l9.mlh_evidence_prev = 0
	l9.converge_time     = 0
	l9.converge_steps    = 0
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

// Find top-N hypotheses by evidence across all objects (active only).
@(private = "file")
top_hypotheses :: proc(lm: ^Learning_Module, n: int, out_idx: []int, out_evid: []f32) -> int {
	for i in 0..<n {
		out_idx[i] = -1
		out_evid[i] = -99999
	}
	count := 0
	for hi in 0..<lm.hyp_count {
		h := &lm.hypotheses[hi]
		if !h.active do continue
		e := h.evidence
		// Insertion into top-N
		pos := n
		for j in 0..<n {
			if e > out_evid[j] { pos = j; break }
		}
		if pos < n {
			// shift right from pos
			for j := n - 1; j > pos; j -= 1 {
				out_evid[j] = out_evid[j - 1]
				out_idx[j]  = out_idx[j - 1]
			}
			out_evid[pos] = e
			out_idx[pos]  = hi
			if count < n do count += 1
		}
	}
	return count
}

// Rotation angle (radians) from identity for display
@(private = "file")
rot_angle_from_identity :: proc(r: Mat3) -> f32 {
	return rotation_angle_between(r, MAT3_IDENTITY)
}

l9_sandbox_draw_ui :: proc(game: ^Game_State) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	db := &game.model_db
	lm0 := &game.lms[0]

	mode_label: cstring = "SINGLE LASER"
	mode_c := Color{255, 140, 140, 220}
	if l9.mode == .Optic_Array {
		mode_label = "OPTIC ARRAY (9 LMs)"
		mode_c = Color{180, 220, 255, 230}
	}

	// ── Top-left status ─────────────────────────────────────────────────
	pw, ph: f32 = 320, 134
	rl.DrawRectangle(10, 10, i32(pw), i32(ph), Color{0, 0, 0, 160})
	rl.DrawRectangleLinesEx({10, 10, pw, ph}, 1, Color{60, 80, 120, 150})
	rl.DrawText(mode_label, 20, 18, 16, mode_c)
	rl.DrawText("[TAB] cycle mode", 20, 40, 12, Color{120, 140, 170, 200})
	rl.DrawText(fmt.ctprintf("pos  x:%.0f  z:%.0f", game.ship.pos.x, game.ship.pos.z),
		20, 60, 13, Color{200, 220, 240, 220})
	rl.DrawText(fmt.ctprintf("objects in view: %d", len(game.world.objects)),
		20, 78, 13, Color{200, 220, 240, 220})
	rl.DrawText(fmt.ctprintf("model_db: %d objects", db.object_count),
		20, 96, 13, Color{200, 220, 240, 220})
	rl.DrawText(fmt.ctprintf("pulses total: %d", l9.pulses_total),
		20, 114, 13, Color{200, 220, 240, 220})

	// ── LM 0 DEEP VIEW (left column, below status) ──────────────────────
	dv_x: f32 = 10
	dv_y: f32 = ph + 18
	dv_w: f32 = 380
	dv_h: f32 = sh - dv_y - 170    // leave room for log + footer
	rl.DrawRectangle(i32(dv_x), i32(dv_y), i32(dv_w), i32(dv_h),
		Color{0, 0, 0, 180})
	rl.DrawRectangleLinesEx({dv_x, dv_y, dv_w, dv_h}, 1, Color{100, 160, 220, 180})
	rl.DrawText("LM 0  —  DEEP VIEW", i32(dv_x) + 10, i32(dv_y) + 8, 15,
		Color{120, 180, 255, 230})
	rl.DrawText(fmt.ctprintf("steps: %d   active: %d / %d",
			lm0.step_count, lm_active_count(lm0), lm0.hyp_count),
		i32(dv_x) + 10, i32(dv_y) + 28, 12, Color{180, 200, 220, 200})
	if l9.pruned_last_step > 0 {
		rl.DrawText(fmt.ctprintf("(pruned %d last step)", l9.pruned_last_step),
			i32(dv_x) + 200, i32(dv_y) + 28, 12, Color{255, 180, 100, 200})
	}

	// MLH details
	my := i32(dv_y) + 50
	rl.DrawText("MLH", i32(dv_x) + 10, my, 12, Color{160, 180, 200, 200})
	my += 18
	if lm0.mlh_idx >= 0 && lm0.mlh_idx < lm0.hyp_count {
		mlh := &lm0.hypotheses[lm0.mlh_idx]
		mlh_obj_name: cstring = "—"
		if mlh.object_idx >= 0 && mlh.object_idx < db.object_count {
			mlh_obj_name = db.objects[mlh.object_idx].name
		}
		rl.DrawText(fmt.ctprintf("  object: %s", mlh_obj_name),
			i32(dv_x) + 10, my, 13, Color{255, 220, 100, 230}); my += 16
		rl.DrawText(fmt.ctprintf("  evidence: %.2f  (prev %.2f, Δ%+.2f)",
				mlh.evidence, l9.mlh_evidence_prev, mlh.evidence - l9.mlh_evidence_prev),
			i32(dv_x) + 10, my, 12, Color{200, 220, 240, 220}); my += 14
		rl.DrawText(fmt.ctprintf("  loc: (%+.1f, %+.1f, %+.1f)",
				mlh.location.x, mlh.location.y, mlh.location.z),
			i32(dv_x) + 10, my, 12, Color{180, 200, 220, 200}); my += 14
		ang := rot_angle_from_identity(mlh.rotation) * 180 / 3.14159
		rl.DrawText(fmt.ctprintf("  rot: %.0f° (from identity)", ang),
			i32(dv_x) + 10, my, 12, Color{180, 200, 220, 200}); my += 18
	} else {
		rl.DrawText("  (no MLH yet — pulse to start)", i32(dv_x) + 10, my, 13,
			Color{140, 160, 190, 200}); my += 30
	}

	// Top-5 hypotheses
	rl.DrawText("TOP HYPOTHESES", i32(dv_x) + 10, my, 12, Color{160, 180, 200, 200}); my += 18
	top_idx:  [5]int
	top_evid: [5]f32
	n_top := top_hypotheses(lm0, 5, top_idx[:], top_evid[:])
	max_top: f32 = 0.001
	if n_top > 0 do max_top = max(top_evid[0], 0.001)
	for i in 0..<n_top {
		h := &lm0.hypotheses[top_idx[i]]
		oname: cstring = "?"
		if h.object_idx >= 0 && h.object_idx < db.object_count {
			oname = db.objects[h.object_idx].name
		}
		bar_w := i32(dv_w) - 180
		fill  := i32(clamp(top_evid[i] / max_top, 0, 1) * f32(bar_w))
		rl.DrawText(oname, i32(dv_x) + 10, my, 12, Color{220, 230, 240, 220})
		rl.DrawRectangle(i32(dv_x) + 140, my + 1, bar_w, 10, Color{25, 25, 35, 200})
		c := mode_c
		if i == 0 { c = Color{255, 220, 100, 230} }
		if fill > 0 do rl.DrawRectangle(i32(dv_x) + 140, my + 1, fill, 10, c)
		rl.DrawText(fmt.ctprintf("%.2f", top_evid[i]),
			i32(dv_x) + 140 + bar_w + 4, my, 12, Color{200, 220, 240, 220})
		my += 14
	}
	my += 6

	// Threshold gauges
	rl.DrawText("THRESHOLDS", i32(dv_x) + 10, my, 12, Color{160, 180, 200, 200}); my += 18

	mlh_ev: f32 = 0
	rival_ev: f32 = 0
	if lm0.mlh_idx >= 0 && lm0.mlh_idx < lm0.hyp_count {
		mlh_ev = lm0.hypotheses[lm0.mlh_idx].evidence
		best_per_obj := [MAX_OBJECTS]f32{}
		lm_best_evidence_per_object(lm0, db, best_per_obj[:])
		mlh_obj := lm0.hypotheses[lm0.mlh_idx].object_idx
		for oi in 0..<db.object_count {
			if oi == mlh_obj do continue
			if best_per_obj[oi] > rival_ev do rival_ev = best_per_obj[oi]
		}
	}

	gauge_w: f32 = dv_w - 24
	draw_gauge :: proc(x, y: i32, w: f32, label: cstring, value, threshold, scale: f32, ok: bool) {
		rl.DrawText(label, x, y, 12, Color{200, 220, 240, 220})
		bar_x := x + 90
		bar_y := y + 2
		bar_w := i32(w) - 90 - 80
		rl.DrawRectangle(bar_x, bar_y, bar_w, 8, Color{25, 25, 35, 200})
		fill := i32(clamp(value / scale, 0, 1) * f32(bar_w))
		c := ok ? Color{120, 255, 160, 220} : Color{180, 200, 240, 220}
		if fill > 0 do rl.DrawRectangle(bar_x, bar_y, fill, 8, c)
		// Threshold marker
		thr_x := bar_x + i32(clamp(threshold / scale, 0, 1) * f32(bar_w))
		rl.DrawLine(thr_x, bar_y - 2, thr_x, bar_y + 10, Color{255, 220, 100, 230})
		rl.DrawText(fmt.ctprintf("%.1f/%.1f", value, threshold),
			bar_x + bar_w + 4, y, 11, Color{200, 220, 240, 200})
	}

	// Evidence vs converge_min_evid
	draw_gauge(i32(dv_x) + 10, my, gauge_w, "evidence", mlh_ev, lm0.converge_min_evid,
		lm0.converge_min_evid * 2.5, lm0.crit_evidence)
	my += 16
	// Margin vs converge_gap (margin = MLH - best rival)
	margin := mlh_ev - rival_ev
	draw_gauge(i32(dv_x) + 10, my, gauge_w, "margin", margin, lm0.converge_gap,
		lm0.converge_gap * 2.5, lm0.crit_margin)
	my += 16
	// Pose uniqueness — simple ok/not via crit_pose; "value" is symbolic
	pose_val: f32 = lm0.crit_pose ? 1.0 : 0.0
	draw_gauge(i32(dv_x) + 10, my, gauge_w, "pose unique", pose_val, 1.0, 1.0,
		lm0.crit_pose)
	my += 16
	// Stable steps toward symmetry path
	draw_gauge(i32(dv_x) + 10, my, gauge_w, "stable", f32(lm0.stable_steps),
		f32(lm0.sym_required_steps), f32(lm0.sym_required_steps) * 1.5,
		lm0.is_symmetric)
	my += 20

	// Convergence state line
	conv_text: cstring = "still working..."
	conv_c := Color{200, 220, 240, 200}
	if lm0.converged {
		conv_text = "✓ CONVERGED"
		conv_c = Color{120, 255, 160, 230}
		if lm0.is_symmetric { conv_text = "✓ converged (symmetric)" ; conv_c = Color{220, 200, 100, 230} }
	}
	rl.DrawText(conv_text, i32(dv_x) + 10, my, 13, conv_c); my += 18

	// Last step diagnostics for the MLH
	if lm0.mlh_idx >= 0 && lm0.mlh_idx < lm0.hyp_count && lm0.step_count > 0 {
		info := &lm0.step_info[lm0.mlh_idx]
		rl.DrawText("LAST STEP (MLH)", i32(dv_x) + 10, my, 12, Color{160, 180, 200, 200}); my += 16
		if info.node_idx >= 0 {
			rl.DrawText(fmt.ctprintf("  node #%d  dist %.2f", info.node_idx, info.node_dist),
				i32(dv_x) + 10, my, 12, Color{200, 220, 240, 220}); my += 14
			rl.DrawText(fmt.ctprintf("  morph %+.2f   feat %.2f   Δ %+.2f",
					info.morphology_score, info.feature_score, info.delta),
				i32(dv_x) + 10, my, 12, Color{200, 220, 240, 220})
		} else {
			rl.DrawText("  (no node match — penalised)",
				i32(dv_x) + 10, my, 12, Color{220, 140, 100, 200})
		}
	}

	// ── Right-side archetype tally ──────────────────────────────────────
	right_x := sw - 360
	right_y: f32 = 10
	right_w: f32 = 350
	right_h: f32 = 38 + f32(len(proc_archetypes)) * 24
	rl.DrawRectangle(i32(right_x), i32(right_y), i32(right_w), i32(right_h),
		Color{0, 0, 0, 170})
	rl.DrawRectangleLinesEx({right_x, right_y, right_w, right_h}, 1,
		Color{100, 160, 220, 180})
	rl.DrawText("ARCHETYPES IDENTIFIED", i32(right_x) + 10, i32(right_y) + 8, 13,
		Color{120, 180, 255, 220})
	for ai in 0..<len(proc_archetypes) {
		arch := &proc_archetypes[ai]
		y := i32(right_y) + 30 + i32(ai) * 24
		c := Color{u8(arch.material.color.x * 255),
		           u8(arch.material.color.y * 255),
		           u8(arch.material.color.z * 255), 255}
		rl.DrawRectangle(i32(right_x) + 10, y + 2, 18, 14, c)
		rl.DrawRectangleLines(i32(right_x) + 10, y + 2, 18, 14, Color{180, 200, 230, 200})
		rl.DrawText(arch.name, i32(right_x) + 34, y + 2, 13,
			l9.id_count[ai] > 0 ? Color{220, 240, 255, 230} : Color{140, 160, 190, 200})
		count_text: cstring = fmt.ctprintf("× %d", l9.id_count[ai])
		count_c := l9.id_count[ai] > 0 ? Color{120, 255, 160, 230} : Color{100, 110, 130, 180}
		rl.DrawText(count_text, i32(right_x) + i32(right_w) - 70, y + 2, 13, count_c)
	}

	// ── Right-side LM stats (under tally) ───────────────────────────────
	st_y := right_y + right_h + 10
	st_h: f32 = 130
	rl.DrawRectangle(i32(right_x), i32(st_y), i32(right_w), i32(st_h),
		Color{0, 0, 0, 170})
	rl.DrawRectangleLinesEx({right_x, st_y, right_w, st_h}, 1,
		Color{100, 160, 220, 180})
	rl.DrawText("LM FLEET STATS", i32(right_x) + 10, i32(st_y) + 8, 13,
		Color{120, 180, 255, 220})

	active_lms := 1
	if l9.mode == .Optic_Array do active_lms = SANDBOX_PATCH_CELLS
	conv_count := 0
	for i in 0..<active_lms {
		if game.lms[i].converged do conv_count += 1
	}
	rl.DrawText(fmt.ctprintf("active LMs: %d", active_lms),
		i32(right_x) + 10, i32(st_y) + 32, 13, Color{200, 220, 240, 220})
	rl.DrawText(fmt.ctprintf("converged:  %d / %d", conv_count, active_lms),
		i32(right_x) + 10, i32(st_y) + 50, 13, Color{120, 255, 160, 220})
	if lm0.converged && l9.converge_steps > 0 {
		rl.DrawText(fmt.ctprintf("LM 0 conv:  %d steps", l9.converge_steps),
			i32(right_x) + 10, i32(st_y) + 68, 13, Color{180, 220, 255, 220})
	}
	// Convergence pills (inline) for LM 0
	lm_draw_convergence_inline(lm0, i32(right_x) + 10, i32(st_y) + 92)

	// ── CMP MESSAGE LOG (bottom strip) ──────────────────────────────────
	log_h: f32 = 130
	log_y := sh - log_h - 38
	log_x := dv_x + dv_w + 10
	log_w := right_x - log_x - 10
	rl.DrawRectangle(i32(log_x), i32(log_y), i32(log_w), i32(log_h),
		Color{0, 0, 0, 180})
	rl.DrawRectangleLinesEx({log_x, log_y, log_w, log_h}, 1, Color{100, 160, 220, 180})
	rl.DrawText("CMP MESSAGE LOG  (most recent → top)", i32(log_x) + 10, i32(log_y) + 6, 12,
		Color{120, 180, 255, 220})

	// Print newest-first
	now := f32(rl.GetTime())
	row_y := i32(log_y) + 26
	for i in 0..<l9.cmp_log_count {
		idx := (l9.cmp_log_head - 1 - i + SANDBOX_CMP_LOG) % SANDBOX_CMP_LOG
		e := &l9.cmp_log[idx]
		dt_ago := now - e.t
		row_c := Color{200, 220, 240, 220}
		if dt_ago > 2.5 do row_c = Color{120, 140, 170, 180}

		if !e.valid {
			tag: cstring = "miss"
			if e.cell_idx >= 0 do tag = fmt.ctprintf("c%d miss", e.cell_idx)
			rl.DrawText(fmt.ctprintf("[-%.1fs] %s", dt_ago, tag),
				i32(log_x) + 10, row_y, 11, Color{220, 140, 100, 200})
		} else {
			loc := e.cmp.location
			r  := e.cmp.features.roughness.?   or_else 0
			t_ := e.cmp.features.temperature.? or_else 0
			res := e.cmp.features.resonance.?  or_else 0
			c, _ := e.cmp.features.color.?

			prefix: cstring = "    "
			if e.cell_idx >= 0 do prefix = fmt.ctprintf("c%d  ", e.cell_idx)

			rl.DrawText(fmt.ctprintf("[-%.1fs] %s%s   loc(%+.0f,%+.0f)  rough %.2f  temp %.2f  reson %.2f",
					dt_ago, prefix, e.obj_name, loc.x, loc.z, r, t_, res),
				i32(log_x) + 30, row_y, 11, row_c)
			// Color swatch for the color feature
			rl.DrawRectangle(i32(log_x) + 10, row_y, 14, 11,
				Color{u8(c.x * 255), u8(c.y * 255), u8(c.z * 255), 255})
		}
		row_y += 12
		if row_y > i32(log_y + log_h) - 12 do break
	}
	if l9.cmp_log_count == 0 {
		rl.DrawText("(no pulses yet — press [F])", i32(log_x) + 10, row_y, 12,
			Color{140, 160, 190, 200})
	}

	// ── Message overlay ─────────────────────────────────────────────────
	if l9.message_timer > 0 && l9.message != nil {
		alpha := u8(min(l9.message_timer * 1.5, 1) * 255)
		msg_w := rl.MeasureText(l9.message, 18)
		mx := i32(sw / 2) - msg_w / 2
		my := i32(sh - log_h - 100)
		rl.DrawRectangle(mx - 14, my - 8, msg_w + 28, 50, Color{0, 0, 0, alpha / 2})
		rl.DrawText(l9.message, mx, my, 18, Color{255, 255, 255, alpha})
	}

	if l9.show_help {
		rl.DrawText("[WASD] Fly  [F] Pulse  [SPACE] Auto  [TAB] Mode  [N] New episode  [H] Help  [ESC] Back",
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
