# V2 Feature Plan

> *Captured 2026-05-18 from owner-driven requirements. Builds on the Phase 0–4 baseline. Each phase is weekend-sized and ends with a working, manually-verifiable result, same convention as `phases.md`.*

-----

## Background

The Phase 0–4 work delivered teleport, route playback, joystick, GPX import/export, saved waypoints, and a tunnel supervisor. V2 closes the gap between that baseline and the desired day-to-day developer workflow: drop the device on the desk, tap a point on the map, watch the device walk there with realistic GPS jitter, optionally take manual control mid-route, and keep a record of every session for later replay.

## Requirements (verbatim)

1. Connect an iPhone over USB or Wi-Fi (device already in Developer Mode).
2. See a map; pick the connected iPhone (USB or LAN); long-press to teleport.
3. Pick a second point and either travel directly to it or follow an Apple Maps route.
4. Travel speed selectable as Walk (5 km/h), Cycle (15 km/h), Drive (50 km/h), or a custom value in km/h.
5. Always-on Gaussian position noise (σ ≈ 5 m) to mimic real GPS variance.
6. Record toggle that captures every reported coordinate for a session; today's recordings are retained for replay.
7. Joystick must work *during* a direct-travel or route-playback session, not only standalone.
8. First-class saved routes alongside saved waypoints.

## Gap summary

|#|Requirement                                  |Status in baseline|Phase delivering V2 work|
|-|---------------------------------------------|------------------|------------------------|
|1|USB / Wi-Fi connect with auto-discovery      |Partial (manual RSD)|Phase 8                |
|2|Long-press teleport in any mode              |Gated to joystick mode|Phase 6                |
|3|Second-point destination on map; direct or routed|Search-bar only|Phase 7                |
|4|Calibrated base speeds + custom km/h         |Wrong cycle/drive, no custom|Phase 6                |
|5|Always-on GPS noise (σ ≈ 5 m)                |None             |Phase 6                |
|6|Record button + per-day recordings library   |None             |Phase 9                 |
|7|Joystick layered on direct travel / route playback|Mutually exclusive|Phase 10               |
|8|Saved routes library                         |GPX file only    |Phase 11                |

-----

## Phase 6 — Always-On Realism (1 evening)

**Goal:** the device's reported location should look indistinguishable from a real GPS fix while idle, and the speed selector should match the spec.

### 6.1 — Calibrate base speeds + custom value

- `AppState.swift::TransportMode.baseSpeed`: walk stays at 1.4 m/s; cycle becomes `15.0 / 3.6 ≈ 4.167`; drive becomes `50.0 / 3.6 ≈ 13.889`.
- Add a fourth case `case custom(Double)` carrying km/h. `baseSpeed` reads as `kmh / 3.6`. Update `directionsTransportType` to map custom → `.automobile` if ≥ 20 km/h, else `.walking` (driving routes for fast custom values, walking polylines for slow ones).
- `ContentView.swift::RouteSection`: when `.custom` is selected, reveal a numeric `TextField` for km/h next to the picker. Validate `> 0`, clamp display to 1 decimal. Persist last custom value to `UserDefaults`.
- `JoystickSection`: same control reused (the speed cap is the same concept on both sides).

Keep `speedMultiplier` as-is — it is a playback fast-forward (1×/5×/100×) for time-compressed testing, orthogonal to the simulated real-world speed.

### 6.2 — Ambient GPS noise

