package monty

import rl "vendor:raylib"

// In-game documentation of how this Odin reimplementation maps to (and
// diverges from) the actual Numenta Monty project. Reachable from the
// level selector with [I]. Scrollable like the per-level briefings,
// reusing briefing_draw_detail for the prose rendering.

about_text := cstring(
`THE PROJECT
This game teaches Numenta's Thousand Brains Theory and the Monty
sensorimotor learning framework by progressively unlocking sensors on
a spaceship. Every level demonstrates one Monty primitive: motor
system, features-at-pose, the Learning Module, multi-column voting,
model-based action policies, cross-modal CMP, hierarchical composition.

WHAT'S FAITHFUL
The core algorithm in src/lm.odin matches real Monty:

  - CMP_Message format: { location, orientation, features, confidence }
  - Reference-frame alignment: object_disp = R^T * body_disp
  - Hypothesis-population inference (thousands of candidates, not a
    single MLH)
  - Morphology score from sensed normal vs stored normal dot product
  - Per-feature similarity score with tolerances
  - Three-criterion convergence: EVIDENCE + MARGIN + POSE uniqueness
  - Symmetry escape path when pose can't be resolved
  - Voting protocol carrying hypotheses + offsets between LMs, with
    both DESTRUCTIVE pruning of inconsistent hypotheses AND CONSTRUCTIVE
    evidence boosts to consistent ones
  - Hierarchical composition: a higher LM treats lower LMs' winning
    object IDs as its own input features at relative poses

The same LM core runs at every level — the only differences are which
sensor produces the CMP messages and how many LMs are voting.

WHAT'S SIMPLIFIED
Honest authenticity gaps in this Odin implementation:

  1. INITIAL ROTATIONS. Real Monty derives ~2 rotations per node from
     the sensed point normal and curvature direction (the curvature
     axis has a 180-degree ambiguity). We seed 8 fixed Y-axis rotations
     per node, observation-blind. So real Monty starts inference with
     a much tighter, observation-informed pose set.

  2. BUFFER / SHORT-TERM MEMORY. Real Monty has an explicit observation
     buffer during inference that can be committed to long-term graph
     memory after recognition — supporting CONTINUOUS LEARNING. We
     commit immediately during the LEARN phase and discard observations
     in INFER mode. No new objects can be learned during inference.

  3. EVIDENCE UPDATE THRESHOLD. Real Monty's evidence_update_threshold
     (configurable: mean / median / X% of MLH / all) decides which
     hypotheses are worth updating each step — skip the weak ones to
     save work. We update every active hypothesis every step.

  4. NEAREST-NEIGHBOUR SEARCH. Real Monty uses a KD-tree (scipy
     KDTree) for graph node lookups. We do linear scan. Correct, but
     O(n) vs O(log n) — fine for our <512 nodes per object, worse at
     production scale.

  5. FEATURE WEIGHTS. Real Monty supports per-LM per-feature weights
     and tolerances. We use uniform weights with hard-coded tolerance
     constants (ROUGHNESS_TOL = 0.25, COLOR_TOL = 0.20, etc.).

  6. GOAL-STATE GENERATION. Our "curiosity hint" in the Range level
     picks the location where the top-2 candidates predict the most
     different features. Real Monty's goal generation is more general
     — proposing ANY action (translation, rotation, attention shift)
     that reduces hypothesis uncertainty fastest.

  7. WORLD MODEL. Real Monty runs in Habitat-Sim with photorealistic
     3D scenes and physics. Our world is sparse spheres / cubes /
     cylinders with hand-crafted material profiles.

WHY THE DIFFERENCES
This is a teaching reimplementation, not a port. Each shortcut removes
either substantial code complexity (KD-tree, observation-derived
rotations, the full habitat simulator) or per-experiment configuration
surface area (feature weights, update thresholds) that doesn't change
the conceptual lesson.

The omitted machinery becomes load-bearing when you're running
production-scale experiments — the kind in Numenta's benchmark papers
— but isn't needed to feel HOW multi-column voting collapses a
hypothesis funnel, or WHY reference-frame alignment makes object
recognition robust to rotation.

If you want to see the real implementation working on real objects,
clone tbp.monty and run the tutorials in their docs.

REAL MONTY POINTERS
  - tbp.monty source code:
    github.com/thousandbrainsproject/tbp.monty

  - Thousand Brains Project paper (December 2024):
    arxiv.org/abs/2412.18354

  - Monty API reference:
    api-monty.thousandbrains.org

  - Project documentation portal:
    thousandbrainsproject.readme.io

  - Original theory book — Jeff Hawkins, "A Thousand Brains" (2021).

The actual Monty source is about 30K lines of Python with comprehensive
configurability, multiple matching strategies, and integration with
real robotics simulators. This game is about 5K lines of Odin focused
on the conceptual core.

CREDITS
  Designed by Dash.
  Built with Opus 4.7.
  Odin + raylib. Hack font embedded as a compile-time asset.
  NixOS dev shell — same toolchain reproducible anywhere with a flake.
  Inspired by Numenta's Thousand Brains Project and Jeff Hawkins'
  book "A Thousand Brains."`)

