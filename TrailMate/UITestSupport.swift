import Foundation

#if DEBUG
// Launch-argument switches for UI tests, DEBUG-only so release builds carry
// no test hooks.
enum UITestSupport {
    // Replaces device discovery and the tunnel+daemon pair with mocks so
    // connected-only UI flows are testable with no device, tunnel, or admin
    // prompt (see docs/project-plan/testing.md).
    static let mockConnection = ProcessInfo.processInfo.arguments.contains("--uitest-mock-connection")

    // Opens the Wander sheet at launch (with a synthetic center) so the
    // persistence test doesn't depend on the map long-press flow, which is
    // flaky under XCUITest's alert-interruption handling on CI.
    static let openWander = ProcessInfo.processInfo.arguments.contains("--uitest-open-wander")
}
#endif
