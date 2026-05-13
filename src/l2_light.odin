package monty

import rl "vendor:raylib"
import "core:math"
import "core:math/linalg"
import "core:fmt"

// Level 2 — Photon Probe (Light)
//
// Your first DIRECTIONAL sensor. Aim with the ship's heading,
// press [F] to fire a photon pulse. The pulse traces a ray
// forward; the first object it hits returns a brightness reading
// (modulated by surface albedo, incidence angle, and distance).
//
// Each pulse builds a real CMP message:
//
//   CMP_Message {
//     location:    hit_point        ← where in space the photon landed
//     orientation: surface_normal   ← which way the surface faces
//     features:    { brightness }   ← what was sensed
//     confidence:  1.0
//   }
//
// Monty concept (the foundational one): "features at a pose".
// Every Monty observation is a feature value tied to a 3D pose.
// Sensor modules produce them; learning modules consume them;
// graph nodes store them; votes are derived from them.
//
// Objective: probe at least 4 unique objects.

PROBE_MAX_RANGE :: 30.0
MAX_PROBE_HITS  :: 32
LIGHT_TARGETS_TO_PROBE :: 4
PROBE_COOLDOWN :: 0.15

Probe_Hit :: struct {
	wobj_idx:  int,
	cmp:       CMP_Message,
	timestamp: f32,
}

@(private = "file")
L_Light_State :: struct {
	cooldown:       f32,
	pulse_anim:     f32,        // fading flash after each shot
	hits:           [MAX_PROBE_HITS]Probe_Hit,
	hit_count:      int,
	last_cmp:       CMP_Message,
	last_cmp_obj:   cstring,
	last_cmp_valid: bool,
	probed_wobjs:   [16]bool,
	unique_count:   int,
	completed:      bool,
	message:        cstring,
	message_timer:  f32,
	show_help:      bool,
}

@(private = "file")
ll: L_Light_State

l2_light_vtable :: proc() -> Level_Vtable {
	return {
		init    = l2_light_init,
		update  = l2_light_update,
		draw    = l2_light_draw,
		draw_ui = l2_light_draw_ui,
		cleanup = l2_light_cleanup,
	}
}

l2_light_init :: proc(game: ^Game_State) {
	ll = {}
	ll.show_help     = true
	ll.message       = "Photon probe online — aim forward, [F] to pulse.\nEach pulse is a CMP message: a feature at a pose."
	ll.message_timer = 6

	game.ship.pos     = {0, 0, -5}
	game.ship.heading = 0
	game.ship.speed   = 0
	game.ship.vel     = {0, 0, 0}
	clear(&game.ship.trail)

	game.camera = rl.Camera3D{
		position   = {0, 22, 18},
		target     = {0, 0, 0},
		up         = {0, 1, 0},
		fovy       = 60,
		projection = .PERSPECTIVE,
	}
}

// Treat every object as a sphere for ray intersection (good enough
// at the play scale we're using; could be extended per-kind)
ray_sphere :: proc(origin, dir, center: Vec3, radius: f32) -> (t: f32, hit: bool) {
	oc := origin - center
	b := linalg.dot(oc, dir)
	c := linalg.dot(oc, oc) - radius * radius
	disc := b * b - c
	if disc < 0 do return 0, false
	sq := math.sqrt(disc)
	t1 := -b - sq
	if t1 > 0.01 do return t1, true
	t2 := -b + sq
	if t2 > 0.01 do return t2, true
	return 0, false
}

// Find the first world object intersected by a ray.
// Returns object index, hit point, surface normal, distance.
l2_light_raycast :: proc(world: ^World, origin, dir: Vec3) -> (int, Vec3, Vec3, f32) {
	best_idx := -1
	best_t: f32 = PROBE_MAX_RANGE + 1

	for i in 0..<len(world.objects) {
		obj := &world.objects[i]
		// Use bounding sphere with radius = max extent
		r := obj.size.x
		if obj.size.y > r do r = obj.size.y
		if obj.size.z > r do r = obj.size.z
		t, hit := ray_sphere(origin, dir, obj.pos, r)
		if hit && t < best_t {
			best_t = t
			best_idx = i
		}
	}

	if best_idx < 0 || best_t > PROBE_MAX_RANGE {
		return -1, origin + dir * PROBE_MAX_RANGE, dir, PROBE_MAX_RANGE
	}

	hit_pt := origin + dir * best_t
	normal := linalg.normalize(hit_pt - world.objects[best_idx].pos)
	return best_idx, hit_pt, normal, best_t
}

