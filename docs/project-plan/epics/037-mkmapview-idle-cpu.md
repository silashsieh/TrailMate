---
type: epic
id: 037
title: Map-surface re-architecture — MKMapView + frequency-partitioned data flow (idle CPU)
status: open
milestone: v2.4.0
issue:
opened: 2026-06-24
shipped:
tags: [performance, ui, map, architecture]
---

# Epic 037: Map-surface re-architecture — MKMapView + frequency-partitioned data flow (idle CPU)

> The real fix for the map idle-CPU problem found during the 2026-06-23/24 profiling session.
> Supersedes the map-rendering concern that [[036-reduce-swiftui-invalidation]] was gated on
> (036 is dropped — see its note). Independent of the simulation-loop wins in
> [[034-cpu-idle-playback-spikes]] / [[035-throttle-simulation-loop]], which are shipped.
>
> **Scope refreshed 2026-07-10** after a follow-up investigation of the 15–30% playback CPU:
> widened from a like-for-like `MKMapView` re-host to the full map *data-flow* re-architecture
> (telemetry plane + imperative map surface), because the re-host alone would leave the 2 Hz
> whole-map-content rebuild and the follow-mode animation churn in place. The telemetry-plane
> substrate is filed separately as [[041-telemetry-plane]] so both can be built in parallel;
> this epic consumes it. The broader presentation rework (view decomposition, SPM packages,
> simulation-kernel extraction) is **not** in this epic — it is planned separately for v2.3.0.
> Build plan + agent work packages: [[../v2.4.0-design|v2.4.0-design]].

## Why

With the app idle and visible (disconnected, no playback, untouched), TrailMate burns ~12% CPU;
during route playback Activity Monitor reads **15–30%**. Three causes, one root:

1. **The ~12% floor: SwiftUI `Map` never sleeps.** Profiling traced idle burn to MapKit's
   renderer (`VectorKit` — `md::MapEngine::render`, `ggl::MetalRenderItem`) repainting the map
   continuously while its window is visible. Our features (follow, recenter, focus-on-saved-route)
   need *programmatic* camera control, which in SwiftUI `Map` requires the two-way `position:`
   binding — and that binding is the render driver. The owner's control test is decisive:
   closing the window drops CPU to near-zero, and Apple's own Maps.app (raw AppKit `MKMapView`,
   imperative `setRegion`/`setCamera`) idles at ~0% on the same machine with the same VectorKit
   underneath. Matches Apple DTS forum thread 705203. Framework-level; not tunable from app code
   (elevation, camera-frequency, and AttributeGraph-cycle experiments each moved it only
   marginally).
2. **Playback adds a 2 Hz whole-map-content rebuild.** `MapArea`'s `Map` content builder reads
   `session.simState.simulatedCoordinate`, so every snapshot push re-evaluates the entire
   builder — re-declaring every session's `MapPolyline` (routes can be thousands of vertices)
   and every marker, and re-syncing the overlay set into VectorKit. The 2 Hz playback snapshot
   throttle in `SimulationActor` exists *only* to bound this; it is a workaround, not a fix — in
   SwiftUI `Map` there is no way to move the dot without re-declaring the polylines.
3. **Follow mode keeps the camera permanently animating (the ~30% end).** With Follow on,
   `.onChange(of: simulatedCoordinate)` runs `withAnimation { cameraPosition = .region(…) }`
   every 500 ms — a camera animation is always in flight, forcing sustained rendering plus
   continuous `.onMapCameraChange(frequency: .continuous)` callbacks.

A secondary, real-but-minor finding: an **AttributeGraph dependency cycle** in `MapArea` (the
`.onMapCameraChange` handlers reading/writing camera state synchronously, entangled with the
`position: $cameraPosition` binding) produced continuous `AttributeGraph: cycle detected` spam.
Deferring those side effects shaved only ~5%, so that experiment was reverted in favour of the
migration here, which deletes the code outright.

## Goal

Idle, visible TrailMate sits at ~1% CPU (Apple-Maps-like), route displayed or not; route
playback stays in the low single digits, with Follow no longer a separate cost tier — and the
dot gets *smoother* (10 Hz instead of 2 Hz). No loss of current map features.

The load-bearing architectural property: **a coordinate-only tick never re-evaluates map
content** — no `MapSurface` update pass, no overlay reconciliation; the dot moves by in-place
annotation mutation fed directly from the telemetry stream. Small, explicitly isolated SwiftUI
readouts (playback progress, recording count) keep updating at a throttled, equality-guarded
rate — "zero SwiftUI updates during playback" would be both unnecessary and false.

## Design

Two planes replace today's single `@Observable` snapshot channel:

- **Telemetry plane (2–10 Hz):** `SimulationActor` yields `TelemetryFrame` (coordinate,
  progress, elapsed distance, deviation) into a per-session `AsyncStream`
  (`bufferingNewest(1)`, latest-wins). Consumed by non-SwiftUI code — primarily the map
  surface controller.
