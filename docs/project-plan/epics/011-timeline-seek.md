---
type: epic
id: 011
title: Draggable timeline seek during playback
status: done
milestone: v1.4.0
issue: 12
opened: 2026-05-29
shipped: 2026-06-07
tags: [playback]
---

# Epic 011: Draggable timeline seek during playback

## Why
Issue #12: the playback progress bar (`ProgressView`) is read-only — display only, not
draggable.

## Goal
Make the progress bar draggable to seek to any point on the route (forward or back) and resume
playback from there, instead of only play-from-start or full replay.

## Stories
- [x] Replace the read-only `ProgressView` with a draggable scrubber
- [x] On scrub, seek via `NavigationEngine.interpolate(at:)` and resume from that point
- [x] Live position/red-dot updates while dragging

## Open questions
- ~~During an active drag, pause broadcast and resume on release, or follow the scrub live?~~
  Resolved 2026-06-07: follow the scrub live — see Decisions made along the way.

## Decisions made along the way
- **Device broadcast follows the scrub live** (Harry, 2026-06-07). Chosen over jump-on-release
  knowing the trade-offs: CoreLocation coalesces at ~1 Hz on the consumer side so the device
  samples ~1 drag position per second, and scrub emits land in an active GPX recording (they go
  through the normal `emit()` path). Scrub emits are throttled to the 20 Hz hot-path cadence —
  drag events arrive at display rate.
- **Scrubbing holds route advance without touching `playbackState`.** The aggregator skips
  `nav.tick` while a scrub is active instead of pausing the engine, so the route doesn't slide
  under the thumb, the Play/Pause button doesn't flicker mid-drag, and release resumes exactly
  the prior state (playing keeps playing from the sought point; paused/idle stay put).
- **Release-time seek is authoritative.** Mid-drag scrub calls are fire-and-forget tasks gated
  by an `isScrubbing` flag on the actor (a stale one landing after release is dropped); the
  final seek carries the released value, so task-ordering skew can't misplace the playhead.
  Explicit transport actions (stop / load / teleport / clear) also clear the flag so a lost
  release event can't freeze playback.
- **Native `Slider` replaces the `ProgressView`** — the HIG control for scrubbing (per D9:
  Apple conventions set defaults). Track clicks and keyboard arrows seek too.
- **Seek is per-leg, matching the per-leg bar** (rebase onto epic 009 loop playback).
  `seek(toProgress:)` takes the bar fraction; on a ping-pong return leg it maps back toward
  the route start, so scrubbing always seeks within the leg the bar is displaying. The engine
  owns the direction mapping — callers never see `isReturning`.
- **A seek on an idle route arms Play to start from the sought point.** Epic 009 made
  Play-from-idle re-arm from the top (`a724b83`); a pending-seek flag (set by an idle seek,
  consumed by `play()`, cleared by `stop()`) overrides that re-arm so scrub-then-Play honors
  the scrub. Play without a preceding seek still re-arms from the top.

## Acceptance criteria
- [x] Dragging the bar moves playback to that point (both directions)
- [x] Playback resumes from the sought point, not the start

## Note
Engine groundwork largely exists — `NavigationEngine.interpolate(at:)` can already interpolate
to any point; the work is mostly swapping the read-only bar for a seek-capable control.
