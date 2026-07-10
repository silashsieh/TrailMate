import CoreLocation

// The high-frequency plane of simulation state (epic 041). Carries only the
// values that change at telemetry rate — the clean position and its
// route-relative derivatives — so a consumer can move the red dot per tick
// without evaluating a SwiftUI body. Structural state (playback state,
// joystick/recording flags) travels the other plane: change-guarded writes to
// SimulationStateBridge. Split this way because Observation does not dedupe
// same-value writes, so folding telemetry into the @Observable bridge would
// re-invalidate every observing view on every tick.
//
// A Sendable value type: built on SimulationActor, consumed anywhere.
struct TelemetryFrame: Sendable {
    var coordinate: CLLocationCoordinate2D?   // last emitted clean position
    var progress: Double                      // 0…1 within the current leg
    var elapsedDistance: Double               // meters along route
    var routeDeviationMeters: Double
    var recordingPointCount: Int
}
