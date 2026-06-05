import SwiftUI
import AppKit

@main
struct TrailMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .onAppear { delegate.appState = appState }
        }
        .defaultSize(width: 1100, height: 700)
    }
}

// Bridges Cmd-Q (and any other NSApp.terminate path) into our async
// disconnect() so the daemon gets a real QUIT → EXIT handshake before the
// process dies. .terminateLater gives us up to 5 s; our escalator caps at ~5 s.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            // The bridge's 1 s save throttle can lag the red dot at quit;
            // capture the exact final position before disconnect clears it.
            if let coord = self.appState?.simState.simulatedCoordinate {
                SimulatedPositionPersistence.save(coord)
            }
            await self.appState?.disconnect()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