@(private = "file")
about_open := false

@(private = "file")
about_scroll_y: f32 = 0

@(private = "file")
about_content_height: f32 = 0

about_is_open :: proc() -> bool { return about_open }

about_toggle :: proc() {
	about_open    = !about_open
	about_scroll_y = 0
}

about_close :: proc() { about_open = false }

about_handle_scroll :: proc(dt: f32) {
	speed: f32 = 600.0
	if rl.IsKeyDown(.UP)   || rl.IsKeyDown(.K) do about_scroll_y -= speed * dt
	if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.J) do about_scroll_y += speed * dt
	if rl.IsKeyPressed(.PAGE_UP)   do about_scroll_y -= 240
	if rl.IsKeyPressed(.PAGE_DOWN) do about_scroll_y += 240
	if rl.IsKeyPressed(.HOME)      do about_scroll_y = 0

	wheel := rl.GetMouseWheelMove()
	if wheel != 0 do about_scroll_y -= wheel * 60

	max_scroll := about_content_height
	if max_scroll < 0      do max_scroll = 0
	if about_scroll_y < 0  do about_scroll_y = 0
	if about_scroll_y > max_scroll do about_scroll_y = max_scroll
}

about_draw :: proc() {
	if !about_open do return

	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())

	// Dim background
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), Color{0, 0, 0, 220})

	// Panel
	pw: f32 = min(sw - 40, 1300)
	ph: f32 = min(sh - 40, sh - 40)
	px := (sw - pw) / 2
	py := (sh - ph) / 2
	rl.DrawRectangleRounded({px, py, pw, ph}, 0.02, 8, Color{15, 20, 30, 250})
	rl.DrawRectangleRoundedLinesEx({px, py, pw, ph}, 0.02, 8, 2, Color{120, 220, 255, 220})

	// Header
	rl.DrawText("ABOUT", i32(px) + 28, i32(py) + 22, 40, Color{255, 255, 255, 255})
	rl.DrawText("Odin reimplementation vs real Monty",
		i32(px) + 28, i32(py) + 70, 22, Color{120, 220, 255, 220})

	rl.DrawLine(i32(px) + 28, i32(py) + 110, i32(px + pw) - 28, i32(py) + 110,
		Color{60, 80, 120, 150})

	// Scrollable content
	content_top  := i32(py) + 124
	content_bot  := i32(py + ph) - 60
	content_h    := content_bot - content_top
	content_left := i32(px) + 28
	content_w    := i32(pw) - 56 - 14

	rl.BeginScissorMode(content_left, content_top, content_w + 14, content_h)
	end_y := briefing_draw_detail(about_text, content_left, content_top - i32(about_scroll_y))
	rl.EndScissorMode()

	// Scrollbar
	total := f32(end_y - (content_top - i32(about_scroll_y)))
	max_s := total - f32(content_h)
	if max_s < 0 do max_s = 0
	about_content_height = max_s

	if max_s > 0 {
		track_x := content_left + content_w + 4
		track_w: i32 = 6
		rl.DrawRectangle(track_x, content_top, track_w, content_h,
			Color{40, 50, 70, 160})
		thumb_frac := f32(content_h) / total
		thumb_h := i32(thumb_frac * f32(content_h))
		if thumb_h < 20 do thumb_h = 20
		thumb_y := content_top + i32((about_scroll_y / max_s) * f32(content_h - thumb_h))
		rl.DrawRectangle(track_x, thumb_y, track_w, thumb_h, Color{120, 220, 255, 220})
	}

	// Footer
	hint_y := i32(py + ph) - 44
	rl.DrawLine(i32(px) + 28, hint_y - 10, i32(px + pw) - 28, hint_y - 10,
		Color{60, 80, 120, 150})
	rl.DrawTextEx(g_font, "[UP/DOWN] scroll   [I]/[ESC] back to map",
		{f32(i32(px) + 28), f32(hint_y)}, 18, 1, Color{180, 220, 240, 220})
}