// Compute brightness for a pose+target — the actual "sensor reading"
l2_light_brightness :: proc(obj: ^World_Object, hit_pt, ray_dir, normal: Vec3, dist: f32) -> f32 {
	// Surface albedo from color (perceptual luminance approximation)
	albedo := obj.material.color.x * 0.30 + obj.material.color.y * 0.59 + obj.material.color.z * 0.11
	// Incidence: how head-on the ray is (-dir · normal). 1 = straight on, 0 = grazing
	incidence := clamp(-linalg.dot(ray_dir, normal), 0, 1)
	// Distance falloff
	falloff := 1.0 / (1.0 + 0.05 * dist)
	return clamp(albedo * incidence * falloff * 2.0, 0, 1)
}

l2_light_pulse :: proc(game: ^Game_State) {
	ship := &game.ship
	fwd := ship_forward(ship)
	origin := ship.pos
	dir := fwd

	idx, hit_pt, normal, dist := l2_light_raycast(&game.world, origin, dir)

	if idx < 0 {
		ll.last_cmp_valid = false
		ll.message       = "No hit — probe travelled into empty space."
		ll.message_timer = 1.5
		return
	}

	obj := &game.world.objects[idx]
	brightness := l2_light_brightness(obj, hit_pt, dir, normal, dist)

	cmp := CMP_Message{
		location    = hit_pt,
		orientation = normal,
		features    = Features{ brightness = brightness, color = obj.material.color },
		confidence  = 1.0,
	}

	ll.last_cmp       = cmp
	ll.last_cmp_obj   = obj.name
	ll.last_cmp_valid = true
	ll.pulse_anim     = 1.0

	// Record hit
	if ll.hit_count < MAX_PROBE_HITS {
		ll.hits[ll.hit_count] = Probe_Hit{
			wobj_idx  = idx,
			cmp       = cmp,
			timestamp = f32(rl.GetTime()),
		}
		ll.hit_count += 1
	} else {
		// Ring-buffer style: shift left
		for i in 1..<MAX_PROBE_HITS { ll.hits[i - 1] = ll.hits[i] }
		ll.hits[MAX_PROBE_HITS - 1] = Probe_Hit{ wobj_idx = idx, cmp = cmp, timestamp = f32(rl.GetTime()) }
	}

	// Mark unique object
	if idx >= 0 && idx < len(ll.probed_wobjs) && !ll.probed_wobjs[idx] {
		ll.probed_wobjs[idx] = true
		ll.unique_count += 1
		ll.message = fmt.ctprintf("Identified: %s  brightness=%.2f  (%d/%d)",
			obj.name, brightness, ll.unique_count, LIGHT_TARGETS_TO_PROBE)
		ll.message_timer = 3

		if ll.unique_count >= LIGHT_TARGETS_TO_PROBE && !ll.completed {
			ll.completed = true
			game.levels[Level_ID.Light].completed = true
			game.levels[Level_ID.Touch].unlocked  = true
			game.ship.sensors += {.Contact}
			popup_show(game, .Level_Complete)
			save_write(game)
		}
	}
}

l2_light_update :: proc(game: ^Game_State, dt: f32) {
	ship := &game.ship

	// flight controls
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

	// Cooldown
	if ll.cooldown > 0 do ll.cooldown -= dt
	if ll.pulse_anim > 0 do ll.pulse_anim -= dt * 2

	// Fire pulse
	if rl.IsKeyPressed(.F) || (rl.IsKeyDown(.SPACE) && ll.cooldown <= 0) {
		l2_light_pulse(game)
		ll.cooldown = PROBE_COOLDOWN
	}

	// Camera follow from above-behind
	fwd := ship_forward(ship)
	game.camera.position = ship.pos + Vec3{0, 18, 0} - fwd * 12
	game.camera.target   = ship.pos + fwd * 4

	if ll.message_timer > 0 do ll.message_timer -= dt
	if rl.IsKeyPressed(.H) do ll.show_help = !ll.show_help
	if rl.IsKeyPressed(.ESCAPE) do popup_show(game, .Confirm_Leave_Level)
}

// ── 3D draw ─────────────────────────────────────────────────────────────────

