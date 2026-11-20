import XCTest

final class LocationChoiceTests: XCTestCase {
    func testEmptyPanesOfferLocationsAndRequestPhotoAccessOnDemand() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launch()
        let photos = app.buttons["open-photos-A"]
        XCTAssertTrue(photos.waitForExistence(timeout: 15))
        for pane in ["A", "B"] {
            for choice in ["place-onMyIPhone-", "place-iCloudDrive-", "choose-folder-", "browse-files-", "open-photos-", "connect-windows-"] {
                XCTAssertTrue(app.buttons[choice + pane].exists, choice + pane)
            }
        }
        app.buttons["connect-windows-B"].tap()
        XCTAssertTrue(app.textFields["Computer name or IP address"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        photos.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        let deny = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Allow"))
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Don")).firstMatch
        XCTAssertTrue(deny.exists)
        deny.tap()
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["choose-folder-B"].exists)
    }

    func testFolderPickerReturnsExternalDownloadsToPaneBAndReopensAfterRelaunch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FILES_FIXTURE"] == "1", "Requires the simulator Files fixture")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let confirm = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "Done"])).firstMatch
        let addedFolder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@", "item-A-", "item-A-Newexplorer")).firstMatch

        // Opening the top of On My iPhone turns pane A into the combined On My iPhone list.
        let rootPicker = app.buttons["choose-folder-A"]
        XCTAssertTrue(rootPicker.waitForExistence(timeout: 15))
        rootPicker.tap()
        showOnMyIPhone(in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5) && confirm.isEnabled, app.debugDescription)
        XCTContext.runActivity(named: "Local root offers Open") { _ in }
        open(confirm, until: app.buttons["place-add-A"], in: app)
        XCTAssertEqual(app.buttons["Pane A location"].value as? String, "On My iPhone")
        XCTAssertTrue(app.buttons["item-A-Newexplorer"].waitForExistence(timeout: 5), app.debugDescription)

        // The top level does not include other apps' folders; add the fixture app's folder.
        app.buttons["place-add-A"].tap()
        showOnMyIPhone(in: app)
        cell("Folder Test Source", in: app).tap()
        if cell("root-file", in: app).waitForExistence(timeout: 2) {
            XCTContext.runActivity(named: "Tapping a folder while adding opened it") { _ in }
        }
        open(confirm, until: addedFolder, in: app)
        XCTContext.runActivity(named: "Added folder shows as \(addedFolder.identifier)") { _ in }
        addedFolder.tap()
        XCTAssertTrue(app.buttons["item-A-root-file.txt"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["item-A-Downloads"].tap()
        XCTAssertTrue(app.buttons["item-A-inside.txt"].waitForExistence(timeout: 10), app.debugDescription)
        let up = app.buttons.matching(identifier: "arrow.up").firstMatch
        up.tap()
        XCTAssertTrue(app.buttons["item-A-root-file.txt"].waitForExistence(timeout: 10), app.debugDescription)
        up.tap()
        XCTAssertTrue(app.buttons["place-add-A"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.buttons["Pane A location"].value as? String, "On My iPhone")

        let choose = app.buttons["choose-folder-B"]
        XCTAssertTrue(choose.waitForExistence(timeout: 15))
        choose.tap()
        enterFixture(in: app)
        let downloads = cell("Downloads", in: app)
        XCTAssertTrue(downloads.waitForExistence(timeout: 8), app.debugDescription)
        downloads.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        open(confirm, until: app.buttons["item-B-inside.txt"], in: app)
        func checkFolder() {
            XCTAssertTrue(app.buttons["item-B-inside.txt"].waitForExistence(timeout: 12), app.debugDescription)
            XCTAssertEqual(app.buttons["Pane B location"].value as? String, "Downloads")
        }
        checkFolder()
        app.terminate()
        app.launch()
        checkFolder()

        // Pane A reopens On My iPhone, and the added folder still opens after the relaunch.
        XCTAssertTrue(addedFolder.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(app.buttons["Pane A location"].value as? String, "On My iPhone")
        addedFolder.tap()
        XCTAssertTrue(app.buttons["item-A-root-file.txt"].waitForExistence(timeout: 10), app.debugDescription)

        // Single files still open in place from Browse Files locations.
        app.buttons["Pane A location"].tap()
        app.buttons["Browse Files locations"].firstMatch.tap()
        enterFixture(in: app)
        cell("root-file", in: app).tap()
        let selection = app.buttons.matching(NSPredicate(format: "label == %@ AND value == %@", "Pane A location", "Selected files")).firstMatch
        open(confirm, until: selection, in: app)
        XCTAssertTrue(app.buttons["item-A-root-file.txt"].waitForExistence(timeout: 10), app.debugDescription)
    }

    // The simulator sometimes drops an open-in-place pick; Open can be tapped again.
    private func open(_ confirm: XCUIElement, until target: XCUIElement, in app: XCUIApplication) {
        for attempt in 1...3 {
            if confirm.exists && confirm.isEnabled { confirm.tap() }
            if target.waitForExistence(timeout: 6) { return }
            XCTContext.runActivity(named: "Pick not delivered on attempt \(attempt)") { _ in }
        }
        XCTFail("The pick never reached the pane. " + app.debugDescription)
    }

    private func cell(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR label BEGINSWITH %@", name, name)).firstMatch
    }

    // Shows On My iPhone in the picker, where the fixture app's folder is listed.
    private func showOnMyIPhone(in app: XCUIApplication) {
        let fixture = cell("Folder Test Source", in: app)
        if fixture.waitForExistence(timeout: 3) { return }
        let back = app.navigationBars.buttons.matching(NSPredicate(format: "label == %@", "On My iPhone")).firstMatch
        if back.exists {
            back.tap()
        } else {
            let browse = app.buttons["Browse"].firstMatch
            if browse.exists { browse.tap() }
            // The app's own "On My iPhone" button sits behind the picker, so tap the visible match.
            let device = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "On My iPhone", "On My iPhone,"))
            tapVisible(device)
        }
        XCTAssertTrue(fixture.waitForExistence(timeout: 8), app.debugDescription)
    }

    private func tapVisible(_ query: XCUIElementQuery, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
                element.tap()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
    }

    private func enterFixture(in app: XCUIApplication) {
        let rootFile = cell("root-file", in: app)
        if rootFile.waitForExistence(timeout: 2) { return }
        showOnMyIPhone(in: app)
        cell("Folder Test Source", in: app).tap()
        XCTAssertTrue(rootFile.waitForExistence(timeout: 8), app.debugDescription)
    }
}
