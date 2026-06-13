import SwiftUI
import AppKit
import os

// Content of the menu bar item (epic 021). A compact live summary of the
// active session plus quick actions, so TrailMate stays controllable when the
// main window is closed and the app is running in the background (.accessory).
//
// This view is the only place that owns `openWindow` — it is a SwiftUI
// environment action, unreachable from AppDelegate. "Open TrailMate" pairs it
// with the AppKit activation dance (regular policy → activate → front) so the
// window reliably returns from the menu bar even while we're an accessory app.
struct MenuBarStatusView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    private let log = Logger(subsystem: "com.harry.trailmate", category: "menubar")

    var body: some View {
        // Status summary. MenuBarExtra (.menu style) renders plain controls as
        // menu rows; disabled Text reads as a non-interactive header.
        Text(statusSummary)

        Divider()

        Button("Open TrailMate") { openMainWindow() }

        // Playback quick actions, shown only while a route is active so the menu
        // stays short and the actions are never no-ops. A paused route still
        // offers Stop (and Resume) so it isn't stranded when the window is
        // closed — the only other way to control it would be reopening.
        switch appState.simState.navigationPlaybackState {
        case .playing:
            Button("Pause") { appState.pausePlayback() }
            Button("Stop") { appState.stopPlayback() }
        case .paused:
            Button("Resume") { appState.resumePlayback() }
            Button("Stop") { appState.stopPlayback() }
        case .idle:
            EmptyView()
        }

        if appState.connectionStatus.isConnected {
            Button("Disconnect") {
                Task { await appState.disconnect() }
            }
        }

        Divider()

        // Route through NSApp.terminate so the existing
        // applicationShouldTerminate handshake runs the clean daemon/tunnel
        // disconnect — don't reimplement teardown here.
        Button("Quit TrailMate") { NSApp.terminate(nil) }
    }

    // MARK: - Derived state

    private var statusSummary: String {
        let connection: String
        switch appState.connectionStatus {
        case .disconnected: connection = String(localized: "Disconnected")
        case .connecting: connection = String(localized: "Connecting…")
        case .connected: connection = String(localized: "Connected")
        case .error(let message): connection = String(localized: "Error: \(message)")
        }

        let activity: String
        switch appState.simState.navigationPlaybackState {
        case .playing:
            let pct = Int((appState.simState.navigationProgress * 100).rounded())
            activity = String(localized: "Playing \(pct)%")
        case .paused:
            activity = String(localized: "Paused")
        case .idle:
            activity = appState.simState.isRecording
                ? String(localized: "Recording")
                : String(localized: "Idle")
        }

        return "\(connection) · \(activity)"
    }

    // MARK: - Window reopen

    // Reopen sequence per the epic's detailed design: regular policy (so the
    // Dock icon returns and the window can take focus) → activate the app →
    // open/raise the "main" window → force it front in case activation hasn't
    // landed yet. openWindow lives here because it's a view-only action.
    private func openMainWindow() {
        log.debug("Reopening main window from menu bar")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
        // Best-effort raise: SwiftUI doesn't guarantee scene id maps to an
        // NSWindow.identifier, so target whatever became key rather than
        // looking the window up by id.
        NSApp.keyWindow?.orderFrontRegardless()
    }
}
