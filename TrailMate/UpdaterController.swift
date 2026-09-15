import Foundation
import Observation
import Sparkle

/// Owns TrailMate's single Sparkle updater and projects its KVO settings into
/// Swift Observation for the application menu and Settings scene.
@MainActor
@Observable
final class UpdaterController {
    @ObservationIgnored private let standardController: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private(set) var canCheckForUpdates: Bool
    private(set) var automaticallyChecksForUpdates: Bool
    private(set) var automaticallyDownloadsUpdates: Bool

    init(startingUpdater: Bool = UpdaterController.shouldStartUpdater) {
        standardController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let updater = standardController.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates

        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
                Task { @MainActor [weak self] in
                    self?.canCheckForUpdates = updater.canCheckForUpdates
                }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] updater, _ in
                Task { @MainActor [weak self] in
                    self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
                }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] updater, _ in
                Task { @MainActor [weak self] in
                    self?.automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
                }
            },
        ]
    }

    func checkForUpdates() {
        standardController.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        standardController.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        standardController.updater.automaticallyDownloadsUpdates = enabled
        automaticallyDownloadsUpdates = enabled
    }

    private static var shouldStartUpdater: Bool {
#if DEBUG
        // Sparkle's permission/update windows are outside TrailMate's test
        // surface and can otherwise interrupt a clean XCTest host or XCUITest.
        !UITestSupport.isTesting
#else
        true
#endif
    }
}
