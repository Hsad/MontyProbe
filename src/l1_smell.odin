package monty

import rl "vendor:raylib"
import "core:math"
import "core:math/linalg"
import "core:fmt"

// Level 1: Chemical Sensor (Multi-Channel)
//
// Your ship gets a chemical sensor with 3 receptor channels.
// Each object emits a unique chemical signature — a mix of
// 3 compounds. Your sensor reads the blended mixture of all
// nearby sources. By moving, you can separate the signals
// and identify individual objects by their signature.
//
// The HUD shows:
//   - Per-channel intensity bars (colored R/G/B)
//   - A mixture color (the blend of all channels)
//   - An SDR grid: a sparse pattern of active cells that
//     represents the current reading. Different signatures
//     activate different cell patterns. Overlapping signals
//     create union patterns.
//
// Monty concept: Features are multi-dimensional. A CMP message
// carries a feature VECTOR, not a scalar. Different objects have
// different feature signatures at different poses. SDRs are how
// the brain would represent these — sparse, high-dimensional,
// overlap-tolerant patterns.

@(private = "file")
L1_State :: struct {
	found:           [dynamic]int,
	target_count:    int,
	channels:        Chem_Signature,   // current per-channel reading
	total_intensity: f32,
	ch_history:      [CHEM_CHANNELS][128]f32,
	hist_idx:        int,
	sdr:             [SDR_SIZE]bool,   // current SDR representation
	message:         cstring,
	message_timer:   f32,
	show_help:       bool,
	closest_dist:    f32,
}

SDR_SIZE     :: 256  // total cells in SDR
SDR_ACTIVE   :: 20   // number of active cells (sparsity ~8%)
SDR_COLS     :: 32   // grid layout
SDR_ROWS     :: 8

// Channel colors
@(private = "file")
chem_colors := [CHEM_CHANNELS]Color{
	{220, 60, 60, 255},    // Channel 0: Red / Sulfur
	{60, 200, 80, 255},    // Channel 1: Green / Organic
	{60, 100, 220, 255},   // Channel 2: Blue / Ice
}
@(private = "file")
chem_names := [CHEM_CHANNELS]cstring{
	"Sulfur",
	"Organic",
	"Crystal",
}

@(private = "file")
l1: L1_State

l1_smell_vtable :: proc() -> Level_Vtable {
	return {
		init    = l1_init,
		update  = l1_update,
		draw    = l1_draw,
		draw_ui = l1_draw_ui,
		cleanup = l1_cleanup,
	}
}

l1_init :: proc(game: ^Game_State) {
	l1 = {}
	l1.found = make([dynamic]int, 0, 8)
	l1.target_count = 3
	l1.show_help = true
	l1.message = "Chemical sensor online — 3 receptor channels.\nEach object has a unique scent signature.\nFollow the colors. [T] to tag nearby objects."
	l1.message_timer = 7

	game.ship.pos = {0, 0, 0}
	game.ship.vel = {0, 0, 0}
	game.ship.heading = 0
	game.ship.pitch = 0
	game.ship.speed = 0
	clear(&game.ship.trail)

	game.camera = rl.Camera3D {
		position   = {0, 25, 30},
		target     = {0, 0, 0},
		up         = {0, 1, 0},
		fovy       = 60,
		projection = .PERSPECTIVE,
	}
}

// Multi-channel chemical reading at a position.
// Each channel is the weighted sum of all objects' emissions on that channel.
l1_smell_channels :: proc(world: ^World, pos: Vec3) -> Chem_Signature {
	result: Chem_Signature
	for &obj in world.objects {
		d := linalg.distance(pos, obj.pos)
		if d < 0.5 do d = 0.5
		weight := obj.material.smell / (d * d) * 10
		for ch in 0..<CHEM_CHANNELS {
			result[ch] += obj.material.chem_sig[ch] * weight
		}
	}
	// Clamp each channel
	for ch in 0..<CHEM_CHANNELS {
		result[ch] = clamp(result[ch], 0, 1)
	}
	return result
}

