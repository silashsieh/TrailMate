# TrailMate

> *A native macOS companion for simulating real-time GPS location on iOS devices.*

-----

## 1. Project Description

TrailMate is a personal-use SwiftUI macOS application that controls an iPhone’s GPS location in real time. It is designed for iOS developers and testers who need to exercise location-dependent code paths without physically moving — testing a ride-share pickup flow, a weather widget in another timezone, an AR walking experience, or a store-locator from across the world.

TrailMate offers three control modes:

1. **Teleport** — click anywhere on a map to instantly set the device’s location.
1. **Route** — enter From/To, calculate a walking/cycling/driving route, and play it back at configurable speed.
1. **Joystick** — drive the device’s location in real time with a game controller or on-screen virtual stick.

The Mac acts as a controller; the iPhone reports the simulated coordinates to every app on the device through standard CoreLocation. No app is installed on the iPhone, and no jailbreak is required.

-----

## 2. Goals & Non-Goals

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
- **No legacy iOS support.** iOS 17 introduced the personalized DDI + RSD tunnel; that’s the minimum target. Users on iOS ≤16 should use Schlaubischlump’s LocationSimulator.
- **No multi-device orchestration.** One iPhone at a time. (Possible v3 extension; not v1.)
- **No production hardening.** This is a single-user dev tool, not a fleet-simulation platform.

-----

## 3. Target Users & Use Cases

Primary user: **myself** (Harry), a software engineer doing iOS-adjacent work and interview prep. Secondary: other iOS developers and QA engineers who find this on GitHub.

Representative use cases:

- *“I need to test that my app’s geofencing fires correctly when the user enters Da’an district.”*
- *“My app behaves weirdly when the user is moving at driving speed in a tunnel. I need to simulate that without a car.”*
- *“I want to step through a 5km walking route to verify my distance tracker stays accurate.”*
- *“I’m reviewing a CoreLocation bug report from a user in Osaka — I need to put my dev device there.”*

-----

## 4. Technical Architecture

### 4.1 Layer Diagram

```
┌─────────────────────────────────────────────────┐
│  SwiftUI Views                                  │  Presentation
│  (MapView, Sidebar, Toolbar, Joystick)          │
├─────────────────────────────────────────────────┤
│  View Models (@Observable)                      │  State
│  (AppState, MapVM, RouteVM, JoystickVM)         │
├─────────────────────────────────────────────────┤
│  Services                                       │  Domain
│  ├── LocationSpoofingService                    │
│  ├── NavigationEngine (route playback)          │
│  ├── JoystickInputService (GameController)      │
│  └── DeviceDiscoveryService (USB / Wi-Fi)       │
├─────────────────────────────────────────────────┤
│  DaemonBridge                                   │  IPC
│  (Process mgmt, stdin/stdout protocol)          │
├─────────────────────────────────────────────────┤
│  PrivilegedHelper (SMAppService, runs as root)  │  Privilege
│  (Brings up the RSD tunnel; only this needs     │
│  sudo. Spawned once, kept alive.)               │
├─────────────────────────────────────────────────┤
│  tm_daemon.py (long-lived Python process)       │  Transport
│  ├── pymobiledevice3 tunnel client              │
│  ├── DVT LocationSimulation handle              │
│  └── stdin command loop                         │
├─────────────────────────────────────────────────┤
│  RSD tunnel → iPhone DVT service → CoreLocation │  Device
└─────────────────────────────────────────────────┘
```

### 4.2 Process Topology

Three OS processes cooperate at runtime:

|Process          |Privilege|Lifetime|Responsibility                             |
|-----------------|---------|--------|-------------------------------------------|
|`TrailMate.app`  |user     |session |UI, state, all logic                       |
|`TrailMateHelper`|root     |session |Open the RSD TUN tunnel; nothing else      |
|`tm_daemon.py`   |user     |session |Persistent pymobiledevice3 + DVT connection|

The helper exists *only* because creating a TUN interface requires root. It does the absolute minimum and exposes a narrow XPC interface (`startTunnel(udid:)`, `stopTunnel()`). All location logic stays in the unprivileged app.

The Python daemon is a *long-lived* subprocess. Spawning `pymobiledevice3` per command costs ~500ms–1s in interpreter cold-start, which would kill the joystick experience. Instead, we spawn it once, keep the DVT connection open, and stream `lat,lon\n` lines into its stdin.

