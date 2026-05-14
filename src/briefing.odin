package monty

import rl "vendor:raylib"

// Per-level detailed briefing text. Each string is broken into three sections
// with HEADERS so the render code can colour them: "WHAT'S HAPPENING",
// "THE MONTY CONCEPT", "WATCH FOR".
//
// Manual line wrapping — raylib's DrawText has no auto-wrap, and pre-wrapping
// gives reliable alignment with the panel width below.

briefing_motion := cstring(
`WHAT'S HAPPENING
You have no external sensors yet — only motion and self-tracking. The
ship integrates its velocity into a position over time (proprioception)
and remembers where you've been as a trail. Reach four invisible
waypoints by dead-reckoning from your start. You can plot a path, but
the world around you is hidden.

THE MONTY CONCEPT
Every Monty observation is paired with the agent's pose at the time of
sensing. Without the motor system, no two observations can be related to
each other in space — there's no "displacement between samples", which
is the entire basis for building object graphs. This level shows what's
missing when sensorimotor only has motor.

WATCH FOR
The trail your ship leaves is displacement integration in action. The
waypoint bearing display computes from your tracked pose. None of this
sees objects — you're navigating purely from your own movement.`)

briefing_smell := cstring(
`WHAT'S HAPPENING
Your nose has three distinct receptor channels — Sulfur, Organic, Crystal.
Every world object emits a unique chemical signature: a vector of three
values. Your sensor reads the BLEND of all nearby emissions, weighted by
inverse-square distance. Move to localize a source; press [T] when close
enough to tag the object.

THE MONTY CONCEPT
Sensation requires movement, AND features are multi-dimensional. A single
static reading tells you almost nothing — the same intensity could come
from many configurations. Monty's Features struct carries a VECTOR per
observation, not a scalar. The SDR grid is how sparse high-dimensional
codes represent these vectors in the brain: overlap means similarity.

WATCH FOR
The SDR grid on the right. Each channel activates cells in its own region.
When you're between two emitters, multiple regions light up simultaneously
— that's a "union" SDR, representing partial certainty.`)

briefing_light := cstring(
`WHAT'S HAPPENING
Aim your ship and pulse the photon probe with [F]. A ray fires forward;
the first object hit returns a brightness reading scaled by surface
albedo, the angle of incidence, and distance. Each pulse becomes a real
CMP_Message — displayed verbatim on the right side of the screen.

THE MONTY CONCEPT
"Features at a pose" — the atomic unit of the entire Monty system. Every
sensor produces these messages: { location, orientation, features,
confidence }. Every graph node stores one. Every learning step compares
against one. Every vote derives from one. Once you internalise this
structure, the rest of Monty is a way of organising and comparing them.

WATCH FOR
The CMP_MESSAGE panel showing the actual field values updating with each
pulse. That is literally the data flowing through Monty's whole pipeline.
Notice how brightness alone doesn't identify objects — but combined with
location and orientation (the pose), it becomes informative.`)

briefing_touch := cstring(
`WHAT'S HAPPENING
Two phases. LEARN: probe surfaces with [F]; each probe is a contact CMP
(location + surface normal + roughness + temperature). The Learning
Module accumulates these into an object graph — nodes are sampled
points, edges are displacements. Eight+ nodes commits an object. Learn
three. Then press [I] for INFER: the LM seeds thousands of hypotheses
(one per object × node × candidate rotation) and every probe updates
their evidence.

THE MONTY CONCEPT
The Learning Module is Monty's core computational unit — analogous to a
cortical column. It builds object graphs during learning. During
inference it maintains a population of pose hypotheses, scores each by
how well the predicted features at the predicted surface point match
what was sensed (morphology + features), and prunes the weak ones.

WATCH FOR
During LEARN: yellow graph nodes appearing on the object surface in 3D.
During INFER: the "active hypotheses" funnel collapsing from thousands
toward one, and the evidence bars diverging toward the winning object.`)

briefing_drones := cstring(
`WHAT'S HAPPENING
Three drones orbit your mothership, each with its own independent LM
running inference on the closest world object. By default all three
share votes — every probe, each drone broadcasts its top hypothesis to
the others; receivers prune hypotheses inconsistent with the vote.
Press [SPACE] to flip to all-solo for comparison. Identify three
objects to win.

THE MONTY CONCEPT
Multi-column voting — the Thousand Brains theory's central claim. Many
imperfect, locally-receiving columns reach a faster, more robust
consensus than any single column working alone. This is why the brain
has thousands of columns rather than one big network. Each one is
"voting" through long-range lateral connections.

WATCH FOR
The "RECENT RUNS" footer. After completing a run in each mode you'll see
"voting: X steps | solo: Y steps → voting ~Nx faster" — that speedup is
the central result of the theory, measured from your own play.`)

