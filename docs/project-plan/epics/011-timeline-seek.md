---
type: epic
id: 011
title: Draggable timeline seek during playback
status: open
milestone: v1.5.0
issue: 12
opened: 2026-05-29
shipped:
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
- [ ] Replace the read-only `ProgressView` with a draggable scrubber
- [ ] On scrub, seek via `NavigationEngine.interpolate(at:)` and resume from that point
- [ ] Live position/red-dot updates while dragging

## Open questions
- During an active drag, pause broadcast and resume on release, or follow the scrub live?

## Acceptance criteria
- [ ] Dragging the bar moves playback to that point (both directions)
- [ ] Playback resumes from the sought point, not the start

## Note
Engine groundwork largely exists — `NavigationEngine.interpolate(at:)` can already interpolate
to any point; the work is mostly swapping the read-only bar for a seek-capable control.
