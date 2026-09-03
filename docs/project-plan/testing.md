# Testing Strategy

**Status:** Unit suites implemented; CI runs them on every push/PR. Integration and smoke tests remain TODO.

## Running the tests

```bash
xcodebuild test -project TrailMate.xcodeproj -scheme TrailMate -destination 'platform=macOS'
```

- The test target is hosted in TrailMate.app (`TEST_HOST`), so `xcodebuild test` builds and
  launches the app bundle. **Don't run it while a live TrailMate session is open** — the test
  host is a second instance sharing the same bundle id and defaults. Build-only verification
  (`xcodebuild build-for-testing`) is safe alongside a live session.
- Because the app bundle embeds `PythonResources/` (gitignored), a fresh checkout or worktree
  needs it present before any test build: run `./packaging/build.sh`, or in a worktree symlink
  it from the main checkout (`ln -s ../TrailMate/PythonResources PythonResources`).
- Headless runs (CI, agents) should add ad-hoc signing overrides to avoid keychain prompts:
  `CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`.
- The plain command above runs unit **and** UI suites; the UI tests launch the app and drive it
  via accessibility, so the Mac must have a GUI session (and the terminal may need an
  Automation/Accessibility grant on first run). Unit-only:
  `-skip-testing:TrailMateUITests`; UI-only: `-only-testing:TrailMateUITests`.

## CI

`.github/workflows/swift.yml` runs three parallel jobs on every push/PR to `main`:

- **build** — `packaging/release.sh` (full DMG build), unchanged.
- **test** — rebuilds `PythonResources/` (the app's Resources phase needs it; the
  python-build-standalone download is cached on `packaging/.cache`), then runs the
  `xcodebuild test` command above with ad-hoc signing and `-skip-testing:TrailMateUITests`.
  The `.xcresult` bundle is uploaded as an artifact when the job fails.
- **ui-test** — same setup, `-only-testing:TrailMateUITests`. Separate job so an
  XCUITest/TCC flake never taints the unit-test signal.

## Unit Tests (implemented)

