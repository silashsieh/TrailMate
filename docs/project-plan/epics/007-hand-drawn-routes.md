---
type: epic
id: 007
title: Hand-drawn routes on the map
status: open
milestone: v1.5.0
issue: 15
opened: 2026-05-29
shipped:
tags: [routing, map]
---

# Epic 007: Hand-drawn routes on the map

## Why
Issue #15: routes can already be built two ways — sidebar From/To (+Add Stop) on **real roads**
([[001-multi-stop-routes]]), and long-press "Append direct" (straight) / "Append route" (roads)
to extend point-by-point. So multi-point selection exists; the gap is **continuous freehand
drawing**: dragging one smooth curve, unconstrained by roads (through parks, trails, off-road).

## Goal
Draw a route by dragging continuously on the map. Because a freehand stroke is jittery and
unevenly sampled, the app **smooths + uniformly resamples** it so playback moves the red dot
smoothly at a steady speed.

## Out of scope
- "Snap to road" toggle — noted as a future extension, not this epic.

## Stories
- [ ] Freehand drag gesture capturing a coordinate stroke (coexist with pan/zoom)
- [ ] Smoothing + uniform resampling of the raw stroke
- [ ] Load the resampled polyline through the existing route-playback path

## Open questions
- Gesture arbitration: how to enter "draw mode" without fighting map pan/zoom (a modifier,
  an explicit toolbar toggle, or tie to the right-click menu from [[008-right-click-map-menu]]).
- Smoothing approach + resample spacing (tie spacing to playback speed for steady motion).

## Acceptance criteria
- [ ] A freehand stroke becomes a smooth, evenly-spaced playable route
- [ ] Playback red-dot speed is steady (no stutter from raw sampling)
- [ ] Route can leave roads (parks/trails) without snapping
