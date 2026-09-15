import SwiftUI
import AppKit

@main
struct TrailMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var appState = AppState()
    @State private var updaterController = UpdaterController()

    // Menu bar item visibility (epic 021). Default true; persisted so the menu
    // bar presence survives relaunch. Bound to MenuBarExtra's isInserted.
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true

    var body: some Scene {
        // A single reopenable window (epic 021) rather than a WindowGroup that
        // would spawn duplicates on each "Open TrailMate". The id is the target
        // of openWindow(id:) from the menu bar.
        Window("TrailMate", id: "main") {
            ContentView()
                .environment(appState)
                .modifier(MainWindowConfigurator(delegate: delegate, appState: appState))
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updaterController: updaterController)
            }
        }

        // Set-and-forget preferences (⌘, — epic 017). Must share the same
        // AppState instance as the main window: the bindings' didSet paths
        // (noise σ → SimulationActor, restore toggle → UserDefaults) are what
        // keep the relocated controls behaving identically.
        Settings {
            SettingsView(updaterController: updaterController)
                .environment(appState)
        }

        // Menu bar presence (epic 021). .menu style = plain dropdown. The
        // content reads the same AppState, so it must be injected explicitly
        // (scenes don't inherit each other's environment). Visibility is bound
        // to the persisted toggle via isInserted; AppDelegate's policy guard
        // ensures hiding it can never strand the app with no Dock icon either.
        MenuBarExtra("TrailMate", systemImage: "location.fill", isInserted: $showMenuBarItem) {
            MenuBarStatusView()
                .environment(appState)
        }
        .menuBarExtraStyle(.menu)
    }
}

// Captures the SwiftUI openWindow action (unreachable from AppKit) into the
// delegate so applicationShouldHandleReopen — a Dock-icon click with no window
// open — can re-show the single "main" Window, which SwiftUI (unlike a
// WindowGroup) does not auto-reopen. Also wires the delegate's appState and the
// initial activation policy on first appear.
private struct MainWindowConfigurator: ViewModifier {
    let delegate: AppDelegate
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            delegate.appState = appState
            delegate.reopenMainWindow = { openWindow(id: "main") }
            // Window present → regular activation (Dock icon + focus). Covers
            // both first launch and reopen from the menu bar.
            delegate.applyActivationPolicy(windowVisible: true)
        }
    }
}

// App lifecycle owner (epic 021) plus the Cmd-Q disconnect bridge (below).
// Bridges Cmd-Q (and any other NSApp.terminate path) into our async
// disconnect() so the daemon gets a real QUIT → EXIT handshake before the
// process dies. .terminateLater gives us up to 5 s; our escalator caps at ~5 s.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    // Set by the main window on first appear (MainWindowConfigurator). Lets
    // applicationShouldHandleReopen re-show a closed single Window.
    var reopenMainWindow: (() -> Void)?

    // Menu-bar / Dock preference keys. Registered with defaults below so the
    // AppDelegate's UserDefaults reads match the @AppStorage defaults in the UI
    // (a never-written key reads false from UserDefaults.bool, which would
    // silently disable the accessory-when-closed behavior).
    nonisolated static let showMenuBarItemKey = "showMenuBarItem"
    nonisolated static let hideDockWhenWindowClosedKey = "hideDockWhenWindowClosed"

    private var windowCloseObserver: NSObjectProtocol?

    nonisolated func applicationWillFinishLaunching(_ notification: Notification) {
        // @AppStorage("showMenuBarItem") defaults to true and the Dock toggle
        // defaults to "hide when window closed" (Ollama-style accessory app);
        // mirror those here so UserDefaults reads agree before any write.
        UserDefaults.standard.register(defaults: [
            Self.showMenuBarItemKey: true,
            Self.hideDockWhenWindowClosedKey: true,
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Closing the main window must keep the app (AI socket + simulation)
        // alive; we manage the Dock/menu-bar posture ourselves.
        NSApp.setActivationPolicy(.regular)

        // Re-evaluate activation policy whenever a window closes. willClose
        // fires for Settings windows and the GPX open/save NSPanels too, so the
        // handler defers to the next runloop and checks for any remaining main
        // window rather than blindly going accessory. Mirrors AppState's
        // willSleepNotification observer pattern to stay strict-concurrency-clean.
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWindowWillClose()
            }
        }
    }

    // applicationShouldTerminateAfterLastWindowClosed must be false so closing
    // the main window leaves the process (and its socket/simulation) running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Dock-icon click (or `open` of the already-running app) with no visible
    // window. A single Window scene — unlike a WindowGroup — is not auto-reopened
    // by SwiftUI, so without this the app could be stranded windowless (e.g. with
    // the menu bar item hidden). Same reopen dance as the menu bar's Open action.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            reopenMainWindow?()
        }
        return true
    }

    // MARK: - Activation policy (epic 021)

    // Single guarded decision point, called from the window's onAppear (open)
    // and from the deferred willClose handler (close). Never leaves the app
    // unreachable: if the menu bar item is hidden we force .regular regardless
    // of the Dock preference, so there is always a Dock icon OR a menu bar item.
    func applyActivationPolicy(windowVisible: Bool) {
        let menuBarShown = UserDefaults.standard.bool(forKey: Self.showMenuBarItemKey)
        let hideDockWhenClosed = UserDefaults.standard.bool(forKey: Self.hideDockWhenWindowClosedKey)

        let policy: NSApplication.ActivationPolicy
        if windowVisible {
            policy = .regular
        } else if !menuBarShown {
            // No window and no menu bar item → forcing .accessory would hide
            // the Dock icon too and strand the app. Keep the Dock icon.
            policy = .regular
        } else if hideDockWhenClosed {
            policy = .accessory
        } else {
            policy = .regular
        }

        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    private func handleWindowWillClose() {
        // willClose is posted *before* the window leaves NSApp.windows, and it
        // fires for panels/sheets too. Defer to a later main-actor turn (by
        // which point the closing window's isVisible is false), then go
        // accessory only if no real main content window remains.
        // NSSavePanel/NSOpenPanel are NSPanels (excluded); sheets can't become
        // main (excluded).
        Task { @MainActor [weak self] in
            guard let self else { return }
            let hasMainWindow = NSApp.windows.contains { window in
                window.isVisible && window.canBecomeMain && !(window is NSPanel)
            }
            self.applyActivationPolicy(windowVisible: hasMainWindow)
        }
    }

    // MARK: - Quit handshake

    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            // The bridge's 1 s save throttle can lag the red dot at quit;
            // capture the exact final position before disconnect clears it.
            self.appState?.persistSelectedSimulatedPositionNow()
            // prepareForQuit stops the AI socket (unlinks ai.sock) before the
            // device disconnect, so quit honors epic 019's unlink contract.
            await self.appState?.prepareForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
