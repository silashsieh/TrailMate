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
reflects what will actually be saved. Recording capture costs no per-point MainActor hop.

## Out of scope

- The map/CPU work — that is [[037-mkmapview-idle-cpu]].
- Any change to the recordings *library* UX (list, replay, export, delete) beyond it reading
  from the new persistence seam.
- Hoisting `GCController` observers to a ControllerHub (also specified in the v2.0.0 design's
  slice 1; still deferred — file separately if profiling ever justifies it).

## Stories

- [ ] Extract `RecordingCapture`: a per-session, actor-owned buffer — `start()`, synchronous
      `append(_:)` on the actor's hot path (no MainActor `Task` per point; **timestamp stamped
      at emission** via an injected wall clock), and `stop()` returning an immutable
      `Sendable` draft (id, startedAt, points).
- [ ] Reshape `RecorderService` into the app-wide `RecordingsLibrary`: persistence (GPX write),
      index loading, delete — no live capture state.
- [ ] `SimulationActor` owns its `RecordingCapture`; the actor-side `isRecordingActive` /
      `pendingPointCount` become derived from the capture (single source of truth per session).
- [ ] `stopRecording()` hands the draft to `RecordingsLibrary` for persistence; snapshot fields
      (`recordingPointCount`, `isRecording`) continue flowing to the bridge unchanged.
- [ ] Unit tests: two actors recording concurrently produce two disjoint drafts; stop order
      doesn't matter; points appended after one session stops still land in the other's draft;
      counter matches persisted points.

## Open questions

- Should the Record button UI expose per-session recording indicators when multiple sessions
  record at once (map dots already color-code sessions), or is the sidebar state enough?

## Decisions made along the way

- Capture lives on the actor, not MainActor: appends happen at emit-time on the hot path, and
  the draft crosses to MainActor once, at stop — removing the per-point `Task { @MainActor }`.

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] Two sessions recording simultaneously yield two separate GPX files, each containing only
      its own session's points.
- [ ] Stopping either session does not stop, corrupt, or silently disable the other's
      recording; the still-recording session's counter and eventual file agree.
- [ ] Single-session recording behavior (files, index, replay, export) is unchanged.
- [ ] No per-point MainActor task during recording; point timestamps are stamped at emission
      (monotonic within a recording, immune to MainActor pressure).
- [ ] New unit tests cover the two-session scenarios above.
