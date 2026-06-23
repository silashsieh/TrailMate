---
type: epic
id: 034
title: Eliminate idle and route-playback CPU spikes
status: open
milestone: v2.2.0
issue:
opened: 2026-06-23
shipped:
tags: [performance, joystick, playback]
---

# Epic 034: Eliminate idle and route-playback CPU spikes

> Tier 1 of a CPU-profiling session (2026-06-23). Fixes the two states that actually burn CPU:
> disconnected-idle no-op churn, and the route-deviation allocation hotspot. The cadence/throttle
> work is split into [[035-throttle-simulation-loop]] and the SwiftUI fan-out into
> [[036-reduce-swiftui-invalidation]].

## Why

Two near-idle states burn CPU:

1. **Disconnected + idle with a restored red dot → 20 Hz no-op churn.** The selected session's
   joystick is armed from launch (`AppState.syncActiveJoystick`, called in `init`), independent of
   whether a device or controller is connected. `JoystickEngine.tick()` returns a dead-zone `(0,0)`
   rather than `nil` (`JoystickEngine.swift:89`), and the aggregator treats *any* non-nil joystick
   result as activity (`SimulationActor.swift:407`). So every 50 ms tick runs `emit` plus an
   *unthrottled* snapshot push even though nothing moves — rebuilding the `@Observable`
   `SimulationStateBridge`, MapArea, and sidebar at 20 Hz. The "restored red dot" precondition is
   load-bearing: it seeds the integrator via `teleport` (`AppState.swift:281`, see
   [[005-restore-sim-location]]); without a seeded position, line 423's `guard let pos` would
   short-circuit. This is the offline-preview path from [[028-map-while-disconnected]].

2. **Route playback → per-segment `CLLocation` allocation hotspot.** The off-route deviation check
   (`NavigationEngine.distanceFromRoute`, `:253`) runs ~5 Hz during playback (throttled in
   `maybeCheckDeviation`, `SimulationActor.swift:440`), scans *every* segment (`:258`), and
   `distanceFromSegment` allocates two `CLLocation` objects per segment per call (`:299-300`) — the
   `distanceFromRoute / distanceFromSegment / CLLocation.init` profile seen in Instruments.

## Goal

Idle/disconnected TrailMate uses ~no CPU, and route playback's deviation check stops being an
allocation hotspot — with no change to joystick, route, or offline-preview behavior.

## Out of scope

- Lowering the aggregator tick rate or throttling active-motion UI pushes — [[035-throttle-simulation-loop]].
- `@Observable` invalidation fan-out when a snapshot is applied — [[036-reduce-swiftui-invalidation]].
- Changing the "armed = selected session" model.

## Stories

- [ ] `JoystickEngine.tick()` returns `nil` when there is no controller and no input above the dead
      zone (`JoystickEngine.swift:89`, `return (0, 0)` → `return nil`), so an idle armed joystick
      contributes no activity.
- [ ] Confirm the aggregator's `anyContribution` guard (`SimulationActor.swift:412`) then
      short-circuits disconnected-idle — no `emit`, no `pushSnapshot`.
- [ ] Precompute a planar `(x, y)`-in-meters projection of each route vertex once in
      `NavigationEngine.loadRoute` (`:48`).
- [ ] Rewrite `distanceFromSegment` (`:298`) to use that projection with pure `Double` math — zero
      `CLLocation` allocations per check.
- [ ] (Optional) Restrict the deviation scan to segments near the current playhead
      (`segmentIndex`) instead of the full route.
- [ ] Unit tests: dead-zone returns `nil`; deviation distance matches the current implementation
      within tolerance on a known route.

## Open questions

- Does anything rely on `tick()` returning `(0,0)` rather than `nil`? (Analysis: no — only the
  `anyContribution` flag differs, and route playback drives it via `nav.tick`.)
- Windowed deviation scan — safe given a teleport can land far off-route? Keep the full scan if
  uncertain; the allocation removal is the main win regardless.

## Decisions made along the way

- **Gate on real input, not on map focus.** A focus-based arm/disarm was considered and rejected:
  it only shrinks the bug window (the map is normally focused during use) and breaks the hardware
  gamepad path, whose GameController input is global, not focus-scoped.
- **Fix at the engine (`tick → nil`), not only at the aggregator.** Equivalent to a "don't emit
  when summed velocity is zero" guard but simpler and at the right layer; summing `(0,0)` vs
  nothing is identical for the integrator.

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] Disconnected + idle + restored red dot: the aggregator does no per-tick `emit`/`pushSnapshot`;
      CPU sits at/near idle.
- [ ] Joystick (gamepad and keyboard) still drives the red dot and the device exactly as before.
- [ ] During playback, `distanceFromSegment` performs no `CLLocation` allocation; the off-route
      indicator and the deviation-abort behavior are unchanged.
