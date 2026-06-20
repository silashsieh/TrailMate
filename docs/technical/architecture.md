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
│   ├── TrailMateApp.swift             # @main entry point; Window + Settings + MenuBarExtra scenes, AppDelegate
│   ├── AppState.swift                 # device MANAGER (@Observable): owns N DeviceSessions + selected one, app-global tuning/libraries, AI dispatch
│   ├── DeviceSession.swift            # per-device unit: connection lifecycle, its SimulationActor + bridge + DaemonBridge, route/playback state
│   ├── ContentView.swift             # NavigationSplitView: device switcher sidebar + shared N-up map
│   ├── DaemonBridge.swift             # Process wrapper, stdin/stdout IPC with one daemon (event-driven stdout reader)
│   ├── DeviceDiscoveryService.swift   # USB/Wi-Fi device enumeration via tm_list_devices.py
│   ├── CommandProtocol.swift          # AI command layer: verb parser + JSON response envelope (pure value types)
│   ├── CommandServer.swift            # AF_UNIX command socket (off by default; inverse of DaemonBridge)
│   ├── SocketPath.swift               # ai.sock path + permission/length guards
│   ├── AISettingsSection.swift        # Settings "AI control" toggle subview
│   ├── MenuBarStatusView.swift        # MenuBarExtra content: live status + quick actions
│   ├── RoutingService.swift           # routing kernel protocol + MapKitRoutingService (D4 seam)
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
│   ├── SimulationActor.swift          # off-MainActor core: 20 Hz aggregator, engines, snapshot push (one per session)
│   ├── SimulationBackend.swift        # backend protocol + events (DaemonBridge / MockSimulationBackend implement it)
│   ├── StrokeGeometry.swift           # hand-drawn stroke smoothing + uniform resampling
│   ├── TunnelBroker.swift             # one privileged `remote tunneld` for all devices; resolves per-UDID RSD endpoint
│   ├── VirtualJoystickView.swift      # on-screen circular pad with DragGesture
│   ├── WanderPresetPersistence.swift  # wander sheet radius/duration recall
│   ├── WanderRouteBuilder.swift       # chained MKDirections hops for Wander nearby
│   └── Assets.xcassets                # (also: LanguagePreference, MockSimulationBackend, UITestSupport)
│
├── TrailMate.xcodeproj                # Xcode project (hand-managed, no XcodeGen)
├── TrailMate.entitlements
├── TrailMate.icon
├── TrailMateTests/                    # unit tests (see docs/project-plan/testing.md)
├── TrailMateUITests/
│
├── PythonDaemon/
│   ├── tm_daemon.py                   # persistent daemon: SET/SETQ/CLEAR/HEARTBEAT/QUIT (one per device)
│   ├── tm_list_devices.py             # one-shot USB + Wi-Fi device lister
│   └── tm_tunneld.sh                  # root-only `remote tunneld` launcher (parent-watches the host, N tunnels)
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
│  AppState — the device MANAGER (@MainActor @Observable)  │  Coordinator
│  Owns N DeviceSessions + the selected one, app-global    │  (MainActor)
│  tuning/libraries/discovery/tunnel broker/AI command     │
│  server. Forwarding accessors resolve to the selected    │
│  session; dispatch resolves the target by connectedUDID. │
├──────────────────────────────────────────────────────────┤
│  DeviceSession (@MainActor @Observable) — one per device │  Per-device unit
│  Its connection lifecycle + bound UDID, its own          │  (MainActor)
│  SimulationActor + SimulationStateBridge + private        │
│  DaemonBridge, and its route/playback state.             │
├──────────────────────────────────────────────────────────┤
│  SimulationStateBridge (@MainActor @Observable)          │  UI projection
│  One per session. Snapshot fields views observe:         │  (MainActor)
│  simulatedCoordinate, nav playback state/progress,       │
│  joystick active flag, route deviation, recording state. │
│  Populated by its session's SimulationActor snapshot push.│
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
│  TunnelBroker + tm_tunneld.sh                            │  Privilege
│  Sudo escalation via osascript-with-admin-privileges to  │
│  run one pymobiledevice3 remote tunneld (N tunnels, one  │
│  prompt). Per-UDID RSD endpoint queried over its HTTP API.│
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

