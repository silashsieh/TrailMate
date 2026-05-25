# TrailMate

> *A native macOS companion for simulating real-time GPS location on iOS devices.*

-----

## Project Description

TrailMate is a personal-use SwiftUI macOS application that controls an iPhone's GPS location in real time. It is designed for iOS developers and testers who need to exercise location-dependent code paths without physically moving — testing a ride-share pickup flow, a weather widget in another timezone, an AR walking experience, or a store-locator from across the world.

TrailMate offers three control modes:

1. **Teleport** — click anywhere on a map to instantly set the device's location.
1. **Route** — enter From/To, calculate a walking/cycling/driving route, and play it back at configurable speed.
1. **Joystick** — drive the device's location in real time with a game controller or on-screen virtual stick.

The Mac acts as a controller; the iPhone reports the simulated coordinates to every app on the device through standard CoreLocation. No app is installed on the iPhone, and no jailbreak is required.

-----

## Goals & Non-Goals

### Goals

- Real-time GPS simulation on a paired iOS 17+ device (validated on iOS 26.4).
- Three control modes: teleport, route, joystick.
- Native macOS look-and-feel: SwiftUI, MapKit, standard NSWindow chrome.
- Single Mac, single iPhone, single user — build-from-source from a free Apple ID.
- Codebase suitable as a portfolio reference (clean architecture, documented decisions).

### Non-Goals

- **No iOS app component.** Everything runs on the Mac. No sideloading, no jailbreak.
- **No anti-detection.** The device reports `CLLocation.sourceInformation.isSimulatedBySoftware == true`. Apps that check for this (e.g. Pokémon GO) will see through us. Not a goal to defeat.
- **No App Store distribution.** Personal tool. Build from source, run unsigned.
- **No cross-platform.** macOS only. Windows users have LocWarp; Linux users have raw pymobiledevice3.
- **No legacy iOS support.** iOS 17 introduced the personalized DDI + RSD tunnel; that's the minimum target. Users on iOS ≤16 should use Schlaubischlump's LocationSimulator.
- **No multi-device orchestration.** One iPhone at a time. (Possible v3 extension; not v1.)
- **No production hardening.** This is a single-user dev tool, not a fleet-simulation platform.

-----

## Target Users & Use Cases

Primary user: **myself** (Harry), a software engineer doing iOS-adjacent work and interview prep. Secondary: other iOS developers and QA engineers who find this on GitHub.

Representative use cases:

- *"I need to test that my app's geofencing fires correctly when the user enters Da'an district."*
- *"My app behaves weirdly when the user is moving at driving speed in a tunnel. I need to simulate that without a car."*
- *"I want to step through a 5km walking route to verify my distance tracker stays accurate."*
- *"I'm reviewing a CoreLocation bug report from a user in Osaka — I need to put my dev device there."*

-----

## Project Structure

```
TrailMate/
├── README.md
├── .gitignore
│
├── TrailMate/                         # Swift sources (flat layout)
│   ├── TrailMateApp.swift             # @main entry point
│   ├── AppState.swift                 # root @Observable — connection, mode, all state
│   ├── ContentView.swift              # NavigationSplitView with sidebar + map
│   ├── DaemonBridge.swift             # Process wrapper, stdin/stdout IPC with daemon
│   ├── NavigationEngine.swift         # 10Hz route playback with polyline interpolation
│   ├── JoystickEngine.swift           # 20Hz control loop (controller/virtual stick/WASD)
│   ├── VirtualJoystickView.swift      # On-screen circular pad with DragGesture
│   ├── LocationSearch.swift           # MKLocalSearchCompleter wrapper
│   ├── GPXService.swift               # GPX import (XMLParser) and export
│   └── Assets.xcassets
│
├── TrailMate.xcodeproj               # Xcode project (hand-managed, no XcodeGen)
│
├── PythonDaemon/
│   └── tm_daemon.py                   # persistent daemon: SET/SETQ/CLEAR/HEARTBEAT/QUIT
│
└── docs/                              # all detailed documentation
    ├── README.md                      # table of contents
    ├── claude-code-notes.md           # coding conventions, do/don't rules
    ├── project-plan/
    │   ├── phases.md                  # implementation phases with steps and results
    │   ├── risks.md                   # risk register
    │   └── testing.md                 # testing strategy
    └── technical/
        ├── architecture.md            # layer diagram, process topology, daemon protocol
        ├── tech-stack.md              # framework choices and target versions
        ├── features.md                # V1 feature spec (F1–F7) and deferred items
        └── decisions.md               # key technical decisions (D1–D6)
```

-----

## Documentation

See [docs/README.md](docs/README.md) for the full documentation index — architecture, features, tech stack, decisions, project plan, and development notes.

-----

## Implementation Status

All phases 0–4 completed on 2026-05-13. See [docs/project-plan/phases.md](docs/project-plan/phases.md) for details.

| Phase | Goal | Status |
|-------|------|--------|
| 0 — Foundation | Verify pymobiledevice3 on real device | Done |
| 1 — Teleport MVP | Click map → iPhone teleports | Done |
| 2 — Route Mode | Search → calculate → play back route | Done |
| 3 — Joystick Mode | Controller / virtual stick / WASD → real-time movement | Done |
| 4 — Productionize | Heartbeat, GPX import/export, saved waypoints, log sheet | Done |
| 5 — Polish & Release | Screenshots, docs, CI, localization | Optional |

-----

## References

- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3)
- [libimobiledevice](https://libimobiledevice.org/)
- [Apple MapKit](https://developer.apple.com/documentation/mapkit)
- [GameController.framework](https://developer.apple.com/documentation/gamecontroller)
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [python-build-standalone](https://github.com/indygreg/python-build-standalone)
- [SimVirtualLocation](https://github.com/nexron171/SimVirtualLocation) — reference architecture
- [LocWarp](https://github.com/keezxc1223/locwarp) — iOS 26.4 quirks documentation
- [CLLocationSourceInformation](https://developer.apple.com/documentation/corelocation/cllocationsourceinformation)

-----

## License

MIT.