- **Structural plane (rare, edge-triggered):** `StateChange` (playback state, joystick /
  recording flags, controller name, completed loops) continues through the `@Observable`
  bridge for SwiftUI. Split from today's `SimSnapshot`; same-value re-writes guarded so
  Observation fan-out only fires on real changes.

The map itself becomes `MapSurface` (an `NSViewRepresentable` creating one `MKMapView`) whose
coordinator `MapSurfaceController` (MainActor) owns:

- **OverlayStore** — `MKPolyline` per session keyed by `(sessionID, routeVersion)`; a new
  `routeVersion: Int` on `DeviceSession` bumps wherever `routeCoordinates` is set, so
  `updateNSView` diffs an `Int`, never coordinate arrays. Includes the hand-drawn stroke
  polyline and start/stop/end/destination markers.
- **AnnotationStore** — one stable dot annotation per session (color-coded, selected emphasis),
  moved by mutating `coordinate` in place from the telemetry stream; annotation objects are
  never rebuilt as an array.
- **CameraDirector** — imperative `setRegion`/`setCamera`/`setCenter(_:animated:)`: persisted
  region (`MapCameraPersistence`), follow mode + follow-span, follow-disengage on user gesture
  (gesture recognizers / `regionWillChange` — there is no `positionedByUser` equivalent in
  AppKit MapKit), and focus-on-saved-item (`mapFocus`).
- **GestureBridge** — right-click / long-press context menu and the freehand draw-route
  gesture (zoom-only while drawing). Per the gesture spike: all points are **captured in
  AppKit recognizers** (`location(in:)` — no coordinate-space flip needed), never in SwiftUI
  gestures (SwiftUI `.local` is top-left origin while macOS `MKMapView` is bottom-left; a
  SwiftUI-sourced point fed to `convert(_:toCoordinateFrom:)` must be y-flipped). Stroke
  *rendering* may stay an overlay. The hover tracker is dropped — it existed only because
  SwiftUI `.contextMenu` hides the click point; `NSClickGestureRecognizer` hands it over
  directly.

## Out of scope

- The simulation-loop costs — already handled by [[034-cpu-idle-playback-spikes]] /
  [[035-throttle-simulation-loop]].
