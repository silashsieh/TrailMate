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
    // --uitest-mock-connection): pick "Mock iPhone", click Connect, wait for the
    // connected state. The device switcher's connected gate is the Disconnect
    // button (shown only when the selected session is connected) — more robust
    // than the row's status caption, which lives inside the row Button. No admin
    // prompt — the tunnel and daemon are mocked out.
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
        XCTAssertTrue(window.buttons["Disconnect"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(window.staticTexts["Devices"].exists)
        // Exists but stays untouched: clicking Connect raises an admin dialog.
        XCTAssertTrue(window.buttons["Connect"].exists)
    }

    @MainActor
    func testSidebarShowsLogSection() throws {
        // The log is collapsed by default (epic 025), so "View Full Log" only
        // renders when the disclosure is open; --uitest-expand-log forces it
        // open deterministically (without mutating the persisted preference).
        app.launchArguments += ["--uitest-expand-log"]
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
        XCTAssertTrue(
            settings.switches["settings.updates.automaticChecks"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(settings.switches["settings.updates.automaticDownloads"].exists)

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

    // Epic 028 removed connection-gating: the control surface is usable with no
    // device attached (everything drives the local red dot, which a device later
    // mirrors on connect). So the core sections must render at a plain launch,
    // before any Connect — no mock backend needed.
    @MainActor
    func testCoreControlsRenderWithoutConnection() throws {
        app.launch()
        let window = app.windows["TrailMate"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        // Section headers are exposed as accessibility labels.
        XCTAssertTrue(window.staticTexts["Go to Location"].exists)
        XCTAssertTrue(window.staticTexts["Route"].exists)
        XCTAssertTrue(window.staticTexts["Joystick"].exists)
        // A concrete offline control: the coordinate-entry field (epic 027).
        XCTAssertTrue(window.textFields["lat, lon"].exists)
        // Sanity: we never connected, so the connected-state action isn't shown.
        XCTAssertFalse(window.buttons["Disconnect"].exists)
    }

    // Epic 026: the connected device's name and status surface in the sidebar
    // switcher row (the status pill). Reframed from the old "connection gates the
    // UI" check to "the connected state mirrors the device's identity."
    @MainActor
    func testMockConnectionShowsConnectedDeviceNameAndStatus() throws {
        app.launchArguments += ["--uitest-mock-connection"]
        app.launch()
        let window = app.windows["TrailMate"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        connectMockDevice(in: window)
        // Connected: the action surface offers Disconnect...
        XCTAssertTrue(window.buttons["Disconnect"].waitForExistence(timeout: 5))
        // ...and the switcher row shows the mock device's name (epic 026). The
        // row is a Button wrapping name + status, so match on its label.
        let deviceRow = window.buttons
            .containing(NSPredicate(format: "label CONTAINS %@", "Mock iPhone")).firstMatch
        XCTAssertTrue(deviceRow.waitForExistence(timeout: 5))
        XCTAssertTrue(deviceRow.label.contains("Connected"))
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

    // Epic 027: the coordinate field commits a decimal-degrees pair to the red
    // dot; "Go" stays disabled until the text parses, and once a position
    // exists the "Copy Current Coordinate" affordance appears. Runs with no
    // device — exercising epic 028's offline model end to end.
    @MainActor
    func testCoordinateEntryEnablesGoAndRevealsCopy() throws {
        app.launch()
        let window = app.windows["TrailMate"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))

        let field = window.textFields["lat, lon"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let go = window.buttons["Go"]
        XCTAssertTrue(go.exists)
        // Empty (and, below, garbage) text leaves Go disabled.
        XCTAssertFalse(go.isEnabled)

        field.click()
        app.typeText("not a coordinate")
        XCTAssertFalse(go.isEnabled)

        // A valid decimal-degrees pair enables Go; committing it places the dot.
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("25.0330, 121.5654")
        XCTAssertTrue(go.isEnabled)
        go.click()

        // With a position set, the copy affordance appears (it's hidden until
        // simulatedCoordinate != nil).
        XCTAssertTrue(window.buttons["Copy Current Coordinate"].waitForExistence(timeout: 5))
    }

    // Epic 025: the sidebar log is collapsed by default and the expand/collapse
    // choice persists across launches. Drives the real DisclosureGroup (not the
    // --uitest-expand-log forced binding) so the persisted @AppStorage path is
    // what's under test. The log is the sidebar's only disclosure, and its
    // triangle — not the label text — is the toggle target. "View Full Log"
    // renders only while expanded, so its presence is the expansion probe.
    @MainActor
    func testLogExpansionPersistsAcrossRelaunch() throws {
        app.launch()
        var window = app.windows["TrailMate"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))

        let viewFullLog = { window.buttons["View Full Log"] }
        let logToggle = { window.disclosureTriangles.firstMatch }
        XCTAssertTrue(logToggle().waitForExistence(timeout: 5))
        // Normalize to collapsed — the choice persists, so the starting state
        // isn't guaranteed.
        if viewFullLog().exists { logToggle().click() }
        XCTAssertFalse(viewFullLog().waitForExistence(timeout: 2))

        // Expand, relaunch: the log must come back expanded.
        logToggle().click()
        XCTAssertTrue(viewFullLog().waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        window = app.windows["TrailMate"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        XCTAssertTrue(viewFullLog().waitForExistence(timeout: 5))

        // Collapse, relaunch: the log must come back collapsed — which also
        // restores the factory default, leaving the preference as we found it.
        logToggle().click()
        XCTAssertFalse(viewFullLog().waitForExistence(timeout: 2))
        app.terminate()
        app.launch()
        window = app.windows["TrailMate"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        XCTAssertFalse(viewFullLog().waitForExistence(timeout: 2))
    }

    // Epic 030: the sheet's two modes share the center and the radius but swap
    // what sits under them — Random keeps the duration presets, Sweeping trades
    // them for a lane spacing and derives distance/time from the geometry — and
    // the mode itself is a remembered preference, like the presets around it.
    // The segmented Picker exposes its segments as RadioButtons.
    @MainActor
    func testWanderSweepingModeSwapsControlsAndPersists() throws {
        app.launchArguments += ["--uitest-open-wander"]
        app.launch()

        // Random is the factory default: duration presets, no spacing field.
        var sheet = wanderSheet()
        XCTAssertTrue(sheet.buttons["wander.duration.30"].waitForExistence(timeout: 5))
        XCTAssertFalse(sheet.textFields["wander.sweep.spacing"].exists)

        sheet.radioButtons["Sweeping"].click()
        let spacing = sheet.textFields["wander.sweep.spacing"]
        XCTAssertTrue(spacing.waitForExistence(timeout: 5))
        XCTAssertEqual(String(describing: spacing.value ?? ""), "70")
        // No duration control when sweeping — the route's length fixes its time.
        XCTAssertFalse(sheet.buttons["wander.duration.30"].waitForExistence(timeout: 2))
        // Radius stays shared, and Start only enables once the geometry built.
        XCTAssertTrue(sheet.buttons["wander.radius.500"].exists)
        XCTAssertTrue(sheet.buttons["Start"].isEnabled)

        // Type a distinctive spacing. Every change persists (epic 018), so Close
        // starts no sweep and loses nothing.
        spacing.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("120")
        sheet.buttons["Close"].click()

        // Relaunch: the sheet must reopen already in Sweeping, with that spacing.
        app.terminate()
        app.launch()
        sheet = wanderSheet()
        let sweeping = sheet.radioButtons["Sweeping"]
        XCTAssertTrue(sweeping.waitForExistence(timeout: 15))
        XCTAssertEqual(switchValue(sweeping), "1")
        let restored = sheet.textFields["wander.sweep.spacing"]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertEqual(String(describing: restored.value ?? ""), "120")

        // Switch back: the duration presets return. Park the sheet on the factory
        // defaults (Random, 70 m) so suite order can't inherit this test's state.
        restored.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("70")
        sheet.radioButtons["Random"].click()
        XCTAssertTrue(sheet.buttons["wander.duration.30"].waitForExistence(timeout: 5))
        XCTAssertFalse(sheet.textFields["wander.sweep.spacing"].exists)
        sheet.buttons["Close"].click()
    }
}
