# Agent handoff: Epic 030 area serpentine coverage routing

Work only in this worktree:

- Path: `/Users/harry/Documents/pikmin/TrailMate-epic-030`
- Branch: `agent/epic-030-area-coverage`
- Draft PR: created as the bootstrap for this task
- Linked issue: https://github.com/silashsieh/TrailMate/issues/47

Do not merge the PR, delete the worktree, or modify the original checkout. Leave the completed,
committed result in this worktree; the primary agent will review, push, merge, and clean it up after
the user reports that you are finished.

## Objective

Complete `docs/project-plan/epics/030-area-coverage-routing.md` by extending the existing **Wander
Nearby** window with two peer route-generation modes:

1. **Random** — preserve the existing random, road-routed wander behavior.
2. **Sweeping** — generate a continuous geometric boustrophedon/serpentine (“mow the lawn”)
   route inside a square centered on the same selected map point.

Both modes share the selected map point and radius. The sweeping square's side length is exactly
`2 × radius`. Its path must be dense, deterministic, non-repeating, configurable by scan-line/lane
spacing, and usable by the existing playback, recording, save, and GPX-export flows.

Sweeping is geometric direct movement like **Go directly** and hand-drawn routes. Do not use
`MKDirections` or snap Sweeping to roads. Preserve Random mode's current `MKDirections` behavior,
and do not rewrite the routing engine or daemon protocol.

## Read before editing

Follow `CLAUDE.md`, especially its docs-first, coordinate-test, localization, and project-management
rules. Read these current sources before choosing the implementation:

- `docs/project-plan/epics/030-area-coverage-routing.md`
- `docs/project-plan/scope.md`
- `docs/technical/features.md`
- `docs/technical/architecture.md`
- `docs/technical/decisions.md`
- `docs/project-plan/testing.md`
- `TrailMate/ContentView.swift` (`WanderSheet`, destination actions, playback controls)
- `TrailMate/WanderPresetPersistence.swift`
- `TrailMate/WanderRouteBuilder.swift`
- `TrailMate/DeviceSession.swift` (`wanderNearby`, `loadDrawnRoute`)
- `TrailMate/AppState.swift` (route handoff and selected-session forwarding)
- the current route/geometry tests under `TrailMateTests/`

Build against current `main`, which still uses SwiftUI `Map` + `MapReader`. Epic 037’s unmerged
`MKMapView` work is future architecture and is not a dependency. Keep pure geometry and UI state
separated enough that a later map-surface migration will not require rewriting the route builder.

## Product scope and expected interaction

- Keep a single **Wander Nearby** sheet. Add a clear macOS-native mode selector inside it with
  **Random** and **Sweeping** at the same hierarchy level; do not add a separate area-selection
  window, map-drawing workflow, or standalone sweeping control.
- Both modes use `appState.pendingWanderCenter`, i.e. the selected map point from which the user
  invoked **Wander nearby…**. Do not replace it with the selected session's current simulated
  red-dot coordinate.
- Keep the radius control shared between both modes.
  - In Random mode it retains the existing circular-wander meaning and current behavior.
  - In Sweeping mode it defines a square centered on the selected map point, with side length
    exactly `radius × 2` (radius is the center-to-edge half-side, not a corner distance).
- Random mode must preserve the current duration presets/custom duration, distance preview, random
  `WanderRouteBuilder`, road routing, and auto-play behavior. Its generated route begins at the
  selected map point exactly as it does today.
- Sweeping mode must hide/omit the user-editable duration control. Instead, expose a scan-line
  spacing control in metres, defaulting to **70 m**, validate it as a finite positive value, and
  persist the last valid selection using the existing Wander preference pattern.
- While Sweeping is selected, show the route's estimated distance and time in the same sheet before
  Start. Compute the estimate from the generated geometric route length and
  `appState.effectiveBaseSpeedMPS`; duration is `length ÷ speed`. Do not ask the user for a duration.
  Treat teleporting from the selected center to the first boundary point as instantaneous and do
  not include that jump in route distance or estimated time.
- Both modes use the sheet's existing explicit **Start** action and then auto-play through the
  selected session, consistent with current Wander Nearby behavior.
