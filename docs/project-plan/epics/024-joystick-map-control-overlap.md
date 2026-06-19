---
type: epic
id: 024
title: Fix joystick overlapping the map zoom/compass controls
status: done
milestone: v2.1.0
issue: 43
opened: 2026-06-19
shipped: 2026-06-19
tags: [bug, ui, map]
---

# Epic 024: Fix joystick overlapping the map zoom/compass controls

> Bug in the shipped joystick UI (reported in #43). New `bug` epic per [[process]] triage —
> the joystick predates the epic model (see [[phases]]); this links back to it as a fix, not a
> reopen.

## Why

The bottom-right virtual joystick sits on top of MapKit's built-in zoom and compass controls,
so the user can't reach them while the joystick is visible. Normal-severity UI overlap → next
milestone.

## Goal

The joystick and MapKit's map controls (zoom, compass) are both reachable: no control is
occluded by the joystick at any window size.

## Out of scope

- Redesigning the joystick or its gesture model.
- Moving unrelated overlays (record button, status pill) unless they collide too.

## Stories

- [x] Inset/reposition the MapKit controls (or the joystick) so neither occludes the other,
      following Apple's `MapControls` placement conventions (HIG, not Google Maps — [[decisions]] D9).
- [x] Verify at minimum window size and with the joystick armed vs idle.

## Open questions

- Move the joystick, move the map controls, or add a safe-area inset? Prefer the
  least-surprising HIG-aligned option. → **Resolved: safe-area inset** (see below).

## Decisions made along the way

- The on-screen joystick moved from a plain `.overlay(alignment: .bottomTrailing)` to a
  `.safeAreaInset(edge: .bottom, alignment: .trailing)` on the `Map`. MapKit positions its
  built-in controls within the map's safe area, so reserving the joystick's footprint as a
  bottom inset makes the zoom stepper and compass reflow *above* the joystick rather than
  being occluded. This is the HIG-aligned option (D9): it uses MapKit's own placement
  mechanism instead of hand-positioning the controls, and it neither redesigns the joystick
  (the `Map` still draws full-bleed behind the inset, so the stick keeps floating in the same
  corner) nor moves the record/status overlays. The inset collapses to zero when the joystick
  is idle, returning the controls to the corner.

## Bugs / follow-ups found while building

- None.

## Acceptance criteria

- [x] With the joystick visible, the user can tap zoom +/- and the compass.
- [x] No regression to joystick reachability or the record/status overlays.