l2_light_draw :: proc(game: ^Game_State) {
	rl.BeginMode3D(game.camera)

	// World is visible — you can see what you're aiming at
	world_draw(&game.world, true)
	ship_draw(&game.ship)
	ship_draw_trail(&game.ship)

	// Aim beam — faint when idle, bright on pulse
	fwd := ship_forward(&game.ship)
	idx, hit_pt, normal, dist := l2_light_raycast(&game.world, game.ship.pos, fwd)
	beam_end := idx >= 0 ? hit_pt : game.ship.pos + fwd * PROBE_MAX_RANGE

	idle_alpha: u8 = u8(50 + ll.pulse_anim * 180)
	rl.DrawLine3D(game.ship.pos, beam_end, Color{255, 220, 100, idle_alpha})

	// Reticle at the predicted hit point
	if idx >= 0 {
		ring_alpha: u8 = u8(120 + ll.pulse_anim * 100)
		rl.DrawCircle3D(hit_pt, 0.4, normal, 0, Color{255, 220, 100, ring_alpha})
		// Normal arrow
		rl.DrawLine3D(hit_pt, hit_pt + normal * 1.0, Color{255, 255, 200, 160})
	}

	// Pulse flash at hit
	if ll.pulse_anim > 0 && ll.last_cmp_valid {
		rl.DrawSphere(ll.last_cmp.location, 0.3 + (1 - ll.pulse_anim) * 1.5,
			Color{255, 240, 150, u8(ll.pulse_anim * 220)})
	}

	// Persistent tags at each probed object
	for i in 0..<len(game.world.objects) {
		if !ll.probed_wobjs[i] do continue
		obj := &game.world.objects[i]
		tag_pos := obj.pos + Vec3{0, obj.size.y + 0.8, 0}
		rl.DrawSphere(tag_pos, 0.18, Color{100, 255, 150, 220})
	}

	// Draw recent hit history as small fading dots
	now := f32(rl.GetTime())
	for i in 0..<ll.hit_count {
		h := &ll.hits[i]
		age := now - h.timestamp
		if age > 4.0 do continue
		alpha := u8((1 - age / 4.0) * 200)
		b := h.cmp.features.brightness.? or_else 0
		c := Color{u8(b * 255), u8(b * 220 + 35), u8(b * 100 + 60), alpha}
		rl.DrawSphere(h.cmp.location, 0.1, c)
	}

	rl.EndMode3D()
}

// ── HUD ─────────────────────────────────────────────────────────────────────