// Convert a chemical reading into an SDR pattern.
// Each channel activates a band of cells. The pattern is
// deterministic — same input always gives same pattern.
// Overlapping signals create union SDRs (more active bits).
l1_channels_to_sdr :: proc(channels: Chem_Signature) -> [SDR_SIZE]bool {
	sdr: [SDR_SIZE]bool

	// Each channel "owns" a region of the SDR space
	// Within that region, the intensity determines which cells fire
	cells_per_channel := SDR_SIZE / CHEM_CHANNELS

	for ch in 0..<CHEM_CHANNELS {
		intensity := channels[ch]
		if intensity < 0.02 do continue

		base := ch * cells_per_channel
		// Number of active cells scales with intensity
		n_active := int(intensity * f32(SDR_ACTIVE / CHEM_CHANNELS) + 0.5)
		n_active = clamp(n_active, 0, cells_per_channel)

		// Deterministic pattern: hash-like distribution based on intensity
		// Quantize intensity to create discrete "bands"
		band := int(intensity * 12) // 12 distinct levels
		for i in 0..<n_active {
			// Simple deterministic scatter using golden ratio
			cell := (band * 7 + i * 13 + ch * 3) % cells_per_channel
			sdr[base + cell] = true
		}
	}
	return sdr
}

l1_nearest_untagged :: proc(world: ^World, pos: Vec3, found: ^[dynamic]int) -> (int, f32) {
	best_idx := -1
	best_dist: f32 = 9999
	for i in 0..<len(world.objects) {
		already := false
		for j in 0..<len(found) {
			if found[j] == i { already = true; break }
		}
		if already do continue
		d := linalg.distance(pos, world.objects[i].pos)
		if d < best_dist { best_dist = d; best_idx = i }
	}
	return best_idx, best_dist
}

l1_update :: proc(game: ^Game_State, dt: f32) {
	ship := &game.ship

	turn_rate: f32 = 2.0
	if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A)  { ship.heading += turn_rate * dt }
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) { ship.heading -= turn_rate * dt }

	accel: f32 = 8.0
	drag: f32 = 2.0
	if rl.IsKeyDown(.UP) || rl.IsKeyDown(.W) {
		ship.speed += accel * dt
	} else if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S) {
		ship.speed -= accel * dt
	} else {
		ship.speed *= (1 - drag * dt)
	}
	ship.speed = clamp(ship.speed, -5, 15)

	ship_update(ship, dt)

	// Multi-channel chemical reading
	l1.channels = l1_smell_channels(&game.world, ship.pos)
	l1.total_intensity = 0
	for ch in 0..<CHEM_CHANNELS {
		l1.total_intensity += l1.channels[ch]
	}
	l1.total_intensity /= f32(CHEM_CHANNELS)

	// Per-channel history
	idx := l1.hist_idx % len(l1.ch_history[0])
	for ch in 0..<CHEM_CHANNELS {
		l1.ch_history[ch][idx] = l1.channels[ch]
	}
	l1.hist_idx += 1

	// Compute SDR
	l1.sdr = l1_channels_to_sdr(l1.channels)

	_, nearest_dist := l1_nearest_untagged(&game.world, ship.pos, &l1.found)
	l1.closest_dist = nearest_dist

	// Tag
	if rl.IsKeyPressed(.T) {
		tag_idx, dist := l1_nearest_untagged(&game.world, ship.pos, &l1.found)
		if tag_idx >= 0 && dist < 3.5 {
			append(&l1.found, tag_idx)
			obj_name := game.world.objects[tag_idx].name
			l1.message = fmt.ctprintf("Tagged: %s! (%d/%d)", obj_name, len(l1.found), l1.target_count)
			l1.message_timer = 3
			if len(l1.found) >= l1.target_count {
				game.levels[Level_ID.Smell].completed = true
				game.levels[Level_ID.Light].unlocked = true
				game.levels[Level_ID.Touch].unlocked = true  // bridge: Light not yet built
				game.ship.sensors += {.Light_Probe}
				popup_show(game, .Level_Complete)
			}
		} else if tag_idx >= 0 {
			l1.message = "Too far to tag. Get closer!"
			l1.message_timer = 2
		}
	}

	// Camera
	fwd := ship_forward(ship)
	game.camera.position = ship.pos + Vec3{0, 18, 0} - fwd * 12
	game.camera.target = ship.pos

	if l1.message_timer > 0 { l1.message_timer -= dt }
	if rl.IsKeyPressed(.H) { l1.show_help = !l1.show_help }
	if rl.IsKeyPressed(.ESCAPE) { popup_show(game, .Confirm_Leave_Level) }
}

