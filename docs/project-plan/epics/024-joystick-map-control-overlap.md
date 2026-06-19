---
type: epic
id: 024
title: Fix joystick overlapping the map zoom/compass controls
status: open
milestone: v2.1.0
issue: 43
opened: 2026-06-19
shipped:
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

- [ ] Inset/reposition the MapKit controls (or the joystick) so neither occludes the other,
      following Apple's `MapControls` placement conventions (HIG, not Google Maps — [[decisions]] D9).
- [ ] Verify at minimum window size and with the joystick armed vs idle.

## Open questions

- Move the joystick, move the map controls, or add a safe-area inset? Prefer the
  least-surprising HIG-aligned option.

## Decisions made along the way

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] With the joystick visible, the user can tap zoom +/- and the compass.
- [ ] No regression to joystick reachability or the record/status overlays.
