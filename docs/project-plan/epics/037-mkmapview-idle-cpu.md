---
type: epic
id: 037
title: Migrate MapArea to MKMapView (NSViewRepresentable) for idle CPU
status: open
milestone: v2.2.0
issue:
opened: 2026-06-24
shipped:
tags: [performance, ui, map]
---

# Epic 037: Migrate MapArea to MKMapView (NSViewRepresentable) for idle CPU

> The real fix for the map idle-CPU problem found during the 2026-06-23/24 profiling session.
> Supersedes the map-rendering concern that [[036-reduce-swiftui-invalidation]] was gated on
> (036 is dropped — see its note). Independent of the simulation-loop wins in
> [[034-cpu-idle-playback-spikes]] / [[035-throttle-simulation-loop]], which are shipped.

## Why

With the app idle and visible (disconnected, no playback, untouched), TrailMate burns ~12% CPU,
rising further when a route polyline is displayed. Profiling traced this to **MapKit's renderer
(`VectorKit` — `md::MapEngine::render`, `ggl::MetalRenderItem`, `AGX…RenderContext`) repainting the
map continuously while its window is visible.** The owner's control test is decisive: **closing the
window drops CPU to near-zero**, and Apple's own Maps.app (a raw AppKit `MKMapView`) idles at ~2 ms
over 8 s — i.e. ~0% — on the same machine with the same VectorKit underneath.

The difference is the wrapper, not the renderer:

- **We use SwiftUI's `Map`**, which re-syncs/repaints the underlying map while visible. Our features
  (follow, recenter, focus-on-saved-route) need *programmatic* camera control, which in SwiftUI
  `Map` requires the two-way `position:` binding — and that binding is what keeps the map
  re-rendering. This matches the long-standing report in Apple DTS forum thread 705203 ("Why is
  MapKit CPU usage higher with SwiftUI than AppKit?": SwiftUI Map idles 5–15%, AppKit `MKMapView`
  drops to 0%).
- **Apple Maps drives an `MKMapView` imperatively** (`setRegion`/`setCamera`) with no SwiftUI
  binding, so it renders on change and then sleeps (event-driven).

A secondary, real-but-minor finding from the same session: an **AttributeGraph dependency cycle**
in `MapArea` (the `.onMapCameraChange` handlers reading/writing camera state synchronously, entangled
with the `position: $cameraPosition` binding) produced continuous `AttributeGraph: cycle detected`
spam. Deferring those side effects off the update pass eliminated the cycle but only shaved ~5% — it
was not the dominant cost — so that experiment was reverted in favour of the migration here, which
replaces the code outright.

## Goal

Idle, visible TrailMate sits at ~1% CPU (Apple-Maps-like), route displayed or not, with no loss of
current map features. The map renders on interaction/animation and is otherwise quiescent.

## Out of scope

- The simulation-loop costs — already handled by [[034-cpu-idle-playback-spikes]] /
  [[035-throttle-simulation-loop]].
- Any new map features. This is a like-for-like re-host of the existing `MapArea` behavior.

## Stories

- [ ] Wrap `MKMapView` in an `NSViewRepresentable` (`MapAreaRepresentable`), driving the camera
      imperatively (`setRegion`/`setCamera`) — no SwiftUI two-way camera binding.
- [ ] Re-implement the current map content on `MKMapView`: per-session simulated-dot annotation
      (color-coded, selected emphasis), route `MKPolyline` overlays (selected vs others), the
      hand-drawn stroke polyline, and start/stop/end/destination markers.
- [ ] Re-implement camera behaviors: persisted region (`MapCameraPersistence`), follow mode +
      follow-span, follow-disengage on user gesture, and focus-on-saved-item (`mapFocus`).
- [ ] Re-implement interactions: the freehand draw-route gesture (zoom-only while drawing) and the
      right-click / long-press context menu with correct map-local→coordinate conversion.
- [ ] Verify idle CPU with the **window visible** (the only valid measurement — an occluded/
      background-launched window pauses MapKit rendering and reads a false ~0%).

## Open questions

- Can a single `MKMapView` host multi-session overlays/annotations as cleanly as the SwiftUI
  `ForEach(sessions)` does today? (Expected yes — standard `MKMapViewDelegate` rendererFor/viewFor.)
- Does any residual idle cost remain from annotations (the 705203 "vibrating annotation")? Measure
  with the dot present vs absent.

## Decisions made along the way

- **MKMapView over SwiftUI `Map`.** Apple Maps proves a VectorKit map idles at ~0% when driven
  imperatively via AppKit; SwiftUI `Map`'s visible-window render is framework-level and not tunable
  from app code (confirmed by elevation, camera-frequency, and AttributeGraph-cycle experiments that
  each moved the needle only marginally).
- **Measure with the window visible.** `top`/sampling a background-launched instance reads ~0%
  because the occluded window pauses MapKit; trust on-screen Instruments runs only.

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] Idle + visible + route loaded: ~1% CPU (down from ~12%), comparable to Apple Maps.
- [ ] All current map features behave identically: dot, routes, markers, draw, context menu,
      follow/recenter/focus, region persistence.
- [ ] No `AttributeGraph: cycle detected` output at idle.
