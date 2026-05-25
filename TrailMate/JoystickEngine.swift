import CoreLocation
import GameController

// Owned exclusively by SimulationActor. Marked nonisolated because the
// project sets default actor isolation to MainActor; without this, the
// actor couldn't synchronously call into the engine. GCController
// observation moved to SimulationActor so notification callbacks can
// mutate engine state under actor isolation.
nonisolated final class JoystickEngine {
    enum Direction: Hashable {
        case up, down, left, right
    }

    var isActive = false
    var stickX: Float = 0
    var stickY: Float = 0
    var connectedControllerName: String?

    private var baseSpeedMPS: Double = 1.4
    private var pressedDirections: Set<Direction> = []
    private var virtualStickX: Float = 0
    private var virtualStickY: Float = 0

    func start(baseSpeed: Double) {
        baseSpeedMPS = baseSpeed
        isActive = true
    }

    func stop() {
        isActive = false
        stickX = 0
        stickY = 0
        virtualStickX = 0
        virtualStickY = 0
        pressedDirections.removeAll()
    }

    func updateBaseSpeed(_ baseSpeed: Double) {
        baseSpeedMPS = baseSpeed
    }

    func updateStickInput(x: Float, y: Float) {
        virtualStickX = x
        virtualStickY = y
    }

    func pressDirection(_ direction: Direction) {
        pressedDirections.insert(direction)
    }

    func releaseDirection(_ direction: Direction) {
        pressedDirections.remove(direction)
    }

    // Called by AppState's aggregator. Reads whichever input source is most
    // engaged and returns its (vx, vy) velocity contribution in m/s. Returns
    // (0,0) inside the dead zone, nil only when the engine is inactive — the
    // aggregator may still want to sum a zero contribution alongside the
    // route engine's tangent vector.
    func tick() -> (vx: Double, vy: Double)? {
        guard isActive else { return nil }

        // Priority: hardware controller wins outright. Otherwise pick whichever
        // of virtual stick or keyboard has greater magnitude.
        if let controller = GCController.controllers().first,
           let gamepad = controller.extendedGamepad {
            stickX = gamepad.leftThumbstick.xAxis.value
            stickY = gamepad.leftThumbstick.yAxis.value
        } else {
            var kx: Float = 0, ky: Float = 0
            if pressedDirections.contains(.up) { ky += 1 }
            if pressedDirections.contains(.down) { ky -= 1 }
            if pressedDirections.contains(.left) { kx -= 1 }
            if pressedDirections.contains(.right) { kx += 1 }

            let virtualMag = virtualStickX * virtualStickX + virtualStickY * virtualStickY
            let keyMag = kx * kx + ky * ky

            if virtualMag >= keyMag {
                stickX = virtualStickX
                stickY = virtualStickY
            } else {
                stickX = kx
                stickY = ky
            }
        }

        let magnitude = Double((stickX * stickX + stickY * stickY).squareRoot())
        guard magnitude > 0.1 else { return (0, 0) }

        let cappedMag = min(magnitude, 1.0)
        let scale = cappedMag / magnitude

        let vx = Double(stickX) * scale * baseSpeedMPS
        let vy = Double(stickY) * scale * baseSpeedMPS
        return (vx, vy)
    }

}