- New file `TrailMate/LocationNoise.swift`: `final class LocationNoise` with `var sigmaMeters: Double = 5.0`, a Box-Muller Gaussian sampler, and `func apply(to coord: CLLocationCoordinate2D) -> CLLocationCoordinate2D` that adds zero-mean N(0, σ²) jitter independently to the latitude and longitude axes (in meters, then converted to degrees using the local-flat math at the current latitude — same approximation used in `JoystickEngine.tick()`).
- `AppState.swift`:
  - Hold one `LocationNoise` instance.
  - Introduce a single private chokepoint `private func emitSimulated(_ clean: CLLocationCoordinate2D)` that:
    1. Stores `clean` in `simulatedCoordinate` (the map marker shows the intent, not the jitter — keeps the marker steady visually).
    2. Calls `daemonBridge?.setLocationQuiet(latitude:longitude:)` with `noise.apply(to: clean)`.
  - Route every existing call site through this chokepoint: `teleport`, `handlePlaybackPosition`, `recenterJoystick`, and the new direct-travel mode from Phase 7.
- Idle jitter: start a 1 Hz `Task` on `connect()` that re-emits the current `simulatedCoordinate` through `emitSimulated` whenever `playbackState == .idle` and `joystickEngine.isActive == false`. Cancels in `disconnect()`. This is what makes a "stationary" location wiggle a few metres each second, matching what an iPhone sitting on a desk would report.
- Sidebar control: optional sigma slider (0–10 m) tucked under "Connection" so the value is tunable for tests that need a cleaner signal. Default 5.

### 6.3 — Lift the long-press gate

- `ContentView.swift::MapArea`, line ~512: remove the `appState.controlMode == .joystick` guard from the long-press handler. Long-press always teleports while connected, regardless of mode. If a route is playing, teleport implicitly stops it (mirror existing joystick-reposition behaviour in `AppState.teleport`).

**Exit criteria:** with no playback active, the map marker stays put but `tcpdump`-style daemon stdin observation shows a fresh `SETQ` ~1×/s with σ ≈ 5 m around the chosen point. Custom km/h flows through both route playback and joystick. Teleport works in Route mode.

-----

## Phase 7 — Map-Driven Travel (1 weekend)

**Goal:** click a point on the map and travel there — either instantly (teleport, already done), in a straight line at the current speed, or following an Apple Maps route — without ever touching the sidebar text fields.

### 7.1 — Long-press popover for the second point

- Replace the current "long-press → immediate teleport" with "long-press → coordinate popover" once `simulatedCoordinate != nil`. The popover offers three actions:
  - **Teleport here** (existing behaviour).
  - **Go directly** — straight-line travel at the current `transportMode.baseSpeed`.
  - **Route here** — `MKDirections` from `simulatedCoordinate` to the chosen point with the current transport type.
- First long-press (no existing simulated coord) keeps the immediate teleport behaviour — there is no "from" yet.
- Implementation: `MapReader`'s long-press handler converts the drag location to a coord, stashes it in `@State var pendingDestination: CLLocationCoordinate2D?`, and surfaces a SwiftUI `.popover` anchored to a `Marker` rendered at that coord. Actions clear `pendingDestination`.

### 7.2 — Direct-travel mode

- Reuse `NavigationEngine`. Add `AppState.travelDirectly(to dest: CLLocationCoordinate2D)`:
  - Builds a two-point `[currentClean, dest]` array.
  - Calls `navigationEngine.loadRoute(coordinates: ..., baseSpeed: transportMode.baseSpeed)` (already linearly interpolates between two endpoints).
  - Calls `navigationEngine.play(multiplier: 1.0)`.
- No new engine code required. The two-point case in `loadRoute` already produces a single straight segment.

### 7.3 — Route from current position

- Add `AppState.routeFromCurrent(to dest: CLLocationCoordinate2D)` that mirrors `calculateRoute` but uses `simulatedCoordinate` as the source instead of `fromCoordinate`, then auto-plays on completion.

### 7.4 — Optional: map-tap for From / To in Route mode

- Right-click context menu on the map: "Set as From" / "Set as To". This is a convenience addition — the From/To text fields stay as a search affordance.

**Exit criteria:** long-press anywhere → popover → "Go directly" walks the marker in a straight line; "Route here" plays an MKDirections polyline; both honour the active `transportMode` and per-tick noise from Phase 6.

-----

