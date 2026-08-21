---
type: epic
id: 030
title: Area serpentine coverage routing
status: in-progress
milestone: v2.2.0
issue: 47
opened: 2026-06-19
shipped:
tags: [routing, map]
---

# Epic 030: Area serpentine coverage routing

> Feature (#47): pick a point on the map and auto-generate a dense, non-repeating path that
> covers the area around it (a serpentine / boustrophedon "mow the lawn" route). Builds on
> [[007-hand-drawn-routes]] and the existing routing/playback pipeline.

## Why

For coverage-style testing (walk every street / cover a region) the user wants to pick an area
and get a route that sweeps it, rather than hand-placing waypoints.

## Goal

Select an area on the map; the app generates a serpentine coverage path within it at a
configurable lane spacing, loadable like any other route (play, record, export).

## Out of scope

- Optimal-coverage / TSP solving — a simple boustrophedon sweep at a chosen lane spacing is
  enough; no routing-engine rewrite.
- Road-aware coverage (follow actual streets) — possible later; v1 is geometric.
- Polygon or free-box area selection, and a separate area-selection window — the area is the
  square implied by the existing Wander center and radius.

## Stories

- [x] Area selection on the map — the **Wander nearby…** point and radius define a north-up
      square of side `2 × radius`, with a **Random / Sweeping** mode picker in the same sheet.
- [x] Generate a serpentine path at a configurable lane spacing (metres, default 70 m,
      persisted); keep every point inside the square.
- [x] Hand the path to the routing/playback pipeline (play, record, save, export).
- [x] Show the derived distance and time before Start, instead of asking for a duration.

## Open questions

- ~~Geometric sweep vs road-snapped~~ — **geometric.** MapKit has no area-coverage primitive,
  and road-aware coverage is a graph-traversal problem over data MapKit doesn't expose. See
  [[decisions]] D12.
- ~~Lane-spacing default and units~~ — **metres, default 70 m**, validated finite and positive,
  persisted like the other Wander presets.

## Decisions made along the way

- **Sweeping lives in the existing Wander sheet as a peer of Random**, selected by a segmented
  picker, sharing the center and the radius control. No second window, no map-drawing workflow.
  Random keeps its `MKDirections` behavior untouched.
- **The radius is the centre-to-edge half-side**, so the side is exactly `2 × radius`; the sheet
  states the resulting side and lane count so that reading isn't left to inference.
- **Fixed orientation**: lanes run east-west, step south to north, and start at the west end of
  the southernmost lane, with the lane set centred between the south and north edges. Identical
  inputs give identical coordinates; a square narrower than one spacing degenerates to a single
  edge-to-edge pass. Rationale in [[decisions]] D12.
- **Two coordinates per lane, no intermediate vertices** — `NavigationEngine` advances by arc
  length, so density buys nothing for playback or the drawn polyline, and the reported length
  stays exact.
- **No duration control when sweeping.** The geometry fixes the length; the sheet builds the real
  route on each change (pure arithmetic, bounded by a 4 000-point cap) and shows
  `length ÷ effectiveBaseSpeedMPS`. Start only enables once that build succeeds.
- **The centre→first-edge-point jump is outside the route.** `sim.loadRoute(resetStart: true)`
  already teleports to `coordinates.first`, so no new mechanism was needed, and the jump counts
  as neither distance nor time.
- **New pure helper `CoverageRouteBuilder`**, alongside `StrokeGeometry` / `RouteMath` /
  `MapRegionMath`, rather than geometry in `ContentView` or changes to `WanderRouteBuilder`.
  Its nested value types are `nonisolated` so the geometry is usable (and testable) off the main
  actor. `RouteMath.totalLengthMeters` was added as the shared polyline-length helper.
- **`DeviceSession.sweepArea` mirrors `travelDirectly`, not the routed paths**: no
  `isCalculatingRoute` spinner (generation is synchronous) and no router. `AppState` forwards it
  from the per-device block, so selected-session routing is correct under multi-device by
  construction.

## Bugs / follow-ups found while building

- **`Localizable.xcstrings` is missing ~22 pre-existing UI strings** (the Menu Bar and AI Control
  settings sections, several status captions like "Idle" / "Paused" / "Recording"), so they render
  English regardless of language; `xcstringstool sync` surfaces them, and "Connection" is now
  stale. Left untouched here to keep this epic's diff scoped — worth its own docs/localization
  epic.
- **`SaveCurrentRouteButton` tags every route `source: "calculated"`** (`ContentView`), so a saved
  sweep, wander, or drawn route is mislabelled and carries no planner waypoints. Pre-existing;
  a `"sweep"` / `"drawn"` source would be a non-breaking fix.
- **No `SWEEP` AI command verb.** Sweeping is GUI-only; adding it means `CommandProtocol`, the
  architecture doc, and the (still deferred) `trailmate` CLI move together.
- **Six inline polyline-length loops remain** (`DeviceSession.loadDrawnRoute`,
  `StrokeGeometry.resampleUniform`, `WanderRouteBuilder.trimTail`, …) that could now adopt
  `RouteMath.totalLengthMeters`.
- **`CLLocation.distance(from:)` is not bit-reproducible across calls.** Two builds from identical
  inputs produced identical coordinates but lengths of 11217.7617 m and 11217.6318 m (~1e-5
  relative) — found because the first determinism test asserted exact equality on the measured
  total. The geometry is deterministic; the metre total derived from it is only stable to
  CoreLocation's own wobble, so the tests use tolerances and `features.md` claims determinism of
  the *coordinates*. Invisible in the UI (0.1 km display precision) and pre-existing wherever the
  app sums `CLLocation.distance` — `NavigationEngine.totalDistance` included.

## Acceptance criteria

- [ ] Selecting an area produces a non-repeating coverage path that visibly sweeps it.
- [ ] The path plays back and exports like a normal route.

> Both ACs need the on-device smoke check (see the epic 030 item in [[testing]]) and get ticked
> in a follow-up commit with the verification date, as in [[006-follow-current-position]]. The
> geometry's unit coverage is green (`CoverageRouteBuilderTests`) and the mode-swap UI test
> passes, but neither can see the marker sweep a real device.