- The multi-device recording-isolation defect found in the same investigation (shared
  `RecorderService` injected into every session's actor) — a correctness bug, its own epic.
- The broader presentation/architecture program: ContentView decomposition into feature
  folders, SPM package extraction, `SimulationKernel` extraction, `LocationSink` narrowing,
  ControllerHub. Planned as separate v2.3.0 epics.
- Any new map features. Feature set is a like-for-like re-host of current `MapArea` behavior.

## Stories

- [ ] **Depends on [[041-telemetry-plane]]** (the `TelemetryFrame` stream, change-guarded
      bridge, and `routeVersion`) — additive substrate, built in parallel, integrated here.
- [x] **Gesture-parity spike first:** prototype freehand draw + long-press + context menu +
      pan/zoom coexisting on a bare `MKMapView` before porting overlays (the riskiest part).
      *Done 2026-07-10, verdict green **at API/compile level; provisional until the owner's
      hand-test** — branch `feat/037-gesture-spike` (never merged); findings + hand-test script
      in `docs/project-plan/spikes/037-gesture-spike-findings.md`; arbitration recorded under
      Decisions below. Review addenda folded into integration: draw mode must also disable
      long-press/right-click and rotate/pitch (today's parity), Control-click must reach the
      context menu, and the stroke must keep its mouse-down origin past NSPan hysteresis.*
- [ ] Wrap `MKMapView` in `MapSurface` (`NSViewRepresentable`) with `MapSurfaceController`
      (OverlayStore / AnnotationStore / CameraDirector / GestureBridge), driving the camera
      imperatively — no SwiftUI two-way camera binding.
- [ ] Re-implement map content on `MKMapView`: per-session dot annotations updated **in place**
      from the telemetry stream; route `MKPolyline` overlays diffed by `(sessionID,
      routeVersion)` (selected vs others); hand-drawn stroke; start/stop/end/destination markers.
- [ ] Re-implement camera behaviors: persisted region, follow mode + follow-span with a
      **coalesced camera cadence** — steady-state follow applies unanimated (or dead-band /
      rate-limited) moves decoupled from the dot's 10 Hz; animation reserved for discrete
      engage/focus commands; follow-disengage on user gesture via `regionWillChange` + an
      origin token — plus focus-on-saved-item.
- [ ] Re-implement interactions: draw-route gesture (zoom-only while drawing), right-click /
      long-press context menu, hover→coordinate conversion.
- [ ] Swap `MapArea`'s `Map` for `MapSurface`; delete the `position:` binding, both
      `.onMapCameraChange` handlers, and the `.onChange(of: simulatedCoordinate)` follow hack.
- [ ] Raise playback telemetry to 10 Hz (the 2 Hz throttle existed only to protect SwiftUI
      `Map`); keep the structural bridge edge-triggered.
- [ ] Verify idle + playback CPU with the **window visible** (the only valid measurement — an
      occluded/background-launched window pauses MapKit rendering and reads a false ~0%),
      against the pre-migration Instruments baselines (idle no-route, idle with route, playback
      follow-off, playback follow-on, joystick).

## Open questions

- Does any residual idle cost remain from annotations (the 705203 "vibrating annotation")?
  Measure with the dot present vs absent.
- Is `.realistic` elevation worth its render cost once rendering is event-driven, or should
  `elevationStyle: .flat` become the default (or a Settings toggle)?

## Decisions made along the way

- **Re-scheduled to v2.4.0 (2026-08-18, owner's call).** Planned as v2.2.0 and fully built +
  validated on `feat/037-integration` in July 2026, but PR
  [#69](https://github.com/silashsieh/TrailMate/pull/69) closed unmerged (branch deleted;
  commits recoverable via `git fetch origin pull/69/head`, tip `9835159`). v2.2.0 is now
  "Area serpentine and auto-update" ([[030-area-coverage-routing]] + [[038-in-app-auto-update]]);
  this epic and [[041-telemetry-plane]] move together to v2.4.0 so the substrate still lands
  first. Nothing about the design changed — only when it ships.
- **Playback map telemetry is capped at 5 Hz, not 10 Hz (2026-07-13 A/B result).** The 10 Hz
  dot's per-move MapKit render passes *regressed* playback CPU; variant C at 5 Hz took
  scenario 3 from 21% → 15% and scenario 4 from 22% → 14%.
  `SimulationTiming.mapTelemetryInterval` = 200 ms for playback only; joystick stays at the
  10 Hz active cadence. `.realistic` elevation was exonerated in the same A/B and stays.
  The "10 Hz dot" wording in Goal/Stories/Acceptance below predates this and is superseded.
- **MKMapView over SwiftUI `Map`.** Apple Maps proves a VectorKit map idles at ~0% when driven
  imperatively via AppKit; SwiftUI `Map`'s visible-window render is framework-level and not
  tunable from app code (confirmed by elevation, camera-frequency, and AttributeGraph-cycle
  experiments that each moved the needle only marginally).
- **Measure with the window visible.** `top`/sampling a background-launched instance reads ~0%
  because the occluded window pauses MapKit; trust on-screen Instruments runs only.
- **Widened to the data-flow re-architecture (2026-07-10).** A pure re-host would still
  re-declare overlays from SwiftUI state at snapshot rate; the telemetry plane is the substrate
  that makes the re-host actually event-driven, and is what allows raising the dot to 10 Hz.
- **Frequency partition over full-state stream.** A full-state latest-wins stream applied to
  the `@Observable` bridge at 10 Hz would re-invalidate observing views at 10 Hz (Observation
  does not dedupe same-value writes); hence the `TelemetryFrame` / `StateChange` split with
  change-guarded bridge writes.
- **Steady follow is unanimated and coalesced (2026-07-10 review correction).** Driving an
  animated `setCenter` on every 100 ms frame would recreate the permanently-in-flight camera
  animation this epic removes. Camera commands get their own cadence, decoupled from the dot;
  animation only on discrete engage/focus; disengage detection uses an origin token/counter
  (not a boolean) so animated programmatic changes spanning multiple will/did callbacks never
  read as user gestures.
- **Gesture arbitration settled by the spike (2026-07-10, verdict green).** Draw:
  `NSPanGestureRecognizer` (buttonMask 0x1) enabled only in draw mode, with
  `mapView.isScrollEnabled = false` while drawing (one documented line — cleaner than
  force-failing MKMapView's unlabelled internal pan recognizer); `isZoomEnabled` stays true so
  pinch/controls zoom stay live. Long-press: `NSPressGestureRecognizer` (0.5 s) → coordinate
  on `.ended`; `allowableMovement` auto-fails it into pan. Right-click:
  `NSClickGestureRecognizer` (buttonMask 0x2) → `NSMenu.popUp(at:in:)`, coordinate converted
  at menu time. Delegate: only `shouldRecognizeSimultaneouslyWith → true`; no
  `require(toFail:)` chains. Points are captured in AppKit recognizers to avoid the
  SwiftUI↔AppKit y-flip trap. Confidence: long-press/right-click high; draw+zoom and numeric
  conversion medium-high — five interactive checks remain for the owner (conversion
  correctness, scroll-wheel zoom under `isScrollEnabled = false`, map stillness under a
  stroke, click/pan latency, menu placement) — hand-test script in the spike findings doc.

## Bugs / follow-ups found while building

## Acceptance criteria

- [ ] Idle + visible + route loaded: ~1% CPU (down from ~12%), comparable to Apple Maps.
- [ ] Route playback + visible: low single digits; Follow on vs off is no longer a distinct
      cost tier (down from 15–30%).
- [ ] Dot moves at 10 Hz during playback (smoother than today's 2 Hz).
- [ ] A coordinate-only tick re-evaluates no map content (no `MapSurface` update pass, no
      overlay reconciliation — verify with signposts); sidebar readouts stay throttled and
      equality-guarded.
- [ ] All current map features behave identically: dot, routes, markers, draw, context menu,
      follow/recenter/focus, region persistence.
- [ ] No `AttributeGraph: cycle detected` output at idle.
