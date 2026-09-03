# Features

Single inventory of what ships in TrailMate today, plus items that were considered during planning but ultimately dropped, deferred, or superseded. For implementation history, see [../project-plan/phases.md](../project-plan/phases.md) or the git log.

## Shipped

### Connection & device discovery

- USB and Wi-Fi devices enumerated by `PythonDaemon/tm_list_devices.py` (uses `usbmux.list_devices` + `bonjour.browse_remoted` from pymobiledevice3). For each discovered UDID the lister opens a lockdown client (`autopair=False`) to read `DeviceName`, so the picker labels devices with their iOS-set name; falls back to the UDID suffix when lockdown isn't reachable (unpaired or pure-remoted only).
- **Simultaneous multi-device (epic 012).** Connect and drive several paired iPhones at once. A sidebar device *switcher* lists one row per device (color-coded, with status); selecting a row binds the shared control surface — route planner, playback bar, joystick — to that device. "Add Device" opens another slot. The map shows every connected device's route + simulated dot in its own color, with the selected device emphasized. Designed for *a few* devices (each is an independent 10 Hz loop + daemon), not dozens.
- `TunnelBroker` opens one privileged `pymobiledevice3 remote tunneld` (`PythonDaemon/tm_tunneld.sh`) via `osascript … with administrator privileges` — **one auth dialog per session, N tunnels**, with hot-plug and promptless sleep/wake recovery. Each device's RSD endpoint is resolved fresh from tunneld's HTTP API at connect (the address+port are ephemeral — tunneld reassigns them on every (re)establishment), keyed by the stable UDID. Teardown on quit/host-death force-kills the daemon (SIGTERM → grace → SIGKILL) so a tunneld wedged on an active tunnel can't leak (epic 032); as a backstop, a fresh launch also reclaims any leftover via tunneld's `/shutdown` before binding (epic 031, best-effort).
- Each connected device runs its own `tm_daemon.py`; commands route to a device by its bound UDID end-to-end, so a command for one device never reaches another.
- macOS sleep (`NSWorkspace.willSleepNotification`) triggers a clean disconnect of every device, since the DVT session can't survive sleep.
- Tunnel-down / daemon-exit callbacks tear the affected device's live state down automatically — no polling heartbeat, no stale "connected" state.

### Map view

- Full-pane MapKit view with pan / zoom.
- Search bar with `MKLocalSearchCompleter` autocomplete (used in the route From/To pickers and the standalone "Go to Location" search — see "Direct location entry").
- Simulated position rendered as a distinct marker.
- Right-click opens the destination menu at the pointer; a 0.5 s long-press is kept as a fallback trigger (see "Map-driven travel" below).
- Camera position (center + span) persists across launches via `UserDefaults`; first launch defaults to Taipei.
- The simulated position (red dot) is a live local state that exists with or without a device connected — teleport, route playback, and the joystick all move it offline, and a connected device mirrors it, snapping to its current spot the moment the session attaches (epic 028). It persists across launches and is restored on launch by default; first launch starts at the same Taipei landmark. "Restore last location on launch" (Settings window, ⌘,) opts out back to a start-empty launch — the position is recorded either way.
- Follow control on the map overlay (next to Record) recenters on and tracks the simulated position, keeping the current zoom. Any manual camera gesture hands control back (MapKit user-tracking semantics); disabled until a simulated position exists; session-only, not persisted.
- Pencil control beside them toggles freehand route drawing (see "Hand-drawn routes" below).

### Teleport

- Right-click (or long-press) → "Teleport" sets the simulated position instantly.
- Works any time, connected or not — it moves the local red dot; a connected device follows immediately, a disconnected one snaps to it on the next connect. Doubles as the way to set the starting location for joystick input when launch restore is off.
- Disconnecting reverts the *device* to its real GPS — the daemon clears the DVT `simulate-location` handle on shutdown — but the local red dot stays put and controllable, so reconnecting re-syncs the device to wherever it ended up. (There is no separate user-facing "Clear" control.)

