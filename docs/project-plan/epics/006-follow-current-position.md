---
type: epic
id: 006
title: Follow / center current position
status: open
milestone: v1.3.0
issue: 14
opened: 2026-05-29
shipped:
tags: [positioning]
---

# Epic 006: Follow / center current position

## Why
Issue #14: the map camera is user-dragged (and remembered), and the existing "Recenter" button
only serves the joystick (jumps to its start). During route playback or joystick movement the
red dot often drifts off-screen.

## Goal
A toggleable **follow** mode: tap to recenter on and follow the **current simulated position
(red dot)**; dragging the map auto-disengages follow. Model it on MapKit's native
user-tracking / Apple Maps' locate-button semantics ([[decisions]] D9 — Apple conventions are
the design baseline).

## Out of scope
- Following the **real** location (blue dot) — that extension died with
  [[004-read-device-real-gps]] (#17 closed as not planned). This epic is red-dot follow only.

## Stories
- [ ] Follow-mode toggle that recenters and tracks `simulatedCoordinate`
- [ ] Auto-disengage on manual map drag
- [ ] Reconcile with the existing joystick "Recenter" button (share one control if natural)

## Open questions
- Should follow and the joystick Recenter become a single shared locate control, or stay
  distinct? #13/#14/#17 all touch a common "current position" control — consider one component.

## Acceptance criteria
- [ ] Follow on → red dot stays centered through playback and joystick movement
- [ ] Dragging the map turns follow off
- [ ] No regression to the joystick Recenter behavior

## Related
- [[005-restore-sim-location]] ("Use current location")
- [[004-read-device-real-gps]] — dropped; blue-dot follow went with it
