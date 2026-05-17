# Monty V2 Design Spec — Mothership & The Cube World

A V2 reimagining grounded in Monty's actual mechanics. Where V1 used
free-flying spacecraft (which we discovered stretches in several places
— sensor offset from contact, drones-as-columns abstraction, etc.),
V2 puts the player above a discrete tiled cube world and uses
ground-bound rovers as the actual sensors. Every game mechanic is a
Monty mechanic, not an analogy to one.

The Dead-Ship-Cockpit ideas in `Sequel.md` are an alternative direction
and remain on the table. This spec is the *other* V2 path.

---

## Premise

You command a mothership stranded in orbit above a single unmapped
cube-shaped planet. The mothership has a partially-functional jump
drive — it can't get you home, but the planet's atmosphere periodically
generates ionic storms that shove the ship to a new orbital position
**at random rotation**. Every time a storm hits, you wake up looking
at a different patch of the surface, oriented differently than before,
and must figure out where on the cube you are and which way is north.

That's the entire game loop: storm → drop rovers → sense → recognise.

Why this works for teaching Monty:

- **Rovers stay on the surface.** A rover's position IS the contact
  point. Sensor displacement equals contact displacement equals
  hypothesis-location displacement. The entire class of "sensor is
  20 units off the surface so hit-point swings wildly" bugs we fixed
  in V1 simply doesn't exist by construction.
- **Multiple rovers per drop = lateral cortical columns.** Three to
  nine rovers within a few tiles of each other on the same patch of
  surface is the exact spatial relationship real cortical columns
  have. Voting between them has direct geometric meaning.
- **The planet IS the object being modeled.** No scale mismatch.
  Object-local frame = planet-local coordinates. Cleanest possible
  mapping for reference-frame machinery.
- **Random respawn rotation IS the rotation discovery demo.** Monty
  seeds N rotation hypotheses per node; the player feels what those
  hypotheses *are* every time a storm hits and they don't know which
  way is up.
- **Storm = kidnapped robot problem.** Monty's flagship inference
  scenario, made diegetic. You're constantly being kidnapped. The
  hypothesis-funnel collapse is the whole game.

---

## World Structure

The planet is a **cube**. Six faces, each a discrete grid of tiles.

- 16 × 16 tiles per face
- 6 faces × 256 tiles = 1,536 tiles in the whole world
- Adjacent faces wrap at edges (with appropriate 90° rotation at the
  seam — like unfolding a cube). Initially the player works on one
  face at a time and edge-wrapping is V2-polish.

The cube framing is doing real work:

- Carcassonne tile mechanics stop being an analogy and become the
  literal geometry. Hawkins' tile-by-tile inference example IS the
  gameplay.
