import CoreLocation
import GameController

@Observable
@MainActor
final class JoystickEngine {
    var isActive = false
    var stickX: Float = 0
    var stickY: Float = 0
    var connectedControllerName: String?

    var onPositionUpdate: ((CLLocationCoordinate2D) -> Void)?

    private var currentPosition: CLLocationCoordinate2D?
    private var loopTask: Task<Void, Never>?
    private var baseSpeedMPS: Double = 1.4

    private static let metersPerDegLat = 111_320.0

    init() {
        setupControllerObservers()
    }

    func start(at coordinate: CLLocationCoordinate2D, baseSpeed: Double) {
        currentPosition = coordinate
        baseSpeedMPS = baseSpeed
        isActive = true

        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        isActive = false
        stickX = 0
        stickY = 0
        currentPosition = nil
    }

    func updateStickInput(x: Float, y: Float) {
        stickX = x
        stickY = y
    }

    private func tick() {
        if let controller = GCController.controllers().first,
           let gamepad = controller.extendedGamepad {
            stickX = gamepad.leftThumbstick.xAxis.value
            stickY = gamepad.leftThumbstick.yAxis.value
        }

        let magnitude = Double(sqrt(stickX * stickX + stickY * stickY))
        guard magnitude > 0.1, var pos = currentPosition else { return }

        let cappedMag = min(magnitude, 1.0)
        let scale = cappedMag / magnitude
        let dt = 0.05

        let dx = Double(stickX) * scale * baseSpeedMPS * dt
        let dy = Double(stickY) * scale * baseSpeedMPS * dt

        let latRad = pos.latitude * .pi / 180
        let metersPerDegLon = Self.metersPerDegLat * cos(latRad)

        pos.latitude += dy / Self.metersPerDegLat
        pos.longitude += dx / metersPerDegLon

        currentPosition = pos
        onPositionUpdate?(pos)
    }

    private func setupControllerObservers() {
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            MainActor.assumeIsolated {
                self?.connectedControllerName = controller.vendorName ?? "Controller"
            }
        }

        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.connectedControllerName = GCController.controllers().first?.vendorName
            }
        }

        connectedControllerName = GCController.controllers().first?.vendorName
    }
}