## Phase 8 — Device Discovery (1 weekend)

**Goal:** stop pasting RSD address/port by hand. The sidebar shows a device list (USB + Wi-Fi) and connecting picks one.

### 8.1 — Daemon: device-listing subcommand

- New script `PythonDaemon/tm_list_devices.py`. One-shot (not the persistent daemon). Uses `pymobiledevice3.usbmux.list_devices()` and `pymobiledevice3.bonjour.browse_remoted()` (the latter only on iOS 17+, which is the support floor anyway). Emits one JSON line per device: `{"udid": "...", "name": "...", "connectionType": "USB|Wi-Fi", "address": "...", "rsdPort": null}`.
- Note: enumeration does **not** require root. Only `start-tunnel` does. So the device list is cheap and can run on every sidebar open.

### 8.2 — Swift: DeviceDiscoveryService

- New file `TrailMate/DeviceDiscoveryService.swift`: `@Observable @MainActor` actor that shells out to `tm_list_devices.py`, parses JSON lines, and exposes `var devices: [DiscoveredDevice]`. Refreshes on app foreground and on a manual "Rescan" button.
- `DiscoveredDevice` carries `udid`, `name`, `connectionType` (`.usb` or `.wifi`), and optional `rsdAddress`/`rsdPort` once a tunnel is up.

### 8.3 — Sidebar: device picker

- Replace the bare RSD address/port `TextField`s with a `Picker` of discovered devices plus a "Manual entry…" escape hatch (keeps the existing fields available for the case where the user has a tunnel started by some other tool).
- After picking a device with no live tunnel: a "Start Tunnel" button shows the exact `sudo pymobiledevice3 lockdown start-tunnel --udid <UDID>` line with a "Copy" affordance, so the user can run it once in a terminal. The daemon-bridge connection still uses the RSD address/port returned by that command — same as today.
- (Automating `start-tunnel` requires the SMAppService privileged helper deferred in Phase 4. Tackle in a follow-up; out of V2 scope unless that helper lands first.)

### 8.4 — Wi-Fi prerequisite hint

- If a device shows up as USB-only and the user has never run `pymobiledevice3 lockdown wifi-connections on`, the picker exposes a one-time "Enable Wi-Fi for this device" action that runs the command (no sudo needed). This persists on the device side; subsequent reboots pick up the Wi-Fi route.

**Exit criteria:** plugging in a fresh iPhone over USB makes it appear in the picker within ~2 s of opening the sidebar. After `wifi-connections on` and a reboot, the same device appears via Bonjour with `connectionType == .wifi`. The "Connect" flow still funnels through `DaemonBridge` with no protocol changes.

-----

## Phase 9 — Session Recording (1 weekend)

**Goal:** a record toggle in the toolbar captures every emitted coordinate; today's sessions persist to disk and can be replayed.

### 9.1 — RecorderService

- New file `TrailMate/RecorderService.swift`: `@Observable @MainActor final class RecorderService`. State: `isRecording: Bool`, `currentSession: RecordedSession?`. Methods: `start()`, `stop() -> URL` (returns the saved file URL), `append(_ coord: CLLocationCoordinate2D, at: Date)`.
- `RecordedSession`: `id: UUID`, `startedAt: Date`, `points: [(Date, CLLocationCoordinate2D)]`. Codable.
- Wired from `AppState.emitSimulated`: every coord written to the daemon also goes to the recorder if recording is on. Record the *clean* coordinate (intent), not the noisy one — the noise is a transport-layer effect, not a property of the trajectory we want to replay.

### 9.2 — Persistence

- File layout: `~/Library/Application Support/TrailMate/recordings/YYYY-MM-DD/HHmmss-<uuid>.gpx`. GPX format reuses `GPXService.generate(coordinates:speedMPS:)` (extend to take an array of `(Date, coord)` tuples so per-point timestamps are preserved instead of derived).
- A small `Recordings` directory wrapper struct enumerates today's files at app start.

