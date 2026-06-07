import SwiftUI

// Standalone Settings window content (⌘, — epic 017). Holds the set-and-forget
// preferences relocated out of the sidebar so it can focus on route/session
// work. Controls bind to the same AppState properties as the sidebar versions
// did, so persistence keys and live propagation are unchanged: the σ slider
// still persists via persistTuning() and reaches LocationNoise through the
// noiseSigmaMeters didSet; the restore toggle persists via its didSet into
// SimulatedPositionPersistence.
struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Realism") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("GPS noise σ")
                        Spacer()
                        Text(String(format: "%.1f m", appState.noiseSigmaMeters))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $appState.noiseSigmaMeters, in: 0...10, step: 0.5)
                        .onChange(of: appState.noiseSigmaMeters) { _, _ in
                            appState.persistTuning()
                        }
                    Text("Gaussian jitter applied to every emitted position, including idle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Launch") {
                Toggle("Restore last location on launch", isOn: $appState.restoreLastSimulatedLocation)
                    .help("Off: start with no simulated position until you teleport. The last position is remembered either way.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 220)
    }
}
