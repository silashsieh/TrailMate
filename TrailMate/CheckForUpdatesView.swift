import SwiftUI

/// SwiftUI application-menu item backed by Sparkle's availability state.
struct CheckForUpdatesView: View {
    let updaterController: UpdaterController

    var body: some View {
        Button("Check for Updates…") {
            updaterController.checkForUpdates()
        }
        .disabled(!updaterController.canCheckForUpdates)
        .accessibilityIdentifier("updates.check")
    }
}
