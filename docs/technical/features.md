# Features

Single inventory of what ships in TrailMate today, plus items that were considered during planning but ultimately dropped, deferred, or superseded. For implementation history, see [../project-plan/phases.md](../project-plan/phases.md) or the git log.

## Shipped

### Connection & device discovery

- USB and Wi-Fi devices enumerated by `PythonDaemon/tm_list_devices.py` (uses `usbmux.list_devices` + `bonjour.browse_remoted` from pymobiledevice3). For each discovered UDID the lister opens a lockdown client (`autopair=False`) to read `DeviceName`, so the picker labels devices with their iOS-set name; falls back to the UDID suffix when lockdown isn't reachable (unpaired or pure-remoted only).
- Sidebar device picker; selecting a device kicks off the connection flow — no more pasting RSD address/port by hand.
- `TunnelSupervisor` opens the privileged `pymobiledevice3 lockdown start-tunnel` via `osascript … with administrator privileges`; one auth dialog per session. RSD address/port returned via a per-call control file.
- macOS sleep (`NSWorkspace.willSleepNotification`) triggers a clean disconnect, since the DVT session can't survive sleep.
- Tunnel-down / daemon-exit callbacks tear live state down automatically — no polling heartbeat, no stale "connected" state.

### Map view

- Full-pane MapKit view with pan / zoom.
- Search bar with `MKLocalSearchCompleter` autocomplete (used in route From/To pickers).
- Simulated position rendered as a distinct marker.
- Right-click opens the destination menu at the pointer; a 0.5 s long-press is kept as a fallback trigger (see "Map-driven travel" below).
- Camera position (center + span) persists across launches via `UserDefaults`; first launch defaults to Taipei.
- The simulated position (red dot) persists too and is restored on launch by default; first launch starts at the same Taipei landmark. "Restore last location on launch" (sidebar Connection section) opts out back to a start-empty launch — the position is recorded either way. A restored position is display-only until connect: the device receives it when the session attaches.
- Follow control on the map overlay (next to Record) recenters on and tracks the simulated position, keeping the current zoom. Any manual camera gesture hands control back (MapKit user-tracking semantics); disabled until a simulated position exists; session-only, not persisted.

### Teleport

- Right-click (or long-press) → "Teleport" sets the device location instantly.
- Works at any time while connected. Doubles as the way to set the starting location for joystick input when launch restore is off (or after Clear).
- "Clear" reverts the device to its real GPS.

### Route playback

- From/To via search or by promoting a destination picked on the map. A location-arrow button beside From fills it with the current simulated position (disabled until a position exists).
- Optional intermediate stops between From and To, visited in order. Each stop has its own search field; "Add Stop" appears once both endpoints are set. Soft notice above 10 stops (Apple Maps throttling risk); no hard cap.
- Transport mode: Walk (5 km/h), Cycle (15 km/h), Drive (50 km/h), or Custom km/h (`TransportMode.custom`).
- `MKDirections.calculate()` is issued per segment ([From, …stops, To] pairs); polylines are merged via `RouteMath.joinSegments` (2 m meters-based join-vertex dedup).
- `NavigationEngine` interpolates along the polyline at the configured base speed.
- Playback time-fast-forward multipliers: 1× / 5× / 10× / 100×.
- Loop playback: Off / Restart / Ping-Pong, with an optional loop count (∞ by default, stepper up to 99). Restart jumps the marker back to the start when the route completes and replays; Ping-Pong walks back along the same polyline — no re-routing, so the return leg is the outbound path exactly. One loop = one start-to-end pass (Restart) or one there-and-back round trip (Ping-Pong); the count reached, playback ends cleanly. The setting is engine-wide — it also loops direct travel, "Route here", wander routes, and recording replays — and session-scoped, like the speed multiplier.
- Transport controls: Play / Pause / Stop. Draggable timeline scrubber (elapsed / total distance): drag to seek anywhere on the route, forward or back; playback continues from the sought point in its prior play/pause state. Track clicks and keyboard arrows seek too. The bar runs 0→1 per leg — on a Ping-Pong return leg, scrubbing seeks within that return leg; while looping, a "Loop k of N" line shows the current iteration.
- While dragging, route advance holds and the device follows the scrub live — positions stream at up to 20 Hz (and land in an active GPX recording, like any other emission); the map red dot tracks the thumb.
- Play on a route that already ran to completion replays it from the start — unless the idle route was scrubbed first, in which case Play starts from the sought point.
- Wall-clock remaining time shown alongside the scrubber in `HH:mm:ss`; accounts for the active playback multiplier (e.g., a 30-min trip at 10× reads ~3 min).
- Saved routes capture the planner inputs (From / To / stops with their labels) so they can be re-loaded as editable fields, not just replayed as a flat polyline. Routes saved before this field existed still play; their planner fields stay empty.