Processes cooperating at runtime (multi-device: one tunneld, N daemons):

|Process        |Privilege         |Lifetime  |Responsibility                                                                       |
|---------------|------------------|----------|-------------------------------------------------------------------------------------|
|`TrailMate.app`|user              |session   |UI, state, all simulation logic                                                      |
|`tm_tunneld.sh`|root (via sudo)   |session   |Run one `pymobiledevice3 remote tunneld` opening every device's RSD TUN tunnel; nothing else|
|`tm_daemon.py` |user              |per device|Persistent pymobiledevice3 + DVT connection — **one per connected device**           |

`tm_tunneld.sh` exists *only* because creating TUN interfaces requires root. It does the absolute minimum: launches one `pymobiledevice3 remote tunneld` (which auto-tunnels all connected devices, with hot-plug), and parent-watches the host PID so a host crash can't leak it. It's brought up by `TunnelBroker.swift` via `osascript … with administrator privileges` — **one auth dialog per session for all devices**. The broker resolves each device's *current* RSD endpoint by querying tunneld's HTTP API at connect time, because the RSD address+port are **ephemeral** — tunneld reassigns them on every (re)establishment, so nothing caches them; the UDID is the only stable key. All location logic stays in the unprivileged app.

The Python daemon is a *long-lived* subprocess. Spawning `pymobiledevice3` per command costs ~500ms–1s in interpreter cold-start, which would kill the joystick experience. Instead, we spawn it once, keep the DVT connection open, and stream `SETQ lat lon\n` lines into its stdin at 20 Hz from the simulation actor.

## Concurrency Topology

Swift 6 strict concurrency, with three isolation domains:

|Domain                |Contents                                                                                                                      |
|----------------------|------------------------------------------------------------------------------------------------------------------------------|
|MainActor             |`AppState` (the device manager), `DeviceSession` (per device) + its `SimulationStateBridge`, `RecorderService`, `TunnelBroker`, `DeviceDiscoveryService`, `CommandServer`, `SavedRoutesStore`, views|
|`SimulationActor`     |Engines (nav/joystick/integrator/noise), aggregator + idle-jitter loops, deviation check, snapshot push, App Nap token. **One per session** — independent actors, no shared mutable state.|
|`DaemonBridge` (actor)|Process lifecycle, stdin/stdout state, pending-line continuations. **One per connected session**, held private to it.          |

Multi-device (epic 012) replicates the actor/bridge/daemon per `DeviceSession` rather than sharing them; `AppState` owns the collection and a `selectedSessionID`. The control surface (route panel, playback, joystick) binds to the selected session via `AppState`'s forwarding accessors; the map iterates all sessions for color-coded markers + routes. Device-routing is structural: a `DeviceSession` holds its `DaemonBridge` privately and a `SimulationActor` only ever talks to the backend injected at its own `attach()`, so a command resolved to session A by `connectedUDID` can never reach B's daemon. The single physical joystick is armed on exactly the selected session (`AppState.syncActiveJoystick`), connected or not — the joystick steers that session's local red dot whether or not a device is mirroring it; other sessions' engines read the controller but stay inactive, contributing no velocity.

The simulated position is a live *local* state, not a device side effect (epic 028). Each session's `SimulationActor` runs its loops for the session's whole lifetime — `startEngine()` at session creation, `stopEngine()` at removal/quit — so teleport, route playback, and joystick drive the red dot with or without a device. `attach()`/`detach()` only swap the device *mirror* in and out: attach injects the backend, immediately re-emits the current position (so the device snaps to the red dot on connect) and takes the App Nap token; detach drops the backend and token but leaves the loops running and the position intact. `emit()` writes the position to the bridge (the red dot) unconditionally and to `backend?` only when one is attached, so a disconnected session simulates locally and emits nothing to any device.

