import Foundation

struct DiscoveredDevice: Identifiable, Hashable {
    var id: String { udid }
    let udid: String
    let name: String
    let connectionType: ConnectionType
    let host: String?
    let port: Int?

    enum ConnectionType: String, Hashable {
        case usb = "USB"
        case wifi = "WiFi"
    }

    var displayLabel: String {
        switch connectionType {
        case .usb: return "USB · \(name)"
        case .wifi:
            if let host { return "Wi-Fi · \(name) (\(host))" }
            return "Wi-Fi · \(name)"
        }
    }
}

@Observable
@MainActor
final class DeviceDiscoveryService {
    private(set) var devices: [DiscoveredDevice] = []
    private(set) var isScanning = false
    private(set) var lastError: String?
    var hasScanned = false
    #if DEBUG
    // Dispatch tests must exercise DEVICES' forced refresh without invoking the
    // bundled lister, which can inspect the owner's connected devices.
    var scanLinesForTesting: [String]?
    #endif

    func scan() async {
        guard !isScanning else { return }
        #if DEBUG
        if let scanLinesForTesting {
            devices = scanLinesForTesting.compactMap(Self.parse)
            lastError = nil
            hasScanned = true
            return
        }
        if UITestSupport.mockConnection {
            devices = [DiscoveredDevice(udid: "UITEST-MOCK-UDID", name: "Mock iPhone",
                                        connectionType: .usb, host: nil, port: nil)]
            hasScanned = true
            return
        }
        // Hosted unit tests also launch TrailMate.app. Keep every test process
        // away from Bonjour/usbmux, including its app-owned manager.
        if UITestSupport.isTesting {
            devices = []
            hasScanned = true
            return
        }
        #endif
        isScanning = true
        lastError = nil
        defer {
            isScanning = false
            hasScanned = true
        }

        do {
            let lines = try await runLister()
            devices = lines.compactMap(Self.parse)
        } catch {
            lastError = error.localizedDescription
        }
    }

    static func parse(line: String) -> DiscoveredDevice? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let udid = obj["udid"] as? String,
              let name = obj["name"] as? String,
              let typeStr = obj["connectionType"] as? String,
              let type = DiscoveredDevice.ConnectionType(rawValue: typeStr) else {
            return nil
        }
        return DiscoveredDevice(
            udid: udid,
            name: name,
            connectionType: type,
            host: obj["host"] as? String,
            port: obj["port"] as? Int
        )
    }

    private func runLister() async throws -> [String] {
        let interpreter = PythonBundle.interpreter
        let script = PythonBundle.script("tm_list_devices").path
        let env = PythonBundle.environment
        let cwd = interpreter.deletingLastPathComponent()

        return try await Task.detached {
            let proc = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.executableURL = interpreter
            proc.arguments = [script]
            proc.environment = env
            proc.currentDirectoryURL = cwd
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()

            let text = String(data: outData, encoding: .utf8) ?? ""
            return text.split(whereSeparator: \.isNewline).map(String.init)
        }.value
    }
}
