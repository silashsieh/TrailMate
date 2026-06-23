# Key Technical Decisions (and why)

## D1: Why pymobiledevice3 instead of native Swift via libimobiledevice?

The iOS 17+ RSD tunnel uses RemoteXPC, personalized DDI mounting, and TUN-based encrypted tunneling. Reimplementing this protocol stack in Swift is a multi-week effort that adds zero user-visible value over shelling out to a maintained Python library. pymobiledevice3 has ~10 releases per year, is the de facto reference implementation, and we can pin a version for reproducibility. Trade: ~80MB app size for the Python runtime; acceptable.

## D2: Why a persistent daemon instead of CLI invocation per command?

Each `pymobiledevice3` CLI invocation pays Python interpreter startup (~500ms-1s) plus tunnel setup (~1-3s on first call). For joystick mode at the 10 Hz control cadence, that's a non-starter. Keeping one daemon alive with the tunnel and DVT handle pre-opened reduces per-command latency to <10ms.

## D3: Why a separate privileged helper instead of running the whole app as root?

Two reasons. First, only the TUN interface creation needs root; everything else (UI, MapKit, GameController, daemon stdin/stdout) is fine as the regular user. Running the whole app as root would be a gratuitous security mistake. Second, isolating the privileged step keeps the root surface tiny: today only `tm_tunneld.sh` runs as root, brought up via `osascript … with administrator privileges`, while the app stays unprivileged. A packaged SMAppService helper is the documented modern path and would drop the per-session auth prompt, but it needs paid signing, so it's deferred (see features.md).

## D4: Why MapKit over Google Maps or OpenStreetMap?

Free, no API key, no account, no quota, native SwiftUI integration, MKDirections for routing in one line. The only argument against is map data density — Apple's data for Taipei walking routes is decent but not as detailed as OSM in some neighborhoods. If that becomes a real problem, OSRM can be slotted in as the routing backend behind a `RoutingService` protocol while keeping MapKit for visualization.

## D5: Why 10 Hz for the simulation loop?

CoreLocation typically delivers updates to apps at ~1 Hz by default, and rapid updates get coalesced, so wire rate is never the bottleneck for the apps under test. Route playback and joystick share a single 10 Hz aggregator in `SimulationActor`: 100 ms is the invisible floor for app-visible wire freshness, while 4 Hz / 250 ms sits too close to the ~300 ms threshold a human can feel when steering the joystick. SwiftUI redraws are decoupled by snapshot-push throttles (see D7), so the backend still receives every 10 Hz tick.

## D6: Why local-flat coordinate math instead of geodesic (Haversine)?

