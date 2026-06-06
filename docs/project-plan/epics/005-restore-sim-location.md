---
type: epic
id: 005
title: Restore last simulated location on launch
status: done
milestone: v1.3.0
issue: 13
opened: 2026-05-29
shipped: 2026-06-06
tags: [positioning]
---

# Epic 005: Restore last simulated location on launch

## Why
Issue #13: the app has two kinds of "position", handled separately. The **map camera** (where
you're looking) already persists across launches (`MapCameraPersistence`, defaults to Taipei).
The **simulated position** (the red dot `simulatedCoordinate`) does **not** — it starts `nil`
every launch, so you must long-press teleport before there's a red dot at all. The screen has
memory; the position doesn't. The maps-app convention applies: never start the user at a blank
position **by default** (per [[decisions]] D9 as amended: conventions set defaults; an
explicit user preference may opt out).

## Goal
The last simulated position is **always saved** (mirror the camera-persistence mechanism for
`simulatedCoordinate`). Launch behavior is governed by a user preference —
**Restore last simulated location**, default **on**:

- **On (default):** restore in priority order —
  1. **Last simulated position** before quit — the primary, available-today path.
  2. Fall back to a **default landmark (Taipei)**.
- **Off:** start with no simulated position until the user teleports (the pre-005 behavior);
  the saved position is ignored at launch but still recorded.

A restored position is a display default only; it is broadcast to the iPhone only **after**
connect (no self-spoofing while disconnected).

## Out of scope
- Defaulting to the device's **real** location — that extension died with
  [[004-read-device-real-gps]] (#17 closed as not planned). Launch default uses only the
  remembered simulated position.

## Stories
- [x] Persist `simulatedCoordinate` on change/quit (parallel to `MapCameraPersistence`)
- [x] Restore on launch with the Taipei fallback
- [x] Preference toggle **Restore last simulated location** (default on; off = start with no
      simulated position)
- [x] Restored position broadcasts only after connect
- [x] Sidebar route planner From field gains a "Use current location" button (one-tap fill;
      disabled while no simulated position exists, e.g. toggle off before the first teleport)

## Open questions
*(all resolved — see decisions below)*

## Decisions made along the way
- **Restore is opt-out, not unconditional** (2026-06-06): the position is always saved, but a
  preference (default on) chooses between auto-restore and starting with no simulated
  position. Required amending [[decisions]] D9 — conventions set defaults; explicit user
  preferences may opt out.
- **Toggle lives in the sidebar Connection section** (2026-06-06, user decision), next to the
  GPS-noise slider it already hosts. Keeps [[017-settings-window]] fully intact for v1.4.0;
  017 may absorb the toggle once the Settings window exists.
- **`MapCameraPersistence` covers the camera only** (center + span; private to ContentView).
  The new `SimulatedPositionPersistence` mirrors its UserDefaults shape for the red dot and
  shares the same Taipei landmark as the fresh-install fallback.
- **Persistence write path:** `SimulationStateBridge.apply()` saves with a 1 s throttle
  (joystick-only snapshots arrive at 20 Hz — too hot for UserDefaults), plus an unconditional
  save in `applicationShouldTerminate` so quit captures the exact final position. Saving is
  toggle-independent by design; only the launch restore is gated.
- **"Broadcast only after connect" falls out of the architecture:** the launch restore seeds
  the actor while no backend is attached, so `emit()` is display-only; `attach()` re-emits
  `lastEmittedCoordinate` once on connect (it can only be non-nil there via the restore,
  since `detach()` clears it), which also anchors the joystick at the restored spot.
- **From-field fill uses formatted coordinates**, not a "Current Location" label, so the
  field stays truthful if the red dot moves on after the tap.

## Acceptance criteria
- [x] Quit with a red dot at X → relaunch (toggle on) → red dot is at X (not blank)
- [x] Fresh install with no saved position (toggle on) → defaults to Taipei
- [x] Toggle off → launch has no simulated position until the user teleports
- [x] Disconnected restore does not broadcast to the device until Connect

## Related
- [[004-read-device-real-gps]] — dropped; the real-location default went with it
- Sibling concept: [[006-follow-current-position]] (both are "current position" UX)
