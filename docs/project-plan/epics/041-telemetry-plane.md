---
type: epic
id: 041
title: Telemetry plane — frequency-partitioned simulation state
status: open
milestone: v2.2.0
issue:
opened: 2026-07-10
shipped:
tags: [performance, architecture, simulation]
---

# Epic 041: Telemetry plane — frequency-partitioned simulation state

> The data-flow substrate for [[037-mkmapview-idle-cpu]], split out as its own epic so the
> simulation-side work and the map-surface work can proceed in parallel (different agents,
> different files). Purely additive: the existing snapshot path keeps working until 037 swaps
> the map onto the new plane. From the 2026-07-10 idle-CPU investigation.

## Why

Today one channel carries everything: `SimulationActor` pushes a full `SimSnapshot` to the
`@Observable` `SimulationStateBridge`, mixing 10 Hz-class telemetry (coordinate, progress,
deviation, recording counter) with rare structural state (playback state, joystick/recording
flags). Two consequences:

- The 2 Hz playback throttle (`SimulationActor.swift`, `pushSnapshotThrottled`) exists only to
  keep SwiftUI from rebuilding map content per tick — a workaround that also caps dot
  smoothness at 2 Hz.
- Observation does not dedupe same-value writes, so every push re-invalidates every observing
  view even when nothing it reads has changed.

[[037-mkmapview-idle-cpu]]'s map surface needs a way to consume position updates **without
evaluating any SwiftUI body**. That path is this epic.

## Goal

`SimulationActor` publishes two planes: a latest-wins `AsyncStream<TelemetryFrame>` for
high-frequency values (consumed by non-SwiftUI code), and change-guarded, edge-triggered writes
to the existing bridge for structural state (consumed by SwiftUI). `DeviceSession` exposes a
`routeVersion` counter so consumers can diff route identity in O(1). User-visible behavior is
unchanged; the old snapshot path continues to feed the current SwiftUI `Map` until 037 lands.

## Out of scope

- Any UI change — the map swap and the 10 Hz cadence raise belong to [[037-mkmapview-idle-cpu]]
  (the cadence raise only makes sense once nothing rebuilds SwiftUI content per frame).
- The events plane (route-abort, tunnel-down) — already a separate lossless stream; unchanged.
- Backend/`LocationSink` narrowing and `SimulationKernel` extraction — v2.3.0 architecture work.

## Stories

- [x] Define `TelemetryFrame` (coordinate, leg progress, elapsed distance, route deviation,
      recording point count) as a `Sendable` value type in its own file.
- [x] `SimulationActor` yields a frame into a per-actor `AsyncStream<TelemetryFrame>`
      (`bufferingNewest(1)`) wherever it pushes snapshots today; expose the stream to
      `DeviceSession`.
- [x] Split the bridge write path: telemetry fields and structural fields applied separately,
      with per-field change guards so a same-value write never fires Observation.
- [x] Add `routeVersion: Int` to `DeviceSession`, bumped on every `routeCoordinates` assignment
      (`didSet`).
- [x] Unit tests: latest-wins stream semantics under a slow consumer; change-guarded bridge
      writes don't fire on same-value application; `routeVersion` bumps exactly on route
      change (load, clear, draw, wander, GPX import).
- [x] Update the Concurrency Topology / snapshot-push paragraphs in
      [[architecture]] in the same change.

## Open questions

- Does `recordingPointCount` belong in `TelemetryFrame` only (it changes at 10 Hz while
  recording), with the bridge's copy updated at a low rate for the sidebar? Default: yes —
  counter in the frame, bridge updated by the same throttle as today.

## Decisions made along the way

- **Frequency partition over a full-state stream.** A full-state latest-wins stream applied to
  the `@Observable` bridge at 10 Hz would re-invalidate observing views at 10 Hz (Observation
  does not dedupe same-value writes); hence the telemetry/structural split with change-guarded
  bridge writes. (Decision shared with [[037-mkmapview-idle-cpu]].)
- **Additive, dual-publish migration.** The old snapshot path stays until 037 consumes the new
  plane — this epic must be mergeable with zero visible change, so the two epics can be built
  by independent agents and integrated last.
- **Renewable subscription, not a stored stream (2026-07-10 branch-review correction).** A
  single stored `AsyncStream` dies permanently when its consumer task is cancelled — and
  sessions outlive the window (menu-bar background mode), so telemetry would freeze after the
  first window reopen. The actor exposes a factory (`telemetryStream()`) that finishes any
  prior subscription, returns a fresh stream, and seeds it with the latest frame. Also from
  the same review: playback telemetry must be yielded from the aggregator tick path, not
  inside the 5 Hz-guarded deviation check, or 10 Hz is unreachable regardless of throttle
  constants.
- **Single consumer per stream; fan-out lives at integration (2026-07-10 review correction).**
  `AsyncStream` is a queue, not a broadcast bus — multiple iterators *divide* frames between
  them. Each per-session telemetry stream therefore has exactly one documented consumer (the
  037 integration layer), which fans out internally to the dot and the camera. If a second
  independent subscriber ever appears, give each subscriber its own `bufferingNewest(1)`
  channel; never attach two iterators to one stream. Consumer tasks are stored and cancelled
  by session ID and map-surface lifetime.

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] App behavior and CPU profile are unchanged with this epic alone (it is substrate).
- [ ] `AsyncStream<TelemetryFrame>` is available per session, latest-wins, and covered by
      unit tests.
- [ ] Bridge writes are change-guarded (verified by tests, and no Observation fan-out on
      idle same-value pushes).
- [ ] `routeVersion` increments on every route mutation path and nowhere else.
