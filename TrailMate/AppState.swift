import SwiftUI
import MapKit

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var isConnected: Bool { self == .connected }
}

enum ControlMode: String, CaseIterable {
    case teleport = "Teleport"
    case route = "Route"
}

enum TransportMode: String, CaseIterable {
    case walk = "Walk"
    case cycle = "Cycle"
    case drive = "Drive"

    var directionsTransportType: MKDirectionsTransportType {
        switch self {
        case .walk, .cycle: .walking
        case .drive: .automobile
        }
    }

    var baseSpeed: Double {
        switch self {
        case .walk: 1.4
        case .cycle: 5.0
        case .drive: 15.0
        }
    }
}

@Observable
@MainActor
final class AppState {
    // Connection
    var connectionStatus: ConnectionStatus = .disconnected
    var rsdAddress: String
    var rsdPort: String

    // Mode
    var controlMode: ControlMode = .teleport

    // Teleport
    var simulatedCoordinate: CLLocationCoordinate2D?

    // Route
    var fromSearch = LocationSearch()
    var toSearch = LocationSearch()
    var fromCoordinate: CLLocationCoordinate2D?
    var toCoordinate: CLLocationCoordinate2D?
    var transportMode: TransportMode = .walk
    var speedMultiplier: Double = 1.0
    var routeCoordinates: [CLLocationCoordinate2D] = []
    var isCalculatingRoute = false
    let navigationEngine = NavigationEngine()

    // Log
    var logMessages: [String] = []

    private var daemonBridge: DaemonBridge?

    init() {
        self.rsdAddress = UserDefaults.standard.string(forKey: "rsdAddress") ?? ""
        self.rsdPort = UserDefaults.standard.string(forKey: "rsdPort") ?? ""

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.daemonBridge?.stop()
            }
        }

        navigationEngine.onPositionUpdate = { [weak self] coord in
            self?.handlePlaybackPosition(coord)
        }
    }

    // MARK: - Connection

    func connect() async {
        guard connectionStatus != .connecting else { return }
        guard !rsdAddress.isEmpty, !rsdPort.isEmpty else {
            addLog("RSD address and port are required.")
            connectionStatus = .error("Missing RSD address or port")
            return
        }

        connectionStatus = .connecting
        addLog("Connecting to [\(rsdAddress)]:\(rsdPort)...")

        let bridge = DaemonBridge()
        self.daemonBridge = bridge

        do {
            try await bridge.start(rsdAddress: rsdAddress, rsdPort: rsdPort)
            connectionStatus = .connected
            UserDefaults.standard.set(rsdAddress, forKey: "rsdAddress")
            UserDefaults.standard.set(rsdPort, forKey: "rsdPort")
            addLog("Connected — ready for commands.")
        } catch {
            connectionStatus = .error(error.localizedDescription)
            addLog("Connection failed: \(error.localizedDescription)")
            self.daemonBridge = nil
        }
    }

    func disconnect() async {
        navigationEngine.stop()
        daemonBridge?.stop()
        daemonBridge = nil
        connectionStatus = .disconnected
        simulatedCoordinate = nil
        addLog("Disconnected.")
    }

    // MARK: - Teleport

    func teleport(to coordinate: CLLocationCoordinate2D) async {
        guard connectionStatus.isConnected, let bridge = daemonBridge else { return }

        do {
            try await bridge.sendCommand("SET \(coordinate.latitude) \(coordinate.longitude)")
            simulatedCoordinate = coordinate
            addLog(String(format: "Teleported to %.6f, %.6f", coordinate.latitude, coordinate.longitude))
        } catch {
            addLog("Teleport failed: \(error.localizedDescription)")
        }
    }

    func clearLocation() async {
        guard connectionStatus.isConnected, let bridge = daemonBridge else { return }
        navigationEngine.stop()

        do {
            try await bridge.sendCommand("CLEAR")
            simulatedCoordinate = nil
            addLog("Location cleared.")
        } catch {
            addLog("Clear failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Route

    func selectFrom(_ completion: MKLocalSearchCompletion) async {
        fromSearch.select(completion)
        fromCoordinate = await fromSearch.resolve(completion)
    }

    func selectTo(_ completion: MKLocalSearchCompletion) async {
        toSearch.select(completion)
        toCoordinate = await toSearch.resolve(completion)
    }

    func calculateRoute() async {
        guard let from = fromCoordinate, let to = toCoordinate else {
            addLog("Select both From and To locations first.")
            return
        }

        isCalculatingRoute = true
        addLog("Calculating route...")

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = transportMode.directionsTransportType

        do {
            let directions = MKDirections(request: request)
            let response = try await directions.calculate()
            guard let route = response.routes.first else {
                addLog("No route found.")
                isCalculatingRoute = false
                return
            }

            let coords = extractCoordinates(from: route.polyline)
            routeCoordinates = coords
            navigationEngine.loadRoute(coordinates: coords, baseSpeed: transportMode.baseSpeed)

            let distKm = route.distance / 1000
            let timeMin = route.expectedTravelTime / 60
            addLog(String(format: "Route: %.1f km, ~%.0f min (%@)", distKm, timeMin, transportMode.rawValue))
        } catch {
            addLog("Route calculation failed: \(error.localizedDescription)")
        }

        isCalculatingRoute = false
    }

    func startPlayback() {
        guard !routeCoordinates.isEmpty, connectionStatus.isConnected else { return }
        addLog(String(format: "Playing route at %.0f×...", speedMultiplier))
        navigationEngine.play(multiplier: speedMultiplier)
    }

    func pausePlayback() {
        navigationEngine.pause()
        addLog("Playback paused.")
    }

    func resumePlayback() {
        navigationEngine.resume(multiplier: speedMultiplier)
        addLog("Playback resumed.")
    }

    func stopPlayback() {
        navigationEngine.stop()
        simulatedCoordinate = nil
        addLog("Playback stopped.")
    }

    // MARK: - Private

    private func handlePlaybackPosition(_ coordinate: CLLocationCoordinate2D) {
        simulatedCoordinate = coordinate
        daemonBridge?.setLocationQuiet(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    private func extractCoordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(),
            count: polyline.pointCount
        )
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return coords
    }

    func addLog(_ message: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        logMessages.append("[\(ts)] \(message)")
    }
}
