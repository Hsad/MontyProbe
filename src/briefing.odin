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

briefing_is_open :: proc() -> bool { return briefing_open }
briefing_toggle  :: proc() { briefing_open = !briefing_open }
briefing_close   :: proc() { briefing_open = false }

briefing_draw :: proc(game: ^Game_State) {
	if !briefing_open do return

	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	info := game.levels[game.selected_level]

	// Dim the menu underneath
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), Color{0, 0, 0, 200})

	// Panel
	pw: f32 = min(sw - 80, 880)
	ph: f32 = min(sh - 60, 720)
	px := (sw - pw) / 2
	py := (sh - ph) / 2
	rl.DrawRectangleRounded({px, py, pw, ph}, 0.02, 8, Color{15, 20, 30, 250})
	rl.DrawRectangleRoundedLinesEx({px, py, pw, ph}, 0.02, 8, 2, Color{100, 160, 220, 220})

	// Header — level name + sensor + status
	rl.DrawText(info.name, i32(px) + 24, i32(py) + 20, 32, Color{255, 255, 255, 255})
	rl.DrawText(info.sensor_name, i32(px) + 24, i32(py) + 60, 16, Color{120, 220, 160, 200})

	status_x := i32(px + pw) - 200
	status_y := i32(py) + 24
	if info.completed {
		rl.DrawText("✓ COMPLETED", status_x, status_y, 16, Color{120, 255, 160, 230})
	} else if !info.unlocked {
		rl.DrawText("LOCKED", status_x, status_y, 16, Color{255, 140, 120, 220})
	} else {
		rl.DrawText("UNLOCKED", status_x, status_y, 16, Color{120, 180, 255, 230})
	}

	// Horizontal rule
	rl.DrawLine(i32(px) + 24, i32(py) + 90, i32(px + pw) - 24, i32(py) + 90,
		Color{60, 80, 120, 150})

	// Overview (short description)
	rl.DrawText("OVERVIEW", i32(px) + 24, i32(py) + 102, 13, Color{120, 180, 255, 200})
	if info.description != nil {
		rl.DrawText(info.description, i32(px) + 24, i32(py) + 122, 16,
			Color{220, 230, 240, 230})
	}

	// Detail — section-coloured paragraphs
	if info.detail != nil {
		detail_y := i32(py) + 200
		briefing_draw_detail(info.detail, i32(px) + 24, detail_y, i32(pw) - 48)
	}

	// Footer hints
	hint_y := i32(py + ph) - 36
	rl.DrawLine(i32(px) + 24, hint_y - 8, i32(px + pw) - 24, hint_y - 8,
		Color{60, 80, 120, 150})
	if info.unlocked {
		rl.DrawText("[ENTER] launch level   [D]/[ESC] back to map",
			i32(px) + 24, hint_y, 14, Color{180, 200, 220, 220})
	} else {
		rl.DrawText("Complete previous levels to unlock — [D]/[ESC] back to map",
			i32(px) + 24, hint_y, 14, Color{180, 180, 200, 200})
	}
}

// Render the detail string with coloured section headers. Sections are
// identified by all-caps single-line headers (WHAT'S HAPPENING / THE MONTY
// CONCEPT / WATCH FOR); everything else is body text.
@(private = "file")
briefing_draw_detail :: proc(text: cstring, x, y, w: i32) {
	// Walk the cstring byte-by-byte, emitting one line at a time
	body_size: i32 = 15
	header_size: i32 = 14
	line_h: i32 = 18

	cy := y

	// We render the raw cstring with manual line-breaks the author already
	// inserted. Detect headers by checking if a line is one of the known
	// section names; colour accordingly.
	header_what:  cstring = "WHAT'S HAPPENING"
	header_monty: cstring = "THE MONTY CONCEPT"
	header_watch: cstring = "WATCH FOR"

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
		// scan one line into line_buf (null-terminated cstring)
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
			cy += line_h / 2  // blank line spacer
		} else if is_header(line_cstr) {
			cy += 6
			c: Color = {120, 220, 255, 230}
			switch line_cstr {
			case "WHAT'S HAPPENING":  c = Color{255, 220, 100, 230}
			case "THE MONTY CONCEPT": c = Color{120, 220, 160, 230}
			case "WATCH FOR":         c = Color{220, 160, 255, 230}
			}
			rl.DrawText(line_cstr, x, cy, header_size, c)
			cy += line_h - 2
			// underline
			text_w := rl.MeasureText(line_cstr, header_size)
			rl.DrawLine(x, cy - 4, x + text_w, cy - 4, c)
			cy += 4
		} else {
			rl.DrawText(line_cstr, x, cy, body_size, Color{210, 220, 235, 230})
			cy += line_h
		}

		if body[i] == 0 do break
		i += 1  // skip the newline
	}
}