### 9.3 — UI

- Record button in the map's top overlay (currently the hint pill area). Two states: idle (red dot, "Record") / active (white square inside a red ring, "Stop", with elapsed time + point count).
- New sidebar section `Recordings` (visible only when `!recordings.isEmpty`): grouped by date with today expanded. Each row shows duration, point count, distance. Context menu: Replay (loads coords into `NavigationEngine` and plays), Export (`NSSavePanel` copy out as `.gpx`), Delete.

### 9.4 — Replay edge cases

- Replaying a recorded session uses the original timestamps, not the current `transportMode.baseSpeed`. Path: `NavigationEngine.loadRoute(timestamped:)` (new overload) — if timestamps are present, advance by wall-clock delta against the recording's first timestamp; otherwise fall back to constant-speed playback.

**Exit criteria:** start recording, joystick around for two minutes, stop. A file appears under today's folder. Sidebar lists it. Replay reproduces the same trajectory at the original cadence; GPX export round-trips identically.

-----

## Phase 10 — Composite Control (1 weekend)

**Goal:** the joystick is no longer mutually exclusive with route playback or direct travel. The user can deviate from a route with the stick and rejoin it.

### 10.1 — Velocity-vector refactor

- Currently both engines write final coordinates to `AppState.handlePlaybackPosition`. Refactor them to publish *velocity vectors* (m/s in local-flat ENU) instead, with a single integrator in `AppState` summing the vectors per tick.
- New `final class PositionIntegrator` owned by `AppState`. State: `current: CLLocationCoordinate2D`. Method: `step(velocity: (vx: Double, vy: Double), dt: Double)`. Integration uses the same local-flat math as `JoystickEngine.tick()`.
- `NavigationEngine` becomes a velocity source: at each 10 Hz tick, computes the tangent vector along the polyline at its current distance-along-route and scales by `baseSpeed * speedMultiplier`. It still tracks distance-along-route internally so progress/elapsed UI keeps working, but the *position* is no longer authoritative — only the velocity is.
- `JoystickEngine` becomes a velocity source: stick magnitude × `baseSpeed`, with the dead zone unchanged. Its `currentPosition` field goes away.
- The 20 Hz tick wins: when both engines are active, the integrator runs at 20 Hz, and `NavigationEngine`'s tangent is sampled every 50 ms instead of every 100 ms.

### 10.2 — Behavioural rules

- When playback is active and joystick stick magnitude > dead zone, the integrator sums both velocities. The route's distance-along-route still advances at its tangential speed; the joystick contributes purely orthogonal/longitudinal offsets that *drift* the actual position away from the polyline.
- Add a `var routeDeviation: Double` (meters) on `NavigationEngine`, computed as the great-circle distance from `integrator.current` to the nearest point on the polyline. Surface in the playback progress UI as "off-route: 42 m" when > 5 m.
- "Rejoin" button: snaps the integrator's position to the nearest polyline point and resumes pure-route motion until the stick is touched again.
- A long sustained joystick deviation can be interpreted as "abort route" — if `routeDeviation > 200 m` for > 10 s, log a warning and switch to free joystick mode (route stops). Threshold values picked to feel intentional but not annoying; tune in testing.

### 10.3 — Direct travel deviation

