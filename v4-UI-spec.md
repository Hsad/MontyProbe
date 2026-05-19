# Monty v4 UI Spec — The Hopper Cockpit

*Companion document to `v4-mothership-spec.md`. Captures the
information architecture and physical layout decisions made during
the UI brainstorm. Visual / pixel-level design is downstream of
this; this doc constrains what content lives where, how the player
navigates it, and what the cockpit is shaped like.*

---

## Core Principle — The Player Lives in the Hopper

The player is always inside the hopper. The mothership is a
**separate AI agent** that the player communicates with over radio.
This frames the entire UI:

- The cockpit the player walks around in is the **hopper's
  cockpit**, not the mothership's
- The player's primary atlas lives on the hopper and travels with
  them
- The mothership has its own atlas (built from its own
  observations) that the player syncs with via comms
- Most of the *interesting Monty work* happens out in the storm,
  where the hopper goes
- The cockpit's perspective shifts when the player focuses on a
  remote unit's monitor (rover, drone), but the player's body
  stays in the hopper

Reframing benefit: hopper-mothership communication becomes a
literal multi-agent voting / consolidation demonstration, which is
what Thousand Brains theory actually argues for at the inter-agent
scale.

---

## The Hopper as Physical UI

The hopper has **five physical zones** mapping 1:1 to five
information families. The architecture of the ship is the
architecture of the interface — the player navigates information
by walking, not by clicking menus.

| Hopper zone | Position | Screen family | Purpose |
|---|---|---|---|
| **Front window** | Forward | World context | Direct view of dust + eye boundary + storm |
| **Holo-deck (centre)** | Middle, walk-in | Atlas | Spatial render of all atlas knowledge |
| **Patch bays** | Side walls | Columns / infrastructure | Cortical column wiring |
| **Screen wall (rear)** | Back, splittable | Live inference | Per-LM hypothesis funnels, sensor streams |
| **Cargo bay** | Behind screen wall | Operations | Rover / drone outfit, manufactured arrivals |

The player walks *forward* to look out the window, *centre* to
consult the atlas, *side-to-side* to wire the cortex, *back* to
monitor live inference, *further back* to outfit machines.

---

## Hopper Visual Design

Grasshopper / beetle / dune-ornithopter inspired. Body segments
correspond to interior zones:

- **Head** = cockpit (window, holo-deck, patch bays)
- **Thorax** = screen wall + corridor through to cargo
- **Abdomen** = cargo bay with armoured elytra (wing-sheaths) that
  cover when landed and lift to reveal the bay for loading

### Three movement modes

- **Crawl** — articulated legs for slow precise positioning.
- **Hop** — leg power-stroke launches ballistic arcs.
- **Fly** — elytra open, wings beneath, flapping ornithopter
  flight. The mode for going deep into the storm.

---

## Navigation — Walking the Cockpit

### Movement

- **FPS walk** around the cockpit interior (WASD-walk + mouse-look)
- Step into the holo-deck pillars to enter the projection volume
- Walk to a screen / patch bay / window to be near it

### Screen focus

- **Click a screen** → Witness-style focus lock fills the player's
  view with that screen's content
- **WASD-Tab** while focused swaps between screens (KDE virtual-
  desktop style)
- **Scroll wheel** for depth / layer indexing within a screen
- **Pull back** returns the player to ambient cockpit view, all
  screens visible at once

### Screen wall split

The screen wall can split (2×3 + 2×3) to open a corridor through
to the cargo bay.

---

## Screen Family 1 — World Context (Front Window)

The forward window is the player's anchor to *where am I, what's
happening*.

### Content

- **3D out-the-window view** of the immediate surroundings: dust,
  eye boundary, surface below, any nearby structures or vehicles
- **Eye-boundary indicator** at the edge of clear visibility — a
  visible wall of swirling particles
- **Beacon strength + direction-to-home** (mothership beacon)
- **Storm phase indicator** + **ear-LM forecast** (storm-pattern
  predictions, countdown to electric phase, etc.)

When the hopper is hovering high in the eye, the window shows the
mothership in the distance and the surface below. When deep in the
storm, the window shows mostly dust with whatever the active non-
optical sensors can render through it as overlays.