briefing_range := cstring(
`WHAT'S HAPPENING
A long-range laser probe — aim, fire, get a CMP reading from up to 30
units away. After each pulse the system computes a "curiosity hint": for
the top two candidate objects, where on the leading candidate's surface
would the runner-up disagree most? A cyan beacon rises out of the world
at that point. Aim there next to disambiguate fastest.

THE MONTY CONCEPT
Model-based action policies. Monty doesn't only score observations
passively — it generates GOAL-STATES: targeted sensor poses that, given
the current hypothesis set, would resolve uncertainty fastest. The brain
does this constantly: saccades to informative regions, fingers probing
edges and corners (not flat surfaces). Acting is inference.

WATCH FOR
The cyan beacon shifting between pulses as the top-two candidates change.
The "expected discrimination" score in the side panel. Following the hint
gives faster convergence than random scanning. Once only one candidate
remains, the hint vanishes — no disambiguation left to resolve.`)

briefing_eye := cstring(
`WHAT'S HAPPENING
A 3x3 optic patch grows on your ship's nose: nine receptors firing
simultaneously when you pulse. Each is its own Learning Module. After
each pulse: every LM ingests its own CMP, then they vote with each other
in a full mesh — every LM broadcasts to every other LM, using the world-
frame offset between their sensor positions.

THE MONTY CONCEPT
The Thousand Brains moment scaled up. Many parallel partial views, the
same algorithm running in each, integrated by lateral voting. The SDR
panel shows the UNION of active hypotheses across all 9 LMs — initially
wide, collapsing toward a single (object, rotation) cell as voting drives
agreement. That collapse IS the thousand brains in action.

WATCH FOR
The SDR PANEL on the right. Rows are candidate objects, columns are
rotation buckets. Cell brightness = how many of the 9 LMs have an active
hypothesis there. Watch it start wide and shrink. The "Union sparsity"
readout quantifies the collapse.`)

briefing_sonar := cstring(
`WHAT'S HAPPENING
One raycast per pulse — but the same hit point becomes TWO CMP messages
with disjoint feature populations: an OPTIC message (color + roughness),
and a SONAR message (resonance only). Each drives its own LM. After
every pulse, the two LMs vote with each other through the same CMP
voting primitives used by single-modality columns.

THE MONTY CONCEPT
The Cortical Messaging Protocol is modality-agnostic. Vote messages
carry hypotheses (object + pose + evidence) — features are stripped
away. So a vision LM and a hearing LM can collaborate identically to two
vision LMs, because the protocol abstracts modality. This is how the
brain integrates senses without a special "fusion" stage.

WATCH FOR
The cross-modal agreement banner. When both LMs settle on the same
object → green "CROSS-MODAL AGREEMENT". When they disagree → yellow
warning showing what each thinks. Each LM uses entirely different
feature evidence, yet they converge on the same identity.`)

briefing_sandbox := cstring(
`WHAT'S HAPPENING
An infinite procedurally-generated world. Each cell on a 2D hash grid
either holds an object or doesn't, deterministically — fly back and
you'll find the same things. Six archetypes (Iron Asteroid, Ice Boulder,
Crystal Spire, Lava Rock, Methane Pocket, Metal Debris), each distinct
on every feature dimension. Press [TAB] to toggle between single-laser
and 9-cell optic-array modes. [N] resets the LMs for a fresh episode.

THE MONTY CONCEPT
This is free play — every concept from every prior level applies. The
same algorithm scales: a single LM does fine on simple objects but the
9-LM array converges faster with lateral voting. The model database is
pre-loaded with all six archetypes so anything you find is identifiable
by features-at-pose. Streaming object generation keeps memory bounded:
objects spawn within view radius, get culled past it. The procedural
hash means the world is large but reproducible — same coords, same
content.

WATCH FOR
The archetype tally on the right side filling in as you encounter each
type. Position coords telling you where you are in the infinite world.
The hypothesis funnel collapsing per pulse. Switch modes mid-flight to
feel the difference between a single LM grinding and 9 LMs voting in
parallel.`)