- Direct travel uses the same velocity model (Phase 7.2 builds on `NavigationEngine`'s two-point case), so it inherits joystick layering for free.

**Exit criteria:** play a 2 km route at Walk speed; mid-route, push the stick perpendicular — the marker drifts off the line and the "off-route" indicator updates; release the stick — the marker resumes forward motion along the polyline at the new offset; press "Rejoin" — it snaps back.

-----

## Phase 11 — Route Library (1 evening)

**Goal:** routes are first-class saved entities, just like waypoints. Calculating, importing, or recording a route can be saved by name and re-played later.

### 11.1 — Model

- `SavedRoute`: `id: UUID`, `name: String`, `createdAt: Date`, `transportMode: TransportMode`, `coordinates: [CLLocationCoordinate2D]`, optional `source: SavedRouteSource` (`.calculated(from: String, to: String)`, `.directTravel`, `.recorded(sessionId: UUID)`, `.importedGPX(filename: String)`).
- Persistence: one JSON file per route under `~/Library/Application Support/TrailMate/routes/<uuid>.json`, plus an index file for ordering. UserDefaults is unsuitable — a long city walk is hundreds of KB.

### 11.2 — UI

- New sidebar section `Saved Routes` adjacent to `Saved Locations`. List rows show name, distance, transport mode. Actions: Load (sets `routeCoordinates`, switches to Route mode), Replay (loads + plays immediately), Export (GPX), Rename, Delete.
- "Save Current Route" button appears under the route playback section whenever `!routeCoordinates.isEmpty`. Prompts for a name (alert with `TextField`, mirroring the saved-waypoint flow).

### 11.3 — Recorded → saved promotion

- A Recordings row's context menu gains "Save as Route…" — converts a `RecordedSession` to a `SavedRoute` (dropping the timestamps; the route is replayed at the current `baseSpeed`).

**Exit criteria:** Calculate a route from Taipei 101 to Elephant Mountain, save as "ele-mtn-walk", restart the app, see it in the sidebar, click Replay, watch it play through `NavigationEngine`.

-----

## Phase ordering and dependencies

```
6 (realism + speed)
   ↓
7 (map-driven travel) — depends on 6's emit chokepoint
   ↓
8 (discovery) — independent of 7; can swap order if discovery is more painful day-to-day
   ↓
9 (recording) — depends on 6's emit chokepoint
   ↓
10 (composite) — depends on 7 (direct travel) being the same engine path
   ↓
11 (route library) — depends on 9 (recordings → routes)
```

Phase 6 is the smallest and unblocks every later phase, so it goes first regardless. Phases 8 and 9 are independent; pick whichever is more useful first. Phase 10 is the largest behavioural change and should land after recordings exist so deviations can be reproduced from a saved trace.

## Cross-cutting concerns

- **Daemon protocol:** none of these phases require new daemon commands. `SETQ` already carries the per-tick traffic. The composite integrator runs at 20 Hz, which is what joystick already pushes today — no new load on the iOS side.
- **Testing:** add unit tests for `LocationNoise` (mean/variance over N samples, distribution shape), `PositionIntegrator` (closed-form check against a 1-second-straight-line), and `RecorderService` round-trip (record → persist → reload → coords identical).
- **Performance budget:** still the 100 ms floor from `claude-code-notes.md`. The composite integrator at 20 Hz is well below that; the recorder's per-tick `append` is an in-memory array push (free) with a flush-to-disk only on `stop()`.
- **Backwards compatibility:** `TransportMode` gains a `.custom(Double)` case — the `Codable` derivation on `SavedWaypoint` is unaffected (it stores raw lat/lon), but `SavedRoute` will need a hand-written Codable for the associated value. Worth fixing the enum's `Codable` story when Phase 11 lands.
- **Privileged-helper coupling:** Phase 8.3 explicitly punts the "no-sudo tunnel start" goal to whenever the SMAppService helper from Phase 4 ships. Document the manual tunnel step in the picker UI so the workflow is unambiguous.

## Open questions

- Should noise jitter apply during direct-travel mode the same way it applies during route playback? Current plan says yes (it's just another playback path). Confirm with a side-by-side recording before locking in.
- Recordings folder retention: keep forever? Cap by size? Per-day rolling delete? Defer to a follow-up — disk usage at ~20 bytes/point × 20 Hz × 1 hr is ~1.4 MB/hr, which is fine until it isn't.
- Custom km/h above ~120 km/h is past anything the routing engine plans for — accept and let it run, or clamp? Currently planned to accept; high speeds are useful for stress-testing time-based logic.