---

## Screen Family 2 — Atlas (Holo-Deck, Centre)

The atlas is the game's central artefact and lives in the **centre
of the cockpit as a holographic projection volume** between four
pillars.

### Physical form

- **Four pillars** in a square arrangement, projecting a hologram
  through the volume between them
- Player **walks into the centre** to enter the projection — the
  hologram wraps around them
- No table edges in peripheral vision — the player is *inside* the
  atlas, not looking down at it

### Rendering — point cloud / Gaussian splat

The atlas is literally a point cloud (Monty graph nodes at
positions with feature vectors). Rendering matches the data:

- Each graph node = a fuzzy splat at its world position
- **Per-modality colour** — each sensor modality gets its own
  distinct colour; acoustic / temporal patterns presented
  separately as a time-axis side panel
- **Density = evidence**. High-evidence regions look bright and
  dense; low-evidence speculative regions are sparse and faint
- **Hypothesis state spatial render**: candidate-structure ghosts
  overlay at candidate poses. As evidence collapses to one
  hypothesis, ghosts fade except the winner. The hypothesis funnel
  collapse becomes a *spatial event* the player can watch
- **Cross-modal binding visible**: when modalities agree at the
  same pose, their colour clouds reinforce and brighten. When they
  disagree, the colours don't co-locate

### Sand burial visualization

Sand is its own point cloud, low-saturation tan, that flows past
the player's feet at the projection floor. A slider controls sand-
point opacity / size:

- Slider at default: sand visible at current depth field
- Slider reducing: sand fades, buried structures emerge through it

This lets the player *see through the sand* by interactive opacity
control. Magnetometer and GPR scans are the canonical disambiguators
for buried structures.

### Interaction

- **Walk through** the projection — turn your body to see different
  regions
- **Slider controls** for sand opacity, modality filters, time-axis
  playback

### Additional content adjacent to the holo-deck

- **Atlas drift warnings** — pins highlighting structures with
  mixed evidence (construction modification, suspected burial)
- **Cross-modal binding queue** — proposed binds waiting for player
  review
- **Inter-agent consolidation prompts** — when docked or in
  high-bandwidth comms, prompts for merging mothership graphs with
  hopper graphs

---

## Screen Family 3 — Live Inference (Rear Screen Wall)

The rear screen wall is where the player watches Monty *think* in
real time. This is the per-LM working state surface.

### Layout

A grid of monitors on the rear wall (can split with a corridor
through to cargo). Each monitor shows one LM's current state,
selectable per context.

### Per-screen content (per active LM)

- **Hypothesis funnel**: top-N candidates with evidence bars,
  updated live as observations come in
- **Sensor input stream**: what this LM is currently consuming
- **Disagreement overlay**: per-tile prediction-mismatch scores
  for this LM's hypotheses, suggesting informative tiles to scan
- **Commit prompts**: when a column is about to lock in a new
  pattern (in manual-commit mode), the player gets a confirm /
  defer prompt here
- **Saturation indicator**: how full the column's atlas is

### Per-vehicle contexts

When the player focuses on a deployed vehicle's screen (rover,
drone), the rear monitors switch to show that vehicle's LM(s)
specifically.

### Degradation under storms

- Bandwidth drop → vehicle monitor resolution drops, refresh slows
- Comms lost → vehicle monitor goes static
- Electric storm → all remote-vehicle monitors blank; only local
  hopper LM monitors remain

---

## Screen Family 4 — Cortical Columns (Patch Bays, Sides)

The cortical column infrastructure lives on the side walls as
**patch bays** — synthesizer-style pin matrices for wiring the
cortex.

### Patch matrix layout

A 2D grid:

- **Rows = signal sources**
  - Each raw sensor stream
  - Each column's output
  - Each special stream (action / decision streams for the
    speculative tier later)
  - Intermediate hubs (consolidation points that combine multiple
    inputs into a single signal)
- **Columns = signal destinations**
  - Each column's input slot
  - Each hub's input
  - Each visualisation sink
  - Each cross-modal binding candidate slot

