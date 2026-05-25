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
