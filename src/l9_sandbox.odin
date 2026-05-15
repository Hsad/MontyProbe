package monty

import rl "vendor:raylib"
import "core:math"
import "core:math/linalg"
import "core:fmt"
import "core:strings"

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

// Confusion-reset tuning. The LM auto-resets when the MLH gets sustained
// negative deltas, signalling that observations contradict its current
// object type. The threshold sits at 5 — large enough to absorb a couple
// of bad pulses from instance-switching (same type, new location) without
// nuking a healthy converged state, small enough that a real type change
// triggers within a few seconds.
CONFUSION_THRESHOLD       :: 5
CONFUSION_NEG_DELTA_GATE  :: f32(-0.4)   // delta below this counts as "wrong"
CONFUSION_POS_DELTA_GATE  :: f32(0.4)    // delta above this decrements the streak

// After convergence, hold for this many seconds so the player can see the
// result, then auto-reset and start a fresh inference. Turns the sandbox
// into a continuous identification stream instead of one-and-done.
POST_CONVERGE_HOLD  :: f32(2.5)

// Persistent memory of identified procedural-world instances, keyed by cell.
// Bounded so memory stays flat; oldest entries get overwritten when full.
MAX_IDENTIFIED_CELLS :: 512
MAX_RECENT_IDS       :: 6

// Live-learning parameters. The model_db starts EMPTY: the LM has to build
// each archetype's graph from real probes. After NOVELTY_MIN_PROBES on the
// same world object, if evidence is climbing too slowly (rate below
// NOVELTY_RATE_MAX per probe), we declare the object a new type, replay
// the buffered observations as lm_learn_steps, and commit a graph named
// after the actual archetype (we know it because procedural generation
// set obj.name).
//
// Why a RATE check, not an absolute threshold? Even a totally wrong
// match against an existing graph can accumulate evidence steadily — a
// Rhust hypothesis "watching" a Frell sphere scores morphology ≈ 1.0
// per probe by coincidence (radial normals align on any sphere) while
// features score 0. That's ~1.0 per probe of nonsense, so an absolute
// cap gets blown through within 6-7 probes and novelty stops firing.
// A correct recognition accumulates ~2/probe; rate-based detection
// cleanly separates the two regimes.
LEARN_BUFFER_SIZE  :: 16
NOVELTY_MIN_PROBES :: 6
NOVELTY_RATE_MAX   :: f32(1.2)   // evidence/probe below this → novelty
NOVELTY_LEARN_NODES :: 8         // minimum probes harvested into the new graph

Sandbox_Mode :: enum { Single_Laser, Optic_Array }

// pattern_id is an index into game.model_db.objects — i.e. the LM's
// committed graph that absorbed this observation. The LM has no idea
// what proc-world archetype this corresponds to; it just knows it has
// graph #N. The player is the one who maps "Pattern-3 = oh, that's
// the cube I scanned earlier."
@(private = "file")
Identified_Cell :: struct {
	cell_x:        i32,
	cell_z:        i32,
	pattern_id:    int,
	t:             f32,
	pos:           Vec3,
}