| Suite | Covers |
|---|---|
| `CoordinateMathTests` | Flat-ENU math vs known references: Taipei 101 → Taipei Main Station distance within 1% (per the CLAUDE.md "Always do" rule), integrator steps cross-checked against CoreLocation geodesics incl. high-latitude cos scaling, NavigationEngine tick tangent direction/magnitude, and deviation distance against the prior CoreLocation segment reference. |
| `JoystickEngineTests` | Dead-zone input returns nil so an armed idle joystick contributes no aggregator activity; above-dead-zone input still returns velocity. |
| `PositionIntegratorTests` | reset/clear/no-op guards; closed-form 1 s straight line at walking speed; multi-step accumulation. |
| `LocationNoiseTests` | σ=0 identity; mean ≈ 0 and sample σ ≈ configured σ over 10 000 samples (tolerances ≥10 standard errors — the RNG isn't seedable, so tests are statistical but unflakeable in practice). |
| `GPXServiceTests` | Generate→parse round-trips (plain and timestamped), speed-derived timestamp spacing, `trkpt`/`rtept` acceptance, malformed-point skipping. |
| `RouteMathTests` | Segment joining/dedup tolerance behavior. |
| `NavigationEngineLoopTests` | Loop playback boundary math (restart / ping-pong / counts). |
| `NavigationEngineSeekTests` | Scrubber/seek interpolation math. |
| `SimulationActorReplayTests` | Integrator reset on re-play through the actor seam. |
| `SimulationActorAttachTests` | Device-mirror-on-connect (epic 028): attaching a backend immediately pushes the current red dot, and re-attaching after an offline move mirrors the new position. Uses a recording backend at the actor seam — the UI mock backend swallows locations, so this is the only place the mirror is observable. |
| `StrokeGeometryTests` | Hand-drawn stroke smoothing (Chaikin) + resampling. |
| `CommandProtocolTests` | AI command-layer value types: verb parsing (case, whitespace, missing/invalid args), JSON response encoding (optionals omitted), greeting line. |
| `CommandDispatchTests` | Multi-device routing (epic 012): `TELEPORT <A>` moves only A's integrator (A-never-moves-B), unknown vs not-connected UDIDs return the right codes, STATUS reports per-device state. Uses ≥2 sessions via a DEBUG `bindConnectedForTesting` seam (no tunnel/daemon). |
| `CoordinateFormatTests` | Direct location entry (epic 027): decimal-degrees `lat, lon` parsing (whitespace/signs accepted, out-of-range and garbage rejected) and the paste-able clipboard formatting round-trip. |
| `SavedItemsLibraryTests` | Saved-items library (epic 029): `LibraryOrder` drag-reorder/sort + category-assignment persistence, and `MapRegionMath` auto-pan framing for a selected saved location/route. Pure, nonisolated helpers. |
| `TunnelBrokerReclaimTests` | Stale-tunneld reclaim loop (epic 031) via an injected probe/shutdown: skips when nothing's listening, reclaims then confirms the port frees, and reports failure when a tunneld won't die. No networking. |
| `CoverageRouteBuilderTests` | Sweeping-mode serpentine geometry (epic 030): alternating lane order, a square centered on the selected point with side exactly `2 × radius`, containment plus a first point on the west edge, 70 m lane spacing against a CoreLocation reference, byte-identical output for identical inputs, the narrow-square single-lane case, invalid-input and point-cap failures, and `length ÷ speed` estimates. Distances are checked with `CLLocation.distance`, not the builder's own projection, so the suite is an independent oracle. Also covers `WanderMode(persisted:)`'s fallback to Random. Pure, nonisolated helper — no router, no map. |
| `SweepAreaHandoffTests` | The other half of epic 030, in the same file: `AppState.sweepArea` reaches the selected session's `routeCoordinates`, and reset-start leaves the marker on the square's first edge point rather than the selected center (asserted as "within a tick of the edge point, ~a half-side away from the center"). An invalid sweep leaves the loaded route untouched and logs the failure. Device-free — the sweep drives the local red dot like any other route source. |
| `UpdaterConfigurationTests` | Sparkle's required signed-feed policy remains paired with verification before archive extraction, preventing the fatal updater startup configuration shipped in v2.1.2. |

## UI Tests (implemented)

`TrailMateUITests` is a smoke suite. Launch shows the main window with the Connection
section and (untouched against a real device — it raises an admin dialog) Connect button.
Coverage:

- **Sidebar log (epic 025).** The Log section exists; forced open via `--uitest-expand-log`
  it shows the View Full Log button. A separate test drives the real disclosure (the
  sidebar's only disclosure triangle — the label text isn't the toggle) to expand/collapse
  and asserts the choice survives a full relaunch, ending collapsed to restore the default.
- **Offline control model (epic 028).** At a plain launch, before any Connect, the core
  sections — Go to Location, Route, Joystick — and the coordinate field all render, and no
  Disconnect is shown: the control surface is usable with no device. The device-mirrors-the-
  red-dot-on-connect half is a unit test (`SimulationActorAttachTests`), not here, because
  the mock backend swallows locations.
- **Connected device identity (epic 026).** Connecting the mock device (`--uitest-mock-
  connection`) shows Disconnect and a switcher row whose label carries the device name
  ("Mock iPhone") and "Connected" status — the sidebar status pill. (The menu-bar device-name
  mirror isn't UI-tested — MenuBarExtra content isn't reliably queryable; it's on the manual
  checklist.)
- **Direct location entry (epic 027).** The coordinate field keeps "Go" disabled until the
  text parses; a valid `lat, lon` enables it, and committing reveals "Copy Current
  Coordinate" — all with no device (also an offline-model assertion). Place search → Go isn't
  UI-tested (MapKit local search needs network and returns nondeterministic results); the
  `lat, lon` parser is covered by `CoordinateFormatTests`.
- **Settings & preferences.** ⌘, opens Settings with the GPS-noise and restore-on-launch
  controls, and ⌘W closes it; settings persistence is real — the restore-on-launch toggle is
  flipped, the app fully relaunched, the value asserted, then flipped back; the language
  picker and Wander presets get the same relaunch round-trip.
- **Wander modes (epic 030).** Opened via `--uitest-open-wander`: Random (the factory
  default) shows the duration presets and no spacing field; selecting Sweeping hides duration,
  reveals lane spacing at its 70 m default, keeps the shared radius, and leaves Start enabled
  — which is itself the assertion that the geometry built, since Sweeping only enables Start
  on a successful build. A typed spacing plus the mode survive a full relaunch, and the test
  parks the sheet back on Random / 70 m. The segmented mode picker exposes its segments as
  `radioButtons` (`sheet.radioButtons["Sweeping"]`); the sweep math itself is
  `CoverageRouteBuilderTests`, not here.

Every test leaves user preferences as it found them (UI tests run against the real
`com.sh.TrailMate` defaults). Deliberately device-free and data-free otherwise, so the suite
passes identically on a clean CI user and a dev Mac.

**Test-only launch hooks (DEBUG builds only; `UITestSupport.swift`).**

- `--uitest` (passed on every UI-test launch) skips the real device lister, so its
  Bonjour/usbmux scan never raises the macOS Local Network permission dialog — that
  `UserNotificationCenter` prompt sits on top of the UI and blocks automation on a clean CI
  user (it doesn't appear locally once the permission has been answered).
- `--uitest-mock-connection` makes device discovery return a fake "Mock iPhone" and
  `connect()` attach a `MockSimulationBackend` — no tunnel, no admin prompt, no daemon;
  commands are accepted and location updates swallowed. This is the "record-only mock"
  backend the `SimulationBackend` protocol was shaped for, and it unlocks any
  connected-gated UI (`testMockConnectionEnablesConnectedUI` exercises the connect flow).
- `--uitest-open-wander` opens the Wander sheet at launch with a synthetic center, so the
  preset-persistence test (epic 018's contract — selection saved on every change, not just
  Start) can verify a full relaunch round-trip without driving the map long-press, which
  trips XCUITest's alert-interruption handling on CI. The epic 030 mode test reuses it — the
  mode is persisted on the same terms, so it needs the same round-trip.
- `--uitest-expand-log` forces the sidebar Log disclosure open at launch. Epic 025 made the
  log collapsed by default and persists the choice, so "View Full Log" only renders when
  expanded; the hook makes it deterministically present without mutating the persisted
  `sidebarLogExpanded` preference.

Query gotcha for future tests: SwiftUI exposes sidebar headers/buttons as accessibility
*labels* but Form/row `Text`s as *values* — match the latter with a `value ==` predicate.

## Unit Tests (TODO)

- **`DaemonProtocolTests`** — fake daemon process that records commands; verify `DaemonBridge`
  sends correct command strings and parses responses. Needs a fake-daemon harness; build it the
  next time the protocol changes.
- **`RouteVMTests`** — search, From/To state transitions, route calculation result handling.
- **`RecorderServiceTests`** — record → persist → reload → coords identical. Deferred: the
  app-hosted test process shares the real `~/Library/Application Support/TrailMate/`, so this
  needs injectable storage paths first.

## Integration Tests (TODO — semi-automated, slower)

- Daemon round-trip with a real pymobiledevice3 in mock mode (no actual device).
- XPC handshake with the privileged helper, once SMAppService is wired up (see [features.md's deferred items](../technical/features.md#deferred--dropped)).

## Manual Smoke Tests (TODO — checklist to run before tagging a release)

To live in `TrailMateTests/ManualSmokeTestPlan.md` once written.

1. Cold launch with no device connected — UI shows "no device" state.
1. Connect iPhone via USB — appears in sidebar within ~5 s.
1. First-run sudo prompt — accept; tunnel comes up.
1. Teleport to 5 different cities; verify on the iPhone each time.
1. Route from home to office; play at 10×; arrives at correct end coordinate.
1. Joystick: connect controller, push stick, verify smooth movement.
1. Composite control: mid-route, push the stick perpendicular; off-route indicator appears; press Rejoin; marker snaps back.
1. Recording: start, joystick around for 2 min, stop; today's recording appears in the sidebar; Replay reproduces the trajectory.
1. Wi-Fi: pair via USB once, run `pymobiledevice3 lockdown wifi-connections on`, reboot device, confirm it appears under "Wi-Fi" in the picker.
1. Pull USB mid-session — UI shows tunnel-down; reconnect cable; re-Connect recovers cleanly.
1. Sleep the Mac mid-session — on wake, UI is in `.disconnected` state (DVT session cannot survive sleep).
1. Quit the app — verify no orphaned processes (`ps aux | grep -E "tm_daemon|tm_tunnel|pymobiledevice3"`).

Items the automated suites can't cover (UI-fragile or device-bound), so verify here:

1. Menu-bar device name (epic 026): connect a device; the menu-bar item reads `<name> · Connected · <activity>` (MenuBarExtra content isn't UICTest-queryable).
1. Place search → Go (epic 027): type a place name, pick a result; the red dot teleports there and the map pans to frame it (needs live MapKit local search).
1. Saved-items library (epic 029): drag to reorder a saved location and a saved route; assign each to a category via the row context menu; relaunch and confirm both order and category stick. Selecting a saved item auto-pans the map to frame it. (Reorder/auto-pan *math* is unit-tested in `SavedItemsLibraryTests`; the drag/context-menu UI is checked here.)
1. Map-control overlap (epic 024): with the joystick active mid-route, confirm the map controls and off-route indicator don't occlude each other (layout/occlusion, asserted visually).
1. Sweeping coverage (epic 030): right-click the map → **Wander nearby…** → **Sweeping**, 500 m at 70 m spacing; confirm the sheet's square-side/lane caption and distance-time estimate, press Start, and watch the marker jump to the west edge of the southernmost lane and then mow the square lane by lane. Then scrub, loop, Record, **Save Route…**, **Export GPX** on the same route, and switch back to **Random** to confirm its duration presets, road-routed output and auto-play are untouched. (Geometry is unit-tested in `CoverageRouteBuilderTests`; what's checked here is the on-device teleport-then-sweep and the shared route surfaces.)
1. Sparkle bootstrap/update (epics 038 and 047): the published v2.1.3 DMG was installed and **Check for Updates…** successfully reached the signed feed on 2026-09-03. The stable v2.2.0 production run then validated its exported app, staged copy, exact app mounted from the finished DMG, every appcast DMG tag/filename version pair, notarization, and Pages deployment. Use that existing v2.1.3 install to download, validate, install, and relaunch into v2.2.0. Also confirm automatic-check/download preferences persist, a deliberately tampered archive is rejected, and the manual GitHub DMG remains usable if Pages is unavailable. Full signed DMG updates are the supported path while delta generation is disabled; v2.1.2 cannot self-update and must be replaced manually.

## Implementation order for the remaining suites (suggested)

1. `RecorderServiceTests` — once storage paths are injectable.
2. `RouteVMTests` — pure state-machine coverage of search and From/To transitions.
3. `DaemonProtocolTests` — needs a fake daemon harness; build it the next time the protocol changes.
4. Smoke-test checklist — write it down and run it manually for the next release; automate piecewise later.
