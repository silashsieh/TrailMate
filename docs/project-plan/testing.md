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
| `CoordinateMathTests` | Flat-ENU math vs known references: Taipei 101 → Taipei Main Station distance within 1% (per the CLAUDE.md "Always do" rule), integrator steps cross-checked against CoreLocation geodesics incl. high-latitude cos scaling, NavigationEngine tick tangent direction/magnitude. |
| `PositionIntegratorTests` | reset/clear/no-op guards; closed-form 1 s straight line at walking speed; multi-step accumulation. |
| `LocationNoiseTests` | σ=0 identity; mean ≈ 0 and sample σ ≈ configured σ over 10 000 samples (tolerances ≥10 standard errors — the RNG isn't seedable, so tests are statistical but unflakeable in practice). |
| `GPXServiceTests` | Generate→parse round-trips (plain and timestamped), speed-derived timestamp spacing, `trkpt`/`rtept` acceptance, malformed-point skipping. |
| `RouteMathTests` | Segment joining/dedup tolerance behavior. |
| `NavigationEngineLoopTests` | Loop playback boundary math (restart / ping-pong / counts). |
| `NavigationEngineSeekTests` | Scrubber/seek interpolation math. |
| `SimulationActorReplayTests` | Integrator reset on re-play through the actor seam. |
| `StrokeGeometryTests` | Hand-drawn stroke smoothing (Chaikin) + resampling. |

## UI Tests (implemented)

`TrailMateUITests` is a smoke suite: launch shows the main window with the Connection
section and (untouched — it raises an admin dialog) Connect button; the sidebar Log
section and View Full Log button exist; ⌘, opens Settings with the GPS-noise and
restore-on-launch controls, and ⌘W closes it; and settings persistence is real — the
restore-on-launch toggle is flipped, the app fully relaunched, the value asserted, then
flipped back so the suite leaves user preferences as it found them (UI tests run against
the real `com.sh.TrailMate` defaults). Deliberately device-free and data-free otherwise,
so it passes identically on a clean CI user and a dev Mac. Query gotcha for future tests:
SwiftUI exposes sidebar headers/buttons as accessibility *labels* but Form/row `Text`s as
*values* — match the latter with a `value ==` predicate.

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

## Implementation order for the remaining suites (suggested)

1. `RecorderServiceTests` — once storage paths are injectable.
2. `RouteVMTests` — pure state-machine coverage of search and From/To transitions.
3. `DaemonProtocolTests` — needs a fake daemon harness; build it the next time the protocol changes.
4. Smoke-test checklist — write it down and run it manually for the next release; automate piecewise later.
