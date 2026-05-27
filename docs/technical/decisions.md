# Key Technical Decisions (and why)

## D1: Why pymobiledevice3 instead of native Swift via libimobiledevice?

The iOS 17+ RSD tunnel uses RemoteXPC, personalized DDI mounting, and TUN-based encrypted tunneling. Reimplementing this protocol stack in Swift is a multi-week effort that adds zero user-visible value over shelling out to a maintained Python library. pymobiledevice3 has ~10 releases per year, is the de facto reference implementation, and we can pin a version for reproducibility. Trade: ~80MB app size for the Python runtime; acceptable.

## D2: Why a persistent daemon instead of CLI invocation per command?

Each `pymobiledevice3` CLI invocation pays Python interpreter startup (~500ms-1s) plus tunnel setup (~1-3s on first call). For joystick mode at 20Hz, that's a non-starter. Keeping one daemon alive with the tunnel and DVT handle pre-opened reduces per-command latency to <10ms.

## D3: Why a separate privileged helper instead of running the whole app as root?

Two reasons. First, only the TUN interface creation needs root; everything else (UI, MapKit, GameController, daemon stdin/stdout) is fine as the regular user. Running the whole app as root would be a gratuitous security mistake. Second, it's idiomatic macOS: SMAppService is the documented modern path, and the entitlements / installation flow is well-understood. The helper is ~100 lines of Swift.

## D4: Why MapKit over Google Maps or OpenStreetMap?

Free, no API key, no account, no quota, native SwiftUI integration, MKDirections for routing in one line. The only argument against is map data density — Apple's data for Taipei walking routes is decent but not as detailed as OSM in some neighborhoods. If that becomes a real problem, OSRM can be slotted in as the routing backend behind a `RoutingService` protocol while keeping MapKit for visualization.

## D5: Why 10Hz for routes and 20Hz for joystick?

CoreLocation typically delivers updates to apps at ~1Hz by default, and rapid updates get coalesced. 10Hz on the wire ensures we're never the bottleneck for route playback while not wasting CPU. Joystick mode benefits from a slightly tighter loop for perceived responsiveness during direction changes; 20Hz feels noticeably more direct than 10Hz in user testing of similar tools.

## D6: Why local-flat coordinate math instead of geodesic (Haversine)?

For per-tick movement at human-scale speeds (1-25 m/s) and one-tick distances (5cm-1.25m), the flat approximation is correct to better than 0.001%. Geodesic math at this scale is engineering overkill. We use it anyway for any total-distance calculation over a route (just `MKPolyline.totalDistance` via MapKit's own geodesic implementation).

## D7: Why a SimulationActor instead of keeping everything on MainActor?

Before the actor split, the 20 Hz aggregator and the engines all ran on MainActor inside AppState. Any SwiftUI hitch — map gesture, layout pass, sheet animation — could stall the loop and delay `SETQ` delivery to the device, manifesting as visible jitter on the iPhone side. A `Thread.sleep(forTimeInterval: 0.3)` on MainActor would pause the device's simulated motion for the full 300 ms.

The fix is to move the simulation core (aggregator, idle jitter, deviation check, the four engines) onto its own actor's executor. Engines are kept as `nonisolated final class` so the tick is still a synchronous sequence of plain method calls — no per-tick `await` hops between isolation domains, which would reintroduce the same stall problem on a different thread. `DaemonBridge.setLocationQuiet` is `nonisolated` on a serial dispatch queue so the actor's hot path can call it without crossing into the bridge's isolation either.

The 2 Hz UI throttle (introduced as a perf hotfix when the MapPolyline rebuild at 20 Hz was the dominant CPU cost) is folded into the actor's snapshot push, so there's exactly one place that decides when SwiftUI sees a new coordinate. The backend still receives every tick at 20 Hz.

A `SimulationBackend` protocol abstracts the device-control side: `DaemonBridge` (pymobiledevice3 over a privileged tunnel) is one implementation; future implementations — ADB for Android, SSH to a jailbroken iPhone, a record-only mock for tests — slot in without touching the engines. This is the smallest forward-looking abstraction that pays off no matter which long-term direction the project takes. The full XPC service split (separate binary, codable proto) was considered and explicitly deferred: it costs ~weeks of plumbing and isn't justified until there's a concrete second client.

## D8: Why model stops as a separate `RouteStop` type instead of unifying From, To, and stops behind one model?

The current `AppState` keeps From and To as inline `(LocationSearch, CLLocationCoordinate2D?)` pairs. When adding intermediate stops, the obvious refactor is to unify all three into one `RouteWaypoint` model and an ordered list. That refactor touches every call site of `fromCoordinate` / `toCoordinate` (route building, saving, loading, long-press flow, GPX export, etc.) and is large enough to want its own review. We chose to ship multi-stop routing first as an additive change — a new `RouteStop` type, a new `stops: [RouteStop]` collection — and defer the unification to a follow-up PR. The `RouteStop` shape is intentionally identical to what a unified `RouteWaypoint` would be, so the follow-up is a refactor, not a redesign.

The join-vertex dedup tolerance (`RouteMath.joinSegments(toleranceMeters:)`) is meters-based rather than degree-based. A degree-based tolerance over-dedupes near the equator and silently fails to dedupe near the poles, and MKDirections returns segment endpoints quantized at meter scale anyway. 2 m sits above the quantization floor and well below any road segment a user can perceive.