- A Sweeping route may—and should—start at a deterministic point on the square boundary. Loading it
  with reset-start semantics must immediately move/teleport the simulated location from the
  selected center to that first edge point before playback follows the sweep.
- Preserve all current map interactions and controls, including long-press, right-click, Draw,
  Follow, joystick, multi-session overlays, and saved-route behavior.
- All new user-facing strings must be added to `TrailMate/Localizable.xcstrings` with English and
  Traditional Chinese coverage consistent with the project.

## Geometry requirements

Create a focused pure helper (for example `CoverageRouteBuilder`) rather than embedding coordinate
math in `ContentView.swift` or altering the random `WanderRouteBuilder`.

- Accept the selected center, radius/half-side in metres, and lane spacing in metres.
- Construct a north-up square centered on the selected map point with side length exactly
  `2 × radius`. Polygon/rectangle drawing and arbitrary bounds are out of scope.
- Work in a local metre-based projection and convert back to coordinates; do not treat longitude
  degrees as constant metres. Follow the known-reference testing rule in `CLAUDE.md`.
- Keep every generated point inside/on the square bounds (within a small floating-point
  tolerance).
- Traverse alternating lane endpoints so consecutive lanes reverse direction and no lane segment
  is repeated.
- Use a deterministic sweep orientation and deterministic boundary start point so identical inputs
  produce identical coordinates. The first route coordinate must lie on the square edge.
- Produce at least a useful edge-to-edge sweep when the square is narrower than the selected
  spacing.
- Calculate route length from the emitted coordinates so the sheet can derive its live time
  estimate from the effective base speed.
- Validate non-finite center/radius/spacing, non-positive radius/spacing, zero/non-finite speed for
  estimates, and practical route-size limits. Surface failures without crashing or silently
  swallowing them.
- No road routing, optimal coverage solver, polygon clipping, cloud service, or daemon changes.

## Integration and tests

- Add a clean selected-session handoff for sweeping alongside `wanderNearby`; reuse the established
  route-loading/playback pipeline instead of duplicating it. Keep selected-session routing correct
  under multi-device use and preserve Random mode behavior.
- Add Swift Testing unit coverage for the pure builder, including:
  - expected alternating serpentine order;
  - a square centered on the selected point with side length exactly `2 × radius`;
  - containment inside the square and a first point on its edge;
  - lane spacing in metres against a known CoreLocation reference;
  - deterministic output and sweep orientation;
  - narrow-square and invalid-input edge cases;
  - a guard against duplicate consecutive points or repeated lane segments;
  - a practical point-count cap for very large/dense requests;
  - route-length and `length ÷ speed` estimate accuracy.
- Add targeted UI/state coverage for mode-specific controls where deterministic and proportionate:
  Random shows duration and preserves its existing preview; Sweeping shows 70 m default spacing,
  hides duration, and shows derived distance/time. At minimum, ensure the existing test suites
  compile and document a manual smoke check for both modes, center/edge start behavior, playback,
  save, record, and export.
- Update `docs/technical/features.md`, `docs/project-plan/testing.md`, and Epic 030’s decisions,
  checked stories, acceptance criteria, status, and discovered follow-ups so documentation describes
  the implemented behavior. Do not hand-edit generated roadmap/backlog views.

## Validation

A fresh worktree does not contain the ignored Python bundle. Before an app-hosted build/test, either
run `./packaging/build.sh` or reuse the main checkout locally:

```bash
ln -s ../TrailMate/PythonResources PythonResources
```

Prefer the focused builder tests first, then run unit tests without UI automation:

```bash
xcodebuild test \
  -project TrailMate.xcodeproj \
  -scheme TrailMate \
  -destination 'platform=macOS' \
  -skip-testing:TrailMateUITests \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO
```

Do not run tests while the user has a live TrailMate session open; use `build-for-testing` if that
cannot be established safely. Report exactly what was and was not run.

## Handoff requirements

- Keep the change scoped to Epic 030; file unrelated discoveries under the epic’s follow-up section
  rather than implementing them.
- Use conventional commits.
- Before finishing, delete this `EPIC-030-AGENT-PROMPT.md` file and commit that deletion so the final
  PR diff contains only product, test, and project-documentation changes.
- Do not push or merge. Leave the branch and worktree in a clean, committed state and give the user
  a concise summary of implementation, validation, and any remaining risks.
