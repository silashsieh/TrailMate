import XCTest

// Smoke-level UI tests: launch the real app and assert the primary surfaces
// exist and open. Deliberately device-free and data-free — nothing here
// clicks Connect against a real device (the tunnel raises an admin auth
// dialog) or assumes saved locations/routes exist, so the suite runs the
// same on a clean CI user and on a dev Mac. Connected-only flows run against
// the DEBUG-only mock backend via --uitest-mock-connection.
//
// Query notes (from the accessibility hierarchy): SwiftUI sidebar section
// headers and buttons expose accessibility *labels*, but Form/row Texts
// expose *values* — hence the value predicates.
final class TrailMateUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Base flag for every UI test: suppresses the real device lister so no
        // Local Network permission dialog appears on a clean CI user. Tests
        // append the specific --uitest-* hooks they need before launching.
        app.launchArguments = ["--uitest"]
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

    // Connect to the mock backend (requires launching with
    // --uitest-mock-connection): pick "Mock iPhone", click Connect, wait for
    // the status row. No admin prompt — the tunnel and daemon are mocked out.
    private func connectMockDevice(in window: XCUIElement) {
        let picker = window.popUpButtons.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.click()
        let item = app.menuItems["USB · Mock iPhone"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        let connect = window.buttons["Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.click()
        XCTAssertTrue(staticText(withValue: "Connected", in: window).waitForExistence(timeout: 10))
    }

    // The Wander sheet is normally reached via a connected-only map
    // long-press; --uitest-open-wander opens it at launch instead, so the
    // persistence test stays deterministic (the map flow trips XCUITest's
    // alert-interruption handling on CI). Launch with the flag, then grab it.
    private func wanderSheet() -> XCUIElement {
        let sheet = app.windows["TrailMate"].sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        return sheet
    }

    @MainActor
    func testLaunchShowsMainWindowWithConnectionControls() throws {
        app.launch()
        let window = app.windows["TrailMate"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        XCTAssertTrue(window.staticTexts["Connection"].exists)
        // Exists but stays untouched: clicking Connect raises an admin dialog.
        XCTAssertTrue(window.buttons["Connect"].exists)
    }

    @MainActor
    func testSidebarShowsLogSection() throws {
        app.launch()
        let window = app.windows["TrailMate"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        XCTAssertTrue(window.staticTexts["Log"].exists)
        // Disabled until something is logged, so existence only.
        XCTAssertTrue(window.buttons["View Full Log"].exists)
    }

    @MainActor
    func testSettingsWindowShowsRealismAndLaunchControls() throws {
        app.launch()
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
        app.launch()
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

    @MainActor
    func testLanguagePickerPersistsAcrossRelaunch() throws {
        app.launch()
        var settings = openSettings()
        let picker = settings.popUpButtons["settings.language"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(String(describing: picker.value ?? ""), "System Default")

        // Only ever toggle System Default ↔ English: a missed reset can't leave
        // a non-English UI that would break the other suites' assertions.
        picker.click()
        app.menuItems["English"].click()
        XCTAssertEqual(String(describing: picker.value ?? ""), "English")

        // Relaunch: the choice persists.
        app.terminate()
        app.launch()
        settings = openSettings()
        let restored = settings.popUpButtons["settings.language"]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertEqual(String(describing: restored.value ?? ""), "English")

        // Reset to System Default so the override doesn't leak to other tests.
        restored.click()
        app.menuItems["System Default"].click()
        XCTAssertEqual(String(describing: restored.value ?? ""), "System Default")
    }

    @MainActor
    func testMockConnectionEnablesConnectedUI() throws {
        app.launchArguments += ["--uitest-mock-connection"]
        app.launch()
        let window = app.windows["TrailMate"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        connectMockDevice(in: window)
        // Connected-only map controls appear.
        XCTAssertTrue(window.buttons["Disconnect"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testWanderPresetsPersistAcrossRelaunch() throws {
        app.launchArguments += ["--uitest-open-wander"]
        app.launch()

        // Switch the radius to Custom and type a distinctive value. The sheet
        // persists every change (epic 018), so no wander is ever started and
        // Close loses nothing.
        var sheet = wanderSheet()
        sheet.buttons["wander.radius.custom"].click()
        let radiusField = sheet.textFields["meters"]
        XCTAssertTrue(radiusField.waitForExistence(timeout: 5))
        radiusField.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("850")
        sheet.buttons["Close"].click()

        // Relaunch: the sheet must reopen in Custom mode with the typed value.
        app.terminate()
        app.launch()
        sheet = wanderSheet()
        let restoredField = sheet.textFields["meters"]
        XCTAssertTrue(restoredField.waitForExistence(timeout: 5))
        XCTAssertEqual(String(describing: restoredField.value ?? ""), "850")

        // Park the selection on the factory-default preset rather than the
        // test value (the original preset isn't accessibility-readable).
        sheet.buttons["wander.radius.500"].click()
        sheet.buttons["Close"].click()
    }
}
