import XCTest

// Smoke-level UI tests: launch the real app and assert the primary surfaces
// exist and open. Deliberately device-free and data-free — nothing here
// clicks Connect (it raises an admin auth dialog), relies on a paired iPhone,
// or assumes saved locations/routes exist, so the suite runs the same on a
// clean CI user and on a dev Mac.
//
// Query notes (from the accessibility hierarchy): SwiftUI sidebar section
// headers and buttons expose accessibility *labels*, but Form/row Texts
// expose *values* — hence the value predicates for Settings content.
final class TrailMateUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    @MainActor
    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    private func staticText(withValue value: String, in element: XCUIElement) -> XCUIElement {
        element.staticTexts.matching(NSPredicate(format: "value == %@", value)).firstMatch
    }

    private func switchValue(_ element: XCUIElement) -> String {
        String(describing: element.value ?? "")
    }

    @discardableResult
    private func openSettings() -> XCUIElement {
        XCTAssertTrue(app.windows["TrailMate"].waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        return settings
    }

    @MainActor
    func testLaunchShowsMainWindowWithConnectionControls() throws {
        let window = app.windows["TrailMate"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        XCTAssertTrue(window.staticTexts["Connection"].exists)
        // Exists but stays untouched: clicking Connect raises an admin dialog.
        XCTAssertTrue(window.buttons["Connect"].exists)
    }

    @MainActor
    func testSidebarShowsLogSection() throws {
        let window = app.windows["TrailMate"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        XCTAssertTrue(window.staticTexts["Log"].exists)
        // Disabled until something is logged, so existence only.
        XCTAssertTrue(window.buttons["View Full Log"].exists)
    }

    @MainActor
    func testSettingsWindowShowsRealismAndLaunchControls() throws {
        let settings = openSettings()
        XCTAssertTrue(staticText(withValue: "GPS noise σ", in: settings).waitForExistence(timeout: 5))
        XCTAssertTrue(settings.sliders.firstMatch.exists)
        XCTAssertTrue(staticText(withValue: "Restore last location on launch", in: settings).exists)
        XCTAssertTrue(settings.switches.firstMatch.exists)

        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(settings.waitForExistence(timeout: 2))
    }

    @MainActor
    func testSettingsTogglePersistsAcrossRelaunch() throws {
        var settings = openSettings()
        var toggle = settings.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        // Flip the restore-on-launch toggle and confirm the UI registered it.
        let original = switchValue(toggle)
        toggle.click()
        let flipped = switchValue(toggle)
        XCTAssertNotEqual(original, flipped)

        // Full quit + relaunch: the flipped value must come back from disk.
        app.terminate()
        app.launch()
        settings = openSettings()
        toggle = settings.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(switchValue(toggle), flipped)

        // Leave the user's setting as we found it.
        toggle.click()
        XCTAssertEqual(switchValue(toggle), original)
    }
}
