# Technical Architecture

## Project Structure

```
TrailMate/
├── README.md
├── CLAUDE.md                          # entry point for Claude Code sessions
├── LICENSE.md
├── .gitignore
│
├── TrailMate/                         # Swift sources (flat layout)
│   ├── TrailMateApp.swift             # @main entry point; WindowGroup + Settings scenes
│   ├── AppState.swift                 # root @Observable — connection, route/recorder/waypoint state
│   ├── ContentView.swift              # NavigationSplitView with sidebar + map
│   ├── DaemonBridge.swift             # Process wrapper, stdin/stdout IPC with daemon
│   ├── DeviceDiscoveryService.swift   # USB/Wi-Fi device enumeration via tm_list_devices.py
│   ├── GPXService.swift               # GPX import (XMLParser) and export
│   ├── JoystickEngine.swift           # 20 Hz control loop (controller/virtual stick/WASD)
│   ├── LocationNoise.swift            # Box-Muller Gaussian jitter on every emission
│   ├── LocationSearch.swift           # MKLocalSearchCompleter wrapper
│   ├── NavigationEngine.swift         # route playback: polyline interpolation + loop modes (20 Hz tick)
│   ├── PositionIntegrator.swift       # sums engine velocity vectors; owns authoritative position
│   ├── PythonBundle.swift             # resolves bundled interpreter + script paths
│   ├── RecorderService.swift          # session recording: GPX files + index
│   ├── RouteMath.swift                # polyline helpers (segment joining, distances)
│   ├── RouteStop.swift                # intermediate-stop model for the route planner
│   ├── SavedRoutesStore.swift         # per-route JSON persistence under Application Support
│   ├── SettingsView.swift             # Settings window (⌘,): set-and-forget preferences
│   ├── SimulatedPositionPersistence.swift  # red-dot persistence + launch-restore preference
│   ├── SimulationActor.swift          # off-MainActor core: 20 Hz aggregator, engines, snapshot push
│   ├── SimulationBackend.swift        # backend protocol + events (DaemonBridge implements it)
│   ├── StrokeGeometry.swift           # hand-drawn stroke smoothing + uniform resampling
│   ├── TunnelSupervisor.swift         # privileged tunnel bring-up via osascript, control file
│   ├── VirtualJoystickView.swift      # on-screen circular pad with DragGesture
│   ├── WanderPresetPersistence.swift  # wander sheet radius/duration recall
│   ├── WanderRouteBuilder.swift       # chained MKDirections hops for Wander nearby
│   └── Assets.xcassets
│
├── TrailMate.xcodeproj                # Xcode project (hand-managed, no XcodeGen)
├── TrailMate.entitlements
├── TrailMate.icon
├── TrailMateTests/                    # unit tests (see docs/project-plan/testing.md)
├── TrailMateUITests/
│
├── PythonDaemon/
│   ├── tm_daemon.py                   # persistent daemon: SET/SETQ/CLEAR/HEARTBEAT/QUIT
│   ├── tm_list_devices.py             # one-shot USB + Wi-Fi device lister
│   └── tm_tunnel.sh                   # root-only tunnel starter (parent-watches the host)
│
├── PythonResources/                   # bundled CPython runtime (gitignored; built by packaging/build.sh)
├── packaging/                         # build.sh (Python runtime), release.sh (DMG)
│
└── docs/                              # all detailed documentation
    ├── README.md                      # table of contents
    ├── quick-start.md                 # install / build / first teleport
    ├── project-plan/
    │   ├── scope.md                   # vision, goals and non-goals
    │   ├── process.md                 # how work is planned, tracked, and triaged
    │   ├── playbook.md                # step-by-step PM recipes
    │   ├── roadmap.md                 # generated Dataview view: scheduled by milestone
    │   ├── backlog.md                 # generated Dataview view: unscheduled work
    │   ├── epics/                     # one file per accepted feature/idea (the plan's source of truth)
    │   ├── phases.md                  # frozen historical implementation log
    │   ├── risks.md                   # risk register
    │   └── testing.md                 # test coverage + strategy
    └── technical/
        ├── architecture.md            # this file — structure, layers, processes, protocol
        ├── tech-stack.md              # framework choices and target versions
        ├── features.md                # what ships today, plus dropped/deferred items
        └── decisions.md               # key technical decisions and why
```