briefing_fleet := cstring(
`WHAT'S HAPPENING
Three drones run lower-level LMs identifying single world objects. The
mothership runs a HIGHER-LEVEL matcher whose inputs are the lower LMs'
winner_obj IDs at their world poses. Three compositional models are
pre-loaded ("Refueling Outpost" = Fuel Tank + Beacon, etc.). When the
identified parts have the right relative arrangement, the higher level
fires. [N] resets only the drones; [B] resets everything.

THE MONTY CONCEPT
Hierarchical composition. The same "features at a pose" algorithm runs
at every level. LOW: features = colours + normals, nodes = points on a
surface. HIGH: features = part IDENTITIES, nodes = parts in object-
relative space. Whole objects emerge from arrangements of parts —
which can themselves be arrangements of sub-parts.

WATCH FOR
The HIGHER LM panel on the right. Each compositional model lists its
required parts; check marks fill in as the lower LMs identify them. The
higher LM remembers identifications PERSISTENTLY across drone resets —
you can accumulate parts across many fly-by passes.`)

@(private = "file")
briefing_open := false

@(private = "file")
briefing_scroll_y: f32 = 0       // current scroll offset within the content region

@(private = "file")
briefing_content_height: f32 = 0 // last-frame total height of rendered detail (for clamping)

briefing_is_open :: proc() -> bool { return briefing_open }
briefing_toggle  :: proc() {
	briefing_open    = !briefing_open
	briefing_scroll_y = 0
}
briefing_close   :: proc() { briefing_open = false }

// Reset scroll when switching to a different level's briefing
briefing_on_level_change :: proc() {
	briefing_scroll_y = 0
}

// Scroll input — call each frame from the level select while open
briefing_handle_scroll :: proc(dt: f32) {
	speed: f32 = 600.0
	if rl.IsKeyDown(.UP) || rl.IsKeyDown(.K) {
		briefing_scroll_y -= speed * dt
	}
	if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.J) {
		briefing_scroll_y += speed * dt
	}
	if rl.IsKeyPressed(.PAGE_UP)   do briefing_scroll_y -= 240
	if rl.IsKeyPressed(.PAGE_DOWN) do briefing_scroll_y += 240
	if rl.IsKeyPressed(.HOME)      do briefing_scroll_y = 0

	// Mouse wheel
	wheel := rl.GetMouseWheelMove()
	if wheel != 0 do briefing_scroll_y -= wheel * 60

	// Clamp at the end using last-frame's measured content height
	max_scroll := briefing_content_height
	if max_scroll < 0 do max_scroll = 0
	if briefing_scroll_y < 0 do briefing_scroll_y = 0
	if briefing_scroll_y > max_scroll do briefing_scroll_y = max_scroll
}

// Helper — draw text in the loaded Hack font at a given size and colour.
@(private = "file")
draw :: proc(text: cstring, x, y: i32, size: f32, c: Color) {
	rl.DrawTextEx(g_font, text, {f32(x), f32(y)}, size, 1, c)
}

@(private = "file")
measure :: proc(text: cstring, size: f32) -> f32 {
	return rl.MeasureTextEx(g_font, text, size, 1).x
}