### Direct location entry (epic 027)

- "Go to Location" sidebar section, independent of the route From/To fields — it consumes no route slot.
- **Search a place → go there.** A standalone `MKLocalSearchCompleter` search field; tapping a result resolves it and teleports the red dot directly (the result row *is* the "go here" affordance, unlike the route fields where a pick just fills the slot), then frames it on the map (#42).
- **Coordinate field.** Type a decimal-degree `lat, lon` and press Return or "Go" to teleport (#52). `CoordinateFormat.parse` accepts a comma or whitespace separator, tolerates surrounding whitespace and signed values, and range-checks lat ∈ [-90, 90] / lon ∈ [-180, 180]; the Go button stays disabled until the text parses, and a one-line hint appears after a failed parse. Decimal degrees only — DMS is out of scope.
- **Copy a coordinate.** "Copy Current Coordinate" copies the red dot's position to the clipboard (`NSPasteboard`) as a paste-able `lat, lon` string (`CoordinateFormat.string(from:)`, 6 dp, round-trips back through the coordinate field). The map's right-click destination menu and long-press action bar also offer "Copy" for the clicked point (#52).
- All of these reuse the existing teleport path, so none are gated on a connection: they move the local red dot and a connected device mirrors it (epic 028).

### Route playback

- The whole section works with no device connected: search, stops, transport, Calculate Route, GPX import/export, Save Route, and Play all function offline. Play animates the local red dot; a connected device mirrors it. Nothing here is gated on a connection (epic 028).
- From/To via search or by promoting a destination picked on the map. A location-arrow button beside From fills it with the current simulated position (disabled until a position exists).
- Optional intermediate stops between From and To, visited in order. Each stop has its own search field; "Add Stop" appears once both endpoints are set. Soft notice above 10 stops (Apple Maps throttling risk); no hard cap.
- Transport mode: Walk (5 km/h), Cycle (15 km/h), Drive (50 km/h), or Custom km/h (`TransportMode.custom`).
- `MKDirections.calculate()` is issued per segment ([From, …stops, To] pairs); polylines are merged via `RouteMath.joinSegments` (2 m meters-based join-vertex dedup).
- `NavigationEngine` interpolates along the polyline at the configured base speed.
- Playback time-fast-forward multipliers: 1× / 5× / 10× / 100×.
- Loop playback: Off / Restart / Ping-Pong, with an optional loop count (∞ by default, stepper up to 99). Restart jumps the marker back to the start when the route completes and replays; Ping-Pong walks back along the same polyline — no re-routing, so the return leg is the outbound path exactly. One loop = one start-to-end pass (Restart) or one there-and-back round trip (Ping-Pong); the count reached, playback ends cleanly. The setting is engine-wide — it also loops direct travel, "Route here", wander routes, and recording replays — and session-scoped, like the speed multiplier.
- Transport controls: Play / Pause / Stop. Draggable timeline scrubber (elapsed / total distance): drag to seek anywhere on the route, forward or back; playback continues from the sought point in its prior play/pause state. Track clicks and keyboard arrows seek too. The bar runs 0→1 per leg — on a Ping-Pong return leg, scrubbing seeks within that return leg; while looping, a "Loop k of N" line shows the current iteration.
- While dragging, route advance holds and the device follows the scrub live — positions stream at up to 10 Hz (and land in an active GPX recording, like any other emission); the map red dot tracks the thumb.
- Play on a route that already ran to completion replays it from the start — unless the idle route was scrubbed first, in which case Play starts from the sought point.
- Wall-clock remaining time shown alongside the scrubber in `HH:mm:ss`; accounts for the active playback multiplier (e.g., a 30-min trip at 10× reads ~3 min).
- Saved routes capture the planner inputs (From / To / stops with their labels) so they can be re-loaded as editable fields, not just replayed as a flat polyline. Routes saved before this field existed still play; their planner fields stay empty.

### Map-driven travel

- Right-click anywhere on the map to open a native context menu at the pointer (its header shows the clicked coordinate); a 0.5 s long-press opens the same actions as a capsule action bar instead — kept as a fallback trigger. Every action drives the local red dot, so all of them work with or without a device connected (a connected device mirrors the result); only origin-dependent actions disable until a position exists (epic 028). Actions:
  - **Teleport** — instant. Trigger nuance when no simulated position exists yet: long-press teleports immediately (nothing to route from), while right-click still opens the menu with the origin-dependent actions disabled.
  - **Go directly** — straight-line travel at `transportMode.baseSpeed`, served by `NavigationEngine`'s two-point case.
  - **Route here** — `MKDirections` from the current simulated position to the chosen point; auto-plays.
  - **Append direct / Append route** — extend the loaded route from its end to the chosen point (straight line / `MKDirections`); offered only while a route is loaded.
  - **Wander nearby…** — opens a sheet with two peer route modes, a segmented **Random / Sweeping** picker at the top. Both use the clicked point as their center and share one radius control (250 / 500 / 750 m or custom). Every selection — mode, radius, duration, lane spacing, including custom values — persists across launches via `UserDefaults` (`WanderPresetPersistence`), written on each change rather than on Start, so the sheet reopens exactly as it was left; first run defaults to Random, 500 m, 60 min, 70 m spacing. The generated route is one-shot, not persisted.
    - **Random** — pick a duration (30 / 60 / 120 min or custom). `WanderRouteBuilder` chains `MKDirections` walking hops between random points around the center until total walked distance ≈ `effectiveBaseSpeedMPS × duration`. The wander may leak slightly beyond the disc.
    - **Sweeping** — a geometric serpentine (boustrophedon, "mow the lawn") covering a north-up square centered on the same point, side exactly `2 × radius` — the radius is the center-to-edge half-side, and the sheet spells the side and lane count out to say so. `CoverageRouteBuilder` lays lanes east-west and steps them south to north at the chosen lane spacing (default 70 m), centering the lane set between the south and north edges so a square narrower than one spacing still gets one edge-to-edge pass. Alternating lane direction means no segment is retraced, and the output is deterministic: same inputs, same coordinates. There is no duration control — the geometry fixes the length, and the sheet shows the resulting distance and `length ÷ effectiveBaseSpeedMPS` time before Start. Nothing snaps to roads (no `MKDirections`), the same way hand-drawn routes don't. Loading it teleports the marker from the center to the first edge point — the west end of the southernmost lane — and that jump counts as neither distance nor time.
    - Either mode loads into `NavigationEngine` and auto-plays through the selected session.
  - **Copy** — copies the clicked point's coordinate to the clipboard as a paste-able `lat, lon` string (epic 027, #52); in the action bar it leaves the bar open so it can precede another action on the same point.

### Hand-drawn routes

- A pencil toggle on the map overlay (next to Record/Follow, but always visible — drawing is
  route *construction* like the sidebar planner, so it needs no connection) enters draw mode:
  map pan is disabled (zoom stays live), the pointer becomes a selection crosshair, and
  dragging sketches a dashed orange preview stroke. Esc cancels; the right-click menu and
  long-press are suppressed while drawing.
- On release the stroke is smoothed (Chaikin corner-cutting, two passes) and uniformly
  resampled by `StrokeGeometry` — spacing `clamp(base speed × 1 s, 2–15 m)`, ≈ one vertex per
  second of 1× playback — then loaded through the same playback path as every other route
  source: scrubber, loop modes, speed multipliers, joystick compositing, Export GPX all apply.
  No auto-play; press Play (or scrub) to run it.
- The route follows the stroke exactly — through parks, trails, anywhere off-road. Nothing
  snaps to roads ("snap to road" is a possible future extension, out of scope today).
- A click-sized stroke or jitter blob is rejected with a log line and draw mode stays active;
  a successful stroke exits draw mode. Each stroke replaces the loaded route.

### Joystick

- Armed on the **selected** device — no Start button, and regardless of connection, so the one physical controller / WASD / virtual stick drives one red dot at a time (switching the selected device re-homes the joystick). It steers the local position whether or not a device is attached; a connected device mirrors the motion (epic 028). The engine stays inert (no marker, and offline nothing to mirror) until a position seeds the integrator — the restored launch position or the first teleport; from then on, stick input drives the simulated location at the configured base speed.
- Hardware game controller via `GameController.framework` (MFi / DualShock / Xbox / Joy-Con; hot-pluggable).
- On-screen virtual stick (SwiftUI `DragGesture` inside a circular pad) as fallback. It floats in the map's bottom-trailing corner as a safe-area inset, so MapKit's built-in zoom and compass controls reflow above it and stay reachable instead of being occluded; the inset collapses when the stick is idle, returning the controls to the corner.
- WASD + arrow-key input on the focused map view.
- 10 Hz control tick, 10% dead zone.
- Speed cap reuses the same `TransportMode` (including Custom km/h); the picker lives in the Route section and drives both engines.

### Composite control

- Joystick and route playback / direct travel are not mutually exclusive.
- `PositionIntegrator` owns authoritative position; engines publish velocity vectors that are summed per tick.
- During route playback, joystick deflection drifts the simulated position off the polyline; off-route distance is surfaced as "Off-route: 42 m" once it exceeds 5 m.
- **Rejoin** snaps the integrator back to the nearest polyline point.
- Sustained large deviation (>200 m for >10 s) auto-aborts the route and switches to free joystick.

### Always-on GPS noise

- `LocationNoise` adds Box-Muller Gaussian jitter (σ default 5 m, configurable 0–10 m in the Settings window) to every `SETQ` emission, including idle.
- Single `SimulationActor.emit()` chokepoint routes every coord through the noise filter.
- 1 Hz idle re-emission keeps a "stationary" location wiggling like a real GPS fix.
- The map marker shows the clean intent, not the jittered emission, so the on-screen position stays steady visually.

### Settings window

- Standard macOS `Settings` scene (⌘, / app menu → Settings…) holding the set-and-forget
  preferences: GPS noise σ and "Restore last location on launch". Changing σ applies live to
  an active session.
- The sidebar holds only live route/session controls. Transport mode and custom km/h stay in
  the Route section: they're per-route choices that drive the MKDirections transport type and
  cap joystick speed.

### Saved waypoints

- Save current location with a name prompt; persists to `UserDefaults` as JSON (name, coordinate, optional folder).
- Sidebar list. Click a row to **select** it: the map pans and frames the location, and — when connected — the device teleports there. Right-click for rename (inline, Finder-style) / delete.
- **Drag to reorder** within a section; the order persists (it's the stored array order). Right-click → **Category** files the item into a user-defined folder (pick an existing one or create a new one); each folder renders as its own sidebar section. Folders are derived from the items, so an emptied folder simply disappears.

### Saved routes

- `SavedRoute` with name, transport mode, coordinates, and a `source` tag. Two values are written today: `recorded` (a recording promoted via "Save as Route…") and `calculated` (everything saved with the Route section's "Save Route…", which currently tags *all* loaded routes — planner, direct, imported, wander, and hand-drawn — as `calculated`).
- Persisted as per-route JSON under `~/Library/Application Support/TrailMate/routes/`. The drag-reorder sequence lives in a sidecar `order.json` in the same folder (a reorder is one small write, not a rewrite of every route file); the folder assignment lives in each route's own JSON.
- Per-row Load / Replay / Rename (inline, Finder-style) / Delete. Selecting a route (tap, Load, or Replay) frames the whole route on the map. To export a route as GPX, load it and use the Route section's Export GPX.
- **Drag to reorder** and right-click → **Category** folder assignment, same model as saved locations (folders are derived from the items; reordering one folder leaves the others put).
- "Save as Route…" promotes a recorded session into the route library.

### Session recording

- Record button on the map overlay (shown whether or not a device is connected); captures the clean (pre-noise) coordinate on every `SimulationActor.emit()` call, so it records the local red-dot path even with no device attached.
- Sessions persist as GPX with per-point timestamps under `~/Library/Application Support/TrailMate/recordings/YYYY-MM-DD/`.
- Recordings sidebar lists sessions newest-first; per-row Replay, Export, Delete, and "Save as Route…". (On disk they're grouped into per-date folders, per the path above.)
- Replay plays the recorded coordinates at the current transport speed and multiplier (constant-speed); the per-point timestamps in the GPX are not used to pace playback.

### GPX import / export

- Import: `NSOpenPanel` → `XMLParser` handles `<wpt>`, `<trkpt>`, `<rtept>`. Coordinates load into `NavigationEngine` for playback.
- Export: `NSSavePanel` → GPX with `<wpt>` and ISO 8601 timestamps. Round-trips cleanly.

### Status & diagnostics

- Connection status pill in the sidebar (Connecting / Connected / Disconnected / Error).
- The connected device's friendly name surfaces in the status surfaces (epic 026): in the menu bar status summary, and emphasized for the active session in the sidebar device switcher. It clears on disconnect, so no stale name lingers (`AppState.connectedDeviceName` is the single source of truth).
- A live log section in the sidebar (last 20 entries), a `DisclosureGroup` collapsed by default with the expand/collapse choice persisted across launches (`@AppStorage`). Expand it by clicking the **Log** row's disclosure triangle in the sidebar.
- "View Full Log" sheet (monospaced, Copy All, Clear) showing daemon stdout/stderr — opened from the **View Full Log** button inside the expanded Log section.
- Log entries for tunnel start, daemon exit, sleep, recording milestones, route deviation, joystick arming.

### AI control (command socket) (epic 019)

- An off-by-default AF_UNIX command socket (`ai.sock` under Application Support) lets an external agent (e.g. Claude Code, connecting with `nc -U`) drive the app through the *same* facade the GUI uses, so every command still passes the `emit()` chokepoint (noise + recording). Enabled via a Settings toggle ("AI control"); no socket exists until opted in. (A wrapping `trailmate` CLI and an installable MCP shim are planned but not yet shipped — see [Deferred / dropped](#deferred--dropped).)
- Line protocol modeled on the daemon's (one verb per line, JSON `{ok,code,data?,error?}` response). Verbs: `DEVICES`, `STATUS`, `CONNECT`, `DISCONNECT`, `TELEPORT`, `ROUTE`, `PLAY`, `PAUSE`, `STOP`, `SEEK`, `CLEAR`. A greeting line advertises a protocol version on connect.
- **Device-addressed:** every device-scoped verb carries the target UDID; dispatch resolves the connected session by `connectedUDID` (never the GUI selection), so a command for device A can never reach device B. Unknown vs not-connected devices return distinct machine-readable error codes.

### Menu bar & background mode (epic 021)

- A `MenuBarExtra` shows a live status summary (connected device name + connection + playback/recording) and quick actions (Pause/Resume/Stop, Disconnect, Open TrailMate, Quit), so the app stays controllable with the main window closed. The name is truncated to keep the summary compact and tracks the active session under multi-device.
- Closing the main window keeps the app — and the simulation + AI socket — alive: `applicationShouldTerminateAfterLastWindowClosed = false`, a single reopenable `Window(id:"main")`, and a dynamic activation policy (`.regular` with a window, `.accessory` when closed, configurable via a Dock toggle, with a guard so the app can never be left both icon-less and window-less). The App Nap activity token is connection-scoped, so a windowless app keeps simulating.

### Localization

- UI ships in English and Traditional Chinese (繁體中文). By default the app follows the system language; a **Language** picker in the Settings window (⌘,) overrides it — System Default / English / 繁體中文. "System Default" falls back to English when no system language matches.
- The override is stored under an `AppLanguageOverride` default and mirrored into Foundation's standard `AppleLanguages` UserDefaults key, which Foundation binds at process launch, so a change takes effect on the next launch — the picker notes this. (Not live: several strings resolve through `String(localized:)` against the launch-time bundle, and relaunching mid-session would also drop a live device connection.)
- Strings live in a String Catalog (`TrailMate/Localizable.xcstrings`) — keys are the English source text, extracted by the compiler (`SWIFT_EMIT_LOC_STRINGS`) and synced via `xcstringstool`. The brand name and bare numeric/symbol tokens are marked do-not-translate.
- Log and diagnostic messages (the Log sheet, `addLog` entries) stay English by design — they're for debugging. Device-supplied text (device names) and system error descriptions render verbatim. Language endonyms in the picker ("English", "繁體中文") show in their own script.

### Bundled Python runtime

- TrailMate ships a self-contained CPython interpreter + `pymobiledevice3` inside the `.app` bundle (`Contents/Resources/PythonResources/`). End users do not install Python, pip, or pymobiledevice3.
- Built via `packaging/build.sh` from [python-build-standalone](https://github.com/indygreg/python-build-standalone); the tarball is cached under `packaging/.cache/` so subsequent builds are fast.
- `PythonBundle.swift` resolves the interpreter and script paths at runtime so `tm_daemon.py`, `tm_tunneld.sh`, and `tm_list_devices.py` all run from the bundle in release builds (and from the same paths during `xcodebuild` debug builds). (`tm_tunnel.sh`, the pre-multi-device single-tunnel wrapper, is still bundled but no longer on the live path.)
- Embedded binaries are re-signed by a `Re-sign embedded Python binaries` Run Script phase under the same identity as the host app, with Hardened Runtime options and a secure timestamp for Developer ID builds. A nested-code signing failure stops the build.
- Pin point is the Python interpreter version (default 3.13.x) and the pymobiledevice3 release that `build.sh` installs into the bundle's site-packages; bumping either is a deliberate change with a smoke pass.

### Release distribution

- `packaging/release.sh` supports an explicit credential-free ad-hoc path for local/PR verification and a fail-closed Developer ID path for public releases.
- Developer ID builds import a password-protected `.p12` into an ephemeral keychain, verify the certificate type and team, sign the nested Python code, app, and DMG, then verify the exported app, metadata-preserving staged app, finished DMG, and exact app mounted from that DMG.
- Optional notarization uses a team App Store Connect API key with `notarytool`, then staples and assesses the DMG. The GitHub `release` environment supplies these credentials only to the release job.
- **In-app updates (epic 038).** Sparkle 2.9.6 provides the application-menu **Check for Updates…** action plus automatic-check and automatic-download preferences in Settings. The user still confirms installation and relaunch.
- The app trusts the stable GitHub Pages appcast with a pinned EdDSA public key and verifies signed archives before extraction. Public releases generate the signed feed only after notarization, publish the full DMG on GitHub Releases, then deploy the exact appcast to Pages. Feed generation preserves historical entries and validates that each versioned release tag matches its DMG filename. Dry runs create equivalent private workflow artifacts without publishing. Delta generation is currently disabled because GitHub's per-tag asset paths do not fit Sparkle's single-prefix batch generation; full signed updates remain supported.
- v2.1.3 is the corrected bootstrap updater build and has successfully reached the signed feed from an installed public build. Stable v2.2.0 is its first published download, installation, and relaunch target; the post-release end-to-end update confirmation remains pending. The public v2.1.2 pre-release requires one manual replacement because its updater configuration cannot start safely.

## Deferred / dropped

Items considered during planning that were dropped, deferred, or superseded.

- **`trailmate` CLI and installable MCP shim (epic 019).** v2.0.0 shipped only the AF_UNIX command socket; agents drive it directly over `nc -U`. The planned `trailmate` CLI wrapper (swift-argument-parser, embedded in `Contents/Helpers/`) and the stdio MCP shim that would register into Claude Desktop / other MCP clients are not yet built. Tracked as epic 023 (GitHub issue #54).
- **SMAppService privileged helper.** Still using `osascript … with administrator privileges`. One auth dialog per session is acceptable for personal use; Developer ID signing is now available, but designing and installing a privileged helper remains separate work.
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
