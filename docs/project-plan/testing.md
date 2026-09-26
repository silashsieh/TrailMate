# Testing Strategy

**Status (2026-09-26):** The integrated unit suite passed (241 tests). The UI gate remains open:
the saved-route drag probe did not persist an order change, and a later isolated-bundle-ID UI run
lost macOS accessibility authorization after five passes. Manual smoke checks remain pending.

## Running the tests

```bash
xcodebuild test -project TrailMate.xcodeproj -scheme TrailMate -destination 'platform=macOS'
```

- The test target is hosted in TrailMate.app (`TEST_HOST`), so `xcodebuild test` builds and
  launches the app bundle. **Don't run it while a live TrailMate session is open.** Test
  launches use isolated defaults and runtime paths; build-only verification
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
- Local app-hosted UI runs should build with a unique test-only `PRODUCT_BUNDLE_IDENTIFIER`
  override and unique DerivedData, then use the same DerivedData for `test-without-building`.
  On the first WP10 UI run, macOS wrote to the personal
  `com.shihlien.TrailMate.plist` despite the injected defaults suite. AppKit window/status-item
  state follows the bundle ID; `com.sh.TrailMate.WP10.Isolated` wrote to its own plist and
  left the personal plist unchanged in later comparisons. The project and release bundle ID
  remain unchanged. Hold the test-run lease and close the personal instance first.

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
| `CommandDispatchTests` | Every AI verb's positive/failure path, per-device STATUS, CONNECT idempotency and GUI focus, A-never-moves-B, and clean recording versus noisy backend coordinates. Fake discovery, backend, connection attempter, clock, and temporary runtime avoid live services. |
| `CommandServerSocketTests` | Real Unix-socket lifecycle and framing with a fake dispatcher: owner-only directory, greeting, fragmented/multiple/oversized lines, client close, stale node, toggle, and stop/start epochs under a private temporary root. |
| `AppRuntimePathsTests`, `MonotonicTimeSourceTests` | Hosted-process and explicit runtime/defaults isolation, live-path compatibility without writes, and controllable monotonic time. |
| `AppStateSessionTests`, `DeviceSessionRouteTests` | Session add/remove/selection, joystick and tuning ownership, connected-name tracking, independent routes, offline build/play/stop/save, search success/failure, coordinate copy, and disconnect/re-attach mirroring. Uses fake routing/search/backends and an isolated clipboard writer. |
| `DeviceDiscoveryServiceTests`, `TunnelBrokerMapTests` | USB/Wi-Fi/malformed/missing discovery rows; fake UDID maps, usbmux preference/fallback, endpoint changes, errors, and controllable timeout. No real lister or localhost tunneld. |
| `DaemonPipeTests`, `DeviceSessionLossTests`, `DeviceSessionReconnectTests` | Fake pipe READY/reply/timeout/EPIPE/EOF/exit, loss isolation, explicit disconnect and sleep/wake, exact retry/cancel/exhaustion transitions on a manual clock. No real daemon, tunnel, or admin dialog. |
| `CoordinateFormatTests` | Direct location entry (epic 027): decimal-degrees `lat, lon` parsing (whitespace/signs accepted, out-of-range and garbage rejected) and the paste-able clipboard formatting round-trip. |
| `SavedItemsLibraryTests` | Saved-items library (epic 029): `LibraryOrder` drag-reorder/sort + category-assignment persistence, and `MapRegionMath` auto-pan framing for a selected saved location/route. Pure, nonisolated helpers. |
| `SavedItemsPersistenceTests` | Temporary-root route files/order sidecar and isolated-defaults waypoint round-trips, rename/category/delete, and legacy JSON compatibility. |
| `RecordingCaptureTests`, `RecordingsLibraryTests`, `RecordingLifecycleTests` | Per-session clean-point capture and monotonic timestamps, temporary-root GPX/index lifecycle, two-device isolation, selected-only visibility, explicit Stop persistence, and quit/removal discard. |
| `SimulationLoopTests` | Manual-clock idle suppression/re-emission, active/playback UI cadence caps, Rejoin reset, and single timed route abort. |
| `MenuBarStatusFormatterTests`, `ActivationPolicyDecisionTests` | Pure menu status and Dock/menu-bar reachability decisions across session, activity, and preference combinations. |
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
- **Integrated v2.3.0 UI flows.** Isolated fixtures drive offline route Play/Stop/Save Route,
  two-device selection and recording visibility, retry cancellation, updater toggle round-trips
  and command presence, and menu/Dock reachability settings. The saved-route drag probe currently
  fails to produce the order sidecar, so its UI wiring remains a release finding. The complete
  drag matrix and MenuBarExtra interaction remain in the manual plan.