@(private = "file")
Recent_Id :: struct {
	pattern_id:    int,
	t:             f32,
	pos:           Vec3,
}

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
	prev_hit:           Vec3,  // last single-laser hit point (world)
	probed_once:        bool,

	// Optic-array bookkeeping (per-cell)
	cell_origins:       [SANDBOX_PATCH_CELLS]Vec3,
	cell_hits:          [SANDBOX_PATCH_CELLS]bool,
	cell_hit_pos:       [SANDBOX_PATCH_CELLS]Vec3,
	cell_prev_hit:      [SANDBOX_PATCH_CELLS]Vec3,  // hit point at last pulse
	cell_probed_once:   [SANDBOX_PATCH_CELLS]bool,

	// Identifications per committed pattern (model_db index)
	id_count:           [MAX_OBJECTS]int,

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

	// Self-reset on confusion — if observations consistently contradict the
	// current MLH, count up; when the counter exceeds a threshold we trigger
	// a new inference episode automatically so the player doesn't have to
	// press N every time they fly to a different object.
	confusion_streak:   int,

	// Auto-cycle: after the focus LM converges we run this countdown, then
	// auto-reset so the player gets a stream of identifications instead of
	// being stuck on one.
	post_converge_timer: f32,
	auto_cycle_enabled:  bool,

	// Per-instance memory — which procedural cells have been identified, and
	// which archetype they came out as. Used to halo recognised objects in
	// the world and to feed the recent-IDs ticker.
	identified_cells:   [MAX_IDENTIFIED_CELLS]Identified_Cell,
	identified_count:   int,
	identified_head:    int,  // ring-buffer write index when count == MAX

	recent_ids:         [MAX_RECENT_IDS]Recent_Id,
	recent_ids_head:    int,
	recent_ids_count:   int,

	// ── Live-learning state (single-laser focus LM = LM 0) ──────────────
	// No ground-truth dedup: every novelty commit makes a fresh graph,
	// even if it ends up being a duplicate of a prior pattern for the
	// same true archetype. The LM has no way to know they're the same;
	// only inference convergence can consolidate.
	pattern_counter:    int,    // increments on each commit → graph name "Pattern-N"
	learn_cmps:         [LEARN_BUFFER_SIZE]CMP_Message,
	learn_disps:        [LEARN_BUFFER_SIZE]Vec3,
	learn_count:        int,
	learn_target_wi:    int,    // world-object index the buffer is following

	// Discovery celebration
	discovery_anim:     f32,
	discovery_pattern:  int,    // model_db index of the freshly committed pattern
	discovery_pos:      Vec3,

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
	l9.mode               = .Single_Laser
	l9.auto_cycle_enabled = true
	l9.show_help          = true
	l9.learn_target_wi    = -1
	l9.pattern_counter    = 0
	l9.message            = "Unknown world — every object starts as a dust cloud.\nProbe one with [F] to commit a new graph (Pattern-N) for it."
	l9.message_timer      = 10

	game.ship.pos     = {0, 0, 0}
	game.ship.heading = 0
	game.ship.vel     = {0, 0, 0}
	game.ship.speed   = 0
	clear(&game.ship.trail)

	// Start with EMPTY model_db — types are learned live as the player
	// probes unknown objects. Once committed, a type's instances become
	// visible across the world.
	model_db_init(&game.model_db)

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

	// Track confusion at the MLH. Strongly negative deltas across multiple
	// pulses signal the LM has converged on the wrong object type — its
	// alternative-type hypotheses were pruned away, so it can't flip
	// naturally. Note: switching from one Iron Asteroid to ANOTHER iron
	// asteroid usually produces only briefly-negative deltas (just the
	// location estimate is stale, type still matches features), which is
	// why the streak threshold is set fairly high.
	if lm.mlh_idx >= 0 && lm.mlh_idx < lm.hyp_count && lm.step_count > 0 {
		delta := lm.step_info[lm.mlh_idx].delta
		if delta < CONFUSION_NEG_DELTA_GATE {
			l9.confusion_streak += 1
		} else if delta > CONFUSION_POS_DELTA_GATE {
			// Solidly positive evidence — we're back on the rails.
			// Decrement (not zero) so a small relief doesn't wipe a long
			// confusion run.
			if l9.confusion_streak > 0 do l9.confusion_streak -= 1
		}
		// In between (-0.4 .. 0.4) the streak holds — same-instance pose
		// adjustments often produce small deltas in this band.
	}
}

// Returns true if we just auto-reset due to sustained confusion at MLH
@(private = "file")
maybe_self_reset :: proc(game: ^Game_State) -> bool {
	if l9.confusion_streak < CONFUSION_THRESHOLD do return false
	l9_reset_lms(game)
	l9.message       = "Self-reset — features kept contradicting the MLH.\nLM started a new inference episode."
	l9.message_timer = 3.5
	return true
}

@(private = "file")
l9_find_identified_cell :: proc(cell_x, cell_z: i32) -> int {
	for i in 0..<l9.identified_count {
		c := &l9.identified_cells[i]
		if c.cell_x == cell_x && c.cell_z == cell_z do return i
	}
	return -1
}

@(private = "file")
l9_remember_cell :: proc(cell_x, cell_z: i32, pattern_id: int, pos: Vec3, t: f32) {
	entry := Identified_Cell{
		cell_x = cell_x, cell_z = cell_z, pattern_id = pattern_id, pos = pos, t = t,
	}
	existing := l9_find_identified_cell(cell_x, cell_z)
	if existing >= 0 {
		l9.identified_cells[existing] = entry
		return
	}
	if l9.identified_count < MAX_IDENTIFIED_CELLS {
		l9.identified_cells[l9.identified_count] = entry
		l9.identified_count += 1
	} else {
		// Ring-buffer overwrite (oldest)
		l9.identified_cells[l9.identified_head] = entry
		l9.identified_head = (l9.identified_head + 1) % MAX_IDENTIFIED_CELLS
	}
}

@(private = "file")
l9_push_recent :: proc(pattern_id: int, pos: Vec3, t: f32) {
	l9.recent_ids[l9.recent_ids_head] = Recent_Id{ pattern_id = pattern_id, pos = pos, t = t }
	l9.recent_ids_head = (l9.recent_ids_head + 1) % MAX_RECENT_IDS
	if l9.recent_ids_count < MAX_RECENT_IDS do l9.recent_ids_count += 1
}