briefing_draw :: proc(game: ^Game_State) {
	if !briefing_open do return

	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	info := game.levels[game.selected_level]

	// Dim the menu underneath
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), Color{0, 0, 0, 210})

	// Panel — wider to give more horizontal room for the prose
	pw: f32 = min(sw - 40, 1300)
	ph: f32 = min(sh - 40, sh - 40)
	px := (sw - pw) / 2
	py := (sh - ph) / 2
	rl.DrawRectangleRounded({px, py, pw, ph}, 0.02, 8, Color{15, 20, 30, 250})
	rl.DrawRectangleRoundedLinesEx({px, py, pw, ph}, 0.02, 8, 2, Color{100, 160, 220, 220})

	// Header — level name + sensor + status (raylib default font)
	rl.DrawText(info.name,        i32(px) + 28, i32(py) + 22, 40, Color{255, 255, 255, 255})
	rl.DrawText(info.sensor_name, i32(px) + 28, i32(py) + 70, 22, Color{120, 220, 160, 200})

	// Status pill on the right (raylib default font)
	status_text: cstring = "UNLOCKED"
	status_c := Color{120, 180, 255, 230}
	if info.completed {
		status_text = "✓ COMPLETED"
		status_c = Color{120, 255, 160, 230}
	} else if !info.unlocked {
		status_text = "LOCKED"
		status_c = Color{255, 140, 120, 220}
	}
	st_w := rl.MeasureText(status_text, 20)
	rl.DrawText(status_text, i32(px + pw) - st_w - 28, i32(py) + 28, 20, status_c)

	// Horizontal rule
	rl.DrawLine(i32(px) + 28, i32(py) + 110, i32(px + pw) - 28, i32(py) + 110,
		Color{60, 80, 120, 150})

	// ── Scrollable content region ───────────────────────────────────────
	content_top   := i32(py) + 124
	content_bot   := i32(py + ph) - 60   // leave room for footer
	content_h     := content_bot - content_top
	content_left  := i32(px) + 28
	content_w     := i32(pw) - 56 - 14    // leave 14px for scrollbar gutter

	rl.BeginScissorMode(content_left, content_top, content_w + 14, content_h)

	cy := content_top - i32(briefing_scroll_y)

	// Overview — section label (raylib default font) then body (Hack)
	rl.DrawText("OVERVIEW", content_left, cy, 18, Color{120, 180, 255, 200})
	cy += 26
	if info.description != nil {
		draw(info.description, content_left, cy, 21, Color{220, 230, 240, 230})
		// Count lines in description to advance cy
		dbody := ([^]u8)(info.description)
		di := 0
		desc_lines := 1
		for dbody[di] != 0 {
			if dbody[di] == '\n' do desc_lines += 1
			di += 1
		}
		cy += i32(desc_lines * 28) + 18
	}

	// Detail prose
	if info.detail != nil {
		cy = briefing_draw_detail(info.detail, content_left, cy)
	}

	rl.EndScissorMode()

	// Compute total content height for scrollbar / clamp
	content_total := f32(cy - (content_top - i32(briefing_scroll_y)))
	max_scroll := content_total - f32(content_h)
	if max_scroll < 0 do max_scroll = 0
	briefing_content_height = max_scroll

	// Scrollbar on the right edge of the content area
	if max_scroll > 0 {
		track_x := content_left + content_w + 4
		track_y := content_top
		track_w: i32 = 6
		track_h := content_h
		rl.DrawRectangle(track_x, track_y, track_w, track_h, Color{40, 50, 70, 160})

		thumb_frac := f32(content_h) / content_total
		thumb_h := i32(thumb_frac * f32(track_h))
		if thumb_h < 20 do thumb_h = 20
		thumb_pos_frac := briefing_scroll_y / max_scroll
		thumb_y := track_y + i32(thumb_pos_frac * f32(track_h - thumb_h))
		rl.DrawRectangle(track_x, thumb_y, track_w, thumb_h, Color{120, 180, 255, 220})
	}

	// Footer hint
	hint_y := i32(py + ph) - 44
	rl.DrawLine(i32(px) + 28, hint_y - 10, i32(px + pw) - 28, hint_y - 10,
		Color{60, 80, 120, 150})
	footer: cstring = "[LEFT/RIGHT] level   [UP/DOWN] scroll   [ENTER] launch   [D]/[ESC] back"
	if !info.unlocked {
		footer = "[LEFT/RIGHT] level   [UP/DOWN] scroll   [D]/[ESC] back   (locked)"
	}
	draw(footer, i32(px) + 28, hint_y, 17, Color{180, 200, 220, 220})
}

// Render the detail string with coloured section headers. Sections are
// identified by known all-caps single-line headers; everything else is body.
// Returns the final y cursor — caller uses this to know total content height.
@(private = "file")
briefing_draw_detail :: proc(text: cstring, x, y: i32) -> i32 {
	body_size:   f32 = 19
	header_size: f32 = 20
	line_h:      i32 = 24

	cy := y

	body := ([^]u8)(text)
	i := 0
	line_buf: [256]u8

	is_header :: proc(line: cstring) -> bool {
		switch line {
		case "WHAT'S HAPPENING", "THE MONTY CONCEPT", "WATCH FOR":
			return true
		}
		return false
	}

	for {
		// Scan one line into line_buf (null-terminated cstring)
		line_len := 0
		for line_len < len(line_buf) - 1 {
			c := body[i]
			if c == 0 || c == '\n' do break
			line_buf[line_len] = c
			line_len += 1
			i += 1
		}
		line_buf[line_len] = 0
		line_cstr := cstring(raw_data(line_buf[:]))

		if line_len == 0 {
			cy += line_h / 2
		} else if is_header(line_cstr) {
			cy += 8
			c := Color{120, 220, 255, 230}
			switch line_cstr {
			case "WHAT'S HAPPENING":  c = Color{255, 220, 100, 230}
			case "THE MONTY CONCEPT": c = Color{120, 220, 160, 230}
			case "WATCH FOR":         c = Color{220, 160, 255, 230}
			}
			// Headers use raylib's default font for visual contrast
			rl.DrawText(line_cstr, x, cy, i32(header_size), c)
			tw := rl.MeasureText(line_cstr, i32(header_size))
			cy += line_h
			rl.DrawLine(x, cy - 4, x + tw, cy - 4, c)
			cy += 6
		} else {
			// Body prose uses Hack
			draw(line_cstr, x, cy, body_size, Color{210, 220, 235, 230})
			cy += line_h
		}

		if body[i] == 0 do break
		i += 1
	}
	return cy
}
