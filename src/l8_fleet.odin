package monty

import rl "vendor:raylib"
import "core:math"
import "core:math/linalg"
import "core:fmt"

// Level 8 — Fleet (Hierarchical Composition)
//
// Three drones, each running a lower-level Learning Module that
// identifies INDIVIDUAL world objects (same job as the Drones level).
// The mothership runs a HIGHER-LEVEL "compositional" matcher whose
// inputs are the lower LMs' winning object IDs at their world poses.
//
// Compositional models (e.g. "Refueling Outpost" = Fuel Tank + Beacon
// at a known relative offset) are matched against what the drones
// have identified. When the pieces are present at the right relative
// arrangement, the higher level fires.
//
// Monty concept: the same "features at a pose" algorithm runs at
// every level. Low level — features are point normals + colors,
// nodes are points on a surface. High level — features are part
// IDENTITIES, nodes are parts in object-relative space. Whole
// objects emerge from arrangements of parts.
//
// Objective: identify 2 compositional structures.

FLEET_NUM_DRONES   :: 3
FLEET_PROBE_PERIOD :: 0.40
FLEET_ORBIT_R      :: 3.5
FLEET_TARGET_LOCK  :: 9.0
FLEET_TARGET_UNLOCK:: 14.0
FLEET_PROBE_REACH  :: 11.0
COMP_TO_WIN        :: 2
COMP_MATCH_TOL     :: 4.0    // tolerance for relative-offset matching

@(private = "file")
Comp_Part :: struct {
	part_name: cstring,  // must match a world.objects.name
	offset:    Vec3,      // position relative to the composition's origin
}

@(private = "file")
Comp_Model :: struct {
	name:  cstring,
	parts: []Comp_Part,
	color: Color,
}

// Three compositional models defined in terms of the existing world objects.
// The first part's offset is the model's "anchor" — others are positioned
// relative to it. Matching looks at the offset BETWEEN matched parts.
@(private = "file")
fleet_comp_models := [3]Comp_Model{
	{
		name  = "Refueling Outpost",
		parts = []Comp_Part{
			{ part_name = "Fuel Tank", offset = {0, 0, 0} },
			{ part_name = "Beacon",    offset = {10, 0, -12} },
		},
		color = Color{255, 200, 100, 255},
	},
	{
		name  = "Asteroid Pair",
		parts = []Comp_Part{
			{ part_name = "Asteroid Alpha", offset = {0, 0, 0} },
			{ part_name = "Ice Rock",       offset = {-14, 0, -7} },
		},
		color = Color{180, 200, 255, 255},
	},
	{
		name  = "Trade Route",
		parts = []Comp_Part{
			{ part_name = "Cargo Crate", offset = {0, 0, 0} },
			{ part_name = "Fuel Tank",   offset = {15, 0, 4} },
		},
		color = Color{180, 255, 180, 255},
	},
}

fleet_palette := [FLEET_NUM_DRONES]Color{
	{255, 140,  80, 255},
	{120, 220, 180, 255},
	{200, 140, 255, 255},
}

@(private = "file")
L8_State :: struct {
	identified_comps:   [8]bool,    // which composition indices have been matched
	unique_comps:       int,

	// HIGHER-LM persistent memory: which world objects have been identified
	// by ANY lower LM at SOME point this level. Survives drone resets so the
	// player can accumulate parts across many fly-by passes.
	parts_seen:         [16]bool,

	last_match_anim:    f32,
	last_match_idx:     int,

	current_target:     int,        // closest world object to mothership

	completed:          bool,
	message:            cstring,
	message_timer:      f32,
	show_help:          bool,
}

@(private = "file")
l8: L8_State

l8_fleet_vtable :: proc() -> Level_Vtable {
	return {
		init    = l8_fleet_init,
		update  = l8_fleet_update,
		draw    = l8_fleet_draw,
		draw_ui = l8_fleet_draw_ui,
		cleanup = l8_fleet_cleanup,
	}
}

