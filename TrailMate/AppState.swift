import SwiftUI
import CoreLocation

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var isConnected: Bool { self == .connected }
}

@Observable
@MainActor
final class AppState {
    var connectionStatus: ConnectionStatus = .disconnected
    var simulatedCoordinate: CLLocationCoordinate2D?
    var rsdAddress: String
    var rsdPort: String
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
    }

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
        daemonBridge?.stop()
        daemonBridge = nil
        connectionStatus = .disconnected
        simulatedCoordinate = nil
        addLog("Disconnected.")
    }

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

        do {
            try await bridge.sendCommand("CLEAR")
            simulatedCoordinate = nil
            addLog("Location cleared.")
        } catch {
            addLog("Clear failed: \(error.localizedDescription)")
        }
    }

    private func addLog(_ message: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        logMessages.append("[\(ts)] \(message)")
    }
}