// Record an LM recognition. The pattern_id IS the model_db index the LM
// converged on — we report Monty's actual decision, including mistakes.
// probed_wi is the world object the user pointed at so the halo lands
// on the right instance even when the LM is wrong about the archetype.
@(private = "file")
l9_record_id :: proc(game: ^Game_State, lm: ^Learning_Module, probed_wi: int) {
	if !lm.converged || lm.winner_obj < 0 do return
	if lm.winner_obj >= game.model_db.object_count do return
	pattern_id := lm.winner_obj
	l9.id_count[pattern_id] += 1

	now := f32(rl.GetTime())
	pos: Vec3 = l9.last_cmp_world
	if probed_wi >= 0 && probed_wi < len(game.world.objects) {
		obj := &game.world.objects[probed_wi]
		pos = obj.pos
		l9_remember_cell(obj.cell_x, obj.cell_z, pattern_id, pos, now)
	}
	l9_push_recent(pattern_id, pos, now)

	// Kick off the auto-cycle hold so the player can see this result before
	// the LM is reset for the next inference episode.
	if l9.auto_cycle_enabled do l9.post_converge_timer = POST_CONVERGE_HOLD
}

// Find the max evidence across all active hypotheses in any LM.
@(private = "file")
lm_max_active_evidence :: proc(lm: ^Learning_Module) -> f32 {
	best: f32 = 0
	for i in 0..<lm.hyp_count {
		h := &lm.hypotheses[i]
		if !h.active do continue
		if h.evidence > best do best = h.evidence
	}
	return best
}

// Reset the rolling probe buffer used for novelty detection.
@(private = "file")
l9_reset_learn_buffer :: proc() {
	l9.learn_count     = 0
	l9.learn_target_wi = -1
}

// Append a fresh probe to the learn buffer. Drops oldest if full.
@(private = "file")
l9_buffer_push :: proc(cmp: CMP_Message, disp: Vec3) {
	if l9.learn_count < LEARN_BUFFER_SIZE {
		l9.learn_cmps[l9.learn_count]  = cmp
		l9.learn_disps[l9.learn_count] = disp
		l9.learn_count += 1
	} else {
		// shift left, append at end
		for i in 1..<LEARN_BUFFER_SIZE {
			l9.learn_cmps[i - 1]  = l9.learn_cmps[i]
			l9.learn_disps[i - 1] = l9.learn_disps[i]
		}
		l9.learn_cmps[LEARN_BUFFER_SIZE - 1]  = cmp
		l9.learn_disps[LEARN_BUFFER_SIZE - 1] = disp
	}
}

