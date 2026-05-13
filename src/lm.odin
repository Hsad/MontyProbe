package monty

import "core:math"
import "core:math/linalg"

// Learning Module (LM) — Monty's core computational unit.
//
// Maps to a cortical column in the brain. Each LM:
//   1. LEARNS objects by accumulating (pose, features) observations into a graph
//   2. INFERS which object it's sensing by maintaining a set of pose hypotheses
//      and scoring them against each new observation + displacement
//
// The key insight (reference frame): when you move by displacement D while sensing
// object O with rotation R, the displacement in the object's own frame is R^T * D.
// This lets the LM predict where it should be on the object next, and check if
// the features there match what it actually senses.
//
// Multiple LMs (drones) vote laterally to reach consensus faster.

Mat3 :: matrix[3, 3]f32

MAT3_IDENTITY :: Mat3{1, 0, 0,  0, 1, 0,  0, 0, 1}

MAX_HYPOTHESES :: 4096

LM_Mode :: enum { Idle, Learning, Inferring }

// A single pose hypothesis:
//   "I am currently at location L on object O, and the object has rotation R"
Hypothesis :: struct {
    object_idx: int,
    location:   Vec3,   // current estimated position in object's local frame
    rotation:   Mat3,   // how the object is oriented (object→body frame)
    evidence:   f32,    // accumulated score — grows with each consistent observation
    active:     bool,
}

// Per-step debug info for visualization — what happened to one hypothesis
Hyp_Step_Info :: struct {
    node_idx:         int,    // which graph node was matched (-1 = miss)
    node_dist:        f32,
    morphology_score: f32,    // surface normal alignment [-1, 1]
    feature_score:    f32,    // feature similarity [0, 1]
    delta:            f32,    // total evidence change this step
}

// A vote message sent between LMs (level 4+)
LM_Vote :: struct {
    sender_id:  int,
    object_idx: int,
    location:   Vec3,   // where on the object the sender thinks it is
    rotation:   Mat3,   // sender's rotation estimate
    evidence:   f32,
}

Learning_Module :: struct {
    id:           int,
    mode:         LM_Mode,

    // --- Inference state ---
    hypotheses:   [MAX_HYPOTHESES]Hypothesis,
    hyp_count:    int,
    mlh_idx:      int,      // index of most-likely hypothesis
    converged:    bool,
    winner_obj:   int,      // object_idx of winner (-1 if none yet)

    // Per-step debug info (same index as hypotheses)
    step_info:    [MAX_HYPOTHESES]Hyp_Step_Info,
    last_cmp:     CMP_Message,
    last_disp:    Vec3,
    step_count:   int,

    // --- Learning state ---
    learn_buffer:  [MAX_GRAPH_NODES]Graph_Node,
    learn_count:   int,
    learn_origin:  Vec3,    // world-space start of learning episode
    learn_cursor:  Vec3,    // current accumulated position in object frame

    // --- Config ---
    max_match_dist:    f32,  // radius to search for matching nodes
    prune_fraction:    f32,  // prune hypotheses below (mlh_evidence * fraction)
    converge_min_evid: f32,  // MLH must exceed this before we declare a winner
    converge_gap:      f32,  // second-best must be this far below MLH evidence
}

lm_init :: proc(lm: ^Learning_Module, id: int) {
    lm^ = {}
    lm.id          = id
    lm.mode        = .Idle
    lm.mlh_idx     = -1
    lm.winner_obj  = -1
    // Sensible defaults matching Monty's published experiments
    lm.max_match_dist    = 1.2
    lm.prune_fraction    = 0.65
    lm.converge_min_evid = 4.0
    lm.converge_gap      = 2.0
}

// ─── Learning ────────────────────────────────────────────────────────────────

lm_start_learning :: proc(lm: ^Learning_Module, start_world_pos: Vec3) {
    lm.mode         = .Learning
    lm.learn_count  = 0
    lm.learn_origin = start_world_pos
    lm.learn_cursor = {0, 0, 0}  // object frame starts at origin
}

// Add a CMP observation during a learning episode.
// displacement = motion since last observation, in world/body frame.
lm_learn_step :: proc(lm: ^Learning_Module, cmp: CMP_Message, displacement: Vec3) {
    if lm.mode != .Learning do return
    if lm.learn_count >= MAX_GRAPH_NODES do return

    // Advance cursor in object frame (same as body frame during learning —
    // we're building the object model in the frame of the first observation)
    lm.learn_cursor += displacement

    node := Graph_Node{
        location  = lm.learn_cursor,
        normal    = cmp.orientation,
        features  = features_to_stored(cmp.features),
    }
    lm.learn_buffer[lm.learn_count] = node
    lm.learn_count += 1
}