- Each face has a discrete identity ("north pole face", "industrial
  face", etc.) — natural top-tier composition.
- Spherical-coordinate math is avoided entirely.
- Visually playful and unmistakable — a cube planet reads as "weird
  enough to be alien" instantly.

---

## Tile Vocabulary

Deliberately tiny. The lesson is composition, not richness — every
extra tile type costs the player one more thing to memorise.

### Terrain tiles (~70% of the surface)

| Tile | Notes |
|---|---|
| dirt | the baseline; ~50% of all tiles |
| gravel | textured but uninteresting |
| rock-small / rock-large | landmark-able natural features |
| ice / sand | biome variation |

Terrain tiles do not participate in structure composition. They're
noise the LM has to learn to discard as un-discriminative.

### Structure tiles (the only ones that compose)

The vocabulary is intentionally tight:

| Tile | Shape | Orientation |
|---|---|---|
| `wall-N`, `wall-E`, `wall-S`, `wall-W` | straight wall segment | oriented |
| `corner-NE`, `corner-NW`, `corner-SE`, `corner-SW` | rounded outside corner | oriented |
| `door` | corner tile with an opening | oriented; replaces one corner |
| `floor` | interior space | optional — only used in 3×3+ buildings |

That's it. Nine tile classes. Walls, rounded corners, and a door-corner.

Three reasons to keep it this small:

1. The structure tier still has plenty of expressiveness (size + door
   position + roundness gives many distinct shapes).
2. Sub-feature transfer becomes obvious: `wall-N` appears in every
   rectangular structure, so the LM's wall-tile-graph is reused across
   every building type the player ever encounters.
3. Rotation discovery has direct visible signal: every oriented tile
   contributes to collapsing the 4 rotation hypotheses for the
   structure that contains it. The player sees the orientation
   arguments fall out of the tile data.

### Structures from this vocabulary

The smallest meaningful structure is a 2 × 2 — four tiles where each
is a rounded corner and one of those is a door:

```
NW    NE
SW    door
```

This is the **Outpost Hab**. Rotation comes from which corner is the
door — there are 4 rotational variants, all the same structure.

Larger structures interleave walls between corners:

**Hab (3 × 3):**
```
NW    N    NE
W   floor   E
SW   door   SE
```

**Long Hab / Lab (4 × 3):**
```
NW    N    N    NE
W   floor floor  E
SW   door   S    SE
```

**Big Hab (3 × 3 with no floor — solid block):**
```
NW    N    NE
W   door   E
SW    S    SE
```

Even at this vocabulary size you get half a dozen+ recognisable
structures with distinct graph signatures. The LM's job is to recognise
the *arrangement*; the tile data is what it builds from.

Landing pads and special structures (comm dish, solar panel) can be
added in V2 polish — each adds 1-2 tile types and 1-2 structure types.

---

## Composition Tiers

The same Monty algorithm runs at every tier. Each tier's "feature at
a pose" means a different thing, but `lm.odin` is unchanged.

| Tier | Object | Feature at a Pose | Reference Frame |
|---|---|---|---|
| 0 | a single tile reading | tile symbol at (x, y) on a face | face-local 2D grid |
| 1 | a **structure** (Hab, Lab, etc.) | tile-type at (dx, dy) within the structure | structure-local |
| 2 | a **district** (cluster of structures) | structure-type at (dx, dy) within the district | district-local |
| 3 | a **face** of the cube | district-type at (dx, dy) on the face | face-local |
| 4 (optional) | **cube** identity | which-face-is-this at (cube-side) | cube-local |

**Sub-feature transfer at every level.** A `wall-N` tile appears in
every rectangular structure — once the tier-1 LM has a graph for it,
recognising any new rectangular building is faster. A `Hab` structure
appears in many districts — once the tier-2 LM has a Hab graph,
recognising a district that contains one is faster. The cascade is the
*lesson* of Thousand Brains theory: hierarchies of reused patterns.

---

## Rotation Discovery (the killer demo)

When a storm respawns the mothership, the rover spawn rotation is
randomised. The player does not know which way is true-north.

At each tier, the LM seeds 4 rotation hypotheses (0°, 90°, 180°, 270°)
for the structure / district / face it's trying to identify. As more
tiles get scanned, the wrong rotations score badly and die.

The cascade plays out slightly out-of-sync across tiers:

- **Tier 1 (structure):** a single corner read narrows rotation to 1
  of 4. A second oriented tile usually resolves it within 2-3 reads.
- **Tier 2 (district):** independent rotation hypothesis for the
  district layout. Even if every structure within it has its rotation
  pinned, the district itself could still be in any of 4 orientations
  until enough structures are placed in space.
- **Tier 3 (face):** the face's overall rotation is the slowest to
  collapse — needs enough districts identified at known positions.

Player watches three rotation funnels collapse on three different
timescales. Direct visualisation of why reference frames are a big
deal in Monty.

---

## Storm / Respawn Mechanic

```
[loop forever]:
  storm hits → mothership shoves to new orbital position
  rover drop site is randomised + rotated 90° × {0,1,2,3}
  rovers spawn at their drop site, all LMs reset
  player has ~30-60 seconds to drive rovers and resolve:
    - "which face am I on?"
    - "which district within that face?"
    - "which way is true north?"
  recognition success → score; logs the visit
  storm comes back → repeat
```

The mothership has its own LM (or higher-LM) operating at tier 3 — it's
the one trying to identify which face it's hovering over from the
rover-LMs' tier-2 outputs.

Player can call back rovers and reposition them mid-storm if hypothesis
isn't collapsing fast enough — that's the action-policy demo.

---

## Level Chain

Each level isolates one Monty concept. The cube world is shared across
all of them — only the rover capabilities, LM count, and goal change.

| # | Name | What it teaches |
|---|---|---|
| 1 | **Recon** | One rover, drive over tiles, build a graph of one structure (live learning at tier 1). |
| 2 | **Survey** | Move rover across multiple structures. Tier-1 LM commits and recognises. |
| 3 | **Voting** | Three rovers around the same structure. Lateral voting accelerates convergence — visible in the HUD. |
| 4 | **District** | Tier-2 LM running on top of the tier-1 LM. First hierarchical composition step. Player sees the cascade. |
| 5 | **Storm** | First random respawn / rotation. Reorientation game. |
| 6 | **Atlas** | Tier-3 LM identifies the face from district outputs. Full hierarchy live. |
| 7 | **Sandbox** | Free play. Storms keep coming. All tiers running. Pattern-N naming. Recent IDs ticker. The kidnapped-robot loop as steady-state play. |

The Fleet level concept (`l8_fleet.odin`) transfers cleanly — same
hierarchical-LM code, just running on tier-2 districts instead of free
spatial compositions.

---

## What Transfers From V1

The core code mostly survives:

- **`lm.odin`** — entire LM core (hypotheses, evidence, voting,
  convergence, the three criteria + symmetry escape) is reused
  unchanged. Same algorithm, different feature space.
- **`object_model.odin`** (Graph_Node, Object_Graph, Model_Database)
  reused unchanged. A "graph" at tier 1 has tile-features at integer
  positions; at tier 2, structure-IDs at integer positions. The data
  structure doesn't care.
- **`sensor.odin`** (CMP_Message) reused. `features` becomes
  tile-symbol enum + maybe a couple of side channels (height,
  reflectivity).
- **`lm_receive_vote`** — the rate-based novelty + contact-point
  offset logic carries over directly. Tile-position deltas play the
  role of hit-point deltas; the math is identical.
- **The Hack font, raylib bindings, save/load infrastructure,
  level-vtable pattern, briefing system, About page** — all reusable.

What's new:

- Cube-world rendering (6 faces, tile grid, face-edge wrapping)
- Tile-features data type (small enum vs the V1 continuous-value
  feature struct)
- Rover entity (movement, drive logic, per-step tile read)
- Storm event system (timer, transition animation, respawn)
- Multi-tier LM stack (tier-1 LM outputs feed tier-2 LM as features,
  same code recursively)
- Heads-up display for tier-1/2/3 hypothesis funnels side-by-side
  showing the cascade

V1's spacecraft assets and free-flight controls get retired.

---

## Pedagogical Wins Over V1

1. **Sensor mechanics are authentic.** The sensor moves across a
   surface, period. No "ship hovering 20 units off the object with a
   laser" gymnastics.
2. **Multi-column voting is geometrically real.** Co-located rovers
   on the same patch of surface, exactly like adjacent cortical
   columns.
3. **Hierarchy is genuinely fractal.** Tier 1 has internal sub-features
   that compose; tier 2 reuses tier-1 outputs; tier 3 reuses tier-2;
   etc. V1's Fleet level had two thin tiers because the parts (spheres)
   had no internal structure.
4. **The kidnapped-robot scenario IS the game.** Every storm is a fresh
   inference episode. Players spend hours doing what Monty does.
5. **Carcassonne is literal.** Hawkins' analogy *is* the gameplay,
   not a parable explained in a briefing.
6. **Rotation discovery is visible at every tier.** Three funnels
   collapsing on three timescales is hard to forget.

---

## Aesthetic & Tone

The cube world is intentionally playful. Boxy planet, boxy structures,
rounded corners (so it doesn't read brutalist). The mothership is a
solid silhouette in orbit; the surface is a brightly-coloured tile
grid like a board game. Storm animations are dramatic but brief
(ionic crackle, then black, then a new spawn).

The whole thing should feel like a tabletop simulation seen from above
— half toy, half lab instrument. The seriousness is in the HUD readouts
(hypothesis funnels, evidence bars, rotation columns), not in the world
fiction.

---

## Open Questions

- **Single cube or multiple?** Single-cube + storms is narratively
  tightest. Multi-cube (jump drive repair arc) extends naturally for
  V2-late. Multi-cube also unlocks a tier-5 "which planet am I on"
  composition.
- **Rover count cap?** Three feels like the right starting point
  (matches V1 Drones). Eye-level would be 9. Maybe levels unlock
  bigger rover fleets.
- **Procedural vs hand-authored worlds?** Hand-authored districts
  give clean lessons; procedural gives sandbox replayability.
  Probably both — campaign uses authored, sandbox uses procedural.
- **Should rover sensing be partial?** A rover could read its own tile
  cleanly and the 4 adjacent tiles at reduced confidence. Adds
  realism, complicates the LM scoring. Default to "rover reads its
  own tile only" for V2-MVP.
- **What happens when the player has identified a face?** Bonus,
  log entry, score increment? Probably "log entry + score, then wait
  for the next storm." Sandbox doesn't need progression beyond
  satisfying loops.
- **Sound design?** Tile-step click, oriented-corner ping, hypothesis-
  collapse chord, vote-exchange crackle. The cockpit sequel had this
  too — easy to share an audio library.

---

## Implementation Order (rough)

1. Tile-world renderer: one face, 16×16 grid, the 9 tile types as
   sprites/colours.
2. Rover entity that drives over tiles and emits CMPs.
3. Tier-1 LM running on tile features — basically a re-skinned V1
   sandbox LM with discrete-symbol features instead of continuous.
4. Multi-rover voting at tier 1 (port V1 Drones-style voting).
5. Tier-2 LM (hierarchical) running on top of tier-1 outputs. Levels
   "District" and beyond unlock.
6. Storm system + respawn rotation.
7. Cube-world wrap-around at face edges.
8. Polish: HUD with three-tier hypothesis funnel, audio, animations.

A working V2-MVP could live behind step 4 (single face, multi-rover
voting at tier 1, storms but no hierarchy yet) — that's already a
better Monty demo than V1 in the dimensions that matter.