// Commit a fresh graph from buffered probes. The graph's identity is just
// a counter — "Pattern-1", "Pattern-2", ... The LM doesn't know what kind
// of object it just learned; it only knows it built a new graph that
// inference will compare against on future probes. If the LM later
// fails to recognise another instance of the same true archetype, a
// DIFFERENT pattern number will be committed for it. Two graphs for
// the same underlying object is a real Monty failure mode (no
// consolidation step).
@(private = "file")
l9_commit_new_pattern :: proc(game: ^Game_State) {
	if l9.learn_count == 0 do return

	l9.pattern_counter += 1
	name := fmt.aprintf("Pattern-%d", l9.pattern_counter)
	// aprintf allocates; store as cstring permanently. model_db keeps a
	// reference to this string for the lifetime of the graph.
	cname := strings.clone_to_cstring(name)
	delete(name)

	lm := &game.lms[0]

	// Fresh learning episode using the buffered observations.
	lm_init(lm, 0)
	lm_start_learning(lm, l9.learn_cmps[0].location)
	for i in 0..<l9.learn_count {
		lm_learn_step(lm, l9.learn_cmps[i], l9.learn_disps[i])
	}

	obj_idx := lm_commit(lm, &game.model_db, cname)
	if obj_idx < 0 {
		// Model database full — re-arm inference and bail
		lm_init(lm, 0)
		lm_start_inference(lm, &game.model_db)
		l9.pattern_counter -= 1   // commit failed, roll back the counter
		return
	}

	// Refresh ALL LMs against the now-larger model_db so future probes
	// can compare against this new graph.
	for i in 0..<MAX_LMS {
		lm_init(&game.lms[i], i)
		lm_start_inference(&game.lms[i], &game.model_db)
	}

	// Celebration banner + halo
	l9.discovery_anim    = 2.5
	l9.discovery_pattern = obj_idx
	l9.discovery_pos     = l9.learn_cmps[l9.learn_count - 1].location

	now := f32(rl.GetTime())
	l9_push_recent(obj_idx, l9.discovery_pos, now)
	if l9.learn_target_wi >= 0 && l9.learn_target_wi < len(game.world.objects) {
		obj := &game.world.objects[l9.learn_target_wi]
		l9_remember_cell(obj.cell_x, obj.cell_z, obj_idx, obj.pos, now)
	}

	l9.message       = fmt.ctprintf("NEW PATTERN COMMITTED: %s\n(%d nodes from %d probes)",
		cname, game.model_db.objects[obj_idx].node_count, l9.learn_count)
	l9.message_timer = 4

	// Clear the buffer — fresh inference starts now.
	l9_reset_learn_buffer()
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

	// If the player swept the laser onto a different world object, restart
	// the learn buffer — it should only carry observations of one object so
	// novelty-detection works.
	if idx != l9.learn_target_wi {
		l9_reset_learn_buffer()
		l9.learn_target_wi = idx
	}

	// Hit-point delta is the right displacement for a rangefinder; if the
	// buffer was just cleared, this is the first probe of a fresh episode
	// and disp must be zero.
	disp: Vec3
	if l9.probed_once && l9.learn_count > 0 {
		disp = hit - l9.prev_hit
	}
	l9.prev_hit    = hit
	l9.probed_once = true

	// Append to the rolling buffer BEFORE lm_step so we can also use it
	// for the learning replay if novelty triggers.
	l9_buffer_push(cmp, disp)

	lm := &game.lms[0]
	was_converged := lm.converged
	diag_pre(game)
	lm_step(lm, cmp, disp, &game.model_db)
	diag_post(game)

	if lm.converged && !was_converged {
		// Whatever the LM converged on is what we report — even if it's
		// wrong. Mis-recognition of similar archetypes is one of Monty's
		// real failure modes (rate-based novelty can be bypassed when
		// two graphs overlap enough on features to keep evidence growth
		// healthy), and the demo should expose that rather than paper
		// over it with a ground-truth check. The halo will end up in the
		// LM's believed archetype colour so mis-classifications are
		// visible at a glance.
		l9_record_id(game, lm, idx)
		l9_reset_learn_buffer()
	} else if !lm.converged && l9.learn_count >= NOVELTY_MIN_PROBES {
		// Evidence growth rate stayed too low across enough probes → novelty.
		// Commit unconditionally — the LM has no ground-truth way to know
		// whether this is genuinely a new type or just a known one it
		// failed to recognise (a real Monty limitation, no consolidation).
		max_evid := lm_max_active_evidence(lm)
		rate := max_evid / f32(l9.learn_count)
		if rate < NOVELTY_RATE_MAX && l9.learn_count >= NOVELTY_LEARN_NODES {
			l9_commit_new_pattern(game)
		}
	}

	log_append({t = now, valid = true, cell_idx = -1, obj_name = obj.name, cmp = cmp})
	maybe_self_reset(game)
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
		// Hit-point delta is the right displacement for a rangefinder.
		disps[i] = l9.cell_probed_once[i] ? hit - l9.cell_prev_hit[i] : Vec3{0, 0, 0}
		l9.cell_prev_hit[i]    = hit
		l9.cell_probed_once[i] = true
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
			if !valid[receiver] do continue
			if game.lms[receiver].converged do continue
			// Contact-point offset, not cell-origin offset. See lm_receive_vote.
			offset := l9.cell_hit_pos[receiver] - l9.cell_hit_pos[sender]
			lm_receive_vote(&game.lms[receiver], vote, offset, &game.model_db)
		}
	}

	// Record IDs on freshly converged LMs. De-dup by pattern_id (model_db
	// index) — multiple cells often converge on the same graph in one
	// pulse and we only want one record per graph per pulse.
	recorded_pat: [MAX_OBJECTS]bool
	for i in 0..<SANDBOX_PATCH_CELLS {
		lm := &game.lms[i]
		if !lm.converged || prev_converged[i] do continue
		if lm.winner_obj < 0 || lm.winner_obj >= game.model_db.object_count do continue
		if recorded_pat[lm.winner_obj] do continue
		recorded_pat[lm.winner_obj] = true
		if l9.cell_hits[i] {
			l9.last_cmp_world = l9.cell_hit_pos[i]
			l9.last_cmp_valid = true
		}
		// Look up which world object this cell hit so we mark the right cell
		probed_wi := -1
		if l9.cell_hits[i] {
			best_d: f32 = 1e9
			for oi in 0..<len(game.world.objects) {
				d := linalg.distance(game.world.objects[oi].pos, l9.cell_hit_pos[i])
				if d < best_d { best_d = d; probed_wi = oi }
			}
		}
		// Whatever the LM converged on is reported, even if wrong.
		l9_record_id(game, lm, probed_wi)
	}

	// LIVE LEARNING in array mode — uses cell 0 as the learn-buffer source
	// (the same LM the deep-view HUD watches). If cell 0 hit something and
	// its LM stays below the novelty threshold over enough probes, we
	// commit a fresh graph for that archetype just like single-laser mode.
	if valid[0] {
		// Nearest world object to cell 0's hit — used to attribute the buffer
		hit_obj_idx := -1
		best_d: f32 = 1e9
		ref := l9.cell_hit_pos[0]
		for oi in 0..<len(game.world.objects) {
			d := linalg.distance(game.world.objects[oi].pos, ref)
			if d < best_d { best_d = d; hit_obj_idx = oi }
		}
		if hit_obj_idx != l9.learn_target_wi {
			l9_reset_learn_buffer()
			l9.learn_target_wi = hit_obj_idx
		}
		l9_buffer_push(cmps[0], disps[0])

		lm0 := &game.lms[0]
		if !lm0.converged && l9.learn_count >= NOVELTY_MIN_PROBES && hit_obj_idx >= 0 {
			max_evid := lm_max_active_evidence(lm0)
			rate := max_evid / f32(l9.learn_count)
			if rate < NOVELTY_RATE_MAX && l9.learn_count >= NOVELTY_LEARN_NODES {
				l9_commit_new_pattern(game)
			}
		}
	}

	maybe_self_reset(game)
}

