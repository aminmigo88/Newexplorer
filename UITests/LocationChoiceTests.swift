import XCTest

final class LocationChoiceTests: XCTestCase {
    func testEmptyPanesOfferLocationsAndRequestPhotoAccessOnDemand() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launch()
        let photos = app.buttons["open-photos-A"]
        XCTAssertTrue(photos.waitForExistence(timeout: 15))
        for pane in ["A", "B"] {
            for choice in ["choose-folder-", "browse-files-", "open-photos-", "connect-windows-"] {
                XCTAssertTrue(app.buttons[choice + pane].isHittable, choice + pane)
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
        XCTAssertTrue(app.buttons["choose-folder-B"].isHittable)
    }

    func testFolderPickerReturnsExternalDownloadsToPaneBAndReopensAfterRelaunch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FILES_FIXTURE"] == "1", "Requires the simulator Files fixture")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let rootPicker = app.buttons["choose-folder-A"]
        XCTAssertTrue(rootPicker.waitForExistence(timeout: 15))
        rootPicker.tap()
        showLocalRoot(in: app)
        let confirmRoot = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "Done"])).firstMatch
        let offered = confirmRoot.exists && confirmRoot.isEnabled
        XCTContext.runActivity(named: offered ? "Local root offers Open" : "Local root withholds Open") { _ in
            if offered {
                confirmRoot.tap()
                if !app.buttons["item-A-Folder Test Source"].waitForExistence(timeout: 4) {
                    let browse = app.buttons["browse-empty-A"]
                    XCTAssertTrue(browse.waitForExistence(timeout: 8), app.debugDescription)
                    browse.tap()
                    showLocalRoot(in: app)
                    fileItem("Folder Test Source", in: app).tap()
                    let file = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "root-file")).firstMatch
                    XCTAssertTrue(file.waitForExistence(timeout: 8), app.debugDescription)
                    file.tap()
                    let selected = app.buttons["item-A-root-file.txt"]
                    if !selected.waitForExistence(timeout: 2) && confirmRoot.exists { confirmRoot.tap() }
                    XCTAssertTrue(selected.waitForExistence(timeout: 10), app.debugDescription)
                }
            } else {
                app.buttons["Cancel"].firstMatch.tap()
            }
        }
        let choose = app.buttons["choose-folder-B"]
        XCTAssertTrue(choose.waitForExistence(timeout: 15))
        choose.tap()
        if !app.navigationBars["Folder Test Source"].waitForExistence(timeout: 2) {
            showLocalRoot(in: app)
            fileItem("Folder Test Source", in: app).tap()
        }
        let downloads = fileItem("Downloads", in: app)
        XCTAssertTrue(downloads.waitForExistence(timeout: 8), app.debugDescription)
        downloads.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "Done"])).firstMatch
        XCTAssertTrue(confirm.isHittable, app.debugDescription)
        confirm.tap()
        func checkFolder() {
            XCTAssertTrue(app.buttons["item-B-inside.txt"].waitForExistence(timeout: 12), app.debugDescription)
            XCTAssertEqual(app.buttons["Pane B location"].value as? String, "Downloads")
        }
        checkFolder()
        app.terminate()
        app.launch()
        checkFolder()
    }

    private func fileItem(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let match = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")
        return app.descendants(matching: .any).matching(match).firstMatch
    }

    private func showLocalRoot(in app: XCUIApplication) {
        let source = fileItem("Folder Test Source", in: app)
        let device = fileItem("On My iPhone", in: app)
        if !source.waitForExistence(timeout: 2) {
            if !device.exists {
                let browse = app.buttons["Browse"].firstMatch
                if browse.exists { browse.tap() }
            }
            if device.waitForExistence(timeout: 5) { device.tap() }
        }
        XCTAssertTrue(source.waitForExistence(timeout: 8), app.debugDescription)
    }
}
