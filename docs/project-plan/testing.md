# Testing Strategy

## Unit Tests (automated, fast, run on every save)

- `CoordinateMathTests` — flat-projection math, distance calc, interpolation correctness vs. known reference points (e.g. Taipei 101 → Taipei Main Station distance should match Google's value to within 1%).
- `NavigationEngineTests` — feed a fixed polyline, run the engine with mocked time, assert emitted coordinates match expected interpolation.
- `DaemonProtocolTests` — fake daemon process that records commands; verify DaemonBridge sends correct command strings and parses responses.
- `RouteVMTests` — search, From/To state transitions, route calculation result handling.

## Integration Tests (semi-automated, slower)

- Daemon round-trip with a real pymobiledevice3 in mock mode (no actual device).
- XPC handshake with the privileged helper (install, connect, ping, uninstall).

## Manual Smoke Tests (run before tagging a release)

Checklist in `Tests/IntegrationTests/ManualSmokeTestPlan.md`:

1. Cold launch with no device connected — UI shows "no device" state.
1. Connect iPhone via USB — appears in sidebar within 5s.
1. First-run sudo prompt — accept; tunnel comes up.
1. Teleport to 5 different cities; verify on the iPhone each time.
1. Route from your home to your office; play at 10x; arrives at correct end coordinate.
1. Joystick: connect controller, push stick, verify smooth movement.
1. Pull USB mid-session — UI shows TUNNEL_DOWN; reconnect cable; recovers.
1. Quit the app — verify no orphaned processes (`ps aux | grep -E "tm_daemon|TrailMateHelper"`).