@(private = "file")
l9_reset_lms :: proc(game: ^Game_State) {
	for i in 0..<MAX_LMS {
		lm_init(&game.lms[i], i)
		lm_start_inference(&game.lms[i], &game.model_db)
	}
	l9.probed_once       = false
	for i in 0..<SANDBOX_PATCH_CELLS do l9.cell_probed_once[i] = false
	l9.last_active       = 0
	l9.pruned_last_step  = 0
	l9.mlh_evidence_prev = 0
	l9.converge_time     = 0
	l9.converge_steps    = 0
	l9.confusion_streak  = 0
	l9_reset_learn_buffer()
}

l9_sandbox_update :: proc(game: ^Game_State, dt: f32) {
	if rl.IsKeyPressed(.ESCAPE) { popup_show(game, .Confirm_Leave_Level); return }
	if rl.IsKeyPressed(.H)      { l9.show_help = !l9.show_help }
	if rl.IsKeyPressed(.N) {
		l9_reset_lms(game)
		l9.post_converge_timer = 0
		l9.message       = "NEW EPISODE — LMs reset (identification counts kept)."
		l9.message_timer = 2.5
	}
	if rl.IsKeyPressed(.C) {
		l9.auto_cycle_enabled = !l9.auto_cycle_enabled
		if !l9.auto_cycle_enabled do l9.post_converge_timer = 0
		mm: cstring = "AUTO-CYCLE ON — converged LMs reset after a brief hold"
		if !l9.auto_cycle_enabled do mm = "AUTO-CYCLE OFF — manual [N] to reset"
		l9.message       = mm
		l9.message_timer = 2.5
	}
	if rl.IsKeyPressed(.TAB) {
		l9.mode = l9.mode == .Single_Laser ? .Optic_Array : .Single_Laser
		l9_reset_lms(game)
		l9.post_converge_timer = 0
		mm: cstring = "SINGLE LASER mode"
		if l9.mode == .Optic_Array do mm = "OPTIC ARRAY mode (9 LMs)"
		l9.message       = mm
		l9.message_timer = 2.0
	}

	// Auto-cycle: after the focus LM converges and the celebration hold
	// elapses, reset so the player can identify the next thing.
	if l9.post_converge_timer > 0 {
		l9.post_converge_timer -= dt
		if l9.post_converge_timer <= 0 {
			l9_reset_lms(game)
			l9.post_converge_timer = 0
		}
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

	if l9.message_timer  > 0 do l9.message_timer  -= dt
	if l9.discovery_anim > 0 do l9.discovery_anim -= dt
}

// ── 3D draw ─────────────────────────────────────────────────────────────────

// Halo color derived from a pattern_id (model_db index). Patterns get
// evenly-spaced hues via the golden-ratio trick so neighbouring numbers
// look distinct. The LM doesn't pick this — it's just a stable visual
// tag for each graph it commits.
@(private = "file")
pattern_halo_color :: proc(pattern_id: int) -> Color {
	if pattern_id < 0 do return Color{200, 200, 220, 255}
	// Hue rotation by golden angle (~137.5°) keeps colours far apart
	h := math.mod(f32(pattern_id) * 137.508, 360.0)
	// HSV → RGB with S=0.7, V=0.95
	c := f32(0.95) * 0.7
	x := c * (1 - abs(math.mod(h / 60.0, 2.0) - 1))
	m := f32(0.95) - c
	r, g, b: f32
	switch {
	case h <  60: r, g, b = c, x, 0
	case h < 120: r, g, b = x, c, 0
	case h < 180: r, g, b = 0, c, x
	case h < 240: r, g, b = 0, x, c
	case h < 300: r, g, b = x, 0, c
	case        : r, g, b = c, 0, x
	}
	return Color{u8((r + m) * 255), u8((g + m) * 255), u8((b + m) * 255), 255}
}

// Procedural dust-cloud render for an unknown object. Particle positions
// are deterministic per (cell_x, cell_z) so the cloud doesn't shimmer
// randomly each frame, but pulse gently with time.
@(private = "file")
draw_dust_cloud :: proc(obj: ^World_Object, is_aim_target: bool) {
	t := f32(rl.GetTime())
	seed := hash_2d(obj.cell_x, obj.cell_z)
	r := obj.size.x
	N :: 28

	for i in 0..<N {
		// Hash the index into the cell seed for stable but distinct angles
		s := seed ~ u32(i) * 2654435761
		s ~= s >> 13
		s *= 0x5bd1e995
		s ~= s >> 15

		theta: f32 = f32(s & 0xFFFF) / 65535.0 * 2 * f32(math.PI)
		phi:   f32 = f32((s >> 16) & 0xFFFF) / 65535.0 * f32(math.PI)
		rad:   f32 = r * (0.6 + 0.5 * f32((s >> 8) & 0xFF) / 255.0)
		// Gentle wobble — particles breathe
		rad *= 1.0 + 0.08 * math.sin(t * 0.9 + f32(i) * 0.7)

		p := obj.pos + Vec3{
			rad * math.sin(phi) * math.cos(theta),
			rad * math.cos(phi) * 0.7,
			rad * math.sin(phi) * math.sin(theta),
		}
		alpha: u8 = is_aim_target ? 220 : 150
		size: f32 = is_aim_target ? 0.10 : 0.075
		rl.DrawSphere(p, size, Color{180, 200, 240, alpha})
	}

	// Faint outer envelope — gives sense of "something is here"
	env_a: u8 = is_aim_target ? 60 : 30
	rl.DrawSphereWires(obj.pos, r * 1.15, 6, 6, Color{120, 160, 200, env_a})
}

l9_sandbox_draw :: proc(game: ^Game_State) {
	rl.BeginMode3D(game.camera)
	// Background grid only — we render objects ourselves so unknown vs
	// learned types use different visuals.
	world_draw(&game.world, false)
	ship_draw(&game.ship)
	ship_draw_trail(&game.ship)

	// Where the laser is currently pointed — for highlighting the active
	// dust cloud as the player aims.
	fwd_aim := ship_forward(&game.ship)
	aim_idx, _, _ := l9_raycast(&game.world, game.ship.pos, fwd_aim)

	// Per-object rendering: full geometry ONLY if THIS specific instance
	// has been individually scanned and recognised. The type being learned
	// doesn't auto-reveal future instances — each one still has to be
	// scanned (recognition just becomes faster once the LM has the graph).
	for i in 0..<len(game.world.objects) {
		obj := &game.world.objects[i]
		ic_idx := l9_find_identified_cell(obj.cell_x, obj.cell_z)
		instance_known := ic_idx >= 0

		if instance_known {
			// Geometry reveals what the object actually IS — the player
			// needs to be able to see what they probed so they can spot
			// mis-classifications. Halo, in contrast, reflects what the
			// LM BELIEVED. When the two disagree, the player sees an
			// authentic Monty mis-recognition: the shape is one thing
			// but the halo colour is another.
			c := Color{
				u8(obj.material.color.x * 255),
				u8(obj.material.color.y * 255),
				u8(obj.material.color.z * 255),
				255,
			}
			switch obj.kind {
			case .Sphere:
				rl.DrawSphere(obj.pos, obj.size.x, c)
				rl.DrawSphereWires(obj.pos, obj.size.x, 8, 8, Color{255, 255, 255, 40})
			case .Cube:
				rl.DrawCube(obj.pos, obj.size.x, obj.size.y, obj.size.z, c)
				rl.DrawCubeWires(obj.pos, obj.size.x, obj.size.y, obj.size.z, Color{255, 255, 255, 40})
			case .Cylinder:
				rl.DrawCylinder(obj.pos, obj.size.x, obj.size.x, obj.size.y, 12, c)
			case .Torus, .LShape:
				rl.DrawSphere(obj.pos, obj.size.x, c)
			}

			belief_pattern := l9.identified_cells[ic_idx].pattern_id
			if belief_pattern >= 0 {
				hc := pattern_halo_color(belief_pattern)
				rl.DrawSphereWires(obj.pos, obj.size.x + 0.25, 8, 8,
					Color{hc.r, hc.g, hc.b, 180})
			}
		} else {
			draw_dust_cloud(obj, i == aim_idx)
		}
	}

	// Celebration ring on the in-flight converged hold (if any)
	if l9.post_converge_timer > 0 && l9.recent_ids_count > 0 {
		idx := (l9.recent_ids_head - 1 + MAX_RECENT_IDS) % MAX_RECENT_IDS
		r   := l9.recent_ids[idx]
		if r.pattern_id >= 0 {
			c := pattern_halo_color(r.pattern_id)
			tt := 1 - (l9.post_converge_timer / POST_CONVERGE_HOLD)
			pulse := 1 + 0.6 * tt
			rl.DrawSphereWires(r.pos, 2.4 * pulse, 12, 12,
				Color{c.r, c.g, c.b, u8((1 - tt * 0.5) * 220)})
		}
	}

	// Discovery celebration — bright pulsing ring on a brand-new pattern
	if l9.discovery_anim > 0 && l9.discovery_pattern >= 0 {
		c := pattern_halo_color(l9.discovery_pattern)
		tt := 1 - (l9.discovery_anim / 2.5)
		pulse := 1 + tt * 1.8
		rl.DrawSphereWires(l9.discovery_pos, 1.8 * pulse, 14, 14,
			Color{c.r, c.g, c.b, u8((1 - tt) * 240)})
	}

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
	pw, ph: f32 = 320, 168
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

	// Auto-cycle indicator
	cycle_label: cstring = "auto-cycle: ON"
	cycle_c := Color{120, 255, 160, 220}
	if !l9.auto_cycle_enabled {
		cycle_label = "auto-cycle: OFF  [C] toggle"
		cycle_c = Color{200, 180, 120, 220}
	} else if l9.post_converge_timer > 0 {
		cycle_label = fmt.ctprintf("auto-cycle: resetting in %.1fs", l9.post_converge_timer)
		cycle_c = Color{255, 220, 100, 230}
	}
	rl.DrawText(cycle_label, 20, 132, 13, cycle_c)
	rl.DrawText("[C] toggle auto-cycle", 20, 150, 11, Color{120, 140, 170, 180})

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

	// Confusion streak — counter that triggers an auto-reset when high enough
	if l9.confusion_streak > 0 {
		streak_c := Color{255, 200, 120, 220}
		if l9.confusion_streak >= CONFUSION_THRESHOLD - 2 do streak_c = Color{255, 140, 100, 230}
		rl.DrawText(fmt.ctprintf("confusion streak: %d / %d  (auto-reset at %d)",
				l9.confusion_streak, CONFUSION_THRESHOLD, CONFUSION_THRESHOLD),
			i32(dv_x) + 10, my, 12, streak_c)
		my += 16
	}

	// Novelty signal — evidence-growth rate vs the cut-off that triggers
	// learning. Below the threshold means "the LM is stuck and a fresh
	// graph should be committed for this object."
	if l9.learn_count > 0 {
		max_evid := lm_max_active_evidence(lm0)
		rate := max_evid / f32(l9.learn_count)
		rate_c := Color{200, 220, 240, 220}
		hint:  cstring = "rate ok (recognising)"
		if l9.learn_count >= NOVELTY_MIN_PROBES && rate < NOVELTY_RATE_MAX {
			rate_c = Color{255, 200, 120, 230}
			hint   = "rate LOW — novelty pending"
		} else if rate < NOVELTY_RATE_MAX {
			rate_c = Color{200, 200, 220, 200}
			hint   = "rate low — need more probes"
		}
		rl.DrawText(fmt.ctprintf("novelty rate: %.2f / probe  (cut %.2f, buf %d/%d)  %s",
				rate, NOVELTY_RATE_MAX, l9.learn_count, LEARN_BUFFER_SIZE, hint),
			i32(dv_x) + 10, my, 12, rate_c)
		my += 16
	}

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

	// ── Right-side patterns panel ───────────────────────────────────────
	// Lists every graph committed by the LM. Empty at start, grows by one
	// each time novelty fires. Multiple entries can correspond to the same
	// true archetype if the LM failed to recognise an instance as a known
	// pattern — that's real Monty behaviour (no consolidation step).
	pattern_total := db.object_count

	right_x := sw - 360
	right_y: f32 = 10
	right_w: f32 = 350
	max_rows := 16
	displayed := min(pattern_total, max_rows)
	if displayed < 4 do displayed = 4
	right_h: f32 = 50 + f32(displayed) * 20
	rl.DrawRectangle(i32(right_x), i32(right_y), i32(right_w), i32(right_h),
		Color{0, 0, 0, 170})
	rl.DrawRectangleLinesEx({right_x, right_y, right_w, right_h}, 1,
		Color{100, 160, 220, 180})
	rl.DrawText(fmt.ctprintf("COMMITTED PATTERNS: %d", pattern_total),
		i32(right_x) + 10, i32(right_y) + 8, 13, Color{120, 180, 255, 220})
	rl.DrawText("(graphs the LM has built — names are pure counters)",
		i32(right_x) + 10, i32(right_y) + 26, 11, Color{140, 160, 190, 180})

	if pattern_total == 0 {
		rl.DrawText("  — nothing yet —", i32(right_x) + 10, i32(right_y) + 48, 13,
			Color{140, 160, 190, 200})
	} else {
		row := 0
		for pi in 0..<db.object_count {
			if row >= max_rows do break
			y := i32(right_y) + 48 + i32(row) * 20
			c := pattern_halo_color(pi)
			rl.DrawRectangle(i32(right_x) + 10, y + 2, 14, 12, c)
			rl.DrawText(db.objects[pi].name, i32(right_x) + 30, y + 2, 12,
				Color{220, 240, 255, 230})
			cnt := l9.id_count[pi]
			count_text := fmt.ctprintf("× %d", cnt)
			count_c := cnt > 0 ? Color{120, 255, 160, 230} : Color{160, 180, 200, 200}
			rl.DrawText(count_text, i32(right_x) + i32(right_w) - 60, y + 2, 12, count_c)
			row += 1
		}
		if pattern_total > max_rows {
			rl.DrawText(fmt.ctprintf("(+%d more)", pattern_total - max_rows),
				i32(right_x) + 10, i32(right_y) + 48 + i32(max_rows) * 20, 11,
				Color{160, 180, 200, 180})
		}
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

	// ── Recent identifications ticker ───────────────────────────────────
	ri_y := st_y + st_h + 10
	ri_h: f32 = 30 + f32(MAX_RECENT_IDS) * 22
	rl.DrawRectangle(i32(right_x), i32(ri_y), i32(right_w), i32(ri_h),
		Color{0, 0, 0, 170})
	rl.DrawRectangleLinesEx({right_x, ri_y, right_w, ri_h}, 1,
		Color{100, 220, 160, 180})
	rl.DrawText("RECENT IDS  (newest first)", i32(right_x) + 10, i32(ri_y) + 8, 13,
		Color{140, 240, 180, 230})
	now_t := f32(rl.GetTime())
	for i in 0..<l9.recent_ids_count {
		idx := (l9.recent_ids_head - 1 - i + MAX_RECENT_IDS) % MAX_RECENT_IDS
		r   := &l9.recent_ids[idx]
		if r.pattern_id < 0 || r.pattern_id >= db.object_count do continue
		y := i32(ri_y) + 30 + i32(i) * 22
		c := pattern_halo_color(r.pattern_id)
		rl.DrawRectangle(i32(right_x) + 10, y + 3, 12, 12, c)
		rl.DrawText(db.objects[r.pattern_id].name,
			i32(right_x) + 30, y + 2, 13, Color{220, 240, 255, 230})
		dt_ago := now_t - r.t
		ago_s: cstring = fmt.ctprintf("%.1fs ago", dt_ago)
		rl.DrawText(ago_s, i32(right_x) + i32(right_w) - 110, y + 2, 12,
			Color{160, 180, 210, 180})
		rl.DrawText(fmt.ctprintf("(%+.0f,%+.0f)", r.pos.x, r.pos.z),
			i32(right_x) + 170, y + 2, 11, Color{140, 160, 190, 180})
	}
	if l9.recent_ids_count == 0 {
		rl.DrawText("  (pulse an object to start the stream)",
			i32(right_x) + 10, i32(ri_y) + 36, 12, Color{140, 160, 190, 180})
	}

	// Identified-instance counter (bottom strip overlay)
	mapped_text := fmt.ctprintf("instances mapped: %d", l9.identified_count)
	rl.DrawText(mapped_text, i32(right_x) + 10, i32(ri_y) + i32(ri_h) - 18, 11,
		Color{160, 200, 230, 200})

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
		rl.DrawText("[WASD] Fly  [F] Pulse  [SPACE] Auto  [TAB] Mode  [N] Reset  [C] Auto-cycle  [H] Help  [ESC] Back",
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
