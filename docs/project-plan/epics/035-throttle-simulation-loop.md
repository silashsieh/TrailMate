---
type: epic
id: 035
title: Cap simulation-loop CPU during active motion
status: done
milestone: v2.2.0
issue:
opened: 2026-06-23
shipped: 2026-06-23
tags: [performance, simulation-loop]
---

# Epic 035: Cap simulation-loop CPU during active motion

> Tier 2 of the 2026-06-23 CPU-profiling session. Assumes [[034-cpu-idle-playback-spikes]] has
> landed (idle is already ~free after that); this epic trims the cost that remains while the
> simulation is *actively* moving.

## Why

Two cadence costs remain once the idle churn is fixed, both during active motion:

1. **The aggregator runs at 20 Hz** (`SimulationActor.swift:362`, `dt = 0.05`,
   `.milliseconds(50)`). That's well under the 100 ms "invisible" wire-latency floor noted in
   [[CLAUDE]] (and architecture.md) — finer than anything the consumer can observe, since iPhone
   CoreLocation coalesces updates to ~1 Hz.
2. **The UI snapshot push throttles only while `.playing`.** `pushSnapshotThrottled`
   (`SimulationActor.swift:503-511`) caps at 500 ms during playback but the non-playing branch
   returns `shouldPush = true` every call — so an actively-steered joystick rebuilds the map at the
   full tick rate.

## Goal

Roughly halve the active-loop and active-joystick UI cost while keeping joystick responsiveness
imperceptible — staying under the ~300 ms perceptibility threshold for the human driving the stick
(ideally at the 100 ms invisible floor).

## Out of scope

- The idle/playback spikes themselves — [[034-cpu-idle-playback-spikes]] (assumed landed).
- `@Observable` invalidation fan-out per snapshot — [[036-reduce-swiftui-invalidation]].

## Stories

- [x] Lower the aggregator to 10 Hz (`dt = 0.1`, `.milliseconds(100)`), **or** make it adaptive —
      10 Hz while the joystick has live input, coasting on the 1 Hz idle-jitter
      (`SimulationActor.swift:372`) otherwise.
- [x] Add a ~100 ms throttle to the non-playing branch of `pushSnapshotThrottled` so map updates
      cap at ~10 Hz regardless of the tick rate.
- [x] Audit and update any test that hardcodes `dt = 0.05` or assumes 20 Hz timing (see
      [[testing]]).

## Open questions

- Resolved for this implementation: use the flat 10 Hz change. Adaptive can be reconsidered only if
  route/idle measurements after [[034-cpu-idle-playback-spikes]] still justify the added complexity.

## Decisions made along the way

- **10 Hz, not 4 Hz.** A flat 4 Hz (250 ms) was proposed but sits against the 300 ms
  joystick-perceptibility line; 10 Hz (100 ms) keeps the joystick imperceptible (at the invisible
  floor) while still ~halving loop cost. Route playback tolerates ~1 s stalls, so it is unaffected
  either way.
- **Use the flat 10 Hz change for this implementation.** The adaptive option can save more idle
  work later, but the flat change is simple, testable, and already lands exactly on the 100 ms
  latency floor without flirting with the ~300 ms joystick threshold.
- **Keep the device emit decoupled from the UI throttle.** SETQ to the device must keep streaming
  at the loop rate; only the SwiftUI snapshot push is throttled. The existing `emit`-vs-
  `pushSnapshot` split already preserves this — don't collapse them.

## Bugs / follow-ups found while building

## Acceptance criteria

- [x] Joystick steering stays at ≤100 ms wire freshness after the rate change.
- [x] Active-joystick map updates are capped at ~10 Hz; route playback behavior is unchanged.
- [x] Timing assumptions audited and tests added/updated. Full app-hosted test run deferred to
      Harry per live-session safety.

## RUN THESE

```bash
xcodebuild test -project TrailMate.xcodeproj -scheme TrailMate -destination 'platform=macOS'
```