l2_light_draw_ui :: proc(game: ^Game_State) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())

	// Top-left: status
	panel_w: f32 = 280
	panel_h: f32 = 90
	rl.DrawRectangle(10, 10, i32(panel_w), i32(panel_h), Color{0, 0, 0, 150})
	rl.DrawRectangleLinesEx({10, 10, panel_w, panel_h}, 1, Color{60, 80, 120, 150})
	rl.DrawText("PHOTON PROBE", 20, 18, 14, Color{255, 220, 100, 220})
	rl.DrawText(fmt.ctprintf("Unique objects probed: %d / %d",
		ll.unique_count, LIGHT_TARGETS_TO_PROBE), 20, 38, 16, Color{200, 220, 240, 220})
	rl.DrawText(fmt.ctprintf("Total pulses: %d", ll.hit_count),
		20, 60, 14, Color{160, 180, 210, 200})

	// Right side: CMP message structure — the lesson
	cmp_x := sw - 360
	cmp_y: f32 = 10
	cmp_w: f32 = 350
	cmp_h: f32 = 230
	rl.DrawRectangle(i32(cmp_x), i32(cmp_y), i32(cmp_w), i32(cmp_h), Color{0, 0, 0, 180})
	rl.DrawRectangleLinesEx({cmp_x, cmp_y, cmp_w, cmp_h}, 1, Color{100, 160, 220, 180})
	rl.DrawText("CMP MESSAGE (latest pulse)", i32(cmp_x) + 10, i32(cmp_y) + 8, 14,
		Color{120, 180, 255, 220})

	if ll.last_cmp_valid {
		c := &ll.last_cmp
		ty := i32(cmp_y) + 30
		rl.DrawText(fmt.ctprintf("  target:      %s", ll.last_cmp_obj),
			i32(cmp_x) + 10, ty, 14, Color{255, 220, 100, 230})

		rl.DrawText("  location {", i32(cmp_x) + 10, ty + 22, 14, Color{200, 220, 240, 220})
		rl.DrawText(fmt.ctprintf("    x: %+.2f   y: %+.2f   z: %+.2f",
			c.location.x, c.location.y, c.location.z),
			i32(cmp_x) + 10, ty + 40, 13, Color{180, 200, 220, 200})
		rl.DrawText("  }", i32(cmp_x) + 10, ty + 58, 14, Color{200, 220, 240, 220})

		rl.DrawText("  orientation (surface normal) {",
			i32(cmp_x) + 10, ty + 78, 14, Color{200, 220, 240, 220})
		rl.DrawText(fmt.ctprintf("    x: %+.2f   y: %+.2f   z: %+.2f",
			c.orientation.x, c.orientation.y, c.orientation.z),
			i32(cmp_x) + 10, ty + 96, 13, Color{180, 200, 220, 200})
		rl.DrawText("  }", i32(cmp_x) + 10, ty + 114, 14, Color{200, 220, 240, 220})

		rl.DrawText("  features {", i32(cmp_x) + 10, ty + 134, 14, Color{200, 220, 240, 220})
		b := c.features.brightness.? or_else 0
		rl.DrawText(fmt.ctprintf("    brightness: %.3f", b),
			i32(cmp_x) + 10, ty + 152, 13, Color{255, 220, 100, 230})
		rl.DrawText("  }", i32(cmp_x) + 10, ty + 170, 14, Color{200, 220, 240, 220})

		rl.DrawText(fmt.ctprintf("  confidence: %.2f", c.confidence),
			i32(cmp_x) + 10, ty + 188, 13, Color{180, 200, 220, 200})
	} else {
		rl.DrawText("  (no readings yet — press [F] to pulse)",
			i32(cmp_x) + 10, i32(cmp_y) + 40, 14, Color{120, 140, 170, 180})
	}

	// Brightness bar (the live reading)
	if ll.last_cmp_valid {
		bar_x: f32 = 10
		bar_y: f32 = 110
		bar_w: f32 = 280
		bar_h: f32 = 18
		rl.DrawRectangle(i32(bar_x), i32(bar_y), i32(bar_w), i32(bar_h), Color{25, 25, 35, 200})
		b := ll.last_cmp.features.brightness.? or_else 0
		fill := i32(clamp(b, 0, 1) * bar_w)
		rl.DrawRectangle(i32(bar_x), i32(bar_y), fill, i32(bar_h), Color{255, 220, 100, 230})
		rl.DrawRectangleLines(i32(bar_x), i32(bar_y), i32(bar_w), i32(bar_h),
			Color{120, 100, 60, 180})
		rl.DrawText(fmt.ctprintf("brightness: %.3f", b),
			i32(bar_x) + 6, i32(bar_y) + 1, 14, Color{30, 30, 40, 200})
	}

	// Probed objects checklist
	check_y: f32 = 145
	rl.DrawText("PROBED:", 14, i32(check_y), 13, Color{150, 170, 200, 180})
	check_y += 18
	count := min(len(game.world.objects), len(ll.probed_wobjs))
	for i in 0..<count {
		c := ll.probed_wobjs[i] ? Color{100, 255, 150, 220} : Color{80, 80, 100, 160}
		mark: cstring = ll.probed_wobjs[i] ? "[x]" : "[ ]"
		rl.DrawText(fmt.ctprintf("%s %s", mark, game.world.objects[i].name),
			18, i32(check_y), 13, c)
		check_y += 16
	}

	// Message overlay
	if ll.message_timer > 0 && ll.message != nil {
		alpha := u8(min(ll.message_timer * 2, 1) * 255)
		msg_w := rl.MeasureText(ll.message, 18)
		mx := i32(sw / 2) - msg_w / 2
		my := i32(sh * 0.78)
		rl.DrawRectangle(mx - 14, my - 8, msg_w + 28, 40, Color{0, 0, 0, alpha / 2})
		rl.DrawText(ll.message, mx, my, 18, Color{255, 255, 255, alpha})
	}

	if ll.show_help {
		rl.DrawText("[WASD] Fly  [F] Pulse  [SPACE] Auto-pulse  [H] Help  [ESC] Back",
			10, i32(sh) - 28, 13, Color{80, 100, 140, 150})
	}

	rl.DrawText("LEVEL 2: PHOTON PROBE", i32(sw) - 240, i32(sh) - 28, 16,
		Color{255, 220, 100, 180})
}

l2_light_cleanup :: proc(game: ^Game_State) {}
