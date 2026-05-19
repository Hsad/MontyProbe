# Monty v4 Design Spec — Mothership in the Eye

*The current working design. Supersedes the earlier topology drafts.*

`V2-Spec.md` (cube planet) and `v3-ringworld-spec.md` (stacked
cylinder of rings) are kept as design history — both worked through
parts of the problem this spec resolves but neither is the
direction. `Sequel.md` (dead-ship cockpit) remains a parallel
alternative path; this is the *other* V4 direction.

The defining moves of v4 vs the earlier drafts:

- The world is an **open dust-shrouded plain on a hex grid**, not
  a cube and not a cylinder. Hex math is harder than square but
  accepted.
- The mothership **station-keeps in the eye** of a slow-moving
  storm. The eye drifts where it drifts; the mothership uses its
  audio to detect storm encroachment and reposition back to the
  quiet center.
- The **radio beacon** gives confident *heading-to-home* but only
  vague distance, and never your angular position on the ring
  around the mothership. Flight is *radial-controlled,
  angular-chaotic*. Atlas-based terrain recognition is the only
  way to know where on the ring you actually are.
- **Three sensor operator types**: flyers as eyes (spatial sampling
  at a distance), rovers as fingers (spatial continuous surface
  contact), mothership as ears (passive temporal listening — only
  the mothership has audio).
- **Storm rotation rates drift slowly once Monty starts learning
  them**, so the ear-LM has to predict from acoustic tone rather
  than memorise fixed values. Electric storms may emerge when one
  ring counter-rotates against another fast enough.
- The LM core **uses the actual `tbp.monty` codebase**, not our
  Odin reimplementation. Both demonstrates faithfulness and shows
  how to integrate Monty into a system producing sensor data.
- **Manual-to-automatic delegation arc** as the spine of the
  campaign. Player runs every Monty step by hand at first;
  automation unlocks per layer as competence is demonstrated.
  Strategic loadout is currently the player's because Monty
  doesn't automate it — a limitation, not a sacred rule.
- **Ant-colony endgame**: the mothership builds bases, sends
  probes, marches with the storm, sometimes re-encounters its own
  constructions and gets confused about them.

---

## Premise

You command a stranded mothership inside the eye of a slow-moving
storm. The world below is a dust-shrouded plain stretching to
horizons no telescope can pierce. The surface is a robotic ghost
town — habitation domes, foundries, labs, solar fields, all left
running on autopilot by a civilisation that is no longer here. No
crew. No survivors. Just machinery, dust, and weather.

The mothership has no jump drive. It **station-keeps within the
eye**, using its audio sensors to detect when it's drifting toward
the storm wall and repositioning back to the quiet center. The eye
itself drifts where it drifts — a force of nature — and the
mothership goes wherever the eye goes.

The mothership's onboard AI woke up after the first storm with most
of its long-term memory wiped. It can't perceive the world directly.
You teach it, probe by probe, scan by scan. What survives is the
atlas: the long-term graphs the AI has *committed*. Lose the atlas
and you lose who you've been training.

The game loop is:

1. The eye drifts. New terrain enters the visibility bubble. The
   mothership station-keeps within the eye.
2. You drive probes within the eye, fly probes out into the dust,
   or deploy crawlers for precision work.
3. Recognise. Decide what's worth committing before the next storm
   pulse wipes the buffer.
4. Spend resources, gain resources, grow the atlas.
5. Storms come and go. Late game, you build factories and resource
   collectors of your own — the colony marches.

There are no living crew. The lights are on and nobody is home.

### Timing — turn-based, continuous game-time world *(open — re-discuss)*

Current leaning, **not final**: player input is **turn-based**
(each player action advances game-time by some amount), but the
world's dynamics — eye drift, sand drift, storm phases, rotation-
rate updates — are *continuous in game-time*. Roguelike-style:
press an action, the world ticks forward, everything advances
incrementally.

Arguments for: each Monty step stays discrete and observable
(player sees hypothesis evolution between actions, no realtime
blur), implementation is cheaper than real-time, the late-game
time-skipping below drops in naturally.

Arguments against: storms feel less visceral than realtime,
mothership ear's "always listening" loses some of its temporal
texture, watching the eye drift in real time has its own appeal.

To revisit before locking in.

Late-game **time-skipping** (assuming turn-based holds): once
enough automation is unlocked, the player can advance N turns at
once with the LM and rovers executing autonomously. Manual-to-
automatic delegation extends naturally into a temporal axis — you
stop pressing each turn, you press "advance 10 turns of current
plan."

**Time-warp for routine travel.** Rover crossings through fully-
known territory would be tedious to watch step by step. Time-warp
runs the simulation fast during routine travel and auto-pauses on
novel events: storm warning, unrecognised structure, hypothesis
funnel collapsing, beacon dropping out, rover stuck. Dwarf-Fortress
/ Rimworld pacing — time runs fast when things are routine, slows
when things are interesting. Player attention scales with
information density.

### Eye drift speed scales over the campaign

Early-game eye drift is **very slow**. The player has time to build
something that feels like a home base inside the eye before the
world starts moving meaningfully. As the campaign progresses the
drift increases, and by mid-late game the eye has wandered far
enough that the home base is now in the dust (and potentially
becoming buried — see Sand Burial below).

This pacing is the structural setup for the slow-drift home-base-
becomes-buried arc.

---

## World — The Dust Plain and the Eye

### The visibility bubble

The eye is the player's clear-vision zone. Inside the eye, optical
sensors work, the world renders crisply, and you can do baseline
recognition with no struggle. Beyond the eye, dust thickens with
distance:

| Zone | Effective range | Available modalities |
|---|---|---|
| **Eye interior** | up to eye radius (~few km) | all (optical baseline) |
| **Eye fringe** | first few km outside the boundary | optical degrades; thermal/radiation primary |
| **Deep dust** | far out | only acoustic, radiation, moisture work |
| **Hazard fringe** | very far out | nothing reliable; storm-current risk |

The optical gradient is *geometric and visible*. The player can see
the eye boundary as a literal wall of dust receding into the
distance. They know when they've stepped outside it. Beyond, the
world fades to dust-colour noise, with whatever the active
non-optical sensors can resolve drawn as overlays.

### The eye drifts; the mothership station-keeps within it

The eye is a slow-moving force of nature — brownian wandering plus
inertia, not controllable by the player. The mothership stays
inside the eye via station-keeping, using its audio to detect when
it's getting close to the storm and repositioning back toward the
quiet center. The eye decides where it goes; the mothership decides
where it sits *within* the eye.

As the eye drifts:

- New terrain slides into the bubble — the AI gets fresh
  observations of unfamiliar ground for free, just by existing.
- Old terrain slides out, into the dust — but it's still
  *physically there*, just no longer in clear vision. Probes can
  fly back out to it.

The eye is *not* a fog-of-war reveal that erases what it leaves.
Once observed, terrain is in the atlas; once in the atlas, it
persists. The eye is the *current zone of free optical perception*,
not a literal fog.

### The world is open and unbounded by geometry

No cube faces, no ring topology, no hard walls. The plain extends
arbitrarily; in practice the storm system bounds it because the eye
can only drift so far in a campaign and the hazard fringe makes
hard-edge exploration suicidal. The player never thinks about
"where the edge of the world is" because the eye carries them; the
relevant world is *whatever the eye covers, has covered, and will
cover next*.

---

## Navigation — Beacon, Flight, Crawl

### The radio beacon

The mothership broadcasts a radio beacon. Probes pick up:

- **Signal strength → vague distance**. You know roughly how far
  you are from home, but the distance reading is fuzzy and
  noisier the deeper into dust you go.
- **Signal direction → confident heading-to-home**. You know
  which way to point your probe to fly back toward the mothership.

What you do *not* know:

- **Your angular position around the mothership**. The beacon
  tells you "home is 4km that way" but it does not tell you "you
  are 4km north of home" vs "4km east-by-southeast." You could be
  anywhere on the ring of radius D around the mothership.
- **A path replay of how you got there**. Once you've flown out,
  you cannot fly back along the same path — only toward the
  beacon. Reaching the same patch of terrain twice requires
  *recognising it again*, not navigating to remembered
  coordinates.

This is the heart of the design: **the atlas is the only persistent
positional bookmark**. Beacon gets you home; recognition gets you
anywhere else.

### Flight model

Probes hop between rough positions. The physics:

- **Radial control is decent.** You set burn duration; you reach
  roughly your intended distance from home.
- **Angular control is bad.** The storm has radial bands rotating
  at different rates. Time spent in the air at radius D drags you
  laterally through those bands. Long hops = unpredictable
  lateral drift. Short hops = small lateral drift.
- **Velocity overshoot is real.** You can overshoot the intended
  distance because the storm currents at altitude vary.

The intrinsic tradeoff: distance and angular precision are
*physically coupled*. No designer-imposed difficulty dial; the
trade-off falls out of the world model.

### Ring rotation rates are learnable and drift

Each radial band of dust has its own rotation rate. The rates
**drift slowly once Monty starts learning them** — Monty has to
predict the current rate from observable cues rather than memorise
a fixed value.

Two independent channels for learning the rate:

1. **Mothership ear-LM** — passive, indirect. Infers rate from
   acoustic tone of the band's rumble.
2. **Flying probe + ground sensor** — active, direct. The probe
   uses atlas-recognised ground features as a velocity reference:
   ground is fixed, probe is drifting, drift velocity = the
   rotational current at that altitude. Probe reports back.

The two channels cross-validate. Redundant modalities converging
on the same world dynamic via lateral voting — very Monty. Flying
into the storm gains scientific value beyond just resource raids.

**Electric storms may emerge when one ring counter-rotates against
another fast enough.** The storm's electrical phase is therefore a
consequence of the ring dynamics, not a designer-imposed event.

### Crawlers — modular rover platform

Flight gets you into the neighbourhood. To do *precise* work —
reach a specific depot tile, walk a structure perimeter, manipulate
a specific feature — you deploy a slow ground rover.

The rover is a **modular platform**: same base chassis, outfitted
for the job. Crane, excavator, transport bed, sensor suite, etc. —
it is whatever it's equipped to be. Smaller mouse-drones exist for
rapid scouting, and bigger ones for heavy work, but the modular
mid-size rover is the workhorse.

- Rovers are heavy, slow, locally-controllable (WASD: turn +
  forward / backward, world rotates around the character).
- Rovers carry their own short-range sensors; their LM data syncs
  with the mothership when they get back into eye range or when
  their parent flyer probe relays.
- Rovers can be **tethered to a parent flyer probe**. Tether is
  *local only* — gives you fine-grained relative position between
  rover and probe — and does **not** give you any absolute
  position. The "you're lost" core is preserved.
- Rovers can place short-range beacons (see below); these
  *supplement* recognition rather than replace it.

### Short-range beacons — supplement Monty, never replace it

Beacons are physical objects with manufacturing cost. Players can
place them freely; the cost regulates abuse. Long breadcrumb trails
burn real budget that could have gone to rovers or refineries.

The principle: **a beacon answers "where is this thing?" Monty
answers "what is this thing?"** Without recognition, a beacon is a
faint glow with no meaning.

Concrete rules:

- **Range proportional to clear air.** Full range in the eye; tens
  of metres at the eye fringe; tile-or-two in heavy dust. Beacons
  reach far where you can already see; they don't help in the dust
  where Monty matters.
- **Electric storms kill them all.** Player-placed and ancient
  alike. When the beacon network goes silent, atlas-only
  navigation is what's left.
- **Tied to atlas content.** A beacon means "near Foundry-3" only
  because the placer recognised Foundry-3 when dropping it. A
  beacon you placed while lost in the dust is just a thing you
  dropped somewhere.
- **Limited supply early, manufacturable late.** Early game,
  beacons are raided from ghost-town stock — scarce, used
  strategically. Late game, Tier 1 manufacturing produces more, but
  they compete with everything else in the parts budget.
- **Reclaimable.** Pick up unused beacons to recover cost.

### Building-emitted ancient beacons

Ghost-town structures broadcast low-power signals on the same
channel as player beacons — emergency systems still running after
the civilisation left. A **passive RF direction-finder** on probes
or the mothership picks them up at long range:

- *"Something is beaconing southwest, faint signal."*
- Player flies that direction; eventually close enough for atlas
  recognition to identify what's there
- The beacon points; recognition names
- Dust attenuates RF, so range is environmental
- Electric storms silence them too

This gives early-game city-finding a directional pull instead of
pure random exploration, without bypassing the recognition step.
*Pattern recognition* of beacon pulse signatures is a later
unlock — see Cortical Columns below.

### Truck navigation — Monty-based, IMU fallback

Late-game cargo trucks (transport-outfitted rovers) need to make
round trips between mines, refineries, factories, and the
mothership. Ideal mode: **trucks navigate via Monty**, using their
own atlas of recognised ground features to self-drive between known
endpoints. The atlas needs to cover the ground path, not just the
endpoints.

IMU dead-reckoning is the fallback for preset point-to-point routes
where the atlas hasn't been built up yet. Trade-off: IMUs get
**scrambled by electrical storms**, so trucks running on IMUs
during an electric phase stop or get lost. Trucks running on Monty
keep going as long as they can recognise terrain.

**Lost trucks** become a parallel of lost probes: scattered through
the dust, atlas-recoverable, and the player has incentive to invest
in Monty-aware trucks so this happens less.

The architecture splits movement into two cleanly different jobs:

| Phase | Movement | Monty's role |
|---|---|---|
| Hop out | Flight, radial-controlled / angular-chaotic | (none — physics) |
| Land + reorient | (the probe is stationary) | Recognition + pose estimation |
| Deploy crawler | Crawler exits the probe | (set local frame) |
| Crawl precisely | Slow surface movement, WASD | Hierarchical prediction — *which depot in this Foundry?* |
| Hop back | Flight, beacon heading | (beacon-guided, low-precision return) |

Recognition is load-bearing in two distinct moments (post-landing
orientation, and during fine crawl). Hierarchy is load-bearing
during crawl. Multi-modal voting is load-bearing in eye-fringe and
deep dust. Beacon does the gross-gravitational pull home.

---

## Sensors and Learning Modules

The mothership starts with **audio only** — its built-in ears
listening to the storm. Additional sensor modalities are discovered
mid-game by finding wreckage of lost probes (or, late-game, by
manufacturing them in mothership factories). Each modality is its
own Learning Module with its own graphs.

### The three biological intuitions

The sensor architecture maps to three different cognitive modes:

| Sensor type | Operator | Reference frame | Real-world intuition |
|---|---|---|---|
| **Eyes** | Flyer probes | Spatial (discrete sampling) | Look at things from a distance |
| **Fingers** | Ground crawlers | Spatial (continuous surface contact) | Feel a surface up close |
| **Ears** | Mothership (built-in) | **Temporal** | Listen to rhythms over time |

Eyes sample discrete points across an area quickly. Fingers
traverse a surface slowly with high resolution. Ears receive
passively and decode patterns *over time* rather than across
*space*.

### Sensor modalities and unlock progression

The campaign unlocks sensors roughly in this order. Earlier sensors
are simpler / shorter-range; later ones reveal things invisible to
the rest.