### Map-driven travel

- Right-click anywhere on the map to open a native context menu at the pointer (its header shows the clicked coordinate); a 0.5 s long-press opens the same actions as a capsule action bar instead — kept as a fallback trigger. Both require a connected device. Actions:
  - **Teleport** — instant. Trigger nuance when no simulated position exists yet: long-press teleports immediately (nothing to route from), while right-click still opens the menu with the origin-dependent actions disabled.
  - **Go directly** — straight-line travel at `transportMode.baseSpeed`, served by `NavigationEngine`'s two-point case.
  - **Route here** — `MKDirections` from the current simulated position to the chosen point; auto-plays.
  - **Append direct / Append route** — extend the loaded route from its end to the chosen point (straight line / `MKDirections`); offered only while a route is loaded.
  - **Wander nearby…** — opens a sheet to pick a radius (50 / 100 / 200 m or custom) and a duration (15 / 30 / 60 min or custom). `WanderRouteBuilder` chains `MKDirections` walking hops between random points around the chosen center until total walked distance ≈ `effectiveBaseSpeedMPS × duration`. The wander may leak slightly beyond the disc; result is loaded into `NavigationEngine` and auto-plays. One-shot, not persisted.

### Joystick

- Arms on connect — no Start button. The engine stays inert (no SETQ, no marker) until a position seeds the integrator — the restored launch position (broadcast at attach) or, with restore off, the first teleport; from then on, stick input drives the simulated location at the configured base speed.
- Hardware game controller via `GameController.framework` (MFi / DualShock / Xbox / Joy-Con; hot-pluggable).
- On-screen virtual stick (SwiftUI `DragGesture` inside a circular pad) as fallback.
- WASD + arrow-key input on the focused map view.
- 20 Hz control tick, 10% dead zone.
- Speed cap reuses the same `TransportMode` (including Custom km/h); the picker lives in the Route section and drives both engines.

### Composite control

- Joystick and route playback / direct travel are not mutually exclusive.
- `PositionIntegrator` owns authoritative position; engines publish velocity vectors that are summed per tick.
- During route playback, joystick deflection drifts the simulated position off the polyline; off-route distance is surfaced as "Off-route: 42 m" once it exceeds 5 m.
- **Rejoin** snaps the integrator back to the nearest polyline point.
- Sustained large deviation (>200 m for >10 s) auto-aborts the route and switches to free joystick.

### Always-on GPS noise

- `LocationNoise` adds Box-Muller Gaussian jitter (σ default 5 m, configurable 0–10 m) to every `SETQ` emission, including idle.
- Single `AppState.emitSimulated()` chokepoint routes every coord through the noise filter.
- 1 Hz idle re-emission keeps a "stationary" location wiggling like a real GPS fix.
- The map marker shows the clean intent, not the jittered emission, so the on-screen position stays steady visually.

### Saved waypoints

- Save current location with a name prompt; persists to `UserDefaults` as JSON.
- Sidebar list with click-to-teleport, right-click rename (inline, Finder-style) / delete.

### Saved routes

