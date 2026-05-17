# Monty v3 Design Spec — Mothership Over The Dust World (Ringworld Branch)

*Working draft. Still iterating. This file captures the current state
of the ringworld design conversation; it is NOT a finished spec. The
cube-planet path lives in `V2-Spec.md` and stays the alternative.
The cockpit/dead-ship path lives in `Sequel.md`.*

A V3 reimagining grounded in Monty's actual mechanics. V1 used
free-flying spacecraft, which stretched in several places (sensor
offset from contact, drones-as-columns abstraction, ground-truth
shortcuts in sandbox). V2 (cube planet) tightened that. V3 (ringworld)
takes it further by doubling down on perception as the central
gameplay verb, multi-modal sensors as the headline, and a topology
that keeps the disambiguation puzzle alive indefinitely.

---

## Premise

You command a stranded mothership in orbit above a world that has
been engulfed in permanent dust storms since some ancient collapse.
The surface is a robotic ghost town — habitation domes, foundries,
labs, solar fields, all left running on autopilot by a civilisation
that is no longer here. The mothership's onboard AI woke up after
the first storm with most of its long-term memory wiped. It can't
perceive the world directly. You teach it, scan by scan.

The mothership has no jump drive. It cannot leave. The dust storms
periodically yeet the ship to a new position above the planet — at
random rotation, sometimes across to a different *ring* of latitude
(see World Structure below). Every storm wipes the AI's short-term
buffer. What survives is the atlas: the long-term graphs the AI has
*committed*.

The game loop is:

1. Storm hits. Position randomised, buffer wiped.
2. Drop probes through the dust onto the surface.
3. Sense. Recognise. Decide what's worth committing before the
   next storm.
4. Spend resources, gain resources, grow the atlas.
5. Storm comes back. Repeat.

The AI grows up as you play. Early game it asks for help on every
step; late game it runs perception autonomously while you set
strategy. The atlas isn't a paycheck — it's the AI's identity,
externalised. Lose it and you lose who you've been training.

There are no living crew. The lights are on and nobody is home.

---

## World Structure — The Stacked Rings

The world is **a stacked cylinder of independent rings**, like a
combination lock.

```
       ┌──────────────────┐
       │  ring 4 (polar)  │
       ├──────────────────┤
       │  ring 3          │
       ├──────────────────┤
       │  ring 2 (equator)│  ← east/west wraps here
       ├──────────────────┤
       │  ring 1          │
       ├──────────────────┤
       │  ring 0 (polar)  │
       └──────────────────┘
```

- **East/west wraps**: each ring is a 1D loop of W tiles around.
  Drive a probe long enough east and you come back where you
  started on that ring.
- **North/south crosses rings**: the boundaries between rings are
  uninhabitable wall-tiles (mountain ridges, void). Crossing
  costs energy.
- **Rings rotate independently**: each ring has its own *phase
  offset*. The longitude where you crossed up from ring 2 to ring 3
  last time is not the same world position you arrive at this time
  — because ring 3 has shifted since you were there.

### Why the stacked-rings topology

This solves a structural problem that single-ring or cube topologies
have: as the player explores, the puzzle gets *too easy* because
more of the world becomes known and the kidnapped-robot game
trivialises. Shifting ring phases keep the disambiguation problem
alive forever.

Concretely:

- **Within a ring**: identity is stable. Once you've mapped a ring,
  the atlas tells you where things are. The LM's rotation invariance
  handles small re-orientations.
- **Across rings**: ring-phase drift between sessions reintroduces
  rotation ambiguity at every storm. You know what's *on* ring 3,
  but you don't know which longitude on ring 3 your current crossing
  lands you at — until you scan and match.

This is exactly the Monty machinery's strength. The LM doesn't care
about absolute longitude; it cares about the *local feature
arrangement*. Ring rotation invalidates your absolute-position
guesses without invalidating anything the LM has actually learned.
The rotation-invariance lesson stops being an opening tutorial trick
and becomes the load-bearing daily mechanic.

Storms cause the ring drift. "The storm spun ring-3 by 70° while
you were out cold." Diegetic explanation, mechanically meaningful.

### Tile grid

Roughly 32 tiles per ring × 5 rings = 160 tiles, plus mountain
divider rows. Bigger than V1, smaller than a fully open world.
Numbers can flex.