### 4.3 Daemon Protocol

Line-delimited text over stdin/stdout. Simple, debuggable with `cat`.

**Mac → Daemon (commands):**

```
SET 25.033 121.5654              # teleport
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

### 4.4 Coordinate Math

All coordinate work is in **EPSG:4326** (lat/lon in degrees, WGS84). For joystick movement and route interpolation, we use the local-flat approximation at the current latitude:

```
meters_per_deg_lat = 111_320
meters_per_deg_lon = 111_320 * cos(lat_in_radians)
```

This is accurate to <0.1% over distances <10km, which covers every realistic single-tick movement. For long routes (>50km), MKDirections gives us a polyline of fine-grained coordinates, so we never need to integrate over long stretches.

-----

## 5. Tech Stack

|Layer            |Choice                                                 |Rationale                                              |
|-----------------|-------------------------------------------------------|-------------------------------------------------------|
|Language (host)  |Swift 6                                                |Modern concurrency, strict typing                      |
|UI               |SwiftUI                                                |Native, fast iteration, no AppKit boilerplate          |
|Map              |MapKit + MKDirections                                  |Free, no API key, built-in routing                     |
|Joystick input   |GameController.framework                               |First-party, supports MFi / DualShock / Xbox / Joy-Cons|
|IPC              |NSXPCConnection (for helper), Process+pipe (for Python)|Standard, well-documented                              |
|Privileged helper|SMAppService (macOS 13+)                               |Modern replacement for SMJobBless                      |
|Device transport |pymobiledevice3 (pinned, vendored)                     |Only mature library supporting iOS 17+ RSD tunnel      |
|Python runtime   |python-build-standalone, bundled in app                |Self-contained; no system Python dependency            |
|Project gen      |XcodeGen                                               |`project.yml` is reviewable; .xcodeproj is generated   |
|Tests            |Swift Testing + XCTest                                 |Swift Testing for new code; XCTest for legacy interop  |

Versions targeted:

- macOS 26.4 (Tahoe / “26”) on Apple Silicon
- iOS 26.4 on a paired iPhone with Developer Mode enabled
- Xcode 26.x
- Python 3.13 (bundled), pymobiledevice3 ≥ 9.12

-----

## 6. Core Features (V1 Scope)

### F1: Device Discovery & Connection

- List USB-paired iPhones via pymobiledevice3 `usbmux list`
- Sidebar device picker
- Mount status indicator (DDI mounted? tunnel up? DVT ready?)
- “Reconnect” button when tunnel drops

### F2: Map View

- Centered, zoomable MapKit view occupying main pane
- Search bar with `MKLocalSearchCompleter` autocomplete
- Click → place pin → “Teleport here” / “Set as start” / “Set as end” context menu
- Current simulated position rendered as a distinct marker
- Real device location (if known and recent) rendered as a ghosted secondary marker

### F3: Teleport Mode

- Click on map → device immediately reports that coordinate
- “Clear” button → device reverts to real GPS

### F4: Route Mode

- From/To pickers (map clicks or search)
- Transport mode segmented control: Walk / Cycle / Drive
- Speed slider: 0.5×, 1×, 5×, 10×, 100×
- “Calculate Route” → `MKDirections.calculate()` → polyline rendered on map
- Playback controls: Play / Pause / Stop / Restart
- Progress bar showing elapsed / remaining
- Interpolation: 10 Hz, smooth movement between MKDirections waypoints

### F5: Joystick Mode

- Hardware game controller via GameController.framework (auto-detected, hot-pluggable)
- On-screen virtual stick as fallback (SwiftUI `DragGesture` inside a circular pad)
- 20 Hz update tick
- Speed cap selector: Walk (1.4 m/s) / Cycle (5 m/s) / Drive (15 m/s) / Custom
- Heading derived from stick angle; magnitude controls speed
- “Recenter” button returns to last teleport location

### F6: Status & Diagnostics

- Tunnel status pill in toolbar (green = up, yellow = mounting, red = down)
- “View Log” sheet showing daemon stdout/stderr
- Copy-coords-to-clipboard from any marker

### Out of V1 (deferred)

- GPX import/export (Phase 4)
- Saved waypoints / route library (Phase 4)
- Altitude / heading / speed overrides (research first; CoreLocation derives most of these)
- Multi-device fan-out
- Recording real movement and replaying it
- Friction simulation (signal dropouts, accuracy variation)

-----

## 7. Project Structure

```
TrailMate/
├── README.md                          # public-facing intro
├── LICENSE                            # MIT (or GPL-3 if vendoring pymobiledevice3 verbatim — check!)
├── CLAUDE.md                          # Claude Code working notes (see §11)
├── project.yml                        # XcodeGen spec
├── .gitignore
│
├── Sources/
│   ├── TrailMateApp/
│   │   ├── TrailMateApp.swift         # @main
│   │   ├── AppState.swift             # root @Observable
│   │   └── Assets.xcassets
│   │
│   ├── Views/
│   │   ├── ContentView.swift          # NavigationSplitView
│   │   ├── Sidebar/
│   │   │   ├── DeviceListView.swift
│   │   │   └── SavedRoutesView.swift
│   │   ├── Map/
│   │   │   ├── MapContainerView.swift # NSViewRepresentable wrapper
│   │   │   └── MapCoordinator.swift
│   │   ├── Modes/
│   │   │   ├── TeleportControls.swift
│   │   │   ├── RouteControls.swift
│   │   │   └── JoystickControls.swift
│   │   ├── Joystick/
│   │   │   └── VirtualJoystickView.swift
│   │   └── Status/
│   │       ├── TunnelStatusPill.swift
│   │       └── LogSheet.swift
│   │
│   ├── ViewModels/
│   │   ├── MapViewModel.swift
│   │   ├── RouteViewModel.swift
│   │   └── JoystickViewModel.swift
│   │
│   ├── Services/
│   │   ├── LocationSpoofingService.swift
│   │   ├── NavigationEngine.swift
│   │   ├── JoystickInputService.swift
│   │   ├── DeviceDiscoveryService.swift
│   │   └── DaemonBridge.swift
│   │
│   ├── Models/
│   │   ├── Coordinate.swift
│   │   ├── Route.swift
│   │   ├── TransportMode.swift
│   │   └── Device.swift
│   │
│   └── Extensions/
│       ├── CLLocationCoordinate2D+Math.swift
│       └── MKPolyline+Coordinates.swift
│
├── Helper/                            # privileged XPC helper
│   ├── main.swift
│   ├── HelperProtocol.swift           # shared with main app
│   └── TunnelManager.swift
│
├── PythonDaemon/
│   ├── tm_daemon.py                   # main script
│   ├── requirements.txt               # pymobiledevice3==9.12.x, pinned
│   └── README.md
│
├── Resources/
│   ├── python-runtime/                # bundled python-build-standalone
│   └── DeveloperDiskImages/           # not committed; downloaded at runtime
│
├── Tests/
│   ├── UnitTests/
│   │   ├── CoordinateMathTests.swift
│   │   ├── NavigationEngineTests.swift
│   │   └── DaemonProtocolTests.swift  # uses a fake daemon
│   └── IntegrationTests/
│       └── ManualSmokeTestPlan.md     # human checklist
│
└── docs/
    ├── architecture.md
    ├── daemon-protocol.md
    └── setup-iphone.md                # user-facing: enable Dev Mode, etc.