A cell at (row × column) is a potential connection point. Click to
toggle a connection. Active connections show as glowing patch
cables / lines between the pins.

### Signal-flow visualization

Pulses of light animate along connections when signals fire. Active
hubs glow when receiving votes. The cortex *moves* visually during
inference. Players can debug architecture by watching where signals
flow and where they stall.

### Node-graph alternate view

A toggle / overview button switches the matrix to a node-graph view:
each column is a labelled box, connections are arrows, the topology
is visually obvious. Same underlying data, different representation.
Better for "what is the signal flow doing? where does this feed?"
when the matrix gets dense.

### Adjacent panels in the patch-bay zone

- **Column inventory** — total count, growing-in-bioreactor
  progress, recovered-from-probe queue
- **Bandwidth allocation** — radio channel priority sliders for
  hopper ↔ mothership ↔ remote vehicles
- **Cloning queue** — labs working on column copies (when docked
  near a known lab)

---

## Screen Family 5 — Operations (Cargo Bay, Rear)

Behind the screen wall, accessible through the split-corridor, is
the cargo bay workshop. This is where outfitting and economy
management happen.

### Cargo bay contents

- **Rover / drone outfit stations** — physical (3D) bays where
  vehicles can be reconfigured. Player walks to a station, the
  vehicle is on it, modular mounts visible.
- **Inventory racks** — manufactured components, raw materials,
  cargo items waiting for transfer to the mothership
- **Resource gauges** — fuel, water, parts, sensor charge, etc.
- **Manufacturing queue** (Tier 1, late game) — what factories are
  producing, ETAs
- **Construction log** — what construction drones have done
- **Mine / refinery / factory network view** — supply chain
  visualisation (late game)

The cargo bay is where abstract "attach a column to a rover"
decisions happen as physical actions in a place.

---

## Inter-Agent Communication — Hopper ↔ Mothership

The hopper carries the player's primary atlas. The mothership is a
**separate AI agent** with its own atlas built from its own
observations (mainly the ear-LM, plus any passive scanning it does
while station-keeping). They communicate over radio.

### Channel tiers

The radio link has 32 channels (existing mechanic from the main
spec), power-allocatable. Inter-agent comms occupy channels at
different bandwidth costs (specific content-to-tier assignments
TBD). Storms degrade higher-bandwidth channels first. Electric
storms kill all radio — both atlases diverge until restored.

### What gets exchanged (Monty-honest types)

1. **Graph transfer** — bidirectional commit-sharing. Each side
   sends graphs the other doesn't have.
2. **Inter-atlas consolidation** — when both agents have similar
   but not identical graphs of the same structure (mothership saw
   from south, hopper saw from north), prompt for merge. Same
   machinery as cross-modal binding, applied across agents.
3. **Predictive querying** — *"I'm at Hab-3, what do you predict
   is nearby?"* — the mothership's higher-tier graphs supply
   spatial priors that bias the hopper's local inference. The
   priors overlay on the hopper's holo-deck as ghost predictions
   from the mothership.
4. **Hypothesis sharing** — even pre-commit, hopper streams its
   current hypothesis population; mothership's columns vote on
   those candidates from a distance.
5. **Probe-data digestion** — returned probe columns carrying
   buffered unresolved observations can be digested by the
   mothership offline, using its broader atlas as priors. *"Probe-
   2's data is being digested, 4 of 5 unresolved patterns resolved
   as Foundry variants."*

### Channel allocation as gameplay

Player allocates channels per expedition. The allocation UI sits
in the patch-bay zone, near the rest of the Monty-infrastructure
controls.

---

## Docking — The Consolidation Event

The hopper can **dock at the mothership** for refuel, resupply, and
full-bandwidth atlas reconciliation. Docking is a meaningful
moment:

### What happens on dock

- **Atlas merge**: bidirectional full graph transfer
- **Inter-atlas consolidation prompts**: player resolves any
  conflicts where the two atlases disagree about the same
  structure
- **Predictive querying**: all atlas tiers immediately available
- **Probe digestion**: pending unresolved probe data resolves with
  mothership-atlas priors. The mothership chews through buffered
  observations and contributes commits to the merged atlas
