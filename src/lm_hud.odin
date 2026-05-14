package monty

import rl "vendor:raylib"
import "core:fmt"

// Compact one-line version: "E M P" with each letter colored green/grey
// depending on whether the corresponding convergence criterion has been met.
// Used in tight HUD panels.
lm_draw_convergence_inline :: proc(lm: ^Learning_Module, x, y: i32) {
	on  := Color{120, 255, 160, 230}
	off := Color{120, 130, 150, 180}
	rl.DrawText("conv:", x, y, 12, Color{160, 180, 200, 180})
	e: Color = lm.crit_evidence ? on : off
	m: Color = lm.crit_margin   ? on : off
	p: Color = lm.crit_pose     ? on : off
	rl.DrawText("E", x + 36, y, 13, e)
	rl.DrawText("M", x + 50, y, 13, m)
	rl.DrawText("P", x + 64, y, 13, p)
	if lm.is_symmetric {
		rl.DrawText("(sym)", x + 80, y, 12, Color{220, 200, 100, 220})
	}
}

// Draws a small three-criterion convergence checklist for a Learning Module.
// Used by every level that runs inference, so the player can see which of
// Monty's three convergence tests are passing and which are holding things back.
//
// Layout: a single row of three pill labels, ~220px wide total.
//   [E ✓] [M ✓] [P ✗]   for evidence / margin / pose
//
// Returns the height drawn.
lm_draw_convergence_checklist :: proc(lm: ^Learning_Module, x, y: i32) -> i32 {
	pill_w: i32 = 70
	pill_h: i32 = 22
	gap:    i32 = 6

	draw_pill :: proc(label: cstring, ok: bool, x, y, w, h: i32) {
		bg := Color{40, 50, 70, 200}
		border := Color{80, 100, 130, 180}
		fg := Color{180, 200, 220, 220}
		if ok {
			bg = Color{40, 100, 60, 220}
			border = Color{100, 220, 140, 220}
			fg = Color{200, 255, 220, 240}
		}
		rl.DrawRectangle(x, y, w, h, bg)
		rl.DrawRectangleLines(x, y, w, h, border)
		mark: cstring = ok ? "✓" : "·"
		rl.DrawText(fmt.ctprintf("%s %s", label, mark), x + 8, y + 4, 13, fg)
	}

	rl.DrawText("CONVERGENCE", x, y, 11, Color{120, 160, 200, 180})

	pill_y := y + 14
	draw_pill("EVID",   lm.crit_evidence, x,                       pill_y, pill_w, pill_h)
	draw_pill("MARGIN", lm.crit_margin,   x + pill_w + gap,        pill_y, pill_w, pill_h)
	draw_pill("POSE",   lm.crit_pose,     x + (pill_w + gap) * 2,  pill_y, pill_w, pill_h)

	// Stable-steps indicator (for the symmetry path)
	if lm.stable_steps > 0 {
		rl.DrawText(fmt.ctprintf("stable: %d / %d (symmetry path)", lm.stable_steps, lm.sym_required_steps),
			x, pill_y + pill_h + 4, 11, Color{180, 180, 100, 180})
	}

	// Final state
	state_y := pill_y + pill_h + 22
	if lm.converged {
		if lm.is_symmetric {
			rl.DrawText("→ converged (symmetric)", x, state_y, 12, Color{220, 200, 100, 230})
		} else {
			rl.DrawText("→ converged", x, state_y, 12, Color{120, 255, 160, 230})
		}
	}

	return state_y + 16 - y
}