---

## Sensors and Learning Modules

The dust justifies the entire sensor design. **Optical is unreliable
through dust**. Most of the time you cannot just *look*. You feel
the world with non-optical modalities, and only see clearly in
unusual conditions (eye of the storm, post-storm temporary clear,
specific terrain where dust thins, etc.).

Each modality is its own Learning Module with its own graphs.

| Sensor | What it senses | When it shines |
|---|---|---|
| **Acoustic / sonar** | tile boundaries, wall echoes, hollow vs solid | always available, low-res |
| **Thermal** | heat signatures (live machinery vs cold ruin) | day/night cycle, finds active depots |
| **Radiation** | shielded structures, power lines, lead-walled labs | finds buried/disguised power |
| **Moisture** | water, ice, fuel slicks, atmosphere processors | resource scouting |
| **Optical (rare)** | full feature read | windows of clear air; bonus modality |

The LMs vote together via the existing lateral protocol from
`lm.odin`. A structure recognised by acoustic alone is *less
confident* than the same structure confirmed by acoustic +
thermal + radiation in agreement.

**This is the Thousand Brains thesis made into the central
mechanic.** Every column votes on object identity using its own
modality. No single sensor solves the world; the vote does.

Cross-modal recognition is *learned*, not given — see the
cross-modal binding section below.

---

## Tile Vocabulary

Deliberately tiny. The lesson is composition, not richness.

### Terrain tiles (~70% of the surface)

| Tile | Notes |
|---|---|
| dirt | the baseline; ~50% of all tiles |
| gravel | textured but uninteresting |
| rock-small / rock-large | landmark-able natural features |
| ice / sand | biome variation |

Terrain tiles do not participate in structure composition. They're
the substrate the lower-level material LMs (moisture, thermal,
radiation) train on first — by the time you're recognising a hab,
your sensors already know what dirt, ice, and rock read like.

### Structure tiles (the only ones that compose)

| Tile | Shape | Orientation |
|---|---|---|
| `wall-N`, `wall-E`, `wall-S`, `wall-W` | straight wall segment | oriented |
| `corner-NE`, `corner-NW`, `corner-SE`, `corner-SW` | rounded outside corner | oriented |
| `door` | corner tile with an opening | oriented; replaces one corner |
| `floor` | interior space | optional — only used in 3×3+ buildings |

Nine tile classes total. Walls, rounded corners, and a door-corner.

Three reasons to keep it this small:

1. The structure tier still has plenty of expressiveness (size +
   door position + roundness gives many distinct shapes).
2. Sub-feature transfer becomes obvious: `wall-N` appears in every
   rectangular structure, so the LM's wall-tile-graph is reused
   across every building type the player ever encounters.
3. Rotation discovery has direct visible signal: every oriented
   tile contributes to collapsing the 4 rotation hypotheses for the
   structure that contains it.

### Structures from this vocabulary

Smallest meaningful structure is a 2×2 — four rounded corners with
one swapped for a door:

```
NW    NE
SW    door
```

This is the **Outpost Hab**. The door position is the rotation
signature; there are 4 rotational variants of the same structure.

Larger buildings interleave walls between corners (3×3 Hab, 4×3
Lab, etc.). Even at this tiny vocabulary you get a dozen distinct
recognisable structure graphs.

---

## Composition Tiers

The same Monty algorithm runs at every tier. Each tier's "feature
at a pose" means a different thing, but `lm.odin` is unchanged.

| Tier | Object | Feature at a Pose | Reference Frame |
|---|---|---|---|
| 0 | a single tile reading | tile symbol at (x, y) on a ring | ring-local |
| 1 | a **structure** (Hab, Lab, etc.) | tile-type at (dx, dy) within structure | structure-local |
| 2 | a **city / district** (cluster of structures) | structure-type at (dx, dy) within district | district-local |
| 3 | a **ring identity** | district-type at (longitude) on the ring | ring-local |

No tier 4. The ring identities are the top level; the cylinder as a
whole is just "the set of rings I've atlas-ed."

**Sub-feature transfer at every level.** A `wall-N` tile appears in
every rectangular structure — once the tier-1 LM has a graph for
it, recognising any new rectangular building is faster. A `Hab`
structure appears in many districts. A `Foundry-pattern` district
appears in many rings. The cascade *is* the lesson of Thousand
Brains theory: hierarchies of reused patterns.

