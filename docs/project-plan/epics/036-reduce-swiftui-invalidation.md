---
type: epic
id: 036
title: Reduce SwiftUI invalidation fan-out from snapshot pushes
status: open
milestone: v2.2.0
issue:
opened: 2026-06-23
shipped:
tags: [performance, ui, swiftui]
---

# Epic 036: Reduce SwiftUI invalidation fan-out from snapshot pushes

> Tier 3 (optional polish) of the 2026-06-23 CPU-profiling session. **Gated on measurement**: do
> this only if Instruments still shows meaningful SwiftUI cost after
> [[034-cpu-idle-playback-spikes]] and [[035-throttle-simulation-loop]] land.

## Why

Each snapshot application re-assigns all 11 `@Observable` properties of `SimulationStateBridge`
unconditionally (`SimulationActor.swift:580-593`), and the Observation framework fires on *every*
assignment regardless of value equality. So views observing low-frequency fields (e.g.
`navigationProgress`) are invalidated even during joystick-only motion where those values never
change. Separately, recording hops a `Task { @MainActor in recorder.append(clean) }` per emit
(`SimulationActor.swift:479`) — one MainActor task per tick while recording.

## Goal

Shrink the per-snapshot SwiftUI invalidation fan-out so a high-frequency coordinate update does not
rebuild views that depend only on route / progress / recording state.

## Out of scope

- The cadence and idle fixes — [[034-cpu-idle-playback-spikes]], [[035-throttle-simulation-loop]].
- A full re-architecture of the bridge beyond field-level isolation.

## Stories

- [ ] Change-guard each assignment in `SimulationStateBridge.apply` (`:580-593`) — write only when
      the value differs. Needs a manual lat/lon compare (`CLLocationCoordinate2D` isn't `Equatable`).
- [ ] (Heavier alternative, if change-guarding isn't enough) Split the bridge so the
      high-frequency `simulatedCoordinate` lives in its own observation scope, separate from the
      route / progress / recording fields.
- [ ] (Minor) Coalesce or batch the recorder append hop instead of one MainActor `Task` per emit.

## Open questions

- Is change-guarding sufficient, or is a bridge split warranted? Measure first.
- Note: the original analysis's "don't emit when velocity is zero" idea is redundant once
  [[034-cpu-idle-playback-spikes]] lands — not tracked here.

## Decisions made along the way

<!-- Gated on measurement; choose change-guard vs bridge split from the profile. -->

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] A coordinate-only snapshot does not invalidate views that depend solely on route / progress /
      recording state.
- [ ] No behavior change to the map marker, route, progress, or recording UI.
- [ ] The change-guard-vs-split decision is recorded with the profile that justified it.