l8_fleet_init :: proc(game: ^Game_State) {
	l8 = {}
	l8.current_target = -1
	l8.last_match_idx = -1
	l8.show_help      = true
	l8.message        = "Drones identify single objects per fly-by.\nThe HIGHER LM accumulates identified parts across all your scans.\nFly near each object on the right list, then watch the model match."
	l8.message_timer  = 10

	game.ship.pos     = {0, 0, 0}
	game.ship.heading = 0
	game.ship.speed   = 0
	game.ship.vel     = {0, 0, 0}
	clear(&game.ship.trail)

	seed_world_objects(&game.model_db, &game.world)

	for i in 0..<FLEET_NUM_DRONES {
		lm_init(&game.lms[i + 1], i + 1)
		lm_start_inference(&game.lms[i + 1], &game.model_db)
	}

	game.ship.drone_count = FLEET_NUM_DRONES
	for i in 0..<FLEET_NUM_DRONES {
		drone := &game.ship.drones[i]
		drone^ = {}
		drone.active       = true
		drone.color        = fleet_palette[i]
		drone.target_wobj  = -1
		drone.orbit_phase  = f32(i) * (2 * math.PI / FLEET_NUM_DRONES)
		drone.orbit_radius = FLEET_ORBIT_R
		drone.probe_timer  = f32(i) * 0.1
		drone.use_voting   = true

		pos := game.ship.pos + Vec3{
			math.cos(drone.orbit_phase) * FLEET_ORBIT_R,
			f32(i - 1) * 0.6,
			math.sin(drone.orbit_phase) * FLEET_ORBIT_R,
		}
		drone.pos      = pos
		drone.prev_pos = pos
	}

	game.camera = rl.Camera3D{
		position   = {0, 18, 16},
		target     = {0, 0, 0},
		up         = {0, 1, 0},
		fovy       = 60,
		projection = .PERSPECTIVE,
	}
}

// Look up the world-object index for a given name.
@(private = "file")
fleet_find_world_obj :: proc(game: ^Game_State, name: cstring) -> int {
	for i in 0..<len(game.world.objects) {
		if cstring(game.world.objects[i].name) == name do return i
	}
	return -1
}

// Try to match each compositional model against the higher LM's persistent
// memory (parts_seen). For each model with N parts, we need each part to be
// flagged as seen at some point. We then check that the world positions of
// the matched parts have offsets matching the model's part offsets within
// COMP_MATCH_TOL. Since the world objects don't move, "world position" is
// just game.world.objects[wi].pos.
@(private = "file")
fleet_check_compositions :: proc(game: ^Game_State) {
	for mi in 0..<len(fleet_comp_models) {
		model := &fleet_comp_models[mi]
		if l8.identified_comps[mi] do continue
		if len(model.parts) < 2     do continue

		matched_pos: [4]Vec3
		all_matched := true
		for pi in 0..<len(model.parts) {
			part := &model.parts[pi]
			wobj_idx := fleet_find_world_obj(game, part.part_name)
			if wobj_idx < 0 || wobj_idx >= len(l8.parts_seen) || !l8.parts_seen[wobj_idx] {
				all_matched = false
				break
			}
			matched_pos[pi] = game.world.objects[wobj_idx].pos
		}
		if !all_matched do continue

		// All parts identified — now check relative offsets
		// Take part 0 as the anchor and compare every other part's world
		// offset to the model's defined offset.
		anchor_world := matched_pos[0]
		anchor_model := model.parts[0].offset
		offsets_ok := true
		for pi in 1..<len(model.parts) {
			expected_off := model.parts[pi].offset - anchor_model
			actual_off   := matched_pos[pi]      - anchor_world
			if linalg.distance(expected_off, actual_off) > COMP_MATCH_TOL {
				offsets_ok = false
				break
			}
		}
		if !offsets_ok do continue

		// COMPOSITIONAL MATCH!
		l8.identified_comps[mi] = true
		l8.unique_comps += 1
		l8.last_match_anim = 2.0
		l8.last_match_idx  = mi
		l8.message       = fmt.ctprintf("HIGHER-LEVEL MATCH: %s  (%d/%d)",
			model.name, l8.unique_comps, COMP_TO_WIN)
		l8.message_timer = 5

		if l8.unique_comps >= COMP_TO_WIN && !l8.completed {
			l8.completed = true
			game.levels[Level_ID.Fleet].completed = true
			save_write(game)
			popup_show_delayed(game, .Level_Complete, 1.5)
		}
	}
}