### Same-archetype, one tile different

Two cities can share an archetype but differ by a single tile —
one Foundry has its hab door on the east, another on the west. T3
orbital recon resolves to "this is a Foundry-cluster." T2 ground
recon resolves to which *specific* Foundry — the door position
disambiguates. This is hierarchical Bayesian inference made
playable: top-down prior plus bottom-up refinement, exactly what
the cortex actually does. No impostor / adversarial framing
required; the disambiguation arises from the natural variation
between instances.

---

## Memory Architecture

Each LM has three memory layers, matching real Monty:

1. **Observation buffer (short-term).** Every incoming CMP message
   lands here. Bounded, rolling. *Storms wipe this entirely.*
2. **Hypothesis population (working).** Thousands of candidate
   `(graph_id, pose)` hypotheses, updated each step with new
   evidence. Lives as long as inference runs.
3. **Atlas — committed graphs (long-term).** Each graph is a set of
   nodes: `(location_in_object_frame, surface_normal,
   feature_vector)`. Persistent across storms. Never forgotten.

**Committing** = promoting buffer → atlas. Either:
- a new graph is created (novelty detected), or
- nodes are added to an existing graph (familiar object, new
  viewpoint).

Trigger varies by phase of the game (manual vs automatic — see
delegation arc below).

**Forgetting in real Monty barely exists.** Once an atlas graph is
committed, it stays. We preserve this honestly: the V1 sandbox
failure mode where the LM commits *duplicate* graphs for the same
true object (because it didn't recognise the second instance) is
kept, surfaced, and turned into a *consolidation* mechanic — see
below.

**Storm = forced commit-or-lose.** Before each storm hits, the
player sees a countdown. Anything in the buffer that hasn't been
committed is gone after the storm. This makes commit decisions
*economic*: gamble on more scans to firm up novelty, or commit
now and lock in what you've got.

---

## Cross-Modal Binding via Sensor Unlocks

Each sensor's LM starts with its own graphs. There is no automatic
cross-modal recognition. **Binding is learned.**

When a new sensor unlocks (story event mid-game — a thermal package
salvaged, a radiation sensor recovered), its LM begins empty. The
player revisits known territory. The new LM commits its own
graphs in *its own feature space* — "hot-pattern-3" here,
"hot-pattern-7" there — with no semantic link to the optical-LM's
Foundry graphs.

**Consolidation prompt:** *"optical-Foundry-3 and thermal-pattern-2
always co-occur at the same poses. Bind?"*

Player merges → either modality now recognises the Foundry. The
binding propagates through the lateral vote.

**Payoff in the next dust storm:** optical blinds out; thermal
alone identifies Foundries because the binding survived. The
player *feels* the moment that early-game training pays off in
late-game adversity.

Sensor unlocks aren't collectibles. They're a structural reason
to re-explore known territory — to teach a new column what the
other columns already know. Way more meaningful than "go pick up
the new sensor part."

---

## Resource Economy

The resource layer is what makes Monty's predictions *consequential*.
Recognition isn't trivia; it's a cost-saving query against the
generative model.

| Resource | Mechanic hook |
|---|---|
| **Fuel** | needed for probe drops, rover travel; predicted by atlas (Foundries have fuel depots at known relative positions) |
| **Water / coolant** | exclusive to moisture-LM detection (rewards cross-modal investment) |
| **Spare parts** | recovered via anomaly detection (damaged habs have parts; intact ones don't) |
| **Sensor charge** | per-scan cost. Goal-state generation that saves you scans extends your own operating budget |

### Prediction-driven scouting (the core loop)

> *"Fuel at 12%. Orbital + acoustic place us near a known
> Foundry-Beta archetype. Foundry-Beta atlas entry shows fuel
> pumps in the southwest depot tiles. Imagine-mode ghost-renders
> the LM's predicted pump locations. Drop rover, scan two tiles to
> confirm (cheap — LM is mostly right), pump fuel, leave. Total
> cost: 2 scans + 1 drop. Alternative: scout fresh terrain — 12+
> scans, no prediction, might find nothing."*

Every Monty capability is load-bearing in this loop: T3 recognition
(Foundry-Beta archetype), T2 prediction (where the depot is),
few-shot speedup (you've seen Foundries before), pose
(which way the depot faces), atlas persistence (last storm didn't
wipe what you committed), cross-modal (thermal confirms the depot
is *active* without optical verification).

### Depleted-depot state

Once you raid a depot, the corresponding tile-node in the atlas
graph gets a `fuel_level = empty` annotation on its feature
vector. The LM still recognises the Foundry. The tile-node still
matches. But the feature reads empty, the tile renders dimmed,
and the prediction "fuel here" is now "no fuel here."

No new machinery required — this is just an extra feature
channel. The same recognition pipeline that finds the Foundry
finds out that *this* Foundry isn't worth raiding.

---

## Storm Countdown + Ring Drift

```
[loop forever]:
  storm warning → countdown begins (~30 game turns?)
  player races to:
    - commit anything in the buffer that's converged
    - extract resources from the current area
    - shelter / retract probes
  storm hits → buffer wiped, ring phases redrawn,
                mothership shifted in latitude (sometimes across rings)
  recovery phase: scan to re-identify which ring + which longitude
  loop continues until the player's atlas is rich enough that
    recovery is fast and resource extraction dominates the loop
```

The mothership has its own T3 LM operating on the rover-LMs' T2
outputs, trying to identify which ring it currently sits above.
Player can reposition probes mid-recovery — that's the
goal-state-generation / action-policy demo from the V1 Range
level, now diegetic.

---

## The Scanner Display — Disagreement Overlay

The HUD does not show "which object lives here." It shows
*hypothesis disagreement*.

At each unscanned tile, the LM looks at its top-N hypotheses and
asks: "what feature does each of them predict here?" Tiles where
predictions disagree are *informative* — scanning them collapses
the funnel. Tiles where everything agrees tell you nothing.

Display: per tile, a small palette of coloured dots, one dot per
top hypothesis, colour = predicted-feature-under-that-hypothesis.
Tiles with one solid uniform colour are boring. Tiles bristling
with different colours are gold.

This is what real Monty's goal-state generator computes. The
visualisation matches the algorithm exactly, and the player learns
to read "many colours crowded together = scan here next."

In the late-game automation phase, the LM picks the next scan tile
itself — same algorithm, just no player click in the loop.

---

## The Manual-to-Automatic Delegation Arc

This is the spine of the game. The player learns Monty by *being*
Monty, then gradually delegates each layer to the automation they
have come to understand and trust. By endgame, the player is the
strategist; Monty is the perceptual substrate.

Every step that *can* be done manually starts manual. Each step
unlocks automation only after the player demonstrates competence at
it. Automation is *earned*, not gifted.

| Step | Manual mode | Automated mode |
|---|---|---|
| **Feature extraction** | Player picks which feature categories apply to a raw sensor read (e.g. "warm + metal + smooth") | Sensor module emits the feature vector directly |
| **Pose alignment** | Player rotates the candidate graph onto observation; the math is visible | LM applies `R^T * body_disp` silently |
| **Hypothesis tracking** | Player reviews the candidate list, prunes by hand | LM maintains thousands of hypotheses silently |
| **Next-scan choice** | Player clicks a tile from the disagreement overlay | LM picks the most-disambiguating tile and proceeds |
| **Commit decision** | Player explicitly commits "Pattern-N" before storm hits | LM auto-commits when novelty rate stays low |
| **Cross-modal binding** | Player merges co-occurring graphs after sensor unlock | LM detects co-occurrence and proposes binds |
| **Consolidation** | Player reviews atlas for duplicates and merges | LM proposes merges nightly |
| **Strategic goals** | Player chooses target + resource priority | **STAYS PLAYER FOREVER** |

The bottom row is the design rule: **the strategic layer must
grow as perception automates**, or the player feels obsolete. As
the LM takes over the low-level loops, the high-level choices get
richer — sensor loadout per expedition (energy budget), which
duplicates to consolidate vs leave, when to trust imagine-mode
predictions vs verify, when to risk a ring crossing for a payoff
on the other side. This is psychologically true to the brain:
prefrontal cortex sets goals; sensory cortex automates perception.

### Acts mapping to roughly seven levels

- **Act 1 — You ARE Monty (L1, L2)**
  - L1 *Recon*: drive one probe over a structure. **Feature
    extraction manual**: player picks features from raw sensor
    reads. **Pose alignment manual**: player rotates candidate
    graphs onto observation. Player commits a tier-1 graph by
    hand. Painful by design — every Monty step is one click.
  - L2 *Survey*: multiple structures, same manual loop. Feature
    extraction automation unlocks at end of level. Pose alignment
    automation unlocks shortly after.
- **Act 2 — Delegate the busywork (L3, L4)**
  - L3 *Voting*: multiple probes on one structure. Lateral voting
    visible. Hypothesis tracking automation unlocks here.
  - L4 *District*: tier-2 LM running on top of tier-1 outputs.
    First hierarchical step. Next-scan choice automation unlocks
    (player can still override). New sensor (thermal?) lands here,
    forcing the first **manual cross-modal binding** episode.
- **Act 3 — Trust the LM at low levels (L5)**
  - L5 *Storm*: first random respawn + ring drift. Reorientation
    game. Scans now autonomous. Commit decisions still manual under
    storm countdown pressure. Binding still manual when a third
    sensor unlocks.
- **Act 4 — Strategy only (L6, L7)**
  - L6 *Atlas*: T3 ring-identity LM. Full hierarchy live. Auto-
    commit unlocks. Auto-binding unlocks. Player sets goals and
    watches columns vote.
  - L7 *Sandbox*: free play. Storms keep coming. Resources flow.
    Strategy and consolidation are the only remaining player
    actions. The endgame *feels different* because the player has
    graduated, not because the game got harder.

---

## Speculative Tier — Resource Prioritisation as a Learned Graph

*This section is an extrapolation beyond what `tbp.monty` currently
implements. Tagged here honestly as a stretch direction, not as a
claim about real Monty.*

A possible late-late-game capability: the resource-prioritisation
*itself* is treated as another Monty graph. Nodes are "strategic
states" with features (fuel level, water level, atlas coverage,
position uncertainty). Edges are actions (drop probe, raid depot,
cross ring, wait out storm). The agent learns this graph by
experience and uses the same prediction machinery to suggest the
next action.

This is reinforcement-learning territory, not Monty's home turf.
But Thousand Brains theory speculates that the cortex uses the same
machinery for high-level concepts as for sensory recognition (the
grid-cell / place-cell generalisation). Treating a strategic state
space as a Monty graph is *theoretically in-spirit*, even though it
is not in `tbp.monty` source today.

For V3, this is best treated as **an optional final-level reveal**
or an honest "the theory says this could go further" note in the
About page — not as a core mechanic. Resource prioritisation
**stays the player's job** as a design rule because (a) it makes
the manual-to-automatic arc land cleanly, and (b) it preserves a
real strategic layer for the player to inhabit.

If it ever becomes a mechanic, gate it behind a clearly speculative
narrative beat ("the AI is learning to plan, not just to see") and
let the player choose whether to delegate to it. Honesty about the
extrapolation matters; the V1 about page already establishes that
norm.

---

## What Transfers From V1

The core code mostly survives:

- **`lm.odin`** — entire LM core (hypothesis population, evidence
  updates, lateral voting, three-criterion convergence, symmetry
  escape) reused unchanged. Same algorithm, different feature
  space (discrete tile symbols instead of continuous-valued
  material features).
- **`object_model.odin`** (Graph_Node, Object_Graph,
  Model_Database) reused unchanged. A tier-1 graph has tile-symbols
  at integer positions; a tier-2 graph has structure-IDs at integer
  positions. The data structure doesn't care.
- **`sensor.odin`** (CMP_Message) reused. `features` becomes a
  small enum plus a couple of side channels (heat, radiation,
  moisture readings).
- **`lm_receive_vote`** — rate-based novelty + contact-point
  offset logic carries over directly. Tile-position deltas play
  the role of hit-point deltas; the math is identical.
- **Sandbox-style live learning** from `l9_sandbox.odin` — novelty
  rate, pattern counter, duplicate-graph honesty — all reused for
  the V3 sandbox endgame.
- **Hack font, raylib bindings, save/load infrastructure,
  level-vtable pattern, briefing system, About page** — all
  reusable.

New in V3:

- Cylinder-of-rings world (ring rendering, ring-phase state,
  cross-ring transitions, mountain-divider tiles)
- Tile-features data type (small enum + side-channel scalars)
- Probe entity (movement, drive logic, per-step tile read)
- Storm event system (countdown, transition, respawn with
  ring drift)
- Multi-modal LM stack (one LM per sensor, lateral voting across
  modalities, cross-modal binding via consolidation)
- Multi-tier LM stack (T1 outputs feed T2, T2 feeds T3 — same
  code recursively)
- Resource state on graph nodes (depleted-depot etc.)
- Storm countdown HUD; buffer-vs-atlas commit pressure
- Disagreement-overlay scanner display
- Manual-mode interfaces for feature extraction, pose alignment,
  hypothesis review, commit, binding, consolidation — each with
  an automation-unlocked counterpart

V1's spacecraft assets, free-flight controls, and continuous-value
material features get retired.

---

## Pedagogical Wins Over V1

1. **Sensor mechanics are authentic.** Probes are on the surface;
   contact point = sensor position. The class of "sensor offset
   from contact" bugs we fixed in V1 simply does not exist.
2. **Multi-column voting is geometrically real.** Co-located
   probes around the same structure, exactly like adjacent
   cortical columns.
3. **Multi-modal voting is the headline.** V1 had voting between
   homogeneous drones. V3 has heterogeneous sensors that *only
   together* solve the world. This is the Thousand Brains thesis
   proper.
4. **Hierarchy is genuinely fractal.** Tier 1 has internal
   sub-features that compose; tier 2 reuses tier-1; tier 3 reuses
   tier-2. V1's Fleet level had two thin tiers because the parts
   (spheres) had no internal structure.
5. **The kidnapped-robot scenario IS the game.** Every storm is a
   fresh inference episode. Ring drift keeps the disambiguation
   problem alive forever.
6. **Carcassonne is literal.** Hawkins' analogy *is* the gameplay,
   not a parable explained in a briefing.
7. **Predictions are consequential.** Resource economy makes the
   LM's generative-model hints economically valuable, not just
   informationally interesting.
8. **Cross-modal binding is dramatic.** New sensors don't just add
   features — they require *teaching*, and the binding moment
   gives a clear "the model fused" beat.
9. **The delegation arc is the lesson.** You learn Monty by being
   Monty. By the time you've graduated to high-level strategy you
   know exactly what each layer is doing and why you trust it.
10. **The mothership AI is a character.** Atlas-as-mind makes
    losses meaningful and commits emotional. Story-mechanic
    alignment is total.

---

## Aesthetic & Tone

A tabletop simulation seen from above — half toy, half lab
instrument. The cylinder world renders in clean low-saturation
colours when scanned, fading to dust-coloured noise where it
hasn't been. Storm transitions are dramatic but brief (ionic
crackle, dust roar, then blackout, then a new spawn).

The mothership AI gets a small text-readout character that
narrates its own confidence and confusion. Early game: *"I think
this is something. I don't know what."* After committing a
pattern: *"I'll call this Pattern-3 for now. I'll know better
when I see another."* When it duplicates: *"...this might be the
same as Pattern-3 actually. I'm not sure yet."* Honest about its
quirks; gives the player a relationship with the perceiver.

Seriousness is in the HUD (hypothesis funnels, evidence bars,
rotation columns, modality-disagreement chips), not in the world
fiction. No dramatic music; ambient hum, sensor pings, the
satisfying chord when a hypothesis funnel collapses.

---

## Honesty Audit — V3 Adds and Stretches vs Real Monty

Continuing the V1 About-page tradition of being explicit about
where the implementation faithfully follows `tbp.monty` and where
it diverges.

**Faithful:**

- CMP message protocol, reference-frame alignment, hypothesis
  population, three-criterion convergence + symmetry escape,
  lateral voting, hierarchical composition, sandbox-style novelty
  detection and pattern committing — all carried over unchanged
  from V1 (which already mirrored the real algorithm).
- Multi-modal LMs with per-modality graphs and lateral binding
  across them is the *core thesis* of Thousand Brains theory;
  this V3 architecture is closer to real Monty than V1 was.
- Atlas persistence with no automatic forgetting matches current
  `tbp.monty`.
- Duplicate-graph commits when re-recognition fails is preserved
  as an honest failure mode, not papered over.

**Adds V3 introduces beyond `tbp.monty` source:**

- Resource economy is gameplay framing, not a Monty mechanic. It
  *uses* Monty's prediction capability, but resource accounting
  itself is not in the algorithm.
- Storm-wipes-buffer is a clean fit for Monty's bounded buffer,
  but the periodic-storm structure is gameplay.
- Manual-mode interfaces for feature extraction / pose alignment
  / hypothesis review are *teaching tools*, not Monty primitives.
  Real Monty never asks a human which features apply.
- Cross-modal binding via player consolidation is a hand-rolled
  mechanic; real Monty's cross-modal binding emerges from lateral
  voting at runtime, not from offline merge prompts.

**Explicitly speculative (tagged in-game):**

- Resource-prioritisation-as-graph (the optional final reveal) is
  extrapolation from Thousand Brains theory beyond current
  `tbp.monty`.

The About page in V3 carries forward V1's structure: WHAT'S
FAITHFUL, WHAT'S SIMPLIFIED, WHY THE DIFFERENCES, REAL MONTY
POINTERS. The list updates but the norm stays.

---

## Open Questions

- **Ring count and tile-per-ring numbers.** 5 rings × 32 tiles is
  a starting guess. Wants playtesting.
- **Ring drift cadence.** Every storm? Every Nth storm? Only some
  rings? A "polar" ring 0 / ring 4 that never drifts gives the
  player a stable reference if they reach it.
- **Probe count cap per drop.** Three feels right early; maybe
  unlocks to nine by endgame.
- **Procedural vs hand-authored worlds.** Campaign hand-authored,
  sandbox procedural is the default plan.
- **Probe sensing radius.** Reads own tile only? Plus four
  adjacents at reduced confidence? Default to "own tile only"
  for MVP; add adjacency later.
- **Storm pacing.** Real-time clock, turn-counter, or
  player-triggered? Probably a soft turn-counter that the player
  can see, so they always know how much budget remains.
- **Sound design.** Tile-step click, oriented-corner ping, sensor
  modality chord, hypothesis-collapse glissando, vote-exchange
  crackle, storm warble.
- **Save / load.** Atlas survives storms in-fiction; needs to
  survive process exit in implementation. The V1 save infra
  carries over.
- **Manual-mode pose alignment UI.** Concretely how does the
  player "rotate the candidate graph onto observation"? Drag a
  ring, type an angle, click 3-of-4 alignment points? Needs a
  prototype.
- **Manual-mode feature extraction UI.** What does the raw
  sensor read look like before the player categorises it? Texture
  swatch, waveform, spectrum chip? Needs a prototype.

---

## Implementation Order (rough)

1. Single ring renderer, 32-tile loop, the 9 structure-tile types
   plus 5 terrain types as coloured sprites.
2. Probe entity that drives across tiles and emits CMPs (acoustic
   only at this stage — one modality).
3. Tier-1 LM on tile features — basically a re-skinned V1 sandbox
   LM with discrete-symbol features. Manual feature extraction
   and manual pose alignment as the first interactions.
4. Multi-probe voting at tier 1 (port V1 Drones-style voting).
   Automation of feature extraction + pose alignment unlocks at
   this milestone.
5. Tier-2 LM (hierarchical) running on top of tier-1 outputs.
   First district recognition.
6. Storm system + ring drift + respawn rotation.
7. Second sensor modality (thermal). Cross-modal binding manual
   interface.
8. Tier-3 LM for ring identity. Atlas persistence + commit-or-lose
   storm pressure.
9. Resource economy + depleted-depot annotation + prediction-driven
   scouting.
10. Third and fourth sensor modalities (radiation, moisture). Auto-
    commit + auto-binding unlocks.
11. Sandbox endgame with optional consolidation, optional
    speculative state-graph reveal.
12. Polish: HUD with multi-tier hypothesis funnels, audio,
    storm-transition animations, mothership-AI narration.

A working V3-MVP could live behind step 4 — single ring, multi-
probe voting at tier 1, manual-mode every step, no storms yet —
and would already be a more honest Monty demo than V1 in the
dimensions that matter.
