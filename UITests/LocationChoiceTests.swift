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
        tap("Folder Test Source", in: app)
        if visible("root-file", in: app, timeout: 2) != nil {
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
        tap("Downloads", in: app)
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

        // Single files still open in place from Browse Files locations. A pick the simulator
        // drops stays dropped in that picker, so retry with a fresh launch.
        let selection = app.buttons.matching(NSPredicate(format: "label == %@ AND value == %@", "Pane A location", "Selected files")).firstMatch
        var delivered = false
        for attempt in 1...3 {
            app.buttons["Pane A location"].tap()
            app.buttons["Browse Files locations"].firstMatch.tap()
            enterFixture(in: app)
            tap("root-file", in: app)
            if confirm.waitForExistence(timeout: 5) && confirm.isEnabled { confirm.tap() }
            if selection.waitForExistence(timeout: 8) { delivered = true; break }
            XCTContext.runActivity(named: "File pick not delivered, attempt \(attempt)") { _ in }
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["Pane A location"].waitForExistence(timeout: 15))
        }
        XCTAssertTrue(delivered, "The file pick never reached the pane. " + app.debugDescription)
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

    // First visible element named like a picker item ("Downloads" or "Downloads, 1 item").
    // The panes' own rows can share a name but sit behind the picker, so they are not hittable.
    private func visible(_ name: String, in app: XCUIApplication, timeout: TimeInterval = 8) -> XCUIElement? {
        let query = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@ OR identifier BEGINSWITH %@", name, name + ",", name + ","))
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return element }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return nil
    }

    private func tap(_ name: String, in app: XCUIApplication) {
        guard let element = visible(name, in: app) else { return XCTFail("\(name) is not visible. " + app.debugDescription) }
        element.tap()
    }

    // Shows On My iPhone in the picker, where the fixture app's folder is listed.
    private func showOnMyIPhone(in app: XCUIApplication) {
        for attempt in 1...4 {
            if visible("Folder Test Source", in: app, timeout: 3) != nil { return }
            let back = app.navigationBars.buttons.matching(NSPredicate(format: "label == %@", "On My iPhone")).firstMatch
            if back.exists && back.isHittable {
                XCTContext.runActivity(named: "Back to On My iPhone, attempt \(attempt)") { _ in }
                back.tap()
                continue
            }
            let browse = app.buttons["Browse"].firstMatch
            if browse.exists { browse.tap() }
            visible("On My iPhone", in: app, timeout: 5)?.tap()
        }
        XCTAssertNotNil(visible("Folder Test Source", in: app, timeout: 5), app.debugDescription)
    }

    private func enterFixture(in app: XCUIApplication) {
        if visible("root-file", in: app, timeout: 2) != nil { return }
        showOnMyIPhone(in: app)
        tap("Folder Test Source", in: app)
        XCTAssertNotNil(visible("root-file", in: app), app.debugDescription)
    }
}
