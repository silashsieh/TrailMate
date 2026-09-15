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
    let updaterController: UpdaterController

    // Seeded from the persisted choice; onChange writes it back. Launch-only —
    // AppleLanguages is bound at process start, so it doesn't need to live on
    // AppState or drive any live view update.
    @State private var language = LanguagePreference.current

    // Menu-bar / Dock prefs (epic 021). Deliberately @AppStorage, not on
    // AppState: they're window/lifecycle UI prefs the AppDelegate reads from
    // UserDefaults, with no effect on the simulation core. Defaults match the
    // register(defaults:) in AppDelegate so reads agree before any write.
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage("hideDockWhenWindowClosed") private var hideDockWhenWindowClosed = true

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Language") {
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(verbatim: lang.displayName).tag(lang)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("settings.language")
                .onChange(of: language) { _, newValue in
                    LanguagePreference.current = newValue
                }
                Text("Takes effect after you relaunch TrailMate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Realism") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("GPS noise σ")
                        Spacer()
                        Text("\(appState.noiseSigmaMeters, specifier: "%.1f") m")
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

            Section("Menu Bar") {
                Toggle("Show menu bar item", isOn: $showMenuBarItem)
                    .help("A status item with quick actions, so TrailMate stays controllable when the window is closed.")

                // Coupled to the menu bar toggle to dodge the unreachable-app
                // trap: hiding both the Dock icon and the menu bar item would
                // leave a running app with no way to reopen or quit it. When the
                // menu bar item is hidden we keep the Dock icon (control
                // disabled), and AppDelegate.applyActivationPolicy enforces the
                // same guard at runtime.
                Toggle("Hide Dock icon when the window is closed", isOn: $hideDockWhenWindowClosed)
                    .disabled(!showMenuBarItem)
                    .help("Run in the background as a menu bar app. Requires the menu bar item so the app stays reachable.")

                Text("With the menu bar item shown, closing the window keeps simulation and AI control running in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updaterController.automaticallyChecksForUpdates },
                        set: { updaterController.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                .accessibilityIdentifier("settings.updates.automaticChecks")

                Toggle(
                    "Automatically download updates",
                    isOn: Binding(
                        get: { updaterController.automaticallyDownloadsUpdates },
                        set: { updaterController.setAutomaticallyDownloadsUpdates($0) }
                    )
                )
                .disabled(!updaterController.automaticallyChecksForUpdates)
                .accessibilityIdentifier("settings.updates.automaticDownloads")

                Text("TrailMate asks before installing an update and relaunching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // AI control settings (epic 019). Self-contained subview owned by
            // the AI-integration work; the single cross-file reference in B3.
            AISettingsSection()
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 520)
    }
}
