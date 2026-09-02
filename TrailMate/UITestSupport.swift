import Foundation

#if DEBUG
// Launch-argument switches for UI tests, DEBUG-only so release builds carry
// no test hooks.
enum UITestSupport {
    // Unit tests host their bundle in TrailMate.app. Starting Sparkle there can
    // present its first-run consent window on a clean runner and keep the host
    // alive after the suite finishes. UI tests carry an explicit launch flag;
    // hosted unit tests carry Xcode's XCTest configuration environment value.
    static let isTesting = isUITesting
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    // True for any UI-test launch (every flag below starts with --uitest, and
    // the harness also passes a bare --uitest). Used to skip the real device
    // lister so its Bonjour/usbmux scan never raises the macOS Local Network
    // permission dialog, which blocks automation on a clean CI user.
    static let isUITesting = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--uitest") }

    // Replaces device discovery and the tunnel+daemon pair with mocks so
    // connected-only UI flows are testable with no device, tunnel, or admin
    // prompt (see docs/project-plan/testing.md).
    static let mockConnection = ProcessInfo.processInfo.arguments.contains("--uitest-mock-connection")

    // Opens the Wander sheet at launch (with a synthetic center) so the
    // persistence test doesn't depend on the map long-press flow, which is
    // flaky under XCUITest's alert-interruption handling on CI.
    static let openWander = ProcessInfo.processInfo.arguments.contains("--uitest-open-wander")

    // Forces the sidebar Log disclosure open at launch. The log is collapsed by
    // default (epic 025) and the choice persists across launches, so the smoke
    // test can't assume the section's contents are rendered; this hook makes
    // them deterministically present without touching the persisted preference.
    static let expandLog = ProcessInfo.processInfo.arguments.contains("--uitest-expand-log")
}
#endif
