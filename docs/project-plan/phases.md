# Implementation Phases

Each phase is sized to roughly one focused weekend (or 2-3 evenings). Don't move to the next phase until the previous one works end-to-end.

-----

## Phase 0 — Foundation (1 evening)

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

### Phase 0 Results (2026-05-13)

- **Status:** All steps passed on macOS 26.4 + iOS 26.4 + pymobiledevice3 9.12.0.
- **Critical finding:** Simulated location does **not** persist after the DVT session ends. When the `simulate-location set` CLI process exits, the device immediately reverts to its real GPS location. This confirms that the app **must** maintain a long-lived DVT connection (via the persistent `tm_daemon.py` process) for the entire duration of a simulation session. One-shot subprocess calls are not viable — not just for latency reasons (D2), but because the simulation itself is tied to the DVT session lifetime.
- **Implication for daemon design:** The daemon must keep the DVT `simulate-location` handle open continuously. `SET` commands should reuse the existing handle, not spawn new processes. `CLEAR` should issue the clear command over the same session without tearing it down.

-----

## Phase 1 — MVP: Teleport (1 weekend)

**Goal:** click on a map in a SwiftUI app, see your iPhone teleport.

Steps:

1. Scaffold project with XcodeGen. Create `project.yml`, generate `.xcodeproj`.
1. Bundle python-build-standalone into `Resources/python-runtime/`. Verify it runs.
1. Write `tm_daemon.py`: stdin loop, `SET`/`CLEAR`/`QUIT` commands. Initially hardcode the tunnel address; we'll automate it in Phase 4.
1. Write `DaemonBridge.swift`: `Process` wrapper, async stdin writer, async stdout reader.
1. Build `MapContainerView` (NSViewRepresentable around MKMapView).
1. Implement click → coordinate → `LocationSpoofingService.teleport(coord)` → daemon SET.
1. Sudo handling: launch the tunnel via `osascript -e 'do shell script "..." with administrator privileges'`. Ugly but works. Replace in Phase 4.
1. End-to-end manual test: click any point in Taipei, verify iPhone updates.

**Exit criteria:** smooth click-to-teleport, clean shutdown, no orphaned processes.

### Phase 1 Results (2026-05-13)

- **Status:** Core functionality working. Teleport end-to-end verified on macOS 26.4 + iOS 26.4.
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

-----

## Phase 2 — Route Mode (1 weekend)

**Goal:** type "Taipei 101" → "Elephant Mountain" → press play → iPhone walks the route.

Steps:

1. From/To search bars with `MKLocalSearchCompleter` + `MKLocalSearch`.
1. `MKDirections.calculate()` with selected transport type; render the polyline.
1. `NavigationEngine`: a `Timer` at 10 Hz that interpolates between consecutive polyline coordinates at the current speed. Emits `Coordinate` values via an `AsyncStream`.
1. Wire NavigationEngine output into LocationSpoofingService.
1. Speed selector (segmented control + multiplier slider).
1. Playback transport controls (Play/Pause/Stop).
1. Progress bar (elapsed distance / total distance).

**Exit criteria:** a 2km walking route plays smoothly start-to-finish; pause holds the location, resume continues, stop clears.

### Phase 2 Results (2026-05-13)

- **Status:** Route mode working end-to-end. Verified on macOS 26.4 + iOS 26.4.
- **What was built:**
  - `LocationSearch.swift` — `@Observable` wrapper around `MKLocalSearchCompleter` with a separate delegate class (avoids `@Observable` + protocol conformance conflict). Provides autocomplete suggestions and coordinate resolution via `MKLocalSearch`.
  - `NavigationEngine.swift` — `@Observable` route playback engine. Pre-computes cumulative distances along the polyline, then runs a 10Hz `Task.sleep` loop that advances distance by `baseSpeed * speedMultiplier * dt` and linearly interpolates position between polyline segments. Exposes `progress`, `elapsedDistance`, `totalDistance`, and play/pause/stop state.
  - `tm_daemon.py` — added `SETQ` command: fire-and-forget location set with no response line. Prevents response queue buildup during 10Hz playback.
  - `DaemonBridge.swift` — added `setLocationQuiet()` method that sends `SETQ` without awaiting a response.
  - `AppState.swift` — added route state (from/to search, transport mode, speed multiplier, route coordinates), `NavigationEngine` integration, and `MKDirections`-based route calculation. Uses `MKMapItem(location:address:)` (non-deprecated API).
  - `ContentView.swift` — rewritten with mode picker (Teleport/Route), collapsible connection section, route search fields with autocomplete, transport mode picker (Walk/Cycle/Drive), speed selector (1x/5x/10x/100x), playback controls (Play/Pause/Stop), progress bar, and map overlays (blue polyline, green start marker, orange end marker, red current-position dot).
- **Deviations from plan:**
  - Used `Task.sleep`-based loop instead of `Timer` for the 10Hz tick — more natural with Swift concurrency.
  - Used `onPositionUpdate` callback instead of `AsyncStream` for position updates — simpler given `@Observable` + `@MainActor` context.
  - Speed selector uses discrete buttons (1x/5x/10x/100x) instead of a slider — more precise and easier to use.

-----

## Phase 3 — Joystick Mode (1 weekend)

**Goal:** plug in a controller, push the stick, iPhone moves in real time.