```

-----

## 8. Implementation Phases

Each phase is sized to roughly one focused weekend (or 2–3 evenings). Don’t move to the next phase until the previous one works end-to-end.

### Phase 0 — Foundation (1 evening)

**Goal:** prove the platform works on *your* iPhone before writing any Swift.

Steps:

1. Install pymobiledevice3 in a fresh virtualenv (`pip install pymobiledevice3==9.12.0` or latest 9.x).
1. Enable Developer Mode on the iPhone (Settings → Privacy & Security → Developer Mode → reboot → trust).
1. `sudo pymobiledevice3 mounter auto-mount` — confirm DDI mounts cleanly.
1. In one terminal: `sudo pymobiledevice3 lockdown start-tunnel`. Note the RSD address and port.
1. In another: `pymobiledevice3 developer dvt simulate-location set --rsd <addr> <port> -- 25.0330 121.5654`.
1. Verify in Apple Maps on the iPhone that your reported location is in Taipei.
1. `pymobiledevice3 developer dvt simulate-location clear --rsd <addr> <port>`. Verify it reverts.

**Exit criteria:** all six commands succeed without modification. If any fail, debug at the CLI layer — do not paper over CLI bugs with Swift code.

#### Phase 0 Results (2026-05-13)

- **Status:** ✅ All steps passed on macOS 26.4 + iOS 26.4 + pymobiledevice3 9.12.0.
- **Critical finding:** Simulated location does **not** persist after the DVT session ends. When the `simulate-location set` CLI process exits, the device immediately reverts to its real GPS location. This confirms that the app **must** maintain a long-lived DVT connection (via the persistent `tm_daemon.py` process) for the entire duration of a simulation session. One-shot subprocess calls are not viable — not just for latency reasons (D2), but because the simulation itself is tied to the DVT session lifetime.
- **Implication for daemon design:** The daemon must keep the DVT `simulate-location` handle open continuously. `SET` commands should reuse the existing handle, not spawn new processes. `CLEAR` should issue the clear command over the same session without tearing it down.

### Phase 1 — MVP: Teleport (1 weekend)

**Goal:** click on a map in a SwiftUI app, see your iPhone teleport.

Steps:

1. Scaffold project with XcodeGen. Create `project.yml`, generate `.xcodeproj`.
1. Bundle python-build-standalone into `Resources/python-runtime/`. Verify it runs.
1. Write `tm_daemon.py`: stdin loop, `SET`/`CLEAR`/`QUIT` commands. Initially hardcode the tunnel address; we’ll automate it in Phase 4.
1. Write `DaemonBridge.swift`: `Process` wrapper, async stdin writer, async stdout reader.
1. Build `MapContainerView` (NSViewRepresentable around MKMapView).
1. Implement click → coordinate → `LocationSpoofingService.teleport(coord)` → daemon SET.
1. Sudo handling: launch the tunnel via `osascript -e 'do shell script "..." with administrator privileges'`. Ugly but works. Replace in Phase 4.
1. End-to-end manual test: click any point in Taipei, verify iPhone updates.

**Exit criteria:** smooth click-to-teleport, clean shutdown, no orphaned processes.

#### Phase 1 Results (2026-05-13)

- **Status:** ✅ Core functionality working. Teleport end-to-end verified on macOS 26.4 + iOS 26.4.
- **What was built:**
  - `PythonDaemon/tm_daemon.py` — async daemon keeping a persistent DVT session; accepts `SET`/`CLEAR`/`HEARTBEAT`/`QUIT` over stdin.
  - `DaemonBridge.swift` — spawns the daemon as a subprocess, manages stdin/stdout IPC with continuation-based async line reading, captures stderr for diagnostics.
  - `AppState.swift` — root `@Observable` state; manages connection lifecycle, teleport, clear, and logging. Persists RSD address/port via `UserDefaults`.
  - `ContentView.swift` — `NavigationSplitView` with sidebar (RSD connection fields, status indicator, log) and a MapKit `Map` with `MapReader` + long-press gesture for teleport.
  - `TrailMateApp.swift` — cleaned up from template; removed SwiftData, injects `AppState` via `.environment()`.
- **Deviations from plan (all intentional):**
  - Skipped XcodeGen — using the existing `.xcodeproj` directly. Can adopt later if needed.
  - Skipped bundled python-build-standalone — using the venv's Python at a hardcoded path. Deferred to Phase 4.
  - Skipped `osascript` sudo automation — user starts the RSD tunnel manually in a separate terminal. Deferred to Phase 4.
  - Used SwiftUI `Map` + `MapReader` instead of `NSViewRepresentable` around `MKMapView` — simpler and more idiomatic for macOS 14+.
  - Used long-press gesture (0.5s) instead of tap — tap conflicts with the Map's built-in pan/zoom gestures.
- **App Sandbox:** Disabled. Required because the daemon subprocess needs unrestricted access to the RSD tunnel's TUN network interface.
- **Clean shutdown verified:** no orphaned `tm_daemon` or `python3` processes after app quit.

### Phase 2 — Route Mode (1 weekend)

**Goal:** type “Taipei 101” → “Elephant Mountain” → press play → iPhone walks the route.

Steps:

1. From/To search bars with `MKLocalSearchCompleter` + `MKLocalSearch`.
1. `MKDirections.calculate()` with selected transport type; render the polyline.
1. `NavigationEngine`: a `Timer` at 10 Hz that interpolates between consecutive polyline coordinates at the current speed. Emits `Coordinate` values via an `AsyncStream`.
1. Wire NavigationEngine output into LocationSpoofingService.
1. Speed selector (segmented control + multiplier slider).
1. Playback transport controls (Play/Pause/Stop).
1. Progress bar (elapsed distance / total distance).

**Exit criteria:** a 2km walking route plays smoothly start-to-finish; pause holds the location, resume continues, stop clears.

### Phase 3 — Joystick Mode (1 weekend)

**Goal:** plug in a controller, push the stick, iPhone moves in real time.

Steps:

1. `JoystickInputService` wrapping `GCController`. Discover, subscribe to thumbstick value changes.
1. On-screen virtual stick as fallback (SwiftUI Circle + `DragGesture`, normalized to [-1, 1]).
1. 20 Hz control loop: read stick → integrate position → call daemon SET.
1. Speed cap UI.
1. “Stop” button that issues CLEAR.

**Exit criteria:** stick movement → iPhone movement with <300ms perceived latency; release stick → motion stops; press stop → location clears.

### Phase 4 — Productionize (1 weekend)

**Goal:** stop being embarrassed about the rough edges.

Steps:

1. Replace `osascript` sudo with a real SMAppService privileged helper. Define XPC protocol, install on first run.
1. Automate DDI mounting on first connect (with the known iOS 26.4 caveat — surface a clear error if upload fails, instruct user to mount via Xcode).
1. Tunnel supervisor: detect disconnect, attempt reconnect with backoff.
1. Persistent daemon: don’t kill/respawn between modes; keep one alive per app session.
1. GPX import (parse a `.gpx`, feed coordinates through NavigationEngine).
1. GPX export (record a session, write `.gpx`).
1. Saved waypoints sidebar.
1. Log sheet UI.

**Exit criteria:** can run for an hour without restart; tunnel drops are recovered; GPX round-trip works.

### Phase 5 — Polish & Release (optional, ~1 weekend)

Only if you want this as a portfolio piece:

- README with screenshots, GIF demo, setup instructions.
- `docs/architecture.md` written up properly.
- Localization scaffold (en + zh-Hant; you’re a native zh-Hant speaker, this is low-effort).
- GitHub Actions: lint, build, unit tests.
- Tagged v1.0 release.

-----

## 9. Key Technical Decisions (and why)

### D1: Why pymobiledevice3 instead of native Swift via libimobiledevice?

The iOS 17+ RSD tunnel uses RemoteXPC, personalized DDI mounting, and TUN-based encrypted tunneling. Reimplementing this protocol stack in Swift is a multi-week effort that adds zero user-visible value over shelling out to a maintained Python library. pymobiledevice3 has ~10 releases per year, is the de facto reference implementation, and we can pin a version for reproducibility. Trade: ~80MB app size for the Python runtime; acceptable.

### D2: Why a persistent daemon instead of CLI invocation per command?

Each `pymobiledevice3` CLI invocation pays Python interpreter startup (~500ms–1s) plus tunnel setup (~1–3s on first call). For joystick mode at 20Hz, that’s a non-starter. Keeping one daemon alive with the tunnel and DVT handle pre-opened reduces per-command latency to <10ms.

### D3: Why a separate privileged helper instead of running the whole app as root?

Two reasons. First, only the TUN interface creation needs root; everything else (UI, MapKit, GameController, daemon stdin/stdout) is fine as the regular user. Running the whole app as root would be a gratuitous security mistake. Second, it’s idiomatic macOS: SMAppService is the documented modern path, and the entitlements / installation flow is well-understood. The helper is ~100 lines of Swift.

### D4: Why MapKit over Google Maps or OpenStreetMap?

Free, no API key, no account, no quota, native SwiftUI integration, MKDirections for routing in one line. The only argument against is map data density — Apple’s data for Taipei walking routes is decent but not as detailed as OSM in some neighborhoods. If that becomes a real problem, OSRM can be slotted in as the routing backend behind a `RoutingService` protocol while keeping MapKit for visualization.

### D5: Why 10Hz for routes and 20Hz for joystick?

CoreLocation typically delivers updates to apps at ~1Hz by default, and rapid updates get coalesced. 10Hz on the wire ensures we’re never the bottleneck for route playback while not wasting CPU. Joystick mode benefits from a slightly tighter loop for perceived responsiveness during direction changes; 20Hz feels noticeably more direct than 10Hz in user testing of similar tools.

### D6: Why local-flat coordinate math instead of geodesic (Haversine)?

For per-tick movement at human-scale speeds (1–25 m/s) and one-tick distances (5cm–1.25m), the flat approximation is correct to better than 0.001%. Geodesic math at this scale is engineering overkill. We use it anyway for any total-distance calculation over a route (just `MKPolyline.totalDistance` via MapKit’s own geodesic implementation).

-----

## 10. Risks & Mitigations

|Risk                                                  |Likelihood|Impact                               |Mitigation                                                                                                                                |
|------------------------------------------------------|----------|-------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
|iOS 26.4 DDI/RSD upload instability                   |High      |Blocks Phase 0–1                     |Don’t auto-mount in the app; surface a “please mount via Xcode first” UX with copy-pastable instructions. Toggle Dev Mode off/on if stuck.|
|pymobiledevice3 API breaking change in a minor version|Medium    |Breaks daemon                        |Pin to exact version (e.g. `9.12.0`). Bump deliberately with integration tests.                                                           |
|Apple changes RSD protocol in iOS 26.5+               |Medium    |Breaks everything                    |Inevitable. Monitor pymobiledevice3 releases. We’re not unique — every spoofer breaks here.                                               |
|sudo prompt UX is jarring                             |High in v1|Annoying                             |Acceptable in v1 (osascript prompt); fixed in Phase 4 (SMAppService one-time install).                                                    |
|Tunnel drops mid-session                              |Medium    |Bad UX                               |Supervisor loop with backoff; clear UI indicator; route playback pauses, joystick stops.                                                  |
|`isSimulatedBySoftware == true` visible to apps       |Certain   |Some apps detect spoof               |Documented limitation. Not a goal to defeat.                                                                                              |
|Game controller incompatibility                       |Low       |Joystick mode unusable for some users|On-screen virtual stick is always available as fallback.                                                                                  |
|Bundled Python runtime breaks on macOS upgrade        |Low       |App won’t launch after OS update     |python-build-standalone is well-maintained; test on each macOS major.                                                                     |
|Vendor pymobiledevice3 license obligations (GPL?)     |Low       |Legal                                |Verify pymobiledevice3 license before bundling; pick TrailMate license to match (likely GPL-3 if we bundle, MIT if we shell out).         |

-----

## 11. Claude Code Working Notes

> *This section is the de facto `CLAUDE.md`. When working on TrailMate via Claude Code, read this first.*

### Project Context

- **Owner:** Harry, solo developer, working on personal Mac (Apple Silicon, macOS 26.4) and personal iPhone (iOS 26.4).
- **Apple Developer Account:** none required; everything runs locally.
- **Reference implementations to consult, in priority order:**
1. `pymobiledevice3` source — authoritative for transport behavior.
1. `nexron171/SimVirtualLocation` — closest working OSS architecture (Swift + pymobiledevice3).
1. `keezxc1223/locwarp` README — best documentation of iOS 26.4-specific quirks.
1. `Schlaubischlump/LocationSimulator` — UI/UX inspiration only; transport is obsolete.

### Coding Conventions

- **Swift:** strict concurrency, async/await over completion handlers, `@Observable` over `ObservableObject`, value types where possible.
- **Error handling:** throwing functions over `Result`; one app-wide `TrailMateError` enum with descriptive cases. No swallowing errors silently — surface in the Log sheet at minimum.
- **Logging:** `os.Logger` with subsystem `com.harry.trailmate`, categories per service.
- **Files:** one type per file; file name matches type name.
- **Tests:** prefer Swift Testing (`@Test`, `#expect`) over XCTest for new code.
- **Comments:** explain *why*, not *what*. The code should explain the what.
- **Commits:** Conventional Commits style (`feat:`, `fix:`, `refactor:`, `docs:`, `test:`).