l1_draw :: proc(game: ^Game_State) {
	rl.BeginMode3D(game.camera)

	world_draw(&game.world, false)
	ship_draw(&game.ship)
	ship_draw_trail(&game.ship)

	// Smell cloud — colored rings showing the channel mix
	for ch in 0..<CHEM_CHANNELS {
		v := l1.channels[ch]
		if v < 0.03 do continue
		c := chem_colors[ch]
		c.a = u8(v * 120)
		r := 2.5 - v * 1.5 + f32(ch) * 0.3
		rl.DrawCircle3D(game.ship.pos, r, {0, 1, 0}, 0, c)
	}

	// Tagged objects revealed
	for i in 0..<len(l1.found) {
		obj := &game.world.objects[l1.found[i]]
		c := Color{
			u8(obj.material.color.x * 255),
			u8(obj.material.color.y * 255),
			u8(obj.material.color.z * 255),
			150,
		}
		rl.DrawSphereWires(obj.pos, obj.size.x, 8, 8, c)
		rl.DrawSphere(obj.pos + {0, obj.size.y + 1, 0}, 0.3, Color{100, 255, 150, 200})
	}

	rl.EndMode3D()
}

l1_draw_ui :: proc(game: ^Game_State) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())

	// === Left HUD: Channel bars ===
	panel_w: i32 = 300
	panel_h: i32 = 180
	rl.DrawRectangle(10, 10, panel_w, panel_h, Color{0, 0, 0, 150})
	rl.DrawRectangleLinesEx({10, 10, f32(panel_w), f32(panel_h)}, 1, Color{60, 80, 120, 150})

	rl.DrawText("CHEMICAL SENSOR", 20, 18, 14, Color{200, 180, 50, 200})

	bar_w: i32 = 200
	bar_h: i32 = 16

	for ch in 0..<CHEM_CHANNELS {
		by := i32(40 + ch * 28)
		// Label
		rl.DrawText(chem_names[ch], 20, by, 14, chem_colors[ch])
		// Bar background
		bx: i32 = 85
		rl.DrawRectangle(bx, by, bar_w, bar_h, Color{30, 30, 40, 200})
		// Bar fill
		fill := i32(clamp(l1.channels[ch], 0, 1) * f32(bar_w))
		c := chem_colors[ch]
		c.a = 220
		rl.DrawRectangle(bx, by, fill, bar_h, c)
		rl.DrawRectangleLines(bx, by, bar_w, bar_h, Color{80, 80, 100, 100})
		// Value
		rl.DrawText(fmt.ctprintf("%.2f", l1.channels[ch]), bx + bar_w + 5, by, 14, Color{180, 180, 200, 200})
	}

	// Mixture color swatch
	mix_r := u8(clamp(l1.channels[0], 0, 1) * 255)
	mix_g := u8(clamp(l1.channels[1], 0, 1) * 255)
	mix_b := u8(clamp(l1.channels[2], 0, 1) * 255)
	rl.DrawRectangle(20, 128, 30, 30, Color{mix_r, mix_g, mix_b, 255})
	rl.DrawRectangleLines(20, 128, 30, 30, Color{150, 150, 180, 150})
	rl.DrawText("Mixture", 58, 135, 14, Color{180, 180, 200, 180})

	// Progress
	rl.DrawText(fmt.ctprintf("Tagged: %d / %d", len(l1.found), l1.target_count), 160, 165, 16, Color{100, 255, 150, 220})

	// === Right HUD: SDR grid ===
	sdr_panel_w: f32 = 230
	sdr_panel_h: f32 = 130
	sdr_x := sw - sdr_panel_w - 10
	sdr_y: f32 = 10
	rl.DrawRectangle(i32(sdr_x), i32(sdr_y), i32(sdr_panel_w), i32(sdr_panel_h), Color{0, 0, 0, 150})
	rl.DrawRectangleLinesEx({sdr_x, sdr_y, sdr_panel_w, sdr_panel_h}, 1, Color{60, 80, 120, 150})

	rl.DrawText("SDR PATTERN", i32(sdr_x) + 8, i32(sdr_y) + 5, 12, Color{120, 150, 200, 180})

	cell_size: f32 = 6
	cell_gap: f32 = 1
	grid_x := sdr_x + 8
	grid_y := sdr_y + 22

	active_count := 0
	for i in 0..<SDR_SIZE {
		col := i % SDR_COLS
		row := i / SDR_COLS
		cx := grid_x + f32(col) * (cell_size + cell_gap)
		cy := grid_y + f32(row) * (cell_size + cell_gap)

		if l1.sdr[i] {
			active_count += 1
			// Color by which channel region this cell belongs to
			ch := i / (SDR_SIZE / CHEM_CHANNELS)
			ch = clamp(ch, 0, CHEM_CHANNELS - 1)
			c := chem_colors[ch]
			rl.DrawRectangle(i32(cx), i32(cy), i32(cell_size), i32(cell_size), c)
		} else {
			rl.DrawRectangle(i32(cx), i32(cy), i32(cell_size), i32(cell_size), Color{25, 25, 35, 200})
		}
	}

	// SDR stats
	rl.DrawText(
		fmt.ctprintf("%d/%d active (%.0f%% sparse)", active_count, SDR_SIZE, f32(active_count) / f32(SDR_SIZE) * 100),
		i32(sdr_x) + 8, i32(sdr_y + sdr_panel_h) - 18, 11, Color{100, 120, 160, 160},
	)

	// === Per-channel sparklines ===
	graph_x: f32 = 10
	graph_y: f32 = f32(panel_h) + 20
	graph_w: f32 = f32(panel_w)
	graph_h: f32 = 60
	rl.DrawRectangle(i32(graph_x), i32(graph_y), i32(graph_w), i32(graph_h), Color{0, 0, 0, 150})
	rl.DrawRectangleLinesEx({graph_x, graph_y, graph_w, graph_h}, 1, Color{60, 80, 120, 150})

	hist_len := len(l1.ch_history[0])
	for ch in 0..<CHEM_CHANNELS {
		c := chem_colors[ch]
		c.a = 180
		for i in 1..<hist_len {
			idx0 := (l1.hist_idx - hist_len + i - 1 + hist_len * 2) % hist_len
			idx1 := (l1.hist_idx - hist_len + i + hist_len * 2) % hist_len
			v0 := clamp(l1.ch_history[ch][idx0], 0, 1)
			v1 := clamp(l1.ch_history[ch][idx1], 0, 1)
			x0 := graph_x + f32(i - 1) / f32(hist_len) * graph_w
			x1 := graph_x + f32(i) / f32(hist_len) * graph_w
			y0 := graph_y + graph_h - v0 * graph_h
			y1 := graph_y + graph_h - v1 * graph_h
			rl.DrawLineEx({x0, y0}, {x1, y1}, 1.5, c)
		}
	}

	// === Message overlay ===
	if l1.message_timer > 0 && l1.message != nil {
		alpha := u8(min(l1.message_timer * 2, 1) * 255)
		msg_w := rl.MeasureText(l1.message, 20)
		mx := i32(sw / 2) - msg_w / 2
		my := i32(sh * 0.80)
		rl.DrawRectangle(mx - 15, my - 10, msg_w + 30, 40, Color{0, 0, 0, alpha / 2})
		rl.DrawText(l1.message, mx, my, 20, Color{255, 255, 255, alpha})
	}

	if l1.show_help {
		rl.DrawText("[WASD/Arrows] Fly  [T] Tag object  [H] Help  [ESC] Back", 10, i32(sh) - 30, 14, Color{80, 100, 140, 150})
	}

	rl.DrawText("LEVEL 1: CHEMICAL SENSOR", i32(sw) - 280, i32(sh) - 30, 18, Color{200, 180, 50, 180})
}

l1_cleanup :: proc(game: ^Game_State) {
	delete(l1.found)
}