| Tier | Sensor | Operator | Output shape | Pedagogical job |
|---|---|---|---|---|
| L1 | **Bump** | Rover | Single bit (collision) per attempted move | Monty from one bit per position |
| L1 | **Mothership ear** (audio) | Mothership | Temporal stream | Temporal-axis LM (weather) |
| L2 | **Geo probe** | Rover | Material code on tile you're on | Sub-surface sensing; can't see habs, can see landing pads / strata |
| L3 | **Chemical sniffer** | Rover | Chemical signature on own tile | Find fuel depots — recognition gets economic teeth |
| L3/L4 | **Sonar (range 1)** | Rover | Adjacent-tile geometric ping | First non-contact spatial sensor |
| L4 | **Scalar colour** | Drone | One averaged colour per scan | Feature vectors beyond binary |
| L5 | **Colour array** (2×2 / 3×3) | Drone | NxN grid of colours | Resolution scaling on same modality |
| L5 | **Thermal IR** | Drone or rover | Heat reading | Active vs dormant distinction; cross-modal binding |
| L6 | **Magnetometer / GPR** | Rover | Magnetic / subsurface signature | Buried structures revealed; mineral deposit location |
| L7 | **Radiation Geiger** | Rover | Scalar count rate | Modality-exclusive distinction (shielded labs) |
| L7 | **FLIR camera** | Drone | Array-thermal | Resolution scaling on thermal |
| L7 | **Ground vibration → Thumper network** | Rover (passive → multi-rover active) | Seismic response | Distributed lateral voting at the sensor level |

Sensor range varies by sensor type (geo probe = own tile, sonar
upgrades extend range, etc.). Some sensors are direct upgrades
along the same modality (sonar-1 → sonar-2 → sonar-3 by range;
scalar colour → colour array → FLIR by resolution).

**Parallelism vs richness as a strategic choice.** At fixed
fabrication budget, the player can field either:

- N drones each with a scalar sensor → N parallel observation
  streams with lateral voting across them, wider spatial coverage
- 1 drone with an NxN array sensor → 1 stream with richer per-
  observation data, faster per-site convergence

Both work; same Monty algorithm; different observational style.
Late-game players who like spreading wide pick parallelism; players
who like deep dives pick richness.

### The ear-LM is on the mothership

The mothership doesn't move spatially in any meaningful sense — it
sits in the eye and *listens*. Its LM operates on a temporal
reference frame: features are sound-events; positions are
time-offsets within a recognised pattern.

The ear-LM is for **weather, not objects** — leaning toward the
mothership *not* hearing things like Foundries on the ground. Its
job is recognising storm patterns, rotation-rate shifts, and
acoustic precursors of phase changes, so the player can anticipate
what the storm is about to do.

Temporal-axis graphs are a clean extension of spatial-axis graphs:
same algorithm, same evidence/hypothesis/commit machinery, just a
different reference frame. Honest to the Thousand Brains theory
even though current `tbp.monty` source emphasises spatial.

### Cross-modal binding

Each sensor's LM starts with its own graphs. There is no automatic
cross-modal recognition. When a new sensor unlocks, its LM begins
empty. The player revisits known territory. The new LM commits its
own graphs in its own feature space — "thermal-pattern-3" here,
"acoustic-pattern-7" there — with no semantic link to the
optical-LM's Foundry graphs.

**Consolidation prompt:** *"optical-Foundry-3 and thermal-pattern-2
co-occur at the same poses. Bind?"* Player merges → either modality
now recognises the Foundry. Payoff in the next electric storm:
optical is irrelevant; thermal alone identifies Foundries because
the binding survived.

Sensor unlocks aren't collectibles. They're a structural reason to
re-explore known territory: *to teach a new column what the others
already know*.

---

## Cortical Columns — The Monty Infrastructure

Cortical columns (Monty modules) are a **transferable, attachable
physical resource** the player manages. This directly reifies the
Thousand Brains thesis: cortical columns are general-purpose
learning units; the same column architecture works on any input.
The player feels the algorithm's generality by literally moving
columns between systems and watching them learn new modalities.

### What a column is

A small biological-on-chip neural tissue unit. Each column is one
Monty Learning Module — has hypothesis population, atlas of
committed graphs, evidence-update machinery. Columns are *physical
objects* the player accumulates, installs, transfers, and clones.

### Where columns come from

- **Starter kit.** Player begins with a small handful (one or two
  attached, maybe a couple of spares).
- **Recovered probes.** Rarely, a recovered probe carries a column
  — often pre-trained on whatever sensor it was attached to. First
  one typically found on a recovered probe in the early game.
- **Mothership bioreactor.** Slowly grows new columns from neural-
  tissue substrate. Needs **food slurry** (ingredients sourced from
  atlas-located mineral deposits + power). Growth rate is the
  primary regulator on column abundance; accelerable with
  investment (more power, more substrate, eventually lab-tuned
  mass production).
- **Tier-1 manufacturing.** Late-game factories can produce columns
  alongside other components, contingent on lab blueprints.

### Attachment

A column plugs into one of:

- A **raw sensor stream** → recognises tier-0 features (tiles,
  sounds, RF pulses, etc.)
- **Another column's output stream** → recognises one tier up
- (Speculatively) An **action / decision stream** → enables the
  speculative reference-frame tiers (state-transition,
  theory-of-mind)

Hierarchical recognition is *literally stacking columns*. T1
recognition = column on a sensor; T2 recognition = column on T1's
output; T3 = column on T2's output. Column scarcity directly
constrains atlas depth.

The player UI shows explicit attachment slots — a panel listing
each sensor and column output stream, with the columns currently
attached. Drag-and-drop to move.

### Reconfiguration and the heterogeneous atlas

Atlases persist on swap — they are *not* deleted. A column's
graphs stay in its memory across reconfigurations:

- **Atlas accumulates across all attachments.** Every feature space
  the column has ever been attached to contributes graphs.
- **Only graphs in the currently-attached feature space can match.**
  Other graphs sit dormant.
- **Swap back → previously-trained graphs become active again.**
- **Saturation is the natural cost.** Each column has finite graph
  capacity. Using one across multiple sensors fills it up faster;
  specialised columns (single sensor) stay clean longer.
- **Hard wipe is an explicit player action** — separate from swap.

Whether you attach two streams *simultaneously* or swap between
them *sequentially*, the column ends up with more graph data than
a specialised column would. Both saturate earlier. Both are worse
than two separate columns + cross-modal binding, which is the
canonical architecture. The player is allowed to try the
suboptimal arrangements as a learning moment — feeling the
algorithm's preferences directly.

### Cloning

Columns can be cloned at a research lab:

- **Labs only.** Lab reads the source column's atlas, instantiates
  it on a fresh column.
- **Slow.** Takes turns to complete.
- **Source survives.** Cloning is non-destructive — original
  column is untouched.
- **Material cost.** Substrate consumed per clone.

This unlocks **mass-producing trained columns** for the late-game
ant-colony swarm: train one column carefully, clone it to every
rover, instant fleet knowledge inheritance. Atlas-as-supply-chain
deepens — losing the lab loses your cloning capability.

### Distribution architecture — where the column physically lives

Columns are physical hardware on a specific platform. The platform
determines what the column has access to.

- **Mothership-mounted column.** Safe, broad atlas band along the
  storm path, ear-LM lives here by default.
- **Hopper-mounted column.** Forward cortex for rovers operating
  nearby. The hopper can act as a *local brain* for dumb-terminal
  rovers via radio.
- **Rover-mounted column.** Fully autonomous rover — its own
  cortex on board. Doesn't need radio to make sense of its input.

Early-game rovers are typically **dumb terminals**: they transmit
sensor data back to a column on the parent hopper or mothership,
which does the inference and sends back commands. Late game,
column abundance lets you put one on each rover for true autonomy.
The mid-game transition is a real capability moment.

### Radio bandwidth scales with power allocation

Sensor data flowing back to a parent column consumes radio
bandwidth. The radio link has **32 channels nominal**, ~16 active
in calm conditions, degrading further as storms thicken. Player
allocates the surviving channels to whichever rovers / sensor
streams matter most:

> *"Cut radiation reads on rover-2 and rover-3, keep the bump
> sensors on all four so they can at least navigate."*

Storms become a *spectrum* of communication failure rather than a
binary. Low-bandwidth sensors stay alive in heavy storms; high-
bandwidth ones die first. Onboard-column rovers are immune to
this entire failure mode — they don't need the link.

### Beacon pattern recognition unlocks via column attachment

The hopper's RF beacon detector starts as a *raw* direction-finder
(picks up signals, no pattern recognition). Attaching a column to
the RF stream unlocks **pulse-pattern recognition**:

- Each beacon (ancient or player-placed) pulses to save energy,
  with a temporal signature unique to its type / model / age.
- The Monty-augmented RF receiver decomposes the **SDR beacon
  chord** from a base — multiple structures' overlapping
  pulse signatures — into constituent patterns.
- Late-game payoff: the mothership "hears what's down there" via
  the chord alone, identifying base composition before any probe
  lands.
- Beacon patterns are *learned*, long to converge, deeply
  informative at maturity. Mature RF atlas gives the player
  probabilistic priors about every region the eye drifts over.

Cross-modal binding works the usual way: an RF pulse-pattern bound
to a visual Foundry signature lets either modality identify
Foundries.

This is also the canonical example of *"attach a column somewhere
unexpected, get a new capability."* Player feels the cortical-
column generality the first time they install one on the RF
detector and the temporal patterns suddenly start resolving.

---

## Tile Vocabulary

Collapsed dramatically from v3. The lesson is composition, not
richness.

### Terrain tiles

Mostly sand. Heavy natural texture would give the player free
navigation landmarks and dilute the value of structures, so
keeping terrain near-uniform makes **habs the concrete landmarks**.
Terrain tiles do not participate in structure composition.

### Structure tiles

| Tile | Notes |
|---|---|
| **Wall** | One wall, rotated to face any hex edge |
| **Outside corner** | One convex corner, rotated |
| **Inside corner** | One concave corner, rotated — enables L / C / E shapes (non-convex outlines) |

That's it. No interior floor tile. No door tile.

### Doors are features, not tiles

Doors are **sub-features attached to a wall or corner**, alongside
vents, damage scuffs, antenna mounts — small disambiguating
details. They're what distinguishes two instances of the same
archetype: same Foundry shape, but one has the door on the east
wall and the other on the west.

### Structures have vertical layers

Walls and corners aren't single-level — structures span multiple
height layers (footprint at layer 1, roof edge at layer 2, antenna
or peak at layer 3, etc.). Sub-features attach at specific heights
(vents low, antennas high, damage scuffs anywhere). Different
sensors see different layers:

- Rover bump / geo probe: ground-line features only
- Drone height range-finder: top features (whatever pokes above
  the sand line)
- Mag / GPR / seismic: read through ground, including below current
  sand level

This enables **partial burial recognition** — see Sand Burial
below.

---

## Composition Tiers

The same Monty algorithm runs at every tier. Each tier's "feature
at a pose" means something different, but `lm.odin` is unchanged.

| Tier | Object | Feature at a Pose | Reference Frame |
|---|---|---|---|
| 0 | a single tile reading | tile symbol at (x, y) | local patch |
| 1 | a **structure** (Hab, Lab, etc.) | tile-type at (dx, dy) within structure | structure-local |
| 2 | a **district** | structure-type at (dx, dy) within district | district-local |
| 3 | a **region archetype** | district-type at relative pose | region-local |

Sub-feature transfer at every level. The wall tile appears in
every structure; once tier-1 has a wall graph, recognising any new
building accelerates. A Hab appears in many districts. A
district-archetype recurs across the plain. The cascade is the
lesson of Thousand Brains theory: hierarchies of reused patterns.

### Same-archetype, one tile different

Two districts can share an archetype but differ by a single tile —
one Foundry-cluster has its hab door east, another west. T2
recognition resolves the *archetype*. T1 details disambiguate
*which specific instance*. Top-down prior plus bottom-up
refinement, no adversarial framing needed.

### Higher tiers unlock transport, not just recognition

Recognising a base individually (T1) doesn't tell you *what's near
it*. To route a rover from Foundry-3 to Hab-7, you need to know
their relative positions — and that lives in the higher-tier
atlas:

- **T1 only**: each base is recognised in isolation. Travel between
  them requires fresh recon flights to discover relative positions.
- **T2 atlas**: "Foundry-3 and Hab-7 are in the same district at
  known offsets." Rover routing between them becomes possible.
- **T3 atlas**: "this district sits near another district at known
  regional offset." Long-haul inter-district routes.

The hierarchy isn't just teaching, it's *unlocking transport
capability*. T2 enables base-to-base rover networks; T3 enables
the late-game logistics chain.

---

## Memory Architecture

Each LM has three memory layers, matching real Monty:

1. **Observation buffer (short-term).** Every incoming CMP message
   lands here. Bounded, rolling. *Storm pulses wipe this.*
2. **Hypothesis population (working).** Thousands of candidate
   `(graph_id, pose)` hypotheses, updated with new evidence each
   step. Lives during inference, dissolves after.
3. **Atlas — committed graphs (long-term).** Each graph is a set of
   nodes: `(location_in_object_frame, surface_normal,
   feature_vector)`. Persistent across storms. Never auto-forgotten.

**Committing** = promoting buffer → atlas. Either a new graph
(novelty) or extending existing nodes (familiar object, new
viewpoint). Triggers vary by phase of the game (manual vs auto —
see Delegation Arc below).

