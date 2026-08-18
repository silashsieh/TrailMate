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

Complete `docs/project-plan/epics/030-area-coverage-routing.md`: let the user select a rectangular
area on the map and generate a continuous geometric boustrophedon/serpentine (“mow the lawn”)
route within it. The path must be dense, deterministic, non-repeating, configurable by lane spacing,
and usable by the existing playback, recording, save, and GPX-export flows.

This is geometric direct movement like **Go directly** and hand-drawn routes. Do not use
`MKDirections`, do not snap to roads, and do not rewrite the routing engine or daemon protocol.

## Read before editing

Follow `CLAUDE.md`, especially its docs-first, coordinate-test, localization, and project-management
rules. Read these current sources before choosing the implementation:

- `docs/project-plan/epics/030-area-coverage-routing.md`
- `docs/project-plan/scope.md`
- `docs/technical/features.md`
- `docs/technical/architecture.md`
- `docs/technical/decisions.md`
- `docs/project-plan/testing.md`
- `TrailMate/ContentView.swift` (`MapArea`, draw mode, destination actions, Wander sheet)
- `TrailMate/StrokeGeometry.swift`
- `TrailMate/WanderRouteBuilder.swift`
- `TrailMate/DeviceSession.swift` (`wanderNearby`, `loadDrawnRoute`)
- `TrailMate/AppState.swift` (route handoff and selected-session forwarding)
- `TrailMateTests/StrokeGeometryTests.swift`

Build against current `main`, which still uses SwiftUI `Map` + `MapReader`. Epic 037’s unmerged
`MKMapView` work is future architecture and is not a dependency. Keep pure geometry and UI state
separated enough that a later map-surface migration will not require rewriting the route builder.

## Product scope and expected interaction

- Ship rectangle selection first. Polygon selection is explicitly future work.
- Add a clear, macOS-native area-selection control near the existing Follow/Draw controls.
- Selection mode must arbitrate gestures deliberately: while selecting, dragging defines the box
  instead of panning the map; Escape cancels and restores normal map interaction.
- Show a world-anchored rectangle preview while selecting. Reject click-sized/degenerate areas with
  an understandable log or inline message rather than producing invalid coordinates.
- After a valid selection, let the user choose/configure lane spacing in metres. Choose a sensible
  small preset set and default, document the rationale in the epic, and persist the last selection
  if that matches the existing Wander preference pattern.
- Generate the route only after an explicit confirmation. Loading it should behave like a
  hand-drawn route: update the selected session’s `routeCoordinates`, load it into the simulation
  pipeline, and leave playback under the existing Play controls rather than auto-playing from
  mouse-up.
- Preserve all current map interactions and controls outside selection mode, including long-press,
  right-click, Draw, Follow, joystick, multi-session overlays, and saved-route behavior.
- All new user-facing strings must be added to `TrailMate/Localizable.xcstrings` with English and
  Traditional Chinese coverage consistent with the project.

## Geometry requirements

Create a focused pure helper (for example `CoverageRouteBuilder`) rather than embedding coordinate
math in `ContentView.swift`.

- Accept the rectangle bounds and lane spacing in metres.
- Work in a local metre-based projection and convert back to coordinates; do not treat longitude
  degrees as constant metres. Follow the known-reference testing rule in `CLAUDE.md`.
- Keep every generated point inside/on the selected bounds (within a small floating-point
  tolerance).
- Traverse alternating lane endpoints so consecutive lanes reverse direction and no lane segment
  is repeated.
- Prefer a sweep parallel to the rectangle’s longer physical dimension to reduce turns, unless a
  simpler deterministic orientation has a stronger documented reason.
- Produce at least a useful centre/edge sweep for an area narrower than the selected spacing.
- Validate non-finite coordinates, inverted/degenerate bounds, non-positive spacing, and practical
  route-size limits. Surface failures without crashing or silently swallowing them.
- No road routing, optimal coverage solver, polygon clipping, cloud service, or daemon changes.

## Integration and tests

- Reuse or cleanly generalize the `loadDrawnRoute` handoff instead of duplicating the playback
  pipeline. Keep selected-session routing correct under multi-device use.
- Add Swift Testing unit coverage for the pure builder, including:
  - expected alternating serpentine order;
  - containment inside the rectangle;
  - lane spacing in metres against a known CoreLocation reference;
  - portrait and landscape rectangles / orientation choice;
  - narrow rectangle and invalid-input edge cases;
  - a guard against duplicate consecutive points or repeated lane segments;
  - a practical point-count cap for very large/dense requests.
- Add targeted UI/state coverage only where deterministic and proportionate. At minimum, ensure the
  existing test suites compile and document a manual smoke check for gesture selection and route
  playback/export.
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