- `SavedRoute` with name, transport mode, coordinates, and source (`calculated` / `directTravel` / `recorded` / `importedGPX`).
- Persisted as per-route JSON under `~/Library/Application Support/TrailMate/routes/`.
- Per-row Load / Replay / Rename (inline, Finder-style) / Delete. To export a route as GPX,
  load it and use the Route section's Export GPX.
- "Save as Route…" promotes a recorded session into the route library.

### Session recording

- Record button on the map overlay; captures the clean (pre-noise) coordinate on every `emitSimulated` call.
- Sessions persist as GPX with per-point timestamps under `~/Library/Application Support/TrailMate/recordings/YYYY-MM-DD/`.
- Recordings sidebar groups by date; per-row Replay, Export, Delete, and "Save as Route…".
- Replay uses original timestamps when present, otherwise falls back to constant-speed playback.

### GPX import / export

- Import: `NSOpenPanel` → `XMLParser` handles `<wpt>`, `<trkpt>`, `<rtept>`. Coordinates load into `NavigationEngine` for playback.
- Export: `NSSavePanel` → GPX with `<wpt>` and ISO 8601 timestamps. Round-trips cleanly.

### Status & diagnostics

- Connection status pill in the sidebar (Connecting / Connected / Disconnected / Error).
- "View Full Log" sheet (monospaced, Copy All, Clear) showing daemon stdout/stderr.
- Log entries for tunnel start, daemon exit, sleep, recording milestones, route deviation, joystick arming.

### Bundled Python runtime

- TrailMate ships a self-contained CPython interpreter + `pymobiledevice3` inside the `.app` bundle (`Contents/Resources/PythonResources/`). End users do not install Python, pip, or pymobiledevice3.
- Built via `packaging/build.sh` from [python-build-standalone](https://github.com/indygreg/python-build-standalone); the tarball is cached under `packaging/.cache/` so subsequent builds are fast.
- `PythonBundle.swift` resolves the interpreter and script paths at runtime so `tm_daemon.py`, `tm_tunnel.sh`, and `tm_list_devices.py` all run from the bundle in release builds (and from the same paths during `xcodebuild` debug builds).
- Embedded binaries are re-signed by a `Re-sign embedded Python binaries` Run Script phase under the same identity as the host app (ad-hoc when no Developer ID is configured), with `--options runtime` so the Hardened Runtime accepts them.
- Pin point is the Python interpreter version (default 3.13.x) and the pymobiledevice3 release that `build.sh` installs into the bundle's site-packages; bumping either is a deliberate change with a smoke pass.

## Deferred / dropped

Items considered during planning that were dropped, deferred, or superseded.

- **SMAppService privileged helper.** Still using `osascript … with administrator privileges`. One auth dialog per session is acceptable for personal use; a packaged helper is the right path but needs a paid Apple ID for signing.
- **DDI auto-mounting.** User mounts via Xcode or `pymobiledevice3 mounter auto-mount` once per OS update.
- **Reconnect button.** Replaced by automatic teardown on tunnel/daemon exit; user re-runs Connect manually.
- **Mount-status indicator showing DDI / tunnel / DVT separately.** Collapsed into a single Connection status pill.
- **Ghosted secondary marker for the real device location.** The simulated coordinate overrides what CoreLocation reports back to the host, so a separate "real" marker would only ever match the simulated one.
- **Right-click "Set as From / Set as To" on the map.** Search fields plus the map destination menu cover the same use cases.
- **0.5× playback multiplier.** Multipliers are now 1× / 5× / 10× / 100×; slower-than-real playback was unused.

## Out of scope (per [scope.md](../project-plan/scope.md))

- Anti-detection — `CLLocationSourceInformation.isSimulatedBySoftware` is true; not bypassable, not a goal.
- iOS ≤16 support — RSD tunnel is the minimum target.
- Altitude / heading / speed overrides — CoreLocation derives these from position deltas; no plan to inject them directly.
- Friction simulation (signal dropouts, accuracy variation) — Gaussian noise covers the realism floor; richer fault models are out of scope.
- Recording and replaying the device's *real* GPS — recording captures the simulated trace, not what the iPhone would naturally report.