// Commit the learning buffer to a new object in the database.
// Returns the new object index, or -1 on failure.
lm_commit :: proc(lm: ^Learning_Module, db: ^Model_Database, name: string) -> int {
    if lm.mode != .Learning || lm.learn_count == 0 do return -1

    obj_idx := model_db_new_object(db, name)
    if obj_idx < 0 do return -1

    for i in 0..<lm.learn_count {
        model_db_add_node(db, obj_idx, lm.learn_buffer[i])
    }

    lm.mode        = .Idle
    lm.learn_count = 0
    return obj_idx
}

// ─── Inference ───────────────────────────────────────────────────────────────

// Begin an inference episode — seed the hypothesis set from all known objects.
// Uses N_INIT_ROTS candidate rotations around the Y axis.
N_INIT_ROTS :: 8

lm_start_inference :: proc(lm: ^Learning_Module, db: ^Model_Database) {
    lm.mode       = .Inferring
    lm.hyp_count  = 0
    lm.mlh_idx    = -1
    lm.converged  = false
    lm.winner_obj = -1
    lm.step_count = 0

    rots := lm_init_rotations()

    for obj_idx in 0..<db.object_count {
        obj := &db.objects[obj_idx]
        for ni in 0..<obj.node_count {
            for ri in 0..<N_INIT_ROTS {
                if lm.hyp_count >= MAX_HYPOTHESES do return
                lm.hypotheses[lm.hyp_count] = {
                    object_idx = obj_idx,
                    location   = obj.nodes[ni].location,
                    rotation   = rots[ri],
                    evidence   = 0,
                    active     = true,
                }
                lm.hyp_count += 1
            }
        }
    }
}

// Core inference step.
// Call once per sensor observation with the new CMP reading and the
// displacement (in world/body frame) since the previous observation.
lm_step :: proc(lm: ^Learning_Module, cmp: CMP_Message, displacement: Vec3, db: ^Model_Database) {
    if lm.mode != .Inferring do return

    lm.last_cmp  = cmp
    lm.last_disp = displacement
    lm.step_count += 1

    max_evidence: f32 = -99999
    max_idx := -1

    for i in 0..<lm.hyp_count {
        hyp := &lm.hypotheses[i]
        if !hyp.active do continue

        obj := &db.objects[hyp.object_idx]

        // ── Reference frame alignment ──────────────────────────────────────
        // Rotate body-frame displacement into object frame.
        // R maps object→body, so R^T maps body→object.
        obj_disp    := linalg.transpose(hyp.rotation) * displacement
        search_loc  := hyp.location + obj_disp

        // ── Nearest-neighbour lookup ───────────────────────────────────────
        node_idx, node_dist := model_nearest_node(obj, search_loc, lm.max_match_dist)

        info := &lm.step_info[i]
        info.node_idx  = node_idx
        info.node_dist = node_dist

        delta: f32

        if node_idx < 0 {
            // Miss: no stored point near the predicted location → penalise
            info.morphology_score = -1
            info.feature_score    = 0
            delta = -1
        } else {
            node := &obj.nodes[node_idx]

            // Morphology: compare surface normals
            // Rotate sensed normal into object frame then dot with stored normal
            sensed_n_obj := linalg.normalize(linalg.transpose(hyp.rotation) * cmp.orientation)
            dot := clamp(linalg.dot(sensed_n_obj, node.normal), -1.0, 1.0)
            info.morphology_score = dot

            // Features: per-channel similarity with tolerances
            info.feature_score = lm_feature_score(cmp.features, node.features)

            delta = info.morphology_score + info.feature_score

            // Snap location to matched node (reduces drift)
            hyp.location = node.location
        }

        hyp.evidence += delta
        info.delta = delta

        if hyp.evidence > max_evidence {
            max_evidence = hyp.evidence
            max_idx = i
        }
    }

    lm.mlh_idx = max_idx

    // ── Prune weak hypotheses ──────────────────────────────────────────────
    if max_idx >= 0 {
        threshold := max_evidence * lm.prune_fraction
        for i in 0..<lm.hyp_count {
            if lm.hypotheses[i].active && lm.hypotheses[i].evidence < threshold {
                lm.hypotheses[i].active = false
            }
        }
    }

    lm_check_convergence(lm, db)
}

// ── Convergence check ────────────────────────────────────────────────────────
lm_check_convergence :: proc(lm: ^Learning_Module, db: ^Model_Database) {
    if lm.mlh_idx < 0 do return

    mlh := &lm.hypotheses[lm.mlh_idx]
    if mlh.evidence < lm.converge_min_evid do return

    // Find best evidence per object
    best := [MAX_OBJECTS]f32{}
    for i in 0..<lm.hyp_count {
        h := &lm.hypotheses[i]
        if h.active && h.evidence > best[h.object_idx] {
            best[h.object_idx] = h.evidence
        }
    }

    // Winner requires: no other object within converge_gap of MLH
    for obj_idx in 0..<db.object_count {
        if obj_idx == mlh.object_idx do continue
        if best[obj_idx] >= mlh.evidence - lm.converge_gap {
            return // still ambiguous
        }
    }

    lm.converged  = true
    lm.winner_obj = mlh.object_idx
}

