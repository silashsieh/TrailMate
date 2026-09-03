---
type: epic
id: 040
title: Isolate recording per session — fix shared-recorder mixed traces
status: open
milestone: v2.3.0
issue:
opened: 2026-07-10
shipped:
tags: [recording, multi-device, bug]
---

# Epic 040: Isolate recording per session — fix shared-recorder mixed traces

> Correctness defect found during the 2026-07-10 architecture review (code inspection; not yet
> reproduced at runtime with two devices). Completes a split that [[012-multi-device]] and the
> v2.0.0 design (`v2.0.0-design.md`, slice 1) explicitly specified — `RecorderService` →
> `RecordingCapture` (per-session) / `RecordingsLibrary` (app-wide) — but that was never
> implemented; the shipped code kept one shared recorder.

## Why

Recording is not isolated between sessions, so simultaneous multi-device recording corrupts
data:

- `AppState` owns **one** app-global `RecorderService` (`AppState.swift:178`).
- Every `DeviceSession` injects that same instance into its `SimulationActor`
  (`DeviceSession.swift:73`).
- Recording state is tracked twice and disagrees: each actor has its own `isRecordingActive`
  flag (`SimulationActor.swift:356`), while the shared recorder has a single `isRecording`
  flag and a single point buffer — and its `start()` silently no-ops when already recording
  (`RecorderService.swift:56`).
- Every recording-active actor appends into the same buffer (`SimulationActor.swift:496`).

Reachable failure with two sessions: A starts recording; B starts recording (B's actor flags
itself recording, the shared `start()` no-ops); both sessions' points interleave into one
buffer; whichever stops first persists the **mixed trace** as its GPX and flips the shared flag
off; the other actor still believes it is recording while `append()` silently discards its
points (`RecorderService.swift:65`) — its point counter keeps rising in the UI while nothing is
saved — and its eventual `stop()` returns nil.

Two single-session flaws ride on the same path (2026-07-10 review). `emit()` spawns one
unstructured `Task { @MainActor }` per recorded point (`SimulationActor.swift:499`) — 10
MainActor hops/second per recording session — and `RecorderService.append` stamps the point's
timestamp when that task finally *runs*, not when the actor emitted it, so MainActor pressure
can delay and bunch recorded timestamps. Unstructured tasks also carry an ordering risk: a
late in-flight append can interleave out of order, or land after a quick stop→start and be
attributed to the *next* recording.

## Goal

Each session records independently: two devices recording simultaneously produce two clean,
separate GPX files with no dropped or interleaved points, and each session's point counter
reflects what will actually be saved. Recording capture costs no per-point MainActor hop. Recording
state remains part of the selected session's control surface: switching away does not stop that
session's capture, but deliberately hides its recording state until the user switches back.

## Out of scope

- The map/CPU work — that is [[037-mkmapview-idle-cpu]].
- Any change to the recordings *library* UX (list, replay, export, delete) beyond it reading
  from the new persistence seam.
- A global or per-device-row indicator for recordings running in non-selected sessions. Recording
  status remains selected-session-only by design.
- Hoisting `GCController` observers to a ControllerHub (also specified in the v2.0.0 design's
  slice 1; still deferred — file separately if profiling ever justifies it).

## Stories

- [ ] Extract `RecordingCapture`: a per-session, actor-owned buffer with `start()`, synchronous
      `append(_:)`, `stop()`, and `discard()`. `start()` captures a wall-clock `Date` anchor and a
      `ContinuousClock.Instant`; each append stamps the point at emission as
      `wallStart + (continuousNow - continuousStart)`. The hot path performs no MainActor task and
      never samples wall time again. `stop()` returns an immutable `Sendable` draft (id, startedAt,
      points); `discard()` clears the active draft without returning anything.
- [ ] Replace `RecorderService` with the app-wide `RecordingsLibrary`: GPX persistence, index loading,
      delete — no live capture state. Give it an injected base directory, defaulting to TrailMate's
      production Application Support recordings directory, so tests can use a temporary directory
      without touching the user's recordings.
- [ ] `SimulationActor` owns its `RecordingCapture`; the actor-side `isRecordingActive` /
      `pendingPointCount` become derived from the capture (single source of truth per session).
- [ ] An explicit Stop hands the draft to `RecordingsLibrary` for persistence; snapshot fields
      (`recordingPointCount`, `isRecording`) continue flowing to the bridge unchanged. App quit and
      session removal call `discard()` instead: an in-progress capture is not implicitly saved and
      no new GPX/index entry is created.
- [ ] Keep recording UI selected-session-only. Switching from A to B leaves A's capture running but
      shows only B's recording flag/count and Record button state; switching back to A reveals A's
      still-active capture and current count. Do not add a recording badge to the device switcher or
      an app-global "recording elsewhere" indicator.
- [ ] Unit tests: two actors recording concurrently produce two disjoint drafts; stop order
      doesn't matter; points appended after one session stops still land in the other's draft;
      counter matches persisted points; timestamps advance from injected `ContinuousClock` instants;
      switching the selected session does not stop either capture; shutdown discards active drafts;
      persisted drafts round-trip through a temporary `RecordingsLibrary` directory.

## Open questions

- None for the capture/library split. The timestamp, persistence, shutdown, and visibility policies
  are settled below; implementation findings still go under Bugs / follow-ups.

## Decisions made along the way

- Capture lives on the actor, not MainActor: appends happen at emit-time on the hot path, and
  the draft crosses to MainActor once, at stop — removing the per-point `Task { @MainActor }`.
- **Derive timestamps from `ContinuousClock` (2026-09-03, owner's call).** Capture one wall-clock
  `Date` and one monotonic instant at Start, then timestamp every point as wall start plus monotonic
  elapsed time. This keeps GPX timestamps human-meaningful, preserves emission order even if the
  system clock jumps, and is deterministic under an injected clock in tests.
- **Use an app-wide `RecordingsLibrary` with an injectable base directory (2026-09-03, owner's
  call).** The library owns only persisted recordings and their index; it has no active-recording
  flag or point buffer. Production uses Application Support, while tests use a temporary directory
  and can prove persist → reload without touching personal data.
- **Discard in-progress captures on shutdown (2026-09-03, owner's call).** Only an explicit Stop
  saves a recording. App quit discards every active per-session capture rather than manufacturing
  recordings the user did not choose to finish; removing a session follows the same destructive
  lifecycle because its actor-owned capture ceases to exist.
- **Recording visibility follows selection (2026-09-03, owner's call).** Switching sessions does
  not stop the prior session's recording, but its recording state becomes invisible until that
  session is selected again. No device-row badge or global background-recording warning is added.

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] Two sessions recording simultaneously yield two separate GPX files, each containing only
      its own session's points.
- [ ] Stopping either session does not stop, corrupt, or silently disable the other's
      recording; the still-recording session's counter and eventual file agree.
- [ ] Single-session recording behavior (files, index, replay, export) is unchanged.
- [ ] No per-point MainActor task during recording; point timestamps are stamped at emission
      from `ContinuousClock` elapsed time (monotonic and nondecreasing within a recording, immune to
      MainActor pressure and wall-clock adjustments).
- [ ] Explicit Stop is the only path that persists an active draft. Quitting the app or removing a
      session while it records discards that draft and creates no GPX/index entry.
- [ ] Switching away from a recording session leaves its capture active but hides its status and
      count; switching back reveals the same active capture and its accumulated count.
- [ ] `RecordingsLibrary` persistence tests use an injected temporary base directory and prove
      persist → reload without reading or writing the production Application Support directory.
- [ ] New unit tests cover the two-session, clock, selection, discard, and persistence scenarios
      above.