## Layer Diagram

```
┌──────────────────────────────────────────────────────────┐
│  SwiftUI Views                                           │  Presentation
│  (ContentView: Sidebar, MapArea, PlaybackProgress,       │
│   VirtualJoystickView, log sheet, SettingsView)          │
├──────────────────────────────────────────────────────────┤
│  AppState (@MainActor @Observable)                       │  Coordinator
│  Connection lifecycle, route/recorder/waypoint state,    │  (MainActor)
│  command shims that forward to SimulationActor.          │
├──────────────────────────────────────────────────────────┤
│  SimulationStateBridge (@MainActor @Observable)          │  UI projection
│  Snapshot fields views observe: simulatedCoordinate,     │  (MainActor)
│  nav playback state/progress, joystick active flag,      │
│  route deviation, recording state. Populated by          │
│  SimulationActor's per-tick snapshot push.               │
├──────────────────────────────────────────────────────────┤
│  SimulationActor                                         │  Simulation core
│  • Owns the engines as nonisolated stored properties.    │  (off MainActor)
│  • 20 Hz aggregator loop, 1 Hz idle jitter, 5 Hz         │
│    deviation check, 2 Hz UI snapshot push.               │
│  • Holds the active SimulationBackend; calls             │
│    setLocationQuiet synchronously on the hot path.       │
│  • Owns the App Nap activity token while attached.       │
│  ├── NavigationEngine (nonisolated)                      │
│  ├── JoystickEngine (nonisolated)                        │
│  ├── PositionIntegrator (nonisolated)                    │
│  └── LocationNoise (nonisolated)                         │
├──────────────────────────────────────────────────────────┤
│  SimulationBackend (protocol)                            │  Abstraction
│  start / stop / sendCommand / setLocationQuiet           │  boundary
│  + events: AsyncStream<SimulationBackendEvent>           │
│  Implemented today by DaemonBridge; future ADB /         │
│  jailbreak-SSH backends slot in here.                    │
├──────────────────────────────────────────────────────────┤
│  DaemonBridge (actor)                                    │  IPC
│  Process mgmt, stdin/stdout protocol. setLocationQuiet   │
│  is nonisolated (cached FileHandle + serial queue) so    │
│  the actor's hot path doesn't cross executors.           │
├──────────────────────────────────────────────────────────┤
│  TunnelSupervisor + tm_tunnel.sh                         │  Privilege
│  Sudo escalation via osascript-with-admin-privileges to  │
│  run pymobiledevice3 lockdown start-tunnel. Status       │
│  shared with the host via a control file.                │
├──────────────────────────────────────────────────────────┤
│  tm_daemon.py (long-lived Python process)                │  Transport
│  ├── pymobiledevice3 tunnel client                       │
│  ├── DVT LocationSimulation handle                       │
│  └── stdin command loop                                  │
├──────────────────────────────────────────────────────────┤
│  RSD tunnel → iPhone DVT service → CoreLocation          │  Device
└──────────────────────────────────────────────────────────┘
```

## Process Topology

Three OS processes cooperate at runtime:

|Process        |Privilege         |Lifetime  |Responsibility                                                                       |
|---------------|------------------|----------|-------------------------------------------------------------------------------------|
|`TrailMate.app`|user              |session   |UI, state, all simulation logic                                                      |
|`tm_tunnel.sh` |root (via sudo)   |per-tunnel|Open the RSD TUN tunnel via `pymobiledevice3 lockdown start-tunnel`; nothing else    |
|`tm_daemon.py` |user              |session   |Persistent pymobiledevice3 + DVT connection                                          |

`tm_tunnel.sh` exists *only* because creating a TUN interface requires root. It does the absolute minimum: starts the tunnel, writes the RSD address+port to a control file the host polls, and parent-watches the host PID so a host crash can't leak the tunnel. It's brought up by `TunnelSupervisor.swift` via `osascript … with administrator privileges`, which gives one auth dialog per session. All location logic stays in the unprivileged app.