@(private = "file")
fleet_surface_dist :: proc(ship_pos: Vec3, obj: ^World_Object) -> f32 {
	d := linalg.distance(ship_pos, obj.pos) - obj.size.x
	return d < 0 ? 0 : d
}

@(private = "file")
fleet_pick_target :: proc(game: ^Game_State) -> int {
	closest := -1
	best: f32 = FLEET_TARGET_LOCK
	for i in 0..<len(game.world.objects) {
		d := fleet_surface_dist(game.ship.pos, &game.world.objects[i])
		if d < best { best = d; closest = i }
	}
	return closest
}

l8_fleet_update :: proc(game: ^Game_State, dt: f32) {
	if rl.IsKeyPressed(.ESCAPE) { popup_show(game, .Confirm_Leave_Level); return }
	if rl.IsKeyPressed(.H)      { l8.show_help = !l8.show_help }
	if rl.IsKeyPressed(.N) {
		// Lower-level reset only — higher LM's parts_seen persists. Harvest
		// any current convergences first so we don't lose the in-progress info.
		for i in 0..<FLEET_NUM_DRONES {
			lm := &game.lms[i + 1]
			if lm.converged && lm.winner_obj >= 0 && lm.winner_obj < len(l8.parts_seen) {
				l8.parts_seen[lm.winner_obj] = true
			}
			lm_init(lm, i + 1)
			lm_start_inference(lm, &game.model_db)
		}
		l8.message       = "Drone LMs reset — higher LM keeps its part history."
		l8.message_timer = 3
	}
	if rl.IsKeyPressed(.B) {
		// Full higher-level reset: forget all parts AND restart drones.
		for i in 0..<len(l8.parts_seen) do l8.parts_seen[i] = false
		for i in 0..<FLEET_NUM_DRONES {
			lm_init(&game.lms[i + 1], i + 1)
			lm_start_inference(&game.lms[i + 1], &game.model_db)
		}
		l8.message       = "BIG reset — higher LM history cleared."
		l8.message_timer = 3
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

	// Target selection with hysteresis (like Drones level)
	new_target := l8.current_target
	if l8.current_target >= 0 {
		d := fleet_surface_dist(ship.pos, &game.world.objects[l8.current_target])
		if d > FLEET_TARGET_UNLOCK do new_target = -1
	}
	if new_target < 0 {
		new_target = fleet_pick_target(game)
	} else {
		closer := fleet_pick_target(game)
		if closer >= 0 && closer != l8.current_target {
			d_cur := fleet_surface_dist(ship.pos, &game.world.objects[l8.current_target])
			d_new := fleet_surface_dist(ship.pos, &game.world.objects[closer])
			if d_new < d_cur - 2.5 do new_target = closer
		}
	}
	if new_target != l8.current_target {
		// Harvest any currently-converged drones into parts_seen FIRST so
		// the higher LM doesn't lose what they identified about the old target
		for di in 0..<FLEET_NUM_DRONES {
			lm := &game.lms[di + 1]
			if lm.converged && lm.winner_obj >= 0 && lm.winner_obj < len(l8.parts_seen) {
				l8.parts_seen[lm.winner_obj] = true
			}
		}
		// Reset all lower LMs so they can scan the new target afresh
		for di in 0..<FLEET_NUM_DRONES {
			lm_init(&game.lms[di + 1], di + 1)
			lm_start_inference(&game.lms[di + 1], &game.model_db)
			game.ship.drones[di].target_wobj = new_target
			game.ship.drones[di].probe_count = 0
		}
		l8.current_target = new_target
	}

	// Continuously harvest live convergences so a drone that converges
	// while you stay near a target is remembered the moment it locks in
	for di in 0..<FLEET_NUM_DRONES {
		lm := &game.lms[di + 1]
		if lm.converged && lm.winner_obj >= 0 && lm.winner_obj < len(l8.parts_seen) {
			l8.parts_seen[lm.winner_obj] = true
		}
	}

	// Drone behaviour
	for di in 0..<FLEET_NUM_DRONES {
		drone := &game.ship.drones[di]
		lm    := &game.lms[di + 1]
		if !drone.active do continue

		drone.orbit_phase += dt * 0.9
		base_off := Vec3{
			math.cos(drone.orbit_phase) * FLEET_ORBIT_R,
			f32(di - 1) * 0.6,
			math.sin(drone.orbit_phase) * FLEET_ORBIT_R,
		}
		desired := ship.pos + base_off
		if l8.current_target >= 0 {
			lean := (game.world.objects[l8.current_target].pos - ship.pos) * 0.25
			desired += lean
		}
		drone.prev_pos = drone.pos
		drone.pos += (desired - drone.pos) * dt * 4

		if l8.current_target >= 0 && !lm.converged {
			target_obj := &game.world.objects[l8.current_target]
			d := linalg.distance(drone.pos, target_obj.pos)
			if d < FLEET_PROBE_REACH {
				drone.probe_timer -= dt
				if drone.probe_timer <= 0 {
					drone.probe_timer = FLEET_PROBE_PERIOD
					cmp := fleet_make_cmp(game, drone)
					disp: Vec3 = drone.probe_count == 0 ? Vec3{0,0,0} : drone.pos - drone.prev_pos
					lm_step(lm, cmp, disp, &game.model_db)
					drone.probe_count += 1
				}
			}
		}

		// (No lateral voting here — drones run independently. The lesson
		// of Level 8 is hierarchy, not voting. Voting would kill
		// non-matching hypotheses too aggressively when the player swings
		// between target objects.)
	}

	// Higher-level check
	fleet_check_compositions(game)

	// follow camera
	fwd := ship_forward(ship)
	game.camera.position = ship.pos + Vec3{0, 16, 0} - fwd * 12
	game.camera.target   = ship.pos + fwd * 3

	if l8.message_timer    > 0 do l8.message_timer    -= dt
	if l8.last_match_anim  > 0 do l8.last_match_anim  -= dt
}

@(private = "file")
fleet_make_cmp :: proc(game: ^Game_State, drone: ^Drone) -> CMP_Message {
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

l8_fleet_draw :: proc(game: ^Game_State) {
	rl.BeginMode3D(game.camera)
	world_draw(&game.world, true)
	ship_draw(&game.ship)
	ship_draw_trail(&game.ship)

	// Halo identified compositions: draw a colored ring connecting their parts
	for mi in 0..<len(fleet_comp_models) {
		if !l8.identified_comps[mi] do continue
		model := &fleet_comp_models[mi]
		// Find world positions of all parts
		part_positions := [4]Vec3{}
		ok := true
		for pi in 0..<len(model.parts) {
			wi := fleet_find_world_obj(game, model.parts[pi].part_name)
			if wi < 0 { ok = false; break }
			part_positions[pi] = game.world.objects[wi].pos
		}
		if !ok do continue
		// Draw lines between every pair of parts, in the model's color
		for a in 0..<len(model.parts) {
			for b in a + 1..<len(model.parts) {
				rl.DrawLine3D(part_positions[a], part_positions[b],
					Color{model.color.r, model.color.g, model.color.b, 200})
			}
		}
		// Halo on each part
		for pi in 0..<len(model.parts) {
			wi := fleet_find_world_obj(game, model.parts[pi].part_name)
			if wi < 0 do continue
			obj := &game.world.objects[wi]
			rl.DrawSphereWires(obj.pos, obj.size.x + 0.4, 10, 10,
				Color{model.color.r, model.color.g, model.color.b, 180})
		}
	}

	// Target halo for current focus
	if l8.current_target >= 0 {
		target := &game.world.objects[l8.current_target]
		pulse := 0.5 + 0.5 * math.sin(f32(rl.GetTime()) * 3)
		rl.DrawCircle3D(target.pos, target.size.x + 0.6, {0, 1, 0}, 0,
			Color{255, 220, 100, u8(pulse * 140)})
	}

	// Drones with probe beams
	for di in 0..<FLEET_NUM_DRONES {
		drone := &game.ship.drones[di]
		if !drone.active do continue
		c := drone.color
		rl.DrawSphere(drone.pos, 0.45, c)
		rl.DrawSphereWires(drone.pos, 0.55, 6, 6, Color{c.r, c.g, c.b, 120})
		if l8.current_target >= 0 {
			tobj := &game.world.objects[l8.current_target]
			diff := drone.pos - tobj.pos
			d := linalg.length(diff)
			if d > 0.001 && d < FLEET_PROBE_REACH * 1.2 {
				n := diff / d
				contact := tobj.pos + n * tobj.size.x
				rl.DrawLine3D(drone.pos, contact, Color{c.r, c.g, c.b, 160})
				rl.DrawSphere(contact, 0.16, c)
			}
		}
	}

	// Pulse on most recent match
	if l8.last_match_anim > 0 && l8.last_match_idx >= 0 {
		model := &fleet_comp_models[l8.last_match_idx]
		for pi in 0..<len(model.parts) {
			wi := fleet_find_world_obj(game, model.parts[pi].part_name)
			if wi < 0 do continue
			obj := &game.world.objects[wi]
			r := obj.size.x + 1.0 + (2.0 - l8.last_match_anim) * 2.0
			a := u8(min(l8.last_match_anim / 2.0, 1) * 200)
			rl.DrawSphereWires(obj.pos, r, 10, 10,
				Color{model.color.r, model.color.g, model.color.b, a})
		}
	}

	rl.EndMode3D()
}

// ── HUD ─────────────────────────────────────────────────────────────────────

l8_fleet_draw_ui :: proc(game: ^Game_State) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	db := &game.model_db

	// Title row
	target_name: cstring = "(none — fly closer)"
	if l8.current_target >= 0 {
		target_name = game.world.objects[l8.current_target].name
	}
	rl.DrawText(fmt.ctprintf("TARGET: %s", target_name), 14, 12, 16, Color{255, 220, 100, 220})
	rl.DrawText(fmt.ctprintf("Compositions: %d / %d", l8.unique_comps, COMP_TO_WIN),
		14, 32, 16, Color{120, 255, 160, 220})
	rl.DrawText("LEVEL 8: FLEET (HIERARCHICAL COMPOSITION)",
		i32(sw) - 460, 12, 16, Color{180, 255, 180, 220})

	// Compact drone status row (lower LMs)
	row_y: f32 = 60
	drone_panel_w: f32 = 240
	for di in 0..<FLEET_NUM_DRONES {
		lm := &game.lms[di + 1]
		x := f32(10 + di) * 0 + 10 + f32(di) * (drone_panel_w + 6)
		rl.DrawRectangle(i32(x), i32(row_y), i32(drone_panel_w), 88, Color{0, 0, 0, 150})
		c := fleet_palette[di]
		rl.DrawRectangleLinesEx({x, row_y, drone_panel_w, 88}, 1, Color{c.r, c.g, c.b, 200})
		rl.DrawText(fmt.ctprintf("DRONE %d (lower LM)", di), i32(x) + 8, i32(row_y) + 6, 12,
			Color{c.r, c.g, c.b, 230})

		active := lm_active_count(lm)
		total  := lm.hyp_count
		frac   := total > 0 ? f32(active) / f32(total) : 0
		rl.DrawRectangle(i32(x) + 8, i32(row_y) + 24, i32(drone_panel_w) - 16, 8,
			Color{25, 25, 35, 200})
		rl.DrawRectangle(i32(x) + 8, i32(row_y) + 24,
			i32(f32(int(drone_panel_w) - 16) * frac), 8, c)

		if lm.converged && lm.winner_obj >= 0 && lm.winner_obj < db.object_count {
			rl.DrawText(fmt.ctprintf("→ %s", db.objects[lm.winner_obj].name),
				i32(x) + 8, i32(row_y) + 38, 13, Color{120, 255, 160, 230})
		} else {
			rl.DrawText("...still working", i32(x) + 8, i32(row_y) + 38, 12,
				Color{160, 180, 200, 200})
		}

		lm_draw_convergence_inline(lm, i32(x) + 8, i32(row_y) + 66)
	}

	// Higher-level "compositional matcher" panel — right side, full-height
	hi_x := sw - 360
	hi_y: f32 = 60
	hi_w: f32 = 350
	hi_h: f32 = sh - 130
	rl.DrawRectangle(i32(hi_x), i32(hi_y), i32(hi_w), i32(hi_h), Color{0, 0, 0, 180})
	rl.DrawRectangleLinesEx({hi_x, hi_y, hi_w, hi_h}, 2, Color{180, 255, 180, 220})
	rl.DrawText("HIGHER LM — Compositional Matcher",
		i32(hi_x) + 10, i32(hi_y) + 8, 14, Color{180, 255, 180, 230})
	rl.DrawText("Features in: part identities from lower LMs",
		i32(hi_x) + 10, i32(hi_y) + 26, 11, Color{160, 220, 180, 200})
	rl.DrawText("Output:      compositional object identification",
		i32(hi_x) + 10, i32(hi_y) + 42, 11, Color{160, 220, 180, 200})

	rl.DrawLine(i32(hi_x) + 10, i32(hi_y) + 62,
		i32(hi_x + hi_w) - 10, i32(hi_y) + 62, Color{80, 120, 100, 150})

	// List each model with its required parts and current status
	my := i32(hi_y) + 72
	for mi in 0..<len(fleet_comp_models) {
		model := &fleet_comp_models[mi]
		c := model.color
		matched := l8.identified_comps[mi]

		// Box
		box_h: i32 = 95
		bg := matched ? Color{60, 80, 60, 200} : Color{20, 25, 30, 200}
		rl.DrawRectangle(i32(hi_x) + 10, my, i32(hi_w) - 20, box_h, bg)
		border := matched ? Color{120, 255, 160, 220} : Color{c.r, c.g, c.b, 160}
		rl.DrawRectangleLines(i32(hi_x) + 10, my, i32(hi_w) - 20, box_h, border)

		// Name + status
		rl.DrawText(model.name, i32(hi_x) + 16, my + 6, 14, c)
		if matched {
			rl.DrawText("✓ MATCHED", i32(hi_x) + i32(hi_w) - 110, my + 6, 13,
				Color{120, 255, 160, 240})
		}

		// Parts list with check marks indicating which drones have ID'd them
		for pi in 0..<len(model.parts) {
			part := &model.parts[pi]
			py := my + 24 + i32(pi) * 16

			// Persisted higher-LM memory of this part
			has_part := false
			wi := fleet_find_world_obj(game, part.part_name)
			if wi >= 0 && wi < len(l8.parts_seen) {
				has_part = l8.parts_seen[wi]
			}
			mark: cstring = has_part ? "✓" : "·"
			mc: Color    = has_part ? Color{120, 255, 160, 230} : Color{140, 160, 180, 200}
			rl.DrawText(fmt.ctprintf("  %s  %s", mark, part.part_name),
				i32(hi_x) + 16, py, 12, mc)
			off := part.offset
			rl.DrawText(fmt.ctprintf("offset (%.0f, %.0f, %.0f)", off.x, off.y, off.z),
				i32(hi_x) + 180, py, 11, Color{140, 160, 190, 180})
		}

		my += box_h + 8
	}

	// Bottom message
	if l8.message_timer > 0 && l8.message != nil {
		alpha := u8(min(l8.message_timer * 1.5, 1) * 255)
		msg_w := rl.MeasureText(l8.message, 18)
		mx := i32(sw / 2) - msg_w / 2 - 200
		my := i32(sh) - 80
		rl.DrawRectangle(mx - 14, my - 8, msg_w + 28, 60, Color{0, 0, 0, alpha / 2})
		rl.DrawText(l8.message, mx, my, 18, Color{255, 255, 255, alpha})
	}

	if l8.show_help {
		rl.DrawText("[WASD] Fly   [N] Reset drones (keep higher memory)   [B] Big reset   [H] Help   [ESC] Back",
			10, i32(sh) - 28, 13, Color{80, 100, 140, 150})
	}
}

l8_fleet_cleanup :: proc(game: ^Game_State) {
	game.ship.drone_count = 0
	for i in 0..<FLEET_NUM_DRONES {
		game.ship.drones[i].active = false
	}
}
