import SwiftUI

// Settings section for the AI control surface (epic 019). Dropped into the
// Settings form by SettingsView as `AISettingsSection()` — keep the no-argument
// initializer; it reads AppState from the environment like the rest of Settings.
//
// Off by default: the toggle gates the Unix-socket command server entirely, so
// there is zero attack surface until the user opts in. When on, the socket path
// is shown so the user (or an agent's setup docs) knows where to connect.
struct AISettingsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        Section("AI Control") {
            Toggle("Enable AI control", isOn: $appState.aiControlEnabled)
                .accessibilityIdentifier("settings.aiControl")

            Text("Lets AI tools (e.g. Claude Code) teleport, plan and play routes, and read status over a local Unix socket. No network port is opened.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.aiControlEnabled {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Socket")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: SocketPath.displayPath())
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
