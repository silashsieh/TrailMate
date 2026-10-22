import Foundation
import Observation
import Sparkle

/// Owns TrailMate's single Sparkle updater and projects its KVO settings into
/// Swift Observation for the application menu and Settings scene.
@MainActor
@Observable
final class UpdaterController {
    @ObservationIgnored private let standardController: SPUStandardUpdaterController?
    @ObservationIgnored private let testDefaults: UserDefaults?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private(set) var canCheckForUpdates: Bool
    private(set) var automaticallyChecksForUpdates: Bool
    private(set) var automaticallyDownloadsUpdates: Bool

    init(startingUpdater: Bool = UpdaterController.shouldStartUpdater) {
        #if DEBUG
        if UITestSupport.isTesting {
            // Sparkle owns bundle preferences outside SwiftUI's defaultAppStorage.
            // Keep UI and hosted tests in their explicit isolated domain, and
            // never contact an update feed from a test process.
            let defaults = AppProcessConfiguration.current.defaults
            standardController = nil
            testDefaults = defaults
            canCheckForUpdates = true
            automaticallyChecksForUpdates = defaults.object(forKey: "testAutomaticUpdateChecks") == nil
                ? true : defaults.bool(forKey: "testAutomaticUpdateChecks")
            automaticallyDownloadsUpdates = defaults.bool(forKey: "testAutomaticUpdateDownloads")
            return
        }
        #endif
        testDefaults = nil
        standardController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let updater = standardController!.updater
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
        standardController?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        if let testDefaults {
            testDefaults.set(enabled, forKey: "testAutomaticUpdateChecks")
        } else {
            standardController?.updater.automaticallyChecksForUpdates = enabled
        }
        automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        if let testDefaults {
            testDefaults.set(enabled, forKey: "testAutomaticUpdateDownloads")
        } else {
            standardController?.updater.automaticallyDownloadsUpdates = enabled
        }
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
