# Testing Strategy

**Status:** Not yet implemented.

The `TrailMateTests` target exists in the Xcode project but only contains the default Swift-Testing template (`@Test func example()` with an empty body). No production tests, integration tests, or smoke-test checklist exist on disk. The CI workflow (`.github/workflows/swift.yml`) runs `packaging/release.sh` (build) only — there is no `xcodebuild test` step.

Everything below is the plan, not the current state. Treat each item as a TODO.

## Unit Tests (TODO — automated, fast, run on every save)

- **`CoordinateMathTests`** — flat-projection math, distance calc, interpolation correctness vs. known reference points (e.g. Taipei 101 → Taipei Main Station distance should match Google's value to within 1%).
- **`NavigationEngineTests`** — feed a fixed polyline, run the engine with mocked time, assert emitted coordinates match expected interpolation.
- **`DaemonProtocolTests`** — fake daemon process that records commands; verify `DaemonBridge` sends correct command strings and parses responses.
- **`RouteVMTests`** — search, From/To state transitions, route calculation result handling.
- **`LocationNoiseTests`** — mean/variance over N samples, distribution shape.
- **`PositionIntegratorTests`** — closed-form check against a 1-second straight-line at known speed.
- **`RecorderServiceTests`** — record → persist → reload → coords identical.

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

## Implementation order (suggested)

1. `CoordinateMathTests` and `LocationNoiseTests` first — pure functions, no async, no fixtures. Trivially valuable.
2. `NavigationEngineTests` with mocked time — locks in the route-playback contract before any refactor.
3. `PositionIntegratorTests` — small and isolated; gives confidence to refactor the composite path.
4. `DaemonProtocolTests` — needs a fake daemon harness; defer until the protocol stabilizes.
5. Smoke-test checklist — write it down and run it manually for the next release; automate piecewise later.
