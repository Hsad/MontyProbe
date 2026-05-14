# Monty: Evolving Sensors — Sequel Ideas

A living document for V2 concepts. Add to it freely as ideas arise.

---

## Core V2 Premise — "Dead Ship Cockpit"

The player starts inside the cockpit of a dead, drifting spacecraft. No
external view. No sensors. The hull is wrecked; the crew is gone. All
they have is one CRT panel slowly flickering to life.

Progress is *bringing systems back online*. Each system that comes back
gives the player a new way to perceive the outside world — strictly
through the cockpit instruments. There is no third-person camera.
You are literally inside the ship the whole game.

This inverts V1's god's-eye perspective. V1 teaches Monty top-down by
flying around. V2 makes you live inside the agent — you only know what
the LMs tell you.

---

## Phase 1 — "Boot one cortical column"

Most of the early game is building up a **single Learning Module** from
its constituent parts, one circuit at a time. The player wires up:

1. **Power & motor system** — the ship can rotate and translate, but
   you have no idea where you are. Pure proprioception loop running on
   a flickering display showing `Δpos` and heading drift.

2. **The sensor module** — a single contact pad on the hull. Provides
   one CMP message stream, displayed as raw numbers in a terminal:
   `{loc: ..., normal: ..., features: ...}`. The player has to read
   the print-out to figure out what's outside.

3. **The buffer / short-term memory** — observations start accumulating
   in a scrolling list. The player can see the most recent N. Without
   this, every observation is forgotten.

4. **The graph builder** — the buffer can now be committed as a learned
   object. A wireframe display starts drawing the graph nodes (in the
   ship's reference frame, since there's no external view).

5. **The hypothesis tracker** — once two objects are stored, a
   hypothesis-set panel comes online. Player watches bars rise/fall.

6. **The reference frame aligner** — the rotation hypotheses panel
   lights up. Now the LM can recognize objects from new angles.

7. **The action policy** — a "where to look next" arrow appears on the
   navigation display. The first model-based goal-state generator.

By the end of Phase 1, the player has a working LM and several views
into its internal state. They understand the column's anatomy because
they wired it up.

---

## Phase 2 — "Second column"

A second LM comes online — a different sensor on a different part of
the hull. Now we have multi-column behavior:

- Both columns build their own (partial) models of the same object
- The voting protocol (CMP votes) flips on as a separate "comms"
  system in the cockpit. You hear a static crackle when they exchange
  hypotheses
- The player watches the voting bar reduce convergence steps

This is the "Aha" moment: two columns working together literally
identifies things faster than the player had been managing with one.

---

## Phase 3 — "Hierarchy"

A higher-level LM comes online that takes the lower LMs' output as its
input features. The player learns compositional objects: "this is a
docking ring (lower LM) attached to a fuel cell (lower LM) — together,
a refuelling drone."

This is also where motor-action hierarchy makes sense: high-level
goals decompose into sensor-pose targets for the lower LMs.

---

## Cockpit Views (the UI grammar of V2)

Each instrument in the cockpit is a different *projection* of the same
underlying LM state. All running concurrently, all live:

| Instrument | What it shows |
|---|---|
| Hypothesis CRT | Bar chart: evidence per candidate object |
| Pose globe | 3D rotation hypotheses for the current MLH, clustering live |
| Graph plotter | Wireframe of the most-likely object's learned graph, rotated to the current pose hypothesis |
| Buffer roll | Recent CMP messages scrolling as text |
| Curiosity arrow | Where to point the next probe |
| Convergence panel | The three criteria (evidence / margin / pose) lighting up as they pass |
| Sensor RAW feed | Numbers from the SM, pre-CMP |
| Vote uplink | Pulses when this LM sends or receives a vote |

The player can rearrange the panels. Different scenarios make
different instruments load-bearing — sometimes the pose globe is the
only way to disambiguate, sometimes the curiosity arrow is decisive.

---

## Narrative Hooks

- Ship logs: text fragments revealing what the ship was doing before
  it died. Some hint at sensor placement (where to expect features).
  Pure flavour but it ties Monty concepts to a setting.
- The "crew" — implied through quarters layouts, voice memos. Their
  specializations could map to specific LM types.
- The hostile environment outside — debris fields, derelict stations.
  Identifying them well = staying alive.

---

## Technical Notes for V2

- All cockpit displays would be raylib render textures composited onto
  3D quads inside the cockpit interior. This keeps the "you're in a
  room" feel.
- Audio matters — sensor pings, voting crackle, the hum of
  newly-online circuits, the panic of low evidence.
- Maybe shaders on the CRTs: scanlines, slight bloom, occasional
  glitch frames when an LM is freshly booted and unstable.
- Could reuse the V1 LM core entirely — the algorithm doesn't change,
  only the *interface to it* does. Sequel is literally V1's `lm.odin`
  + a new cockpit shell.

---

## Open Questions

- Is there a "win" state in V2 or is it open-ended like a survival
  game? Voice-memo idea suggests it could have a story arc.
- Does the player ever leave the cockpit? Maybe in a final sequence
  the external view comes online and they see the whole world they've
  been inferring.
- Do columns "die" or get damaged? A failed system that needs to be
  repaired by triangulating its functioning peers is a great parable
  for the resilience of distributed columns.