Every UI test launches with its own `UserDefaults` suite and temporary runtime root, then removes
those fixtures after the app terminates. Hosted unit tests use a separate process-level domain/root
and explicit temporary roots for AppState fixtures. Sparkle's test controller does not construct
the live updater, read its app-domain preferences, or contact the feed. The UI app still needs the
test-only bundle ID override above to isolate AppKit's own preference writes. Tests must not run
beside a personal TrailMate instance.

**Test-only launch hooks (DEBUG builds only; `UITestSupport.swift`).**

- `--uitest` (passed on every UI-test launch) skips the real device lister, so its
  Bonjour/usbmux scan never raises the macOS Local Network permission dialog — that
  `UserNotificationCenter` prompt sits on top of the UI and blocks automation on a clean CI
  user (it doesn't appear locally once the permission has been answered).
- `--uitest-mock-connection` makes device discovery return a fake "Mock iPhone" and
  `connect()` attach a `MockSimulationBackend` — no tunnel, no admin prompt, no daemon;
  commands are accepted and location updates swallowed. This is the "record-only mock"
  backend the `SimulationBackend` protocol was shaped for, and it unlocks any
  connected-gated UI (`testMockConnectionShowsConnectedDeviceNameAndStatus` exercises the connect
  flow).
- `--uitest-open-wander` opens the Wander sheet at launch with a synthetic center, so the
  preset-persistence test (epic 018's contract — selection saved on every change, not just
  Start) can verify a full relaunch round-trip without driving the map long-press, which
  trips XCUITest's alert-interruption handling on CI. The epic 030 mode test reuses it — the
  mode is persisted on the same terms, so it needs the same round-trip.
- `--uitest-expand-log` forces the sidebar Log disclosure open at launch. Epic 025 made the
  log collapsed by default and persists the choice, so "View Full Log" only renders when
  expanded; the hook makes it deterministically present without mutating the persisted
  `sidebarLogExpanded` preference.
- `--uitest-two-devices`, `--uitest-offline-route`, `--uitest-reconnecting`, and
  `--uitest-saved-route-drag` seed only the isolated test runtime. The recovery clock is parked
  so cancellation needs no real five-second polling delay.

Query gotcha for future tests: SwiftUI exposes sidebar headers/buttons as accessibility
*labels* but Form/row `Text`s as *values* — match the latter with a `value ==` predicate.

## Coverage status and release gates

The acceptance-level matrix remains in [[033-refresh-test-coverage]]. Its deterministic cases now
have dedicated unit or UI suites for multi-session ownership, AI dispatch and socket framing,
connection/discovery failure, offline routing, saved-item persistence, recording isolation,
simulation cadence, updater preferences, and menu/Dock decisions. The full integrated unit suite
passed; the UI drag probe and later accessibility failure keep the UI gate open. Failed `.xcresult`
bundles are recorded in [v2.3.0-release-readiness](v2.3.0-release-readiness.md).

Real USB/Wi-Fi discovery, tunneld authorization, device location delivery, live MapKit search and
routing, sleep/wake, saved-item drag across every section, MenuBarExtra interaction, and the signed
Sparkle update are environment-bound checks. They are tracked in the permanent
[ManualSmokeTestPlan.md](../../TrailMateTests/ManualSmokeTestPlan.md), with an owner, expected
result, status, and evidence field for each row. A debug app with ad-hoc signing is not the release
artifact and cannot pass the signing or production-update rows.

## Later integration candidates

- A daemon round-trip against a controlled pymobiledevice3 mock without a device.
- An XPC handshake for a privileged SMAppService helper if that separate deferred feature ships.
