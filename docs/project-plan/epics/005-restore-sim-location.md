---
type: epic
id: 005
title: Restore last simulated location on launch
status: open
milestone: v1.3.0
issue: 13
opened: 2026-05-29
shipped:
tags: [positioning]
---

# Epic 005: Restore last simulated location on launch

## Why
Issue #13: the app has two kinds of "position", handled separately. The **map camera** (where
you're looking) already persists across launches (`MapCameraPersistence`, defaults to Taipei).
The **simulated position** (the red dot `simulatedCoordinate`) does **not** — it starts `nil`
every launch, so you must long-press teleport before there's a red dot at all. The screen has
memory; the position doesn't. Google Maps' principle: never start the user at a blank position.

## Goal
On launch, the simulated position is restored in priority order:
1. **Last simulated position** before quit (mirror the camera-persistence mechanism for
   `simulatedCoordinate`) — the primary, available-today path.
2. Fall back to a **default landmark (Taipei)**.

A restored position is a display default only; it is broadcast to the iPhone only **after**
connect (no self-spoofing while disconnected).

## Out of scope
- Defaulting to the device's **real** location — that extension died with
  [[004-read-device-real-gps]] (#17 closed as not planned). Launch default uses only the
  remembered simulated position.

## Stories
- [ ] Persist `simulatedCoordinate` on change/quit (parallel to `MapCameraPersistence`)
- [ ] Restore on launch with the Taipei fallback
- [ ] Restored position broadcasts only after connect
- [ ] Sidebar route planner From field gains a "Use current location" button (one-tap fill)

## Open questions
- Confirm exactly what `MapCameraPersistence` already covers so this only adds the missing
  simulated-coordinate persistence and doesn't duplicate work.

## Decisions made along the way

## Acceptance criteria
- [ ] Quit with a red dot at X → relaunch → red dot is at X (not blank)
- [ ] Fresh install with no saved position → defaults to Taipei
- [ ] Disconnected restore does not broadcast to the device until Connect

## Related
- [[004-read-device-real-gps]] — dropped; the real-location default went with it
- Sibling concept: [[006-follow-current-position]] (both are "current position" UX)