`DaemonBridge` reads its daemon's stdout with an event-driven `readabilityHandler` (feeding an ordered `AsyncStream` drained by one Task into the actor), **not** `FileHandle.bytes.lines`. This is load-bearing for multi-device: `bytes.lines` does a blocking read that holds Foundation's shared file-handle async-read queue, so once one device connects and its daemon goes idle, that bridge's blocked reader starves every *other* bridge's reader — a second device's daemon connects and prints `READY` but the bridge never reads it, hanging on "Connecting…" forever. The readabilityHandler never blocks, so concurrent bridges read independently. (Connecting one device at a time always worked, which is what made this look like a stack/tunnel limit rather than a reader bug.)

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

## Command Protocol (AI integration)

A second, *separate* line protocol — the AI command socket (epic 019). `CommandServer` listens on an `AF_UNIX` socket (`ai.sock`, off by default; the inverse of `DaemonBridge`), parses one command per line via `CommandProtocol`, hops to MainActor, and calls `AppState.dispatch(_:)` — the *same* facade the GUI buttons use, so every move still passes the `SimulationActor.emit()` chokepoint (noise + recording). Dispatch is a command *source*, never a parallel state owner.

**Mac → socket (requests):** one verb per line.

```
DEVICES                          # list discovered devices
STATUS                           # all-devices state document
CONNECT <udid>                   # find-or-make a session, connect (async; poll STATUS)
DISCONNECT <udid>
TELEPORT <udid> <lat> <lon>
ROUTE <udid> <lat0> <lon0> <lat1> <lon1> …
PLAY <udid> | PAUSE <udid> | STOP <udid> | SEEK <udid> <0…1> | CLEAR <udid>
```

**socket → Mac (responses):** one JSON line per command, optionals omitted.

```
{"ok":true,"data":{…}}
{"ok":false,"code":"not_connected","error":"device … is not connected"}
```

`ok` means *accepted*, not completed (most moves are fire-and-forget; read `STATUS` for realized state). Device-scoped verbs carry the target UDID; dispatch resolves the connected session by `connectedUDID` and **never** reads the GUI's `selectedSessionID`, so a command for device A can never reach device B. A greeting line on connect advertises the protocol version. Adding a verb means updating `CommandProtocol.swift`, `AppState.dispatch(_:)`, and this section together (see CLAUDE.md); the planned `trailmate` CLI is not yet built (see [features.md](features.md#deferred--dropped)), but will need the same treatment once it ships.

## Coordinate Math

All coordinate work is in **EPSG:4326** (lat/lon in degrees, WGS84). For joystick movement and route interpolation, we use the local-flat approximation at the current latitude:

```
meters_per_deg_lat = 111_320
meters_per_deg_lon = 111_320 * cos(lat_in_radians)
```

This is accurate to <0.1% over distances <10km, which covers every realistic single-tick movement. For long routes (>50km), MKDirections gives us a polyline of fine-grained coordinates, so we never need to integrate over long stretches.

Hand-drawn strokes pass through `StrokeGeometry` before reaching the engine: Chaikin corner-cutting (two passes) takes hand jitter out of the path shape, then uniform arc-length resampling emits one vertex per `clamp(baseSpeed × 1 s, 2 m, 15 m)`. The resampler's contract is what `NavigationEngine` relies on — at least two distinct vertices and no near-zero segments (its velocity tangent normalizes by segment length); click-sized strokes and jitter blobs resample to nil and never load. Chaikin's linear blends run on raw degrees (local-flat error at stroke scale is far below GPS noise), while all spacing decisions are meters-based via `CLLocation.distance`, the same rationale as `joinSegments`.

For multi-stop routes, the planner issues one `MKDirections.calculate()` call per `[From, …stops, To]` pair sequentially (Apple Maps throttles parallel requests). Each segment's polyline is appended via `RouteMath.joinSegments`, which drops a duplicate vertex at the join when `CLLocation.distance` between the last point of the prior segment and the first point of the next is under 2 m. The threshold is meters-based, not degree-based, because MKDirections returns endpoints quantized at meter scale and a degree-based comparison would over-dedupe near the equator and under-dedupe near the poles. On any segment failure the whole route is aborted with a labeled log line (e.g. `Route failed: Stop 1 → Stop 2: …`); no partial polyline is rendered.