**No forgetting of atlas graphs.** Real to Monty. Duplicate graphs
(LM commits a second copy of the same true object because it
didn't recognise the second instance) are kept as an honest failure
mode and turned into a **consolidation** mechanic — optional
late-game player action to merge duplicates.

**Storm pulses force commit-or-lose.** Before each major storm
pulse, the player sees a countdown. Anything in the buffer not
committed is gone after the pulse. Commit decisions become
economic: gamble on more scans to firm up novelty, or commit now
and lock in what you have.

---

## Storms

Storms are not single events. The world has a *constant low-grade
storm* (the dust) plus periodic pulses of stronger weather. Storm
behaviour is a spectrum:

| Phase | Effect on visibility | Effect on beacon | Player consequence |
|---|---|---|---|
| **Calm** | Eye stable, dust thin | Beacon clear | Easy operations |
| **Pulse** | Eye contracts briefly | Beacon range shrinks | Pull probes in |
| **Electric storm** | Eye normal | **Beacon cuts out** | Atlas-or-die for any probe in flight |
| **Major drift** | Eye relocates significantly | Beacon survives | Wake up over new terrain |

The **electric storm** is the dramatic forcing function. Normal
storms: beacon up, navigation possible. Electric storms: beacon
dead, no heading-to-home, no fuzzy distance, *only* terrain
recognition gets you back. If you're in scouted territory, the
atlas saves you. If you're not, you wait it out somewhere safe or
get caught in the dust until it passes.

This creates three real player choices:

- Stay near home during electric weather (safe, low yield)
- Push out during normal weather only (productive, predictable)
- Get caught mid-flight (atlas mastery or perish)

Storms get *easier* to survive late-game because your atlas
coverage grows — wherever the eye drifts, you can likely recognise
some terrain and find shelter. **Late-game difficulty comes from
greed**: late-game resource demands push you to spread past your
known terrain, and that's where electric storms catch you. The
ear-LM's storm prediction matters in both phases, but for different
reasons (early-game survival, late-game informed gambling).

### Major drift events

A subset of storm pulses produce a *major eye relocation*: the
mothership wakes up over significantly different terrain. This is
the kidnapped-robot puzzle in full force — but it doesn't happen
every storm, only on rare flares. Smaller drift between storms is
continuous (brownian). Major drift is discontinuous and dramatic.

---

## Sand Burial — The Drifting Home Base

The world has a continuous **sand-depth field** that the storm
reshapes over time. Sand drifts; structures get covered; previously
unknown structures get uncovered. The atlas isn't drift-free even
if you do nothing — the world itself moves under your model.

### Height encoding

Sand depth lives on a 32-step scale, roughly:

- 4 layers above ground (visible structure heights)
- ~16 layers below ground (burial depth steps)

Visible burial buckets: **unburied → sorta covered → half covered
→ nearly covered → covered**. Structures' upper layers stick out of
shallow burial; their footprint stays hidden. Combined with the
multi-layer structures (see Tile Vocabulary), this gives partial-
match recognition states.

### Burial dynamics

Sand depth is a **low-octave Perlin field** painted over the world,
with intensity correlated with storm position:

- **Near the eye**: shallow changes, slow drift. The current eye
  area is naturally protected.
- **Far from the eye / inside the storm**: large coherent patches
  shift, rotate with storm currents, can change rapidly.
- Field updates incrementally per turn.

This means: while the eye is over your home base, sand stays
roughly put. Once the eye drifts away and your old base sits in
the storm, sand drift goes wild in that area.

### The slow-drift home-base-becomes-buried arc

The single strongest narrative beat of the campaign. Sequence:

- **Early game**: eye barely moves. Player invests in a home base
  near the eye. Emotional investment.
- **Mid game**: eye drifts. Home base slips toward the dust.
- **Late game**: home base behind the storm wall, possibly buried.
  Magnetometer / GPR / excavator-equipped rovers needed to
  re-find your own home.

That last beat is the Monty payoff with personal weight. The
player's relationship to their atlas shifts: not just "places I've
been" but "places I'm losing track of." Recognising your own old
base via subsurface signatures is the emotional centre of the late
game.

### Side effects of sand on sensors

- **Geo probe on top of thin sand cover**: returns a weird material
  reading (concrete substrate under sand) rather than just sand —
  incidental detection of buried structures.
- **Drone height range-finder**: measures top-of-sand and top-of-
  structure, both. Tracking change in either reveals burial /
  unburying over time.
- **Mag / GPR / seismic**: read through sand cleanly. The primary
  tools once burial is real.

### Partial-burial recognition is a Monty teaching beat

Half-buried structure: top features (high sub-features, wall-tops)
match the atlas; bottom features (footprint, perimeter, low sub-
features) hidden. The LM produces mixed-evidence recognition:
*"Foundry-3 with burial, depth ~3 units"* reconciles all evidence
cleanly. New feature channel (burial depth) on existing graph
nodes. Mag/GPR is the disambiguator that confirms the lower portion
is still the Foundry-3 footprint.

---

## Probes — Types, Budgets, Recovery

### Probe types and weight classes

| Class | Cost | Sensor capacity | Typical role |
|---|---|---|---|
| **Light scout** | Cheap | One simple sensor | Recon, scouting ahead of the eye |
| **Standard probe** | Moderate | 2 sensors | General-purpose work |
| **Heavy lander** | Expensive | Multiple sensors + crawler payload | Detailed atlas-building, fine work |
| **Cargo drone** | Moderate | Minimal sensors | Resource hauling along known routes |

Drone count grows over the campaign. Early game: one probe at a
time. Mid game: a small fleet. Endgame: an ant-colony swarm with
specialised roles. Composition of the swarm becomes the late-game
strategic decision.

### Commit budget per excursion

Probes operate in dust beyond beacon range. Their findings need to
get *back* to the mothership atlas. Each probe has a limited
**commit budget** per excursion — N transmission events. A commit
event = a relay rocket fires up out of the dust, transmitting the
current buffer state to the mothership. Run out of commits, the
remaining observations are lost when the probe returns or is
destroyed.

This creates the storm-wipes-buffer mechanic *between agents*
rather than within a single LM. The probe has local working memory;
the mothership has long-term atlas; transmission is the commit
event. Strategically: spend commits early on safe ground, or
gamble all of them on a deep-dust prize?

### Lost probe recovery

Old probes from past expeditions are scattered through the dust.
Recovering one gives you its atlas data — possibly graphs from
sensors you don't currently have, in regions you haven't personally
visited. Multiple wins:

- Atlas growth without personal scanning
- Cross-modal binding material (recovered probes may have used
  sensors you only just unlocked)
- Atmospheric texture: derelict probes scattered in dust, each a
  tiny narrative
- Justifies surprising atlas entries appearing mid-game

The lost-probe mechanic creates a non-resource exploration
incentive that scales with how willing the player is to push into
risky terrain. It also gives a *natural late-game atlas growth
mechanism* that doesn't require the player to scan everything
themselves.

### Sensor recovery from probes

A found probe broadcasts a **short-range recovery beacon** to help
you land near it and find it once on the ground. Recovery gives
you a sensor type you may not have. You then choose where to
install it:

| Option | Risk | Notes |
|---|---|---|
| **Mothership** | Safe | Sensor lives in the eye |
| **Player's hopper** | A little risky — lost if hopper crashes | Active sensing in dust |
| **Player's ground rover** | More risky if the rover gets left behind | Surface sensing at distance |
| **Working research lab → disassemble** | Probe permanently consumed | Yields blueprints; you can fabricate that sensor in a factory, but you have to find the lab again to keep producing |

The mothership-mount advantage is its own beat: as the eye drifts,
mothership-attached sensors lay down a **band along the storm's
path** where multiple atlas types overlap. If you find that band
again you can pick up everything that was on that path across
sensor types.

---

## Construction and Atlas Drift

Mid-late game, the mothership manufactures construction drones that
build new structures and augment existing ones — both inside the
eye (visible to the player) and out in the dust (out of sight).

### Construction is logged, not integrated into the atlas

When a construction drone completes a task, the mothership log
records the order ("Foundry-3 expanded with 4 new wall segments,
completed T+312"). The atlas is **not** auto-updated. The LM only
believes what it has *observed*.

The player does not manually integrate construction reports into
the atlas. They are reference information in the log, nothing more.
The atlas degrades passively wherever construction has happened.

### Discovering the drift

When the player or a probe next re-encounters a modified structure,
the LM's recognition shows mixed evidence:

> *Foundry-3 recognised. Evidence: mixed. Local mismatches at 4 nodes.*

That's the discovery moment. No external memory required; the LM
flags its own confusion through the existing evidence display.

The player can then:

- **Trust it anyway** (atlas is mostly right; resources may still
  be where predicted; gamble on a landing)
- **Re-scan in person** to let the LM observe and update the
  affected nodes (slow, accurate)
- **Ignore for now** and deal with the drift later if a resource
  trip there pays off poorly

Same prediction-vs-verify tradeoff as the rest of the game,
applied to one more decision surface.

### Why this works as a Monty mechanic

- Reason to revisit known territory. A static world becomes
  trivial once mapped; modification keeps the atlas degrading, so
  revisiting and updating is always meaningful work.
- Resource uncertainty becomes a Monty problem (predict vs verify)
  rather than a player-memory problem.
- Honest to Monty: the LM doesn't auto-update its model when the
  world changes underneath; player observation triggers the
  update. Algorithm and mechanic match.
- Story: the AI is slow to update its model of a world the
  *player* is changing without telling it. Grounded narrative
  ("you're the only one building right now"), no mystery actor.
  The AI's confusion is genuine, charming, resolvable.

---

## Resource Economy

The resource layer is what makes Monty's predictions consequential.
Recognition isn't trivia; it's a cost-saving query against the
generative model.

| Resource | Mechanic hook |
|---|---|
| **Fuel** | Probe drops, crawler runs; predicted by atlas (Foundries have fuel depots at known relative positions) |
| **Water / coolant** | Exclusive to moisture-LM detection (rewards cross-modal investment) |
| **Spare parts** | Recovered from damaged habs (cross-modal disagreement flags damage) |
| **Sensor charge** | Per-scan cost; goal-state generation that saves you scans extends your operating budget |

### The core loop

> *Fuel at 12%. Orbital + acoustic place us near a known
> Foundry-Beta archetype. Foundry-Beta atlas entry shows pumps in
> the southwest depot tiles. Imagine-mode ghost-renders the LM's
> predicted pump locations. Drop standard probe, scan two tiles to
> confirm prediction, deploy crawler, pump fuel, hop back. Total
> cost: 2 scans + 1 drop + 1 crawl. Alternative: scout fresh
> terrain — 12+ scans, no prediction, might find nothing.*

Every Monty capability is load-bearing in this loop: T2 recognition
(Foundry-Beta), T1 prediction (where the depot is), few-shot
speedup (you've seen Foundries before), pose (which way the depot
faces), atlas persistence (last storm didn't wipe what you
committed), cross-modal (thermal confirms the depot is *active*
without optical), construction-aware (was this Foundry expanded
since last raid?).

### Depleted-depot state

Once you raid a depot, the corresponding tile-node in the atlas
graph gets a `fuel_level = empty` annotation on its feature vector.
The LM still recognises the Foundry. The tile-node still matches.
But the feature reads empty, the tile renders dimmed, and the
prediction "fuel here" is now "no fuel here." Same recognition
pipeline; one more feature channel.

### Resource scarcity drives outward push

Early game, eye-local resources are enough. Mid-game pushes you to
the near-dust. Late-game requires deep-dust raids and ant-colony
infrastructure. Difficulty rises *because the player's needs grow*,
not because the world changes — the cleanest progression curve
this design considered.

### Tier 0 (raid) → Tier 1 (manufacture)

Throughout most of the campaign, the **ghost-town economy is
sufficient**: raid existing buildings for parts, fuel, coolant,
etc. The civilisation that left this place stocked it. You don't
build; you steal.

Only towards the end-game, when raided depots are depleted enough
that the supply can't keep up, does **Tier 1 manufacturing** come
online. Minimum-complexity Factorio-flavoured loop:

- **Mines**: extract raw resources (metal ore, oil) from deposit
  tiles. Fixed yield per turn; if you want more throughput you
  build *more mines* in more places, not bigger mines.
- **Refineries**: raw → refined material (metal, fuel). Need
  power.
- **Factories**: refined material + blueprint → output (probes,
  sensors, rover modules, structures).
- **Labs**: produce blueprints by reverse-engineering recovered
  probes (one reverse-engineering at a time per lab). To keep
  producing, you have to re-find the lab across storms — atlas
  recognition becomes the supply chain.
- **Power**: oil-burning generators or (late-late) reactors.
- **Transport**: cargo-outfitted rovers (trucks). Throughput =
  rovers per round-trip per turn. Closer mine = faster round trip,
  fewer rovers required. Distant mine = more rovers for the same
  rate.

Mine sites are *located by sensor* (magnetometer for metal
anomalies, geo probe for ore strata, chemical sniffer for oil
seeps), so even the economy is gated by recognition. You can't
build a mine until your atlas knows where to put it.

### Excavator rovers

A rover variant outfitted with a digging tool. Used to **unbury
previously-known structures** after sand drift covers them. The
atlas remembers the structure; mag/GPR finds it through the sand;
the excavator clears it for re-use. Critical for late-game home-
base recovery.

---

## The Scanner — Disagreement Overlay

The HUD does not show "which object lives where." It shows
*hypothesis disagreement*.

At each unscanned tile, the LM looks at its top-N hypotheses and
asks: *what feature does each predict here?* Tiles where
predictions disagree are informative. Tiles where everything agrees
tell you nothing.

Display: per tile, a small palette of coloured dots — one dot per
top hypothesis, colour = predicted feature under that hypothesis.
Tiles with one solid uniform colour are boring. Tiles bristling
with different colours are gold.

This matches what real Monty's goal-state generator computes. In
the late-game automation phase, the LM picks the next scan tile
itself — same algorithm, no player click in the loop.

---

## Pathfinding — A* and Monty

Pathfinding is a separate algorithm from Monty (standard A* on hex
grids), but Monty *feeds* it. Several useful pairings:

### Curiosity-driven exploration

The disagreement overlay scores each reachable tile by information
gain. A* turns those scores into a **route** rather than a single
target:

- Greedy: rover always heads toward the nearest high-info tile,
  recomputes after each scan. Reactive — better when the
  disagreement map shifts rapidly as new evidence comes in.
- TSP-style tour: rover plans a sweep through the top-N highest-
  scoring tiles. Better when the map is stable.

This turns Monty's "where should I look next" into a multi-step
plan the rover executes autonomously. Player action becomes "send
rover on a curiosity sweep, budget N scans." The rover does the
rest.

In the manual-to-automatic delegation arc, this is exploration
itself getting delegated:

- Early game: player picks each tile manually from the disagreement
  overlay
- Mid game: player picks a target tile; rover routes there via A*
- Late game: player says "go scan curiously for a while"; rover
  plans a multi-step route and executes

### Predictive A\* using hypothesis state

A* doesn't only use *observed* obstacles — it uses Monty's
*predicted* obstacles. If the top hypothesis says "this is
Foundry-3," the LM predicts where Foundry-3's walls should be in
the unscanned region. A* routes around those predicted walls even
before they've been confirmed. Confidence weights the cost:

- High-confidence hypothesis → predicted obstacle is hard
- Low-confidence → soft cost penalty
- Multi-hypothesis → cost is the max across plausible predictions
  (conservative routing)

Practical effect: **navigation gets faster as recognition gets
better.** Early in an inference episode, rovers route
conservatively. Late in the same episode, with confident
hypotheses, rovers cut through predicted-but-unconfirmed regions
efficiently. Monty's recognition pays off twice — once for
identification, again for routing.

### Multi-rover Voronoi assignment

When multiple rovers are out scanning, naive plans send them all
toward the same high-info tile. Cleaner: partition the curiosity
map by rover position (Voronoi-like) so each rover handles its own
cell.

- Compute each rover's cost-to-reach for each candidate target
- Solve the assignment problem (Hungarian algorithm or greedy)
  to minimise total path cost across the swarm
- Each rover runs its own A* to its assigned target

For the late-game ant-colony swarm this is load-bearing — without
coordination, dozens of rovers clump together. With Voronoi
assignment, the colony's effective scan rate scales with rover
count.

---

## The Manual-to-Automatic Delegation Arc

This is the spine of the game. The player learns Monty by *being*
Monty, then gradually delegates each layer to automation they have
come to understand and trust.

Every step that *can* meaningfully be done manually starts manual.
Each unlocks automation only after the player demonstrates
competence. Automation is *earned*, not gifted.

| Step | Manual mode | Automated mode |
|---|---|---|
| **Probe movement** | WASD-drive the probe across tiles, press space to scan | LM auto-paths the probe through a scan pattern |
| **Pose alignment** | LM shows 6 candidate rotation overlays (hex); player clicks the visually-fitting one | LM picks silently using evidence scores |
| **Hypothesis tracking** | Player reviews top candidates from a list | LM maintains thousands silently |
| **Next-scan choice** | Player picks tile from disagreement overlay | LM picks the most-disambiguating tile |
| **Commit decision** | Player explicitly commits "Pattern-N" before storm hits | LM auto-commits when novelty rate sustains |
| **Cross-modal binding** | Player merges co-occurring graphs after sensor unlock | LM proposes binds when co-occurrence is strong |
| **Consolidation** | Player merges duplicate graphs in the atlas review screen | LM proposes merges automatically |
| **Strategic goals + swarm composition** | Player chooses targets, resource priorities, drone loadout | *Currently outside Monty's algorithmic scope; player-owned by default* |

The bottom row is **not a design rule, it's a current limitation
of the system**. If Monty could automate strategic loadout it
should; for now it can't, so the player owns it. Nothing sacred —
just the honest boundary of what the algorithm covers today. As
the LM takes the low-level loops, the high-level choices get
richer (sensor loadout per drone, which duplicates to consolidate,
when to trust predictions vs verify, when to push deep for rare
resources) because those are the parts Monty isn't yet doing.

Two manual modes that *don't* really exist:

- **Feature extraction**: never really manual. The sensor module
  emits features; the LM consumes them. What's "manual" in early
  levels is just probe movement and scan-triggering — the player
  chooses *where* to sense, not *what features* to extract.
- **Pose math**: never manual either. The math is automatic. What
  the player does at L1 is *pick from a small set of candidate
  rotations* (the same N hypotheses the LM is evaluating), so
  they see what the LM is doing without doing math themselves.

---

## Level Chain — Acts

Four acts mapping to roughly seven levels. Levels build mechanic-
by-mechanic; we don't ship the full mechanic stack at L1.

### Act 1 — You ARE Monty (L1, L2)

- **L1 Recon.** WASD-drive one probe across a single structure.
  One sensor only. Manual pose alignment (click one of 6 candidate
  rotations on the hex grid). Player commits a tier-1 graph by
  hand. Painful by design — every Monty step is one click.
- **L2 Survey.** Multiple structures, same manual loop. Pose
  alignment automation unlocks at end of level. Probe motion
  becomes "drive to next tile" rather than "click rotate."

### Act 2 — Delegate motion-planning (L3, L4)

- **L3 Voting.** Multiple probes around one structure. Lateral
  voting visible in the HUD. Hypothesis tracking automation
  unlocks (LM maintains the candidate list silently).
- **L4 District.** Tier-2 LM running on tier-1 outputs. First
  hierarchical step. Auto-probe-pathing unlocks. **New sensor
  recovered** here (thermal?) — first manual cross-modal binding
  episode.

### Act 3 — Trust the LM at low levels (L5)

- **L5 Storm.** First major drift event. First electric storm
  with beacon outage. Reorientation game in full force. Crawlers
  introduced. Scans now run autonomously between hops. Commit
  decisions still manual under storm-countdown pressure. Third
  sensor recovered (radiation?), with another manual binding.

### Act 4 — Strategy only (L6, L7)

- **L6 Atlas.** Tier-3 region-archetype LM. Construction drones
  introduced; atlas drift starts. Auto-commit unlocks (player
  reviews the LM's commits rather than driving them). Storm-
  prediction via ear-LM goes live.
- **L7 Sandbox.** Free play. Ant-colony management. Storms keep
  coming. Resources flow. Strategy and consolidation are the only
  remaining player actions. The endgame *feels different*
  because the player has graduated — not because the game got
  harder.

---

## Honesty Audit — What's Faithful, What's Extended, What's Speculative

Continuing the V1 About-page tradition of explicit honesty about
where the implementation follows `tbp.monty` and where it diverges.

### Faithful to current `tbp.monty`

- The LM core *is* upstream `tbp.monty`, not a reimplementation.
  CMP message protocol, reference-frame alignment, hypothesis
  population, three-criterion convergence + symmetry escape,
  lateral voting, hierarchical composition, novelty-based commit,
  atlas persistence — all running as actual Numenta code.
- Atlas with no automatic forgetting matches current `tbp.monty`.
- Duplicate-graph commits when re-recognition fails is preserved
  as an honest failure mode rather than papered over.

### Honest extension of the algorithm (in-spirit of Thousand Brains theory)

- **Temporal-axis LMs** (the ear-LM): Hawkins explicitly argues
  the same cortical algorithm handles temporal sequences. We
  implement this for storm prediction and ring-rotation
  learning. Theoretically clean, not strongly emphasised in
  current `tbp.monty` source.
- **Multi-modal LM stack with cross-modal binding via lateral
  voting** is the core thesis of Thousand Brains theory. V3+
  pushes this further than V1 did.
- **World-dynamics as learnable features** (ring rotation rates,
  storm acoustic signatures) is a natural extension of feature-
  at-pose into feature-at-time-or-context.
- **Manual-mode UIs** (rotation selection, commit confirmation)
  are teaching scaffolds, not Monty primitives. They show the
  player what the algorithm is doing.

### Explicitly speculative (to be tagged in-game)

- Resource-prioritisation-as-graph (see next section): Hawkins
  argues the cortex uses the same machinery for strategic
  cognition; not implemented in current `tbp.monty`.
- AI-modelling-the-player (theory-of-mind tier): purely theoretical
  in `tbp.monty`; the strongest realisation of the unifying theory
  but currently the most stretched.

The About page in v4 carries forward V1's structure: WHAT'S
FAITHFUL, WHAT'S SIMPLIFIED, WHY THE DIFFERENCES, REAL MONTY
POINTERS. The list updates but the norm stays.

---

## Speculative Tiers — Reference Frames Beyond Space

*The next section to expand. Hawkins's claim is that the same
cortical algorithm handles many reference frames — temporal,
state-transition, conceptual, theory-of-mind. The current spec uses
spatial + temporal solidly; state-transition and conceptual remain
candidates for late-game mechanics that take the unifying theory
seriously without overcommitting beyond current implementation
reality.*

Reference frames potentially in scope:

- **Spatial** (tile, structure, district): implemented.
- **Temporal** (storm patterns, rotation rates, sequence
  recognition): implemented as the ear-LM.
- **State-transition** (strategic decision-space): speculative —
  could become an optional late-game AI self-planning unlock.
- **Theory of mind** (modelling the player's tendencies): the
  most speculative; could become the final character beat where
  the AI starts predicting your decisions.

The user has flagged interest in exploring how these might fold
into gameplay. To be elaborated in a follow-up discussion before
committing to specific mechanics.

---

## Aesthetic & Tone

A tabletop simulation seen from above — half toy, half lab
instrument. The dust plain renders in low-saturation tones when
scanned, fading to dust-coloured noise where it hasn't been. The
eye is a soft halo of clear vision around the mothership. Storm
transitions are dramatic but brief (ionic crackle, dust roar, then
the eye contracts or expands or shifts).

The mothership AI gets a small text-readout character that narrates
its confidence and confusion. Early game: *"I think this is
something. I don't know what."* On committing: *"I'll call this
Pattern-3 for now. I'll know better when I see another."* On
duplicates: *"…this might be the same as Pattern-3. I'm not sure
yet."* On modified structures: *"Foundry-3 is bigger than I
remember. Did we build that?"* Honest about its quirks; the player
develops a relationship with the perceiver.

Seriousness lives in the HUD (hypothesis funnels, evidence bars,
beacon strength, eye boundary, modality-disagreement chips), not in
world fiction. No dramatic music. Ambient hum, sensor pings, the
chord-collapse when a hypothesis funnel resolves, the dread tone of
beacon dropout.

---

## What Transfers From V1

**The LM core does not transfer** — V4 uses the actual `tbp.monty`
codebase instead of our Odin reimplementation. So `lm.odin`,
`object_model.odin`, `lm_receive_vote`, the sandbox live-learning
logic — these are all replaced by upstream.

What does transfer:

- **`sensor.odin`** (CMP_Message) reused; `features` becomes a
  small enum plus side channels (heat, radiation, moisture).
- **Hack font, raylib, save/load, level-vtable, briefing system,
  About page** — reusable.

New in v4:

- Dust-plain renderer with eye visibility bubble
- Beacon model (strength, direction, outage states)
- Flight physics (radial-controlled / angular-chaotic, ring-band
  rotation rates as world state)
- Crawler entity with WASD surface movement
- Multi-modal LM stack (one LM per sensor type, lateral cross-
  modal voting, consolidation prompts)
- Temporal-axis ear-LM with sequence graphs
- Storm system (calm / pulse / electric / major drift)
- Probe types with weight classes and commit budgets
- Lost-probe recovery mechanic
- Construction drone system with mothership log (no auto-atlas-
  update)
- Multi-tier LM stack (T1 → T2 → T3)
- Disagreement-overlay scanner
- Manual-mode UIs for pose-candidate selection, commit
  confirmation, cross-modal binding, consolidation

V1's spacecraft, free-flight controls, and continuous-value
material features get retired.

---

## Pedagogical Wins Over V1

1. **Sensor mechanics are authentic.** Probes are on the surface;
   contact point = sensor position.
2. **Multi-column voting is geometrically real.** Co-located
   probes, exactly like cortical columns.
3. **Multi-modal voting is the headline.** Heterogeneous sensors
   that *only together* solve the world — the Thousand Brains
   thesis proper.
4. **Hierarchy is genuinely fractal.** Tile → structure →
   district → region, each tier reusing the previous.
5. **Kidnapped-robot is the daily loop.** Every flight is a
   reorientation puzzle because the beacon doesn't tell you
   angular position.
6. **Carcassonne is literal.** Hawkins' tile-by-tile analogy is
   the actual gameplay.
7. **Predictions are economically valuable.** The resource
   economy makes the LM's generative model consequential.
8. **Cross-modal binding is dramatic.** New sensors require
   *teaching*; the binding moment gives a clear "the model fused"
   beat.
9. **The delegation arc is the lesson.** You learn Monty by being
   Monty.
10. **The mothership AI is a character.** Atlas-as-mind makes the
    perception loop emotional.
11. **The ear-LM puts the temporal axis on screen.** Storm
    prediction and rotation-rate learning extend the algorithm
    visibly into a second reference frame.

---

## Open Questions

- **Turn-based vs realtime** — current leaning is turn-based with
  continuous game-time, but undecided. Re-discuss before locking.
- **Eye radius** in tiles? Maybe 8–12 tile radius for a working
  scale. Wants playtest.
- **Eye drift speed curve.** Slow enough early-game for the
  tutorial to land before the player gets lost; ramps up over the
  campaign so the home base eventually drifts out of the eye.
  Exact curve TBD.
- **Storm pulse cadence?** Soft turn counter so the player always
  knows how much budget remains, with rare unpredictable spikes.
- **Probe count cap per excursion** at MVP scale? Three feels
  right; grows to 9–12 by late game.
- **Lab disassembly time** — turns per blueprint. Slow enough that
  the lab being lost or buried between sessions matters. Exact
  value TBD.
- **Procedural generation, layered.** Map is fully procedural with
  hand-authored tutorial structures plopped near the player start
  so they have fuel etc. Generation layers: Ground → Structures →
  Structures from premade sets → Cities → Cities from premade
  sets. Structure generators may need brute-force or wave-function-
  collapse to ensure shapes close — implementation detail to
  decide later.
- **Crawler / rover speed.** Slow enough to feel deliberate, fast
  enough to not be tedious. Tunable.
- **Sand drift rate.** How fast the Perlin field shifts per turn.
  Tunable; affects how quickly buried structures change state.
- **Mine yield rate.** Fixed per turn, but the exact number per
  resource type wants playtest.
- **How does the ear-LM display its temporal graphs?** Needs
  prototyping.
- **Sound design.** Acoustic-ping per tile, modality chord per
  sensor, hypothesis-collapse glissando, vote-exchange crackle,
  beacon strength as a continuous tone, electric storm warble.
- **Save / load.** Atlas survives storms in fiction; needs to
  survive process exit in implementation.

---

## Development Methodology — Testbed First

The first build target is **not the MVP campaign** — it is three
in-engine test spaces that exist from day one and grow as
mechanics get implemented. The documentation *is* the testbed; no
mechanic counts as done until it shows up there.

### The three spaces

- **Gym** — player abilities and controls. Exact ranges of rover
  movement, hopper flight model, sensor inputs, beacon range
  curves, radio bandwidth degradation, sand-depth traversal. The
  feel of every player action gets pinned down in the gym before
  it lands in any campaign content.
- **Zoo** — structure and asset archetypes. Every Hab, Foundry,
  Lab archetype rendered at maximum legibility in one space.
  Sub-feature variants visible side by side. Sand-burial states
  shown on the same archetype at different depths. Doubles as the
  recognition test bench: point a column at the zoo and watch it
  identify everything.
- **Museum** — algorithmic phenomena. Static demonstrations of
  Monty behaviour — hypothesis funnels collapsing, lateral voting
  exchanges, cross-modal binding moments, temporal-axis pattern
  recognition, hierarchy cascade across tiers. Things normally
  seen as fleeting HUD events, paused and labelled. Also where
  speculative-tier visualisations live.

### Why this order

- **Visual verification.** Every behaviour is observable in a
  controlled space. No trusting prose summaries or diff reading.
- **Drift catching.** When a change breaks something, the
  relevant testbed entry shows it immediately.
- **No invisible mechanics.** A mechanic without a testbed entry
  isn't done. Forces internal state to be observable.
- **Working relationship.** Brilliant-fast collaborator means
  fast-moving codebase; the testbed keeps the human in the loop
  with a verifiable surface to look at after each change.

### Operating rule

**Every new mechanic gets a testbed entry the moment it is
implemented.** The MVP campaign is assembled downstream from a
testbed of working pieces, not parallel to it.

---

## Implementation Order

Testbed-first (see Development Methodology above). A working MVP
can ship behind step 5. Each implementation step lands a mechanic
*into the testbed*; the campaign is assembled later from pieces
already proven there.

0. **Testbed shells.** Three navigable in-engine spaces (gym,
   zoo, museum) accessible from a debug menu. Empty hex-grid
   floors with camera controls. Each subsequent step adds to one
   or more of them.
1. Dust-plain renderer (single eye region, no drift yet) with
   hex grid, sand-dominant terrain, and the 3 structure tile types.
2. WASD probe + one sensor. Press space to scan current tile.
3. Tier-1 LM on tile features (via real `tbp.monty`). Manual
   rotation selection (6 candidates per node, hex). Manual commit
   on space-bar.
4. Multi-probe lateral voting at tier 1. Pose-alignment automation
   unlocks. Probe motion auto-pathing unlocks. *MVP done.*
5. Tier-2 LM (hierarchical) on tier-1 outputs. First district
   recognition.
6. Eye drift (brownian, autonomous). New terrain enters the bubble
   as the eye moves.
7. Beacon model. Probe flight (radial + angular drift). Crawlers.
8. Storm system: calm/pulse/electric. Beacon outage drama.
9. Second sensor modality (thermal) recovered from a lost probe.
   Cross-modal binding manual interface.
10. Tier-3 LM for region archetypes. Atlas persistence across
    storm pulses.
11. Resource economy + depleted-depot annotation + prediction-
    driven scouting.
12. Construction drones + atlas drift mechanic.
13. Ear-LM with temporal-axis storm-pattern recognition. Ring-band
    rotation rates as learnable features.
14. Third and fourth sensor modalities (radiation, moisture).
    Auto-commit + auto-binding unlocks.
15. Sandbox endgame with ant-colony composition, optional
    consolidation, optional speculative tiers.
16. Polish: HUD with multi-tier hypothesis funnels, audio, storm
    transitions, mothership-AI narration character.

---

## What's Not Here Yet

- **Speculative reference-frame tiers** (state-transition,
  theory-of-mind) are placeholders pending a later design pass.
- **Turn-based vs realtime timing** — leaning turn-based but
  flagged open in the Premise; revisit.