### Things to Always Do

- When adding a new daemon command, update both the Swift `DaemonBridge` and `tm_daemon.py` and `docs/daemon-protocol.md` in the same change.
- When changing the `HelperProtocol`, bump the protocol version constant and handle backwards compat.
- When touching coordinate math, add a unit test with a known-good reference value.
- Before any “this should work on iOS 26.4” claim, point to a verified source (pymobiledevice3 release notes, LocWarp tested-on note, or a personal test against the real device).

### Things to Never Do

- **Never** call `pymobiledevice3` as a one-shot subprocess in a hot path. Always go through the persistent daemon.
- **Never** put location-spoofing logic inside the privileged helper. The helper only manages the tunnel.
- **Never** bundle `Resources/DeveloperDiskImages/` in git. Those are device-specific and large.
- **Never** invent a pymobiledevice3 API that hasn’t been verified against the pinned version. If unsure, run the CLI first to confirm flags and output.
- **Never** swallow `TUNNEL_DOWN` silently. The user must see it.

### Decision-Making Heuristics for Ambiguous Tasks

- “Should I add this feature?” → If it’s not in §6 Core Features, defer to a later phase. Don’t scope-creep.
- “Should I refactor X while I’m here?” → Only if the refactor is in the immediate path of the task. Otherwise file as a TODO.
- “Should I add a dependency?” → Default to no. Swift stdlib + Apple frameworks + pymobiledevice3 should cover 99% of needs.
- “Should I rewrite this in Swift?” → Probably not. The Python daemon line is small and stable; reimplementation is multi-week.

