---
type: epic
id: 009
title: Route loop playback
status: in-progress
milestone: v1.4.0
issue: 10
opened: 2026-05-29
shipped:
tags: [playback]
---

# Epic 009: Route loop playback

## Why
Issue #10: route playback (`NavigationEngine`) stops after one pass — no looping.

## Goal
Auto-loop on completion, with two selectable modes:
1. **Restart** — A→B finishes, replay A→B.
2. **Ping-pong** — A→B finishes, walk back B→A, repeat.

Optionally a loop count (including infinite).

## Stories
- [x] Loop-mode setting (restart / ping-pong) in the playback controls
- [x] `NavigationEngine` re-arms on completion per the selected mode
- [x] Optional loop count (incl. infinite); stop ends cleanly

## Open questions
*(all resolved — see decisions below)*

## Decisions made along the way
- **Ping-pong walks back the existing polyline, not a re-derived B→A route** (2026-06-07,
  user decision). 原路返回 literally asks for the original path; MKDirections could pick a
  different street (one-way roads in Drive mode) and costs an async call per turnaround.
  Implemented as a direction flag in `NavigationEngine` — no array mutation, so off-route
  detection and Rejoin keep working unchanged.
- **Loop count unit: restart = one A→B pass; ping-pong = one A→B→A round trip** (2026-06-07,
  user decision). Matches the issue's 來回循環 framing and always ends ping-pong back at A.
- **Clamp-and-flip at leg boundaries, no remainder carry-over.** The leg's final tick scales
  velocity to land the integrator on the endpoint, then the *next* tick moves in the new
  direction. The lost sub-tick remainder is ≤ one 50 ms tick — far below the CLAUDE.md
  latency floor — and one-boundary-per-tick keeps sub-tick-length routes at 100× trivially
  correct (no multi-wrap accounting). Restart's wrap is a deliberate teleport: the tick
  returns a `jump` coordinate and zero velocity, and `SimulationActor` resets the integrator.
- **Progress / elapsed are per-leg** (each pass and each ping-pong leg runs the bar 0→1), so
  the remaining-time label and map hint need no direction awareness. A "Loop k of N" caption
  under the progress bar carries the iteration instead.
- **Loop config is engine-wide and survives `stop()`/`loadRoute()`** — deliberately: it also
  loops direct travel, "Route here", wander, and recording replays, and swapping routes
  doesn't silently drop the setting. Only runtime state (direction, completed count) resets.
  Config lives in `AppState` (`didSet` push, like `noiseSigmaMeters`); the snapshot carries
  read-only `completedLoops` for display — no config round-trip through the bridge.
- **Session-scoped, not persisted** — mirrors `speedMultiplier`, the closest analogous
  playback control. Can move into [[017-settings-window]] later if wanted.
- Unit tests live in `TrailMateTests/NavigationEngineLoopTests.swift`. `xcodebuild test`
  launches the TrailMate.app test host (TEST_HOST), so the suite was additionally mirrored
  through a standalone `swiftc` harness during development to verify headlessly while a live
  TrailMate session was running; all checks passed.

## Bugs / follow-ups found while building
- **Play on a finished route was a no-op** (pre-existing): a completed pass left
  `currentDistanceAlongRoute` at `totalDistance` and nothing reset it, so Play re-idled
  instantly — and Stop is disabled while idle, leaving no way out. Fixed here as part of
  "re-arms on completion", in two halves: the engine's `play()` from idle resets
  distance/direction/loop counters, and `SimulationActor.play()` from idle resets the
  `PositionIntegrator` to the route start (it used to seed only a nil position, so after a
  completed pass the marker stayed parked at the far end and would have traced a
  route-shaped ghost path offset from the polyline). The actor seam is pinned by
  `SimulationActorReplayTests` with a recording mock backend — the engine-only tests
  can't see the integrator.

## Acceptance criteria
- [ ] Restart mode replays from A indefinitely (or N times) until Stop
- [ ] Ping-pong reverses smoothly at each end with no jump
- [ ] Loop count honored; Stop always clears