For per-tick movement at human-scale speeds (1-25 m/s) and one-tick distances (5cm-1.25m), the flat approximation is correct to better than 0.001%. Geodesic math at this scale is engineering overkill. We use it anyway for any total-distance calculation over a route (just `MKPolyline.totalDistance` via MapKit's own geodesic implementation).

## D7: Why a SimulationActor instead of keeping everything on MainActor?

Before the actor split, the aggregator and the engines all ran on MainActor inside AppState. Any SwiftUI hitch — map gesture, layout pass, sheet animation — could stall the loop and delay `SETQ` delivery to the device, manifesting as visible jitter on the iPhone side. A `Thread.sleep(forTimeInterval: 0.3)` on MainActor would pause the device's simulated motion for the full 300 ms.

The fix is to move the simulation core (aggregator, idle jitter, deviation check, the four engines) onto its own actor's executor. Engines are kept as `nonisolated final class` so the tick is still a synchronous sequence of plain method calls — no per-tick `await` hops between isolation domains, which would reintroduce the same stall problem on a different thread. `DaemonBridge.setLocationQuiet` is `nonisolated` on a serial dispatch queue so the actor's hot path can call it without crossing into the bridge's isolation either.

The UI throttles are folded into the actor's snapshot push, so there's exactly one place that decides when SwiftUI sees a new coordinate. Route playback snapshots stay at 2 Hz because the MapPolyline rebuild is relatively expensive; active non-playing snapshots are capped at 10 Hz so joystick steering does not rebuild MapKit faster than the loop cadence. The backend still receives every tick at 10 Hz.

A `SimulationBackend` protocol abstracts the device-control side: `DaemonBridge` (pymobiledevice3 over a privileged tunnel) is one implementation; future implementations — ADB for Android, SSH to a jailbroken iPhone, a record-only mock for tests — slot in without touching the engines. This is the smallest forward-looking abstraction that pays off no matter which long-term direction the project takes. The full XPC service split (separate binary, codable proto) was considered and explicitly deferred: it costs ~weeks of plumbing and isn't justified until there's a concrete second client.

## D8: Why model stops as a separate `RouteStop` type instead of unifying From, To, and stops behind one model?

The current `AppState` keeps From and To as inline `(LocationSearch, CLLocationCoordinate2D?)` pairs. When adding intermediate stops, the obvious refactor is to unify all three into one `RouteWaypoint` model and an ordered list. That refactor touches every call site of `fromCoordinate` / `toCoordinate` (route building, saving, loading, long-press flow, GPX export, etc.) and is large enough to want its own review. We chose to ship multi-stop routing first as an additive change — a new `RouteStop` type, a new `stops: [RouteStop]` collection — and defer the unification to a follow-up PR. The `RouteStop` shape is intentionally identical to what a unified `RouteWaypoint` would be, so the follow-up is a refactor, not a redesign.

The join-vertex dedup tolerance (`RouteMath.joinSegments(toleranceMeters:)`) is meters-based rather than degree-based. A degree-based tolerance over-dedupes near the equator and silently fails to dedupe near the poles, and MKDirections returns segment endpoints quantized at meter scale anyway. 2 m sits above the quantization floor and well below any road segment a user can perceive.

## D9: Why Apple's design conventions instead of Google Maps' as the interaction baseline?

Issue #19 proposed defaulting to Google Maps' interaction conventions when facing design choices (locate button, player-style playback controls, etc.). Declined (2026-06-06): TrailMate is built on MapKit and is a native macOS app — interaction design follows Apple's platform conventions (HIG, MapKit's built-in behaviors such as user-tracking/follow semantics, standard Settings scene, context menus). Where MapKit or the HIG offers a native control or pattern, we use it rather than imitating another product. Google Maps remains a fine *comparison point* when describing a capability ("a locate button like maps apps have"), but it is not the design reference — when the two disagree, Apple's convention wins.

**Amendment (2026-06-06, epic 005):** platform conventions set the *defaults*, not a straitjacket — an explicit user preference may opt out of a convention-derived default. First case: epic 005 (open) adopts this for the maps-app "never start at a blank position" convention — restore-last-position will be the default, with an opt-out preference to start with no simulated position each launch.

## D10: Why a session *switcher* with a shared control surface for multi-device?

Epic 012 connects N iPhones at once. Two UI shapes were on the table: tabs/split (each device its own full pane) or a switcher (a shared control surface that targets one selected device, with a map showing all). We chose the **switcher**. `AppState` became the device *manager* — it owns a `[DeviceSession]` (always ≥1; the first is an unbound slot holding the restored red dot + pre-connect route planning) and a `selectedSessionID`. The forwarding accessors that the carve introduced now resolve to the *selected* session, so almost all of `ContentView` keeps reading `appState.X` unchanged; only the map iterates all sessions, drawing each one's route + simulated dot in a per-session color. App-global tuning (transport/speed/noise σ/loop — the `$`-bound controls) stays on the manager and fans out to every session's engine, so the shared sliders mean the same thing on every device. Tabs/split are deferred until the switcher proves insufficient — it reuses the existing single-device control surface wholesale, which tabs would have forced us to N-up.

Two structural invariants make N devices correct rather than merely rendered:

- **Device-routing is by `connectedUDID`, never by list position.** Each `DeviceSession` holds its `DaemonBridge` private and a `SimulationActor` only talks to the backend injected at its own `attach()`. `AppState.dispatch` (AI) and the GUI forwarders resolve the target session by its bound UDID, so "device A's coordinate reaches B's daemon" is impossible by construction (proved by `CommandDispatchTests`). `dispatch` never reads `selectedSessionID` — GUI focus is not a routing input.
- **One physical joystick drives one red dot.** Every session's `SimulationActor` reads the live `GCController`, but only the selected session's joystick engine is *armed* (`AppState.syncActiveJoystick`, called on selection change and after every connect/disconnect). Since epic 028 the arm condition is selection alone, not selection + connection — the joystick steers the selected session's local position whether or not a device is attached. A disarmed engine contributes no velocity, so non-selected devices never move from joystick/WASD/virtual-stick input even though their actors still observe the controller.

Scope cut for v2.0.0: position restore stays a single global last-position (restored into the first session at launch, the selected session's saved at quit). Per-UDID restore is a later refinement, not required for the switcher.

## D11: Why the simulated position is a live local state, not a device side effect?

Epic 028 (#45) started as "make map/planning usable while disconnected" and grew, at the owner's request, into decoupling the *simulation* from the connection: the red dot must be controllable with no device attached, and a device must snap to it on connect. We chose to make the **simulated position the authoritative local state** and treat a device connection as a *mirror* of it, rather than gating the driving controls.

Mechanically this is a lifecycle split in `SimulationActor`. The engine loops (10 Hz aggregator, idle jitter, controller observers) now run for the session's whole lifetime — `startEngine()` at `DeviceSession` init, `stopEngine()` at removal/quit — instead of only between connect and disconnect. `attach()`/`detach()` shrank to swapping the device backend: attach injects it, re-emits the current coordinate so the device jumps to the red dot, and takes the App Nap token; detach drops the backend and token but leaves the loops running and the position intact (disconnecting no longer wipes the dot). `emit()` already wrote the bridge unconditionally and the device only via `backend?`, so a disconnected session simulates locally and sends nothing to any device; idle jitter is gated on a live backend so the offline preview doesn't drift.

This **superseded epic 028's first approach** (a `.requiresConnection()` modifier that disabled teleport/play/joystick with a hint while disconnected). With the local-state model those controls simply work offline, so the gating modifier and its hint copy were removed; the only connection-conditional UI left is informational (the map status pill reads "Local position" vs "Simulating", reinforced by the existing green/grey connection dot). The AI command socket is unchanged — it stays device-addressed by `connectedUDID` and still rejects commands to a not-connected device; offline control is a GUI affordance, not a remote one.

Trade-off accepted: every session runs its loops for its whole life (N cheap 10 Hz no-op ticks for N slots), versus the prior "loops only while connected." The aggregator early-returns when no engine contributes, and TrailMate targets a few devices, so the cost is negligible. Per-session leaks are avoided by routing removal/quit through `DeviceSession.shutdown()` (disconnect + `stopEngine`), since `disconnect()` alone now leaves the engine running.