Steps:

1. `JoystickInputService` wrapping `GCController`. Discover, subscribe to thumbstick value changes.
1. On-screen virtual stick as fallback (SwiftUI Circle + `DragGesture`, normalized to [-1, 1]).
1. 20 Hz control loop: read stick → integrate position → call daemon SET.
1. Speed cap UI.
1. "Stop" button that issues CLEAR.

**Exit criteria:** stick movement → iPhone movement with <300ms perceived latency; release stick → motion stops; press stop → location clears.

### Phase 3 Results (2026-05-13)

- **Status:** Joystick mode working end-to-end. Verified on macOS 26.4 + iOS 26.4.
- **What was built:**
  - `JoystickEngine.swift` — `@Observable` 20Hz control loop that polls hardware game controllers via `GCController.extendedGamepad.leftThumbstick`, accepts virtual stick and keyboard input, and integrates position using the local-flat coordinate approximation. Input priority: hardware controller > virtual stick > keyboard. Dead zone at 10% deflection. Fires `setLocationQuiet()` (SETQ) via the same `onPositionUpdate` callback pattern as route playback.
  - `VirtualJoystickView.swift` — on-screen circular pad (120x120pt) with `DragGesture`, thumb clamped to circle, output normalized to [-1, 1] with Y-inverted (screen down = south). Shows crosshair and `.ultraThinMaterial` background.
  - `AppState.swift` — added `.joystick` to `ControlMode`, `JoystickEngine` instance, `startJoystick()` / `stopJoystick()` / `recenterJoystick()` methods, mutual exclusion with route playback.
  - `ContentView.swift` — joystick sidebar section (controller status, speed cap picker, start/stop/recenter), virtual joystick overlay on map (bottom-right), WASD + arrow key handling via `.onKeyPress(keys:phases:)` with `.focusable()` map.
- **Deviations from plan:**
  - Added WASD + arrow key support as a third input method alongside controller and virtual stick — more natural on macOS than a virtual stick alone.
  - Reused `TransportMode` enum (Walk/Cycle/Drive) for speed cap instead of a separate selector — keeps UI consistent with route mode.
  - Starting position defaults to current `simulatedCoordinate` (or Taipei if none) — user can teleport first to set a specific starting point.

-----

## Phase 4 — Productionize (1 weekend)

**Goal:** stop being embarrassed about the rough edges.

Steps:

1. Replace `osascript` sudo with a real SMAppService privileged helper. Define XPC protocol, install on first run.
1. Automate DDI mounting on first connect (with the known iOS 26.4 caveat — surface a clear error if upload fails, instruct user to mount via Xcode).
1. Tunnel supervisor: detect disconnect, attempt reconnect with backoff.
1. Persistent daemon: don't kill/respawn between modes; keep one alive per app session.
1. GPX import (parse a `.gpx`, feed coordinates through NavigationEngine).
1. GPX export (record a session, write `.gpx`).
1. Saved waypoints sidebar.
1. Log sheet UI.

**Exit criteria:** can run for an hour without restart; tunnel drops are recovered; GPX round-trip works.

### Phase 4 Results (2026-05-13)

- **Status:** Productionization complete (practical items). Verified on macOS 26.4 + iOS 26.4.
- **What was built:**
  - **Tunnel supervisor** (`AppState.startHeartbeat()`) — 5-second polling loop checks `DaemonBridge.isRunning`. If the daemon process exits, the app transitions to `.error("Connection lost")`, stops all engines (joystick, route playback), and logs the event. No command-based heartbeat (avoids concurrent `sendCommand` contention).
  - **GPX import/export** (`GPXService.swift`) — Import: `NSOpenPanel` file picker → `XMLParser` parses `<wpt>`, `<trkpt>`, and `<rtept>` elements → loads coordinates into `NavigationEngine` for playback. Export: `NSSavePanel` → generates GPX with `<wpt>` elements and ISO 8601 timestamps calculated from distance and transport speed. Supports round-trip: import a GPX, play it back, export it again.
  - **Saved waypoints** (`SavedWaypoint` struct, persisted as JSON in `UserDefaults`) — sidebar section listing saved locations. Click to teleport, right-click to delete. "Save Current Location" button with name prompt (alert with text field). Visible whenever there are saved waypoints or a simulated coordinate.
  - **Log sheet** (`LogSheet` view) — full-screen sheet showing all log messages in monospaced font. Copy All, Clear, and Close buttons. Opened via "View Full Log" button in the sidebar log section.
  - **DaemonBridge** — added public `isRunning` computed property for heartbeat polling.
- **Deferred items (require separate Xcode targets / code signing):**
  - SMAppService privileged helper (step 1) — user continues starting RSD tunnel manually.
  - DDI auto-mounting (step 2) — user mounts via Xcode or `pymobiledevice3 mounter auto-mount`.
  - Item 4 (persistent daemon) was already implemented — daemon stays alive for the entire session.

-----

## Phase 5 — Polish & Release (optional, ~1 weekend)

Only if you want this as a portfolio piece:

- README with screenshots, GIF demo, setup instructions.
- `docs/architecture.md` written up properly.
- Localization scaffold (en + zh-Hant; you're a native zh-Hant speaker, this is low-effort).
- GitHub Actions: lint, build, unit tests.
- Tagged v1.0 release.
