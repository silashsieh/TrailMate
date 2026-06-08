---
type: epic
id: 007
title: Hand-drawn routes on the map
status: in-progress
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
- [x] Freehand drag gesture capturing a coordinate stroke (coexist with pan/zoom)
- [x] Smoothing + uniform resampling of the raw stroke
- [x] Load the resampled polyline through the existing route-playback path

## Open questions
- ~~Gesture arbitration: how to enter "draw mode" without fighting map pan/zoom (a modifier,
  an explicit toolbar toggle, or tie to the right-click menu from [[008-right-click-map-menu]]).~~
  **Explicit toolbar toggle** (decided 2026-06-07, options presented with trade-offs) — see
  decisions below.
- ~~Smoothing approach + resample spacing (tie spacing to playback speed for steady motion).~~
  **Chaikin ×2 + uniform resample, spacing tied to base speed** (decided 2026-06-07) — note:
  steady *speed* was already guaranteed by NavigationEngine's arc-length advance; smoothing
  is about path shape, spacing about vertex economy. See decisions below.

## Decisions made along the way
- **Entry is an explicit toolbar toggle** (pencil button beside Record/Follow), not a
  modifier-drag or a right-click-menu entry: an explicit mode like Freeform's tools ([[D9]]:
  HIG/MapKit conventions), discoverable, and zero arbitration risk against the AppKit-backed
  Map's own pan recognizer when off. Chosen by Harry from the three options (2026-06-07).
- **Arbitration via GestureMask + interactionModes, not a blocking overlay:** while drawing,
  `.gesture(…, including: .gesture)` masks the wrapped long-press (a slow stroke would
  otherwise trigger it) and `interactionModes: .zoom` drops pan while keeping zoom and
  mapControls live; while not drawing, `.subviews` disables the stroke gesture entirely, so
  normal map interactions are untouched. The right-click destination menu is suppressed in
  draw mode.
- **Draw button is always visible**, not connection-gated like Record/Follow: drawing is
  route *construction*, same as the sidebar planner (which also works disconnected).
- **Chaikin over RDP + Catmull-Rom:** simplest algorithm that meets the ACs, since the
  engine already plays at constant speed; fewer tuning knobs.
- **Resample spacing** `clamp(baseSpeed × 1 s, 2 m, 15 m)` ≈ one vertex per second of 1×
  playback (walk 2 m, cycle ~4 m, drive ~14 m).
- **Degenerate-stroke contract:** the resampler guarantees ≥2 distinct vertices and no
  near-zero segments (a switchback can fold arc-spaced samples onto one spot), and returns
  nil for click-sized strokes/jitter blobs — NavigationEngine's velocity normalization
  divides by segment length and must never see a raw stroke. Stroke points are decimated in
  *screen* space (jitter lives there; its meter size scales with zoom) and converted to
  coordinates at capture time so the stroke stays world-anchored.
- **Stroke end loads the route but does not auto-play** (unlike Route here / Wander): a
  mouse-up is too accidental a trigger; matches the planner's Calculate. A too-short stroke
  logs and stays in draw mode; a successful one exits it. Follow is forced off on entry so
  the camera holds still under the stroke.
- **Discovered, deferred:** the Route section's Save button hardcodes `source: "calculated"`,
  so wander/direct/imported — and now drawn — routes save mislabeled and capture stale
  planner waypoints. Pre-existing in shipped features → a new enhancement epic, not folded
  in here.

## Acceptance criteria
- [x] A freehand stroke becomes a smooth, evenly-spaced playable route
- [x] Playback red-dot speed is steady (no stutter from raw sampling)
- [x] Route can leave roads (parks/trails) without snapping
