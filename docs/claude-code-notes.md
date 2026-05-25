# Claude Code Working Notes

> *This is the de facto `CLAUDE.md` for TrailMate. When working on TrailMate via Claude Code, read this first.*

## Project Context

- **Owner:** Harry, solo developer, working on personal Mac (Apple Silicon, macOS 26.4) and personal iPhone (iOS 26.4).
- **Apple Developer Account:** none required; everything runs locally.
- **Reference implementations to consult, in priority order:**
1. `pymobiledevice3` source — authoritative for transport behavior.
1. `nexron171/SimVirtualLocation` — closest working OSS architecture (Swift + pymobiledevice3).
1. `keezxc1223/locwarp` README — best documentation of iOS 26.4-specific quirks.
1. `Schlaubischlump/LocationSimulator` — UI/UX inspiration only; transport is obsolete.

## Coding Conventions

- **Swift:** strict concurrency, async/await over completion handlers, `@Observable` over `ObservableObject`, value types where possible.
- **Error handling:** throwing functions over `Result`; one app-wide `TrailMateError` enum with descriptive cases. No swallowing errors silently — surface in the Log sheet at minimum.
- **Logging:** `os.Logger` with subsystem `com.harry.trailmate`, categories per service.
- **Files:** one type per file; file name matches type name.
- **Tests:** prefer Swift Testing (`@Test`, `#expect`) over XCTest for new code.
- **Comments:** explain *why*, not *what*. The code should explain the what.
- **Commits:** Conventional Commits style (`feat:`, `fix:`, `refactor:`, `docs:`, `test:`).

## Things to Always Do

- When adding a new daemon command, update both the Swift `DaemonBridge` and `tm_daemon.py` and `docs/daemon-protocol.md` in the same change.
- When changing the `HelperProtocol`, bump the protocol version constant and handle backwards compat.
- When touching coordinate math, add a unit test with a known-good reference value.
- Before any "this should work on iOS 26.4" claim, point to a verified source (pymobiledevice3 release notes, LocWarp tested-on note, or a personal test against the real device).

## Things to Never Do

- **Never** call `pymobiledevice3` as a one-shot subprocess in a hot path. Always go through the persistent daemon.
- **Never** put location-spoofing logic inside the privileged helper. The helper only manages the tunnel.
- **Never** bundle `Resources/DeveloperDiskImages/` in git. Those are device-specific and large.
- **Never** invent a pymobiledevice3 API that hasn't been verified against the pinned version. If unsure, run the CLI first to confirm flags and output.
- **Never** swallow `TUNNEL_DOWN` silently. The user must see it.

## Decision-Making Heuristics for Ambiguous Tasks

- "Should I add this feature?" — If it's not in the Core Features spec, defer to a later phase. Don't scope-creep.
- "Should I refactor X while I'm here?" — Only if the refactor is in the immediate path of the task. Otherwise file as a TODO.
- "Should I add a dependency?" — Default to no. Swift stdlib + Apple frameworks + pymobiledevice3 should cover 99% of needs.
- "Should I rewrite this in Swift?" — Probably not. The Python daemon line is small and stable; reimplementation is multi-week.
- **Latency budget: ignore anything under 100 ms.** CoreLocation coalesces updates at ~1 Hz on the consumer side, so sub-100ms wire latency is invisible to the apps we're testing. Don't write caveats, benchmarks, or mitigations for latency below that threshold — it's noise. Real concerns start at ~300 ms (perceptible to the human driving the joystick) and at ~1 s (visible stalls in route playback).

## Quick-Reference Commands

```bash
# Build & run debug
xcodebuild -project TrailMate.xcodeproj -scheme TrailMate -configuration Debug build

# Run tests
xcodebuild test -project TrailMate.xcodeproj -scheme TrailMate -destination 'platform=macOS'

# Verify Python daemon standalone
./Resources/python-runtime/bin/python3 PythonDaemon/tm_daemon.py < test_commands.txt

# Smoke test the CLI path (bypass app, for debugging)
sudo pymobiledevice3 lockdown start-tunnel  # terminal 1
pymobiledevice3 developer dvt simulate-location set --rsd <addr> <port> -- 25.0330 121.5654
```
