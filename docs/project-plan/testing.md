# Testing Strategy

**Status:** Unit suites implemented and running in CI; integration and smoke tests remain TODO.

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
- `TrailMateUITests` is skipped in the shared scheme: both files are empty Xcode templates, and
  XCUITest's app-automation needs TCC permissions that make it the classic headless flake. Re-enable
  in the scheme when real UI tests exist.

## CI

`.github/workflows/swift.yml` runs two parallel jobs on every push/PR to `main`:

- **build** — `packaging/release.sh` (full DMG build), unchanged.
- **test** — rebuilds `PythonResources/` (the app's Resources phase needs it; the
  python-build-standalone download is cached on `packaging/.cache`), then runs the
  `xcodebuild test` command above with ad-hoc signing and `-skip-testing:TrailMateUITests`.
  The `.xcresult` bundle is uploaded as an artifact when the job fails.

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

## Unit Tests (TODO)

- **`DaemonProtocolTests`** — fake daemon process that records commands; verify `DaemonBridge`
  sends correct command strings and parses responses. Deferred until the protocol needs to change.
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
2. `DaemonProtocolTests` — needs a fake daemon harness; defer until the protocol stabilizes.
3. Smoke-test checklist — write it down and run it manually for the next release; automate piecewise later.
