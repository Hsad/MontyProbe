# V4 Caveman

Compact load-bearing summary of `v4-mothership-spec.md` + `v4-UI-spec.md`.
Use as agent quick-loader. For "why" and edge cases, read full specs.

## Premise
- Storm planet. Eye = safe zone. Mothership floats in eye, station-keeps.
- Player in hopper. Drives rovers. Real tbp.monty backend (Python IPC).
- No crew. Lights on, nobody home.

## World
- Hex grid. 6-fold rotation hypotheses.
- 3 wall tiles: wall, outside corner, inside corner.
- Composition: T0 building → T1 cluster → T2 district → T3 city.
- Sand burial: 32-step height, low-octave Perlin, drifts.
- Eye drifts. Storms eat structures. Buried ruins beneath.

## Loop
- Sense → CMP → vote → recognise → atlas.
- Raid T0 → resources → unlock sensors/columns → build T1.

## Sensors (unlock order)
- L1 bump · L2 color · L3 depth · L4 geo-probe · L5 sonar · L6 ear · L7 open.

## Columns
- Physical, bioreactor-grown. Attach to: sensor, column, decision stream.
- Heterogeneous atlas accumulation (same column, parallel graphs per modality).

## Nav
- Beacon (short-range, killable) → Flight (hopper) → Crawl (rover).
- A*: curiosity-driven, predictive (uses hypothesis state), Voronoi multi-rover.

## UI
- Player always in hopper. Hopper = physical UI.
- 5 screens: World · Atlas/Holo · Live Inference · Cortex/Patch · Cargo.
- Front window + center holo-deck + side patch bays.
- L-click focus, R-click back, WASD slide between screens.
- Spatial bug-tag any element.

## Dev (testbed-first)
- Phase 0 = Gym + Zoo + Museum shells, before game content.
- One connected dev space, hopper as hub.
- Gym = abilities. Zoo = archetypes. Museum = algorithm.
