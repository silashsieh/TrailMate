---
type: spike-findings
epic: 037
wp: WP2
branch: feat/037-gesture-spike
status: complete
date: 2026-07-10
---

# 037 · WP2 — Gesture-parity spike findings

> **Throwaway spike.** The prototype (`TrailMate/MapSurfacePrototype.swift` +
> the `MapArea` swap in `ContentView.swift`) lives only on `feat/037-gesture-spike`
> and is never merged. These findings are the deliverable — they feed
> [[../v2.2.0-design|v2.2.0-design]] §3 **WP5 (MapGestureBridge)** and the
> [[../epics/037-mkmapview-idle-cpu|epic 037]] *Decisions* section.

## Question

Can TrailMate's four map interactions — **freehand draw**, **long-press**,
**right-click context menu**, **hover→coordinate** — coexist on a raw AppKit
`MKMapView` with its built-in **pan/zoom**, and does **map-local→coordinate
conversion** land correctly? This is the riskiest part of the 037 re-host, so it
was prototyped before any overlay/annotation porting.

## Verdict

**Yes — the design is sound and compiles clean on macOS 26.4 / Swift 6.** All four
gestures map onto stable, documented AppKit APIs, and the arbitration needs *no*
fragile reaching into MKMapView's private internal recognizers. What compilation
cannot prove — that the converted numbers match the pixels, and one macOS
scroll-wheel ambiguity — is listed under [Needs a human](#needs-a-human).

Confidence per gesture (compile-verified API + reasoned behavior; runtime pending
the hand-test):

| Gesture | Confidence | Note |
|---|---|---|
| Long-press → coordinate | **High** | `NSPressGestureRecognizer`; disambiguation is built into the recognizer. |
| Right-click → menu | **High** | `NSClickGestureRecognizer(buttonMask: right)` + `NSMenu`; point is free at fire time. |
| Freehand draw + zoom-live / pan-suppressed | **Medium-High** | `isScrollEnabled` toggle is clean; one scroll-wheel-zoom detail needs hand confirmation. |
| Hover → coordinate | **High** (but likely **unnecessary** — see below) | `NSTrackingArea`; works, but the menu no longer needs it. |
| Coordinate conversion | **Medium-High** | API path verified; *numeric* correctness needs a human eye. |

## Recommended recognizer arbitration (concrete, for WP5 / `MapGestureBridge`)

All recognizers are added to the `MKMapView` and share one
`NSGestureRecognizerDelegate` (the coordinator). Points are taken with
`recognizer.location(in: mapView)` and converted with
`mapView.convert(_:toCoordinateFrom: mapView)`.

1. **Freehand draw — `NSPanGestureRecognizer`, `buttonMask = 0x1` (primary/left).**
   - Enabled **only in draw mode**; disabled otherwise (`recognizer.isEnabled`).
   - While enabled, set **`mapView.isScrollEnabled = false`** so the map's own pan
     is suppressed; restore `true` on exit.
   - `.began`/`.changed`: convert `location(in:)`, append to the stroke.
     `.ended`/`.cancelled`/`.failed`: finish the stroke.
   - **Why the `isScrollEnabled` toggle over gesture-recognizer force-fail:** it is a
     one-line, documented API and mirrors today's `interactionModes: .zoom`
     intent. The alternative — force-failing MKMapView's *internal* pan recognizer
     via `require(toFail:)` / a `shouldBeRequiredToFail` delegate — means finding
     that recognizer in `mapView.gestureRecognizers` (undocumented, unlabelled,
     order not guaranteed) and depending on its identity across OS versions. Reject
     that; toggle the property.
   - `isZoomEnabled` stays `true` throughout, so pinch / zoom-controls / double-click
     zoom remain live while drawing — the "zoom stays live" requirement.

2. **Long-press — `NSPressGestureRecognizer`, `minimumPressDuration = 0.5`,
   `buttonMask = 0x1`.**
   - Report the coordinate on **`.ended`** (release), matching today's
     `LongPressGesture(0.5).sequenced(before: DragGesture)` → on-ended behavior.
   - Does **not** steal a normal click: a <0.5 s press never reaches `.began`.
   - Does **not** steal pan: `allowableMovement` (default ~10 pt) fails the press
     the moment the pointer travels, handing the drag to pan.

3. **Right-click menu — `NSClickGestureRecognizer`, `buttonMask = 0x2` (secondary).**
   - `.ended`: convert `location(in:)`, build an `NSMenu`, `popUp(positioning: nil,
     at: point, in: mapView)`. `point` is already in the map view's coordinate
     system, so the menu appears under the cursor.
   - The coordinate is captured **at menu-build time** (carried on each
     `NSMenuItem.representedObject`) — preserving today's "convert lazily, never
     store a stale coordinate" property, because the point is fresh at fire time.

4. **Hover → coordinate — `NSTrackingArea`** (`.mouseMoved | .activeInKeyWindow |
   `.inVisibleRect`) on a minimal `MKMapView` subclass forwarding `mouseMoved`.
   - Works, but see the simplification below: with the AppKit click recognizer the
     context menu **no longer needs hover at all**.

**Delegate:** implement only
`gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)` → **`true`** for every
pair. This lets our three recognizers run *alongside* MKMapView's internal
pan/zoom/magnify recognizers instead of mutually excluding them. No
`shouldBeRequiredToFail` / `require(toFail:)` relationships are needed:

- draw-pan never competes with map-pan (map scroll is disabled in draw mode; our
  pan is disabled outside it — only one pan recognizer is ever active);
- long-press and right-click don't overlap any built-in pan/zoom trigger.

**Ordering:** none required. (If a *single* left-click action were ever added, it
would need `require(toFail:)` against MKMapView's double-click-to-zoom recognizer;
we have no single-click action, so this does not arise.)

## Coordinate-conversion notes

- **One primitive:** `mapView.convert(point, toCoordinateFrom: mapView)` with
  `point = recognizer.location(in: mapView)` (or, for hover,
  `view.convert(event.locationInWindow, from: nil)`). Every one of these is in the
  map view's *own* coordinate system → **no manual y-flip**.
- **The y-flip trap (the one to warn WP5 about):** macOS `MKMapView` is **not
  flipped** (`isFlipped == false`) → origin bottom-left, y-up. SwiftUI's `.local`
  coordinate space is top-left, y-down. If WP5 keeps point capture in SwiftUI
  (`.onContinuousHover`, `DragGesture(coordinateSpace: .local)`) and converts via a
  stored `mapView` reference, **every point must be flipped first**:
  `CGPoint(x: p.x, y: mapView.bounds.height - p.y)`. Capturing in AppKit recognizers
  sidesteps this completely — hence the recommendation to capture in AppKit and let
  the stroke *rendering* (only) remain an overlay if desired.

## macOS `MKMapView` quirks hit

- **`isScrollEnabled` (pan) vs `isZoomEnabled` (zoom) are separate.** Draw mode wants
  scroll off, zoom on. Confirmed both properties exist and compile on macOS 26.4.
- **Scroll-wheel behavior is the ambiguous one.** On AppKit MKMapView the left-drag
  pans and trackpad **magnify (pinch)** + the **+/− zoom controls** + **double-click**
  zoom — all governed by `isZoomEnabled` and unaffected by `isScrollEnabled=false`.
  Whether a physical **scroll wheel** pans or zooms (and therefore whether it
  survives `isScrollEnabled=false` in draw mode) is hardware/setting dependent and
  is the one behavior to eyeball (see below). Pinch + controls are guaranteed live.
- **No `positionedByUser` equivalent in AppKit** (relevant to **WP4**, not WP2): the
  current follow-disengage reads `cameraPosition.positionedByUser`. AppKit has no
  such flag — WP4 should disengage follow via `mapView(_:regionWillChangeAnimated:)`
  with a "programmatic change in flight" guard, or off a pan/magnify recognizer.
- **Subclassing `MKMapView` for a tracking area is fine.** Apple's "don't subclass"
  caution targets overriding drawing/layout; adding a tracking area + `mouseMoved`
  forward is safe and common.
- **`NSMenu.popUp(at:in:)`** interprets `at:` in the `in:` view's coordinate system —
  feed it the recognizer's `location(in: mapView)` directly.

## Recommended simplifications (change vs. today / vs. epic wording)

1. **Drop the hover tracker for the context menu.** Today `MapArea` keeps a
   `lastHoverPoint` via `.onContinuousHover` *only* because SwiftUI `.contextMenu`
   doesn't expose the click location. `NSClickGestureRecognizer` hands us the point
   directly → the hover state, its staleness comments, and the `MapProxy` dependency
   all disappear. Keep hover **only** if a live cursor-coordinate readout is wanted
   (the app currently has none).
2. **Capture stroke + menu points in AppKit, not SwiftUI gestures.** Removes the
   y-flip risk and the `MapReader`/`MapProxy` dependency. Epic 037's *Design →
   GestureBridge* line says "the stroke may stay a SwiftUI overlay converting points
   via `mapView.convert`" — refine to: *point capture* in AppKit (no flip); the
   stroke *polyline rendering* can still be an overlay if convenient.
3. **`StrokeGeometry` reuse is unaffected.** The prototype captures raw
   `CLLocationCoordinate2D` stroke points exactly as today; WP5 feeds them through the
   existing `StrokeGeometry.chaikin` / `resampleUniform` unchanged. No geometry change.

## What the prototype does

`MapSurfacePrototype` (`NSViewRepresentable`) hosts one `SpikeMapView` (an
`MKMapView` subclass adding the hover tracking area). Its `Coordinator`
(`@MainActor NSObject`, `NSGestureRecognizerDelegate`) attaches the three
recognizers and the hover callback, and logs every firing + converted coordinate to
**subsystem `com.harry.trailmate`, category `spike`**. `MapArea.body` is swapped to
host it behind a "Draw" toggle; the original SwiftUI map is preserved verbatim as
`MapArea.legacyMapBody` (unused on this branch, for reference / trivial revert).

- Draw firings + points: `.info` (begin/end) and `.debug` (each point).
- Long-press / right-click / menu choice: `.info`.
- Hover: `.debug` (fires on every `mouseMoved` — kept quiet on purpose).

## Needs a human

Compilation proves the API path and that everything builds; it cannot prove the
following, which are visual/runtime and were **not** auto-tested (an XCUITest was
considered and skipped — see below):

1. **Conversion correctness** — that a logged lat/lon actually matches the point
   clicked on the rendered map. *This is the core risk and only a human eye closes it.*
2. **Scroll-wheel zoom in draw mode** — that zoom still works via the affordance you
   use while drawing. Pinch + `+/−` controls are guaranteed; a physical scroll wheel
   is the ambiguous case (may pan, and thus be disabled by `isScrollEnabled=false`).
3. **No residual map movement under the stroke** — confirm the map truly holds still
   while drawing (i.e. `isScrollEnabled=false` fully suppresses pan, and MKMapView's
   internal pan doesn't still nudge the map).
4. **No perceptible click/pan latency** from the long-press recognizer sitting in the
   responder chain.
5. **Menu placement + dismissal** — the NSMenu opens at the cursor and dismissing it
   doesn't swallow a following pan/click.

### Why no XCUITest

Considered per the WP2 brief and **skipped as not straightforward / flaky**:
synthesizing a precise drag and right-click *onto an `MKMapView`* in XCUITest is
unreliable, and the actual risk (numeric conversion correctness, item 1 above) can't
be asserted from a UI test without a human confirming the map pixel anyway. A UI test
here would assert only "a gesture fired," which the `os.Logger` output already shows
during the hand-test below at higher signal. If regression coverage is later wanted,
the robust seam is a *unit* test over the pure conversion helper with a laid-out
off-screen map view — but that belongs to WP3/WP5, not this throwaway.

## Hand-test script (owner)

Prereq: no live TrailMate session (`pgrep -lf TrailMate` empty), since the debug
build launches `com.sh.TrailMate`.

1. Open **Console.app** → select this Mac → search field:
   `subsystem:com.harry.trailmate category:spike`. To see the per-point / hover
   `.debug` lines, enable **Action ▸ Include Debug Messages** (Info-level shows the
   begin/end + long-press + right-click + menu lines without it).
2. Build & launch the spike from this worktree:
   `xcodebuild -project TrailMate.xcodeproj -scheme TrailMate -configuration Debug build`,
   then run the built `.app` from DerivedData (or ⌘R in Xcode on this worktree).
   The detail pane shows the map with a **Draw** toggle and a spike hint banner.
3. **Pan/zoom baseline (draw OFF):** drag to pan, pinch / use the `+/−` controls /
   double-click to zoom. → map moves normally; no spike logs for plain pan/zoom.
4. **Long-press:** press and hold (~0.5 s) without moving, then release.
   → `long-press BEGAN` then `long-press RELEASE → <lat>, <lon>`. Confirm the lat/lon
   matches where you held. A quick click logs nothing (correct). A press-then-drag
   logs nothing and pans instead (correct).
5. **Right-click:** right-click anywhere. → `right-click → <lat>, <lon> — presenting
   menu`, and a menu appears at the cursor with the coordinate as its header. Choose
   an item → `menu "<Title>" chosen at <lat>, <lon>`. Confirm the number matches the
   click point.
6. **Draw mode:** click **Draw** (→ `draw mode ON — mapView.isScrollEnabled=false`).
   Drag a stroke. → `draw BEGIN …`, `draw point …` (debug), `draw END → N points`.
   **While mid-stroke, confirm the map does NOT pan.** Then pinch / use `+/−` to
   confirm **zoom still works while drawing**. (Also try the scroll wheel and note
   whether it zooms or does nothing — this answers "Needs a human" item 2.) Toggle
   **Draw** off (→ `draw mode OFF …`) and confirm normal pan returns.
7. **Hover:** with Include-Debug on, move the cursor over the map (draw off).
   → a stream of `hover → <lat>, <lon>` tracking the cursor.

Report back: for 4/5/6, do the logged coordinates match the clicked points, and does
zoom stay live while the map holds still during a stroke?
