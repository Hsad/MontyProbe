# Monty: Evolving Sensors

An interactive game that teaches Numenta's **Thousand Brains Theory** and the
**Monty** sensorimotor learning framework by progressively unlocking sensors
on a spaceship and showing the algorithms behind recognition in real time.

Written in [Odin](https://odin-lang.org/) with raylib. Single executable, no
runtime dependencies beyond the dev shell. Saves progress between sessions.

## Quick start

```bash
nix develop --command odin build src/ -out:monty
./monty
```

(Or `nix develop --command odin run src/`.)

A NixOS flake provides Odin, raylib, X11/Wayland libs, and the bundled Hack
font asset. Save files live at `~/.local/share/monty/save.dat`.

## The lesson chain

Each level teaches one Monty primitive. Press `D` on any level in the menu
for a detailed briefing that maps the gameplay to the algorithm.

| Level | Sensor | Monty concept |
|---|---|---|
| Motion | Gyroscope only | Motor system / displacement tracking |
| Smell | Multi-channel chemical | Multi-dimensional features + SDR codes |
| Light | Directional photon probe | **Features at a pose** (the CMP atomic unit) |
| Touch | Contact scanner | **Learning Module** — object graphs + evidence |
| Drones | 3 drones with own LMs | **Multi-column voting** — the Thousand Brains claim |
| Range | Laser rangefinder | **Model-based action policies** (curiosity hint) |
| Eye | 9-cell sensor array | Thousand Brains at scale, SDR union viz |
| Sonar | Sonar + optic dual LM | **Modality-agnostic CMP** — cross-modal voting |
| Fleet | Drones + higher-LM | **Hierarchical composition** — parts → wholes |
| Sandbox | All sensors | Infinite procedural world, free play with full instrumentation |

## Architecture

```
src/
  main.odin           ─ window, font loading, main loop
  game.odin           ─ Game_State, scene routing, popups, Level_Info table
  briefing.odin       ─ in-game [D] briefing overlay with full Monty descriptions
  level_select.odin   ─ star-chart menu UI

  lm.odin             ─ Learning_Module: hypotheses, evidence, voting, convergence
  lm_hud.odin         ─ shared HUD widgets (convergence checklist / pills)
  object_model.odin   ─ Graph_Node, Object_Graph, Model_Database
  model_seed.odin     ─ analytical samplers (seed_sphere/_cube/_cylinder)
  sensor.odin         ─ CMP_Message + Features
  save.odin           ─ persistent save/load
  ship.odin           ─ Ship + Drone structs, flight, drawing
  world.odin          ─ World, fixed-object setup
  world_proc.odin     ─ procedural infinite world for Sandbox

  l0_motion.odin      ─ Level 0
  l1_smell.odin       ─ Level 1
  l2_light.odin       ─ Level 2
  l2_touch.odin       ─ Level 3 (file named after build order, not Level_ID)
  l4_drones.odin      ─ Level 4
  l5_range.odin       ─ Level 5
  l6_eye.odin         ─ Level 6
  l7_sonar.odin       ─ Level 7
  l8_fleet.odin       ─ Level 8
  l9_sandbox.odin     ─ Level 9 — free play with deep instrumentation

assets/fonts/Hack-Regular.ttf  ─ embedded at compile time via #load
```

### Core types

- `CMP_Message` — `{ location, orientation, features, confidence }`. The
  atomic unit of the system. Every sensor produces these; the LM consumes them.
- `Graph_Node` — a stored observation: pose + features in object-local frame.
- `Object_Graph` — a learned object as a sparse 3D graph of nodes.
- `Model_Database` — flat array of all learned objects.
- `Hypothesis` — "I'm at location L on object O with rotation R, evidence E."
- `Learning_Module` — the cortical-column unit. Builds graphs (learning mode)
  or maintains a hypothesis population (inference mode). Voting protocol is
  in `lm_generate_vote` / `lm_receive_vote`.

### Convergence

`lm_check_convergence` implements the three Monty criteria plus the symmetry
escape:

1. **EVIDENCE** — MLH evidence > `converge_min_evid` (4.0)
2. **MARGIN** — no other object within `converge_gap` (2.0) of MLH
3. **POSE** — all surviving MLH-object hypotheses within `path_sim_thresh`
   (1.5u) and `pose_sim_thresh` (~28°)
4. **SYMMETRY** — if active hypothesis count is stable for
   `sym_required_steps` (8), declare locally symmetric and converge anyway

`crit_evidence` / `crit_margin` / `crit_pose` / `is_symmetric` are exposed so
the HUD can show which checks are pending.

## Known gaps vs real Monty

This is a teaching reimplementation, not a port. Honest gaps:

- **Initial rotations**: we seed 8 fixed Y-axis rotations per node. Real Monty
  derives ~2 rotations per node from the *sensed* point normal + curvature
  axis — observation-driven, not blind.
- **Buffer / STM**: real Monty has an explicit observation buffer during
  inference that can be committed to graph memory on convergence (continuous
  learning). We commit immediately in learn mode and discard in infer mode.
- **Evidence update threshold**: real Monty's `evidence_update_threshold`
  (mean / median / X% / all) decides which hypotheses get updated per step.
  We update every active hypothesis.
- **Nearest-neighbour**: we use linear scan (fine for <512 nodes).
  Real Monty uses a KD-tree.
- **Feature weights**: we use uniform weights + fixed per-feature tolerances.
  Real Monty configures these per LM.
- **Goal-state generation**: our "curiosity hint" picks where the top-2
  candidates disagree on features. Real Monty generates more general action
  policies that propose any movement that reduces uncertainty.

The voting protocol now both **kills** inconsistent hypotheses **and**
**boosts** consistent ones (proportional to location alignment × voter
confidence). That matches real Monty's constructive voting.

## References

- [Monty source (tbp.monty)](https://github.com/thousandbrainsproject/tbp.monty)
- [Thousand Brains Project paper](https://arxiv.org/abs/2412.18354) (Dec 2024)
- [Monty API docs](https://api-monty.thousandbrains.org/)
- [Thousand Brains Project docs](https://thousandbrainsproject.readme.io/)

## Sequel

See `Sequel.md` for V2 ideas — a cockpit-only "dead ship" experience where
you boot up a single Learning Module piece by piece, with each circuit
unlocking a new view into the LM's internal state.