// ── Feature scoring ──────────────────────────────────────────────────────────

ROUGHNESS_TOL  :: 0.25
TEMP_TOL       :: 0.30
COLOR_TOL      :: 0.20
CHEM_TOL       :: 0.20

lm_feature_score :: proc(sensed: Features, stored: Stored_Features) -> f32 {
    score: f32
    count: f32

    feature_match :: proc(sensed_val, stored_val, tol: f32) -> f32 {
        return max(0, 1 - abs(sensed_val - stored_val) / tol)
    }

    if .Roughness in stored.mask {
        if r, ok := sensed.roughness.?; ok {
            score += feature_match(r, stored.roughness, ROUGHNESS_TOL)
            count += 1
        }
    }
    if .Temperature in stored.mask {
        if t, ok := sensed.temperature.?; ok {
            score += feature_match(t, stored.temperature, TEMP_TOL)
            count += 1
        }
    }
    if .Color in stored.mask {
        if c, ok := sensed.color.?; ok {
            diff := linalg.distance(c, stored.color)
            score += max(0, 1 - diff / COLOR_TOL)
            count += 1
        }
    }

    if count == 0 do return 0
    return score / count
}

// ── Voting (lateral connections — used from level 4 / Drones) ────────────────

// Generate a vote from this LM's current MLH
lm_generate_vote :: proc(lm: ^Learning_Module) -> (LM_Vote, bool) {
    if lm.mlh_idx < 0 || !lm.hypotheses[lm.mlh_idx].active {
        return {}, false
    }
    mlh := &lm.hypotheses[lm.mlh_idx]
    return LM_Vote{
        sender_id  = lm.id,
        object_idx = mlh.object_idx,
        location   = mlh.location,
        rotation   = mlh.rotation,
        evidence   = mlh.evidence,
    }, true
}

// Apply incoming votes: eliminate hypotheses inconsistent with the vote
// offset = the known spatial offset between this LM's sensor and the voter's sensor
lm_receive_vote :: proc(lm: ^Learning_Module, vote: LM_Vote, offset: Vec3, db: ^Model_Database) {
    if lm.mlh_idx < 0 do return
    if vote.evidence < lm.converge_min_evid * 0.5 do return  // ignore weak votes

    VOTE_LOC_TOL :: 1.5

    for i in 0..<lm.hyp_count {
        h := &lm.hypotheses[i]
        if !h.active do continue
        if h.object_idx != vote.object_idx {
            // Different object — kill it
            h.active = false
            continue
        }
        // Same object: check if locations are consistent given the sensor offset
        // If voter is at L_v and we're displaced by `offset`, we should be at L_v + R^T*offset
        expected_loc := vote.location + linalg.transpose(vote.rotation) * offset
        if linalg.distance(h.location, expected_loc) > VOTE_LOC_TOL {
            h.active = false
        }
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

// 8 evenly-spaced rotations around the Y axis
// Simplified from Monty's full rotation set — covers the main orientations
lm_init_rotations :: proc() -> [N_INIT_ROTS]Mat3 {
    rots: [N_INIT_ROTS]Mat3
    for i in 0..<N_INIT_ROTS {
        a := f32(i) * (math.PI / f32(N_INIT_ROTS / 2))
        c := math.cos(a)
        s := math.sin(a)
        // Rotation around Y axis
        rots[i] = Mat3{c, 0, s,  0, 1, 0,  -s, 0, c}
    }
    return rots
}

// Count active hypotheses across all objects — useful for UI
lm_active_count :: proc(lm: ^Learning_Module) -> int {
    n := 0
    for i in 0..<lm.hyp_count {
        if lm.hypotheses[i].active do n += 1
    }
    return n
}

// Per-object active hypothesis count — for bar chart visualization
lm_active_per_object :: proc(lm: ^Learning_Module, db: ^Model_Database, out: []int) {
    for i in 0..<len(out) do out[i] = 0
    for i in 0..<lm.hyp_count {
        h := &lm.hypotheses[i]
        if h.active && h.object_idx < len(out) {
            out[h.object_idx] += 1
        }
    }
}

// Best evidence per object — for bar chart visualization
lm_best_evidence_per_object :: proc(lm: ^Learning_Module, db: ^Model_Database, out: []f32) {
    for i in 0..<len(out) do out[i] = 0
    for i in 0..<lm.hyp_count {
        h := &lm.hypotheses[i]
        if h.active && h.object_idx < len(out) && h.evidence > out[h.object_idx] {
            out[h.object_idx] = h.evidence
        }
    }
}