- **Column transfers**: columns can move physically between hopper
  and mothership
- **Resource transfer**: cargo bay → mothership stores, fuel
  refilled, manufactured supplies loaded

### Mode summary

| Mode | Atlas access | Predictive querying | Probe digest |
|---|---|---|---|
| Docked | Full merge | All tiers, immediate | All pending resolves |
| Strong comms | Recent slice, real-time sync | T2 / T3 priors available | Bandwidth-limited |
| Weak comms | Categorical updates only | Single-graph queries | None |
| Comms down | Local atlas only | None | None |

---

## Facility Scope

| Facility | Where | Functions |
|---|---|---|
| **Hopper** | Mobile, player lives here | Outfit / reconfigure rovers + drones, **player's primary atlas**, limited cargo, docks to mothership |
| **Mothership** | Station-keeping in the eye, separate agent | Light manufacturing, bioreactor (column growth), mothership-AI's own atlas, ear-LM, larger cargo capacity |
| **Surface labs** | Atlas-anchored ground buildings | Lost-probe disassembly, blueprint generation, cortical column cloning. Lose track of a lab → lose the capability |

No labs on the mothership or the hopper. Labs are *ground capital*
that must be re-located after storms — atlas-as-supply-chain.

---

## In-Game Spatial Bug Tagging (Dev Tool)

Borrowing from the zoo/gym/museum methodology and Geoff Huntley's
in-page prompt-from-element pattern: the testbed environments
include a **spatial bug-tagging system** that lets the developer
tag items / places in the game with notes. Tags persist where
they're placed and write to a project log file. Tags can optionally
carry prompts that route to the development assistant — the game
becomes the issue-routing interface.

---

## Cinema Beats — Visual Feedback for Internal State

Selected moments where visual changes communicate algorithmic
state:

- **Electric storm**: forward window flickers, screens go static
  in waves, remote-vehicle monitors blank one by one as bandwidth
  collapses
- **Bandwidth degradation**: vehicle monitor resolution drops,
  refresh slows. Watching the screen quality deteriorate IS the
  feeling of comms degrading
- **Hypothesis collapse**: in the holo-deck, candidate-structure
  ghosts fade except for the winning hypothesis. Spatial,
  cinematic, takes a few seconds
- **Cross-modal binding moment**: separate colour clouds at the
  same pose suddenly *merge* (visually pulse, then sustain).
  Player sees the modalities click together
- **Atlas drift discovery**: structure outline shows mixed-evidence
  visual when the player visits a modified location. The atlas's
  lie becomes visible
- **Sand burial accumulation**: sand-cloud gradually rises over
  structures the eye has left behind. Player can see their old
  base sinking
- **Docking sync**: as comms strengthen, mothership-contributed
  graphs populate into the holo-deck progressively. The atlas
  grows visibly as the connection improves
- **Probe digestion**: returned probe's data resolves at the
  mothership; new graphs appear on the holo-deck attributed to
  mothership-side processing

---

## Open UI Questions

- **Window-when-docked** — does the hopper window switch view when
  docked to the mothership?
- **Patch matrix at scale** — how many sensors / columns / hubs
  realistically fit before the matrix needs the node-graph view
  as default rather than alternate?
- **The mothership AI's "voice"** — text-only messages in a comms
  panel? Synthesised speech? Both? How prominent?

---

## What's Not Here Yet

- **Player-modelling speculative tier (theory of mind)** —
  deliberately deferred per the main spec. Will manifest as a
  column attached to the player's decision streams, but the
  specific UI surfaces only become designable late in development
- **Speculative state-transition tier** — same deferral. The
  speculative-tier visualisations would live in the holo-deck and
  on dedicated patch-matrix outputs, but specifics wait
- **Sound design** — what each modality / event sounds like; how
  comms degradation feels acoustically; ear-LM's output as audio
  cues. Wants real sound design, not spec text
- **Tutorial sequencing** — how the L1 player is introduced to
  each cockpit zone in order. Likely a guided tour through the
  zones, attaching one column at a time to one sensor at a time
- **Hex coordinate conventions** for atlas display — axial vs cube
  vs offset coordinates is implementation detail
