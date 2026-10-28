import Foundation

// The menu summary follows the selected session. Keeping its wording here lets
// tests cover every state without querying MenuBarExtra's inaccessible menu.
enum MenuBarStatusFormatter {
    static func summary(
        deviceName: String?,
        connection: ConnectionStatus,
        playback: NavigationEngine.PlaybackState,
        progress: Double,
        isRecording: Bool
    ) -> String {
        let connectionText: String
        switch connection {
        case .disconnected: connectionText = String(localized: "Disconnected")
        case .connecting: connectionText = String(localized: "Connecting…")
        case .connected: connectionText = String(localized: "Connected")
        case .reconnecting, .cancellingRetry:
            connectionText = connection.recoveryText ?? ""
        case .error(let message): connectionText = String(localized: "Error: \(message)")
        }

        let activity: String
        switch playback {
        case .playing:
            let percent = Int((progress * 100).rounded())
            activity = String(localized: "Playing \(percent)%")
        case .paused:
            activity = String(localized: "Paused")
        case .idle:
            activity = isRecording ? String(localized: "Recording") : String(localized: "Idle")
        }

        if connection.isConnected, let deviceName {
            return "\(truncated(deviceName)) · \(connectionText) · \(activity)"
        }
        return "\(connectionText) · \(activity)"
    }

    private static func truncated(_ name: String, max: Int = 24) -> String {
        name.count > max ? "\(name.prefix(max - 1))…" : name
    }
}