### Quick-Reference Commands

```bash
# Regenerate Xcode project after editing project.yml
xcodegen generate

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

-----

## 12. Testing Strategy

### Unit Tests (automated, fast, run on every save)

- `CoordinateMathTests` — flat-projection math, distance calc, interpolation correctness vs. known reference points (e.g. Taipei 101 → Taipei Main Station distance should match Google’s value to within 1%).
- `NavigationEngineTests` — feed a fixed polyline, run the engine with mocked time, assert emitted coordinates match expected interpolation.
- `DaemonProtocolTests` — fake daemon process that records commands; verify DaemonBridge sends correct command strings and parses responses.
- `RouteVMTests` — search, From/To state transitions, route calculation result handling.

### Integration Tests (semi-automated, slower)

- Daemon round-trip with a real pymobiledevice3 in mock mode (no actual device).
- XPC handshake with the privileged helper (install, connect, ping, uninstall).

### Manual Smoke Tests (run before tagging a release)

Checklist in `Tests/IntegrationTests/ManualSmokeTestPlan.md`:

1. Cold launch with no device connected — UI shows “no device” state.
1. Connect iPhone via USB — appears in sidebar within 5s.
1. First-run sudo prompt — accept; tunnel comes up.
1. Teleport to 5 different cities; verify on the iPhone each time.
1. Route from your home to your office; play at 10×; arrives at correct end coordinate.
1. Joystick: connect controller, push stick, verify smooth movement.
1. Pull USB mid-session — UI shows TUNNEL_DOWN; reconnect cable; recovers.
1. Quit the app — verify no orphaned processes (`ps aux | grep -E "tm_daemon|TrailMateHelper"`).

-----

## 13. References

- pymobiledevice3 GitHub: https://github.com/doronz88/pymobiledevice3
- libimobiledevice: https://libimobiledevice.org/
- Apple MapKit for macOS: https://developer.apple.com/documentation/mapkit
- GameController.framework: https://developer.apple.com/documentation/gamecontroller
- SMAppService: https://developer.apple.com/documentation/servicemanagement/smappservice
- XcodeGen: https://github.com/yonaskolb/XcodeGen
- python-build-standalone: https://github.com/indygreg/python-build-standalone
- nexron171/SimVirtualLocation (reference architecture): https://github.com/nexron171/SimVirtualLocation
- LocWarp (iOS 26.4 quirks documentation): https://github.com/keezxc1223/locwarp
- Apple’s CLLocationSourceInformation: https://developer.apple.com/documentation/corelocation/cllocationsourceinformation

-----

## 14. License (placeholder)

MIT.

-----

*Document version: 1.0 — initial scope. Update as the project evolves.*
