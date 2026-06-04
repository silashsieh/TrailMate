---
type: epic
id: 004
title: Read device real GPS (blue dot)
status: dropped
milestone:
issue: 17
opened: 2026-05-29
shipped:
tags: [positioning]
---

# Epic 004: Read device real GPS (blue dot)

> **Dropped (2026-06-01).** Issue #17 was closed as *not planned* by the owner. The epic was
> gated on a feasibility spike (does `pymobiledevice3` support reading device live location?)
> and the owner declined the work before it was scheduled into a build. Kept as the record of
> why; ids are never reused. Downstream consequences: the "real location" extensions noted in
> [[005-restore-sim-location]] and [[006-follow-current-position]] are dropped with it — their
> core scope (persist simulated position; follow the red dot) is unaffected.

## Why
Issue #17: TrailMate is currently **write-only** to the device — it pushes simulated coordinates
but never reads the iPhone's real GPS back. So the app only ever knows the *simulated* position
(red dot), never where the phone actually is. Unlike Google Maps' single blue dot, TrailMate
conceptually has two positions (real vs simulated) but today only controls the latter.

This was positioned as the foundational capability for "current real location" features.

## Goal (as scoped before the drop)
Add a "read the device's current real GPS" capability and render it on the map as a **blue dot**
(à la Google Maps).

## Open questions (unresolved at drop time)
- Feasibility was never confirmed: whether `pymobiledevice3` supports reading the device's live
  location at all. If this epic is ever revived, the feasibility spike is still step one.