The Python daemon is a *long-lived* subprocess. Spawning `pymobiledevice3` per command costs ~500ms–1s in interpreter cold-start, which would kill the joystick experience. Instead, we spawn it once, keep the DVT connection open, and stream `SETQ lat lon\n` lines into its stdin at 20 Hz from the simulation actor.

## Concurrency Topology

Swift 6 strict concurrency, with three isolation domains:

|Domain                |Contents                                                                                                                      |
|----------------------|------------------------------------------------------------------------------------------------------------------------------|
|MainActor             |`AppState`, `SimulationStateBridge`, `RecorderService`, `TunnelSupervisor`, `DeviceDiscoveryService`, `SavedRoutesStore`, views|
|`SimulationActor`     |Engines (nav/joystick/integrator/noise), aggregator + idle-jitter loops, deviation check, snapshot push, App Nap token        |
|`DaemonBridge` (actor)|Process lifecycle, stdin/stdout state, pending-line continuations                                                             |

The engines are marked `nonisolated final class` so the simulation actor can call them synchronously inside a tick — no per-tick `await` hop. The 2 Hz UI throttle lives in the actor's snapshot-push path; the backend still receives every SETQ tick at 20 Hz because `setLocationQuiet` is `nonisolated` on `DaemonBridge` (cached pipe handle + serial queue). A `Thread.sleep(forTimeInterval:)` on MainActor will *not* delay SETQ delivery — that was the failure mode the actor split eliminated.

## Daemon Protocol

Line-delimited text over stdin/stdout. Simple, debuggable with `cat`.

**Mac → Daemon (commands):**

```
SET 25.033 121.5654              # teleport (responds OK)
SETQ 25.033 121.5654             # teleport, fire-and-forget (no response; for high-freq playback)
CLEAR                            # stop simulating
HEARTBEAT                        # check the daemon is alive
QUIT                             # graceful shutdown
```

**Daemon → Mac (events):**

```
READY                            # boot complete, DVT connected
OK                               # last command succeeded
ERR <code> <message>             # last command failed
TUNNEL_DOWN                      # RSD tunnel dropped
EXIT                             # graceful shutdown ack
```

No JSON, no length prefixes. If it ever grows, swap to length-prefixed JSON.

## Coordinate Math

All coordinate work is in **EPSG:4326** (lat/lon in degrees, WGS84). For joystick movement and route interpolation, we use the local-flat approximation at the current latitude:

```
meters_per_deg_lat = 111_320
meters_per_deg_lon = 111_320 * cos(lat_in_radians)
```

This is accurate to <0.1% over distances <10km, which covers every realistic single-tick movement. For long routes (>50km), MKDirections gives us a polyline of fine-grained coordinates, so we never need to integrate over long stretches.

Hand-drawn strokes pass through `StrokeGeometry` before reaching the engine: Chaikin corner-cutting (two passes) takes hand jitter out of the path shape, then uniform arc-length resampling emits one vertex per `clamp(baseSpeed × 1 s, 2 m, 15 m)`. The resampler's contract is what `NavigationEngine` relies on — at least two distinct vertices and no near-zero segments (its velocity tangent normalizes by segment length); click-sized strokes and jitter blobs resample to nil and never load. Chaikin's linear blends run on raw degrees (local-flat error at stroke scale is far below GPS noise), while all spacing decisions are meters-based via `CLLocation.distance`, the same rationale as `joinSegments`.

For multi-stop routes, the planner issues one `MKDirections.calculate()` call per `[From, …stops, To]` pair sequentially (Apple Maps throttles parallel requests). Each segment's polyline is appended via `RouteMath.joinSegments`, which drops a duplicate vertex at the join when `CLLocation.distance` between the last point of the prior segment and the first point of the next is under 2 m. The threshold is meters-based, not degree-based, because MKDirections returns endpoints quantized at meter scale and a degree-based comparison would over-dedupe near the equator and under-dedupe near the poles. On any segment failure the whole route is aborted with a labeled log line (e.g. `Route failed: Stop 1 → Stop 2: …`); no partial polyline is rendered.
