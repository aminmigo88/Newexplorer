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

    func testFolderPickerReturnsChosenFolderToPaneBAndReopensAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let folder = "Downloads-" + UUID().uuidString.prefix(6)
        let child = "Folder contents"
        func createFolder(_ name: String) {
            app.buttons["Pane options"].firstMatch.tap()
            app.buttons["New folder"].tap()
            let alert = app.alerts["New folder"]
            alert.textFields.firstMatch.typeText(name)
            alert.buttons["Save"].tap()
        }
        createFolder(folder)
        let row = app.buttons["item-A-" + folder]
        XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
        row.tap()
        createFolder(child)
        XCTAssertTrue(app.buttons["item-A-" + child].waitForExistence(timeout: 8))

        let paneB = app.buttons["Pane B location"]
        paneB.tap()
        app.buttons["choose-folder-B"].tap()
        let picker = app.descendants(matching: .any)
        func named(_ label: String) -> XCUIElement {
            picker.matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        // The Files picker remembers its last location. Navigate through Browse when needed.
        if !named("Newexplorer").waitForExistence(timeout: 2) && !named("On My iPhone").exists {
            let browse = app.buttons["Browse"].firstMatch
            if browse.exists { browse.tap() }
        }
        let device = named("On My iPhone")
        if device.exists && device.isHittable { device.tap() }
        let container = named("Newexplorer")
        XCTAssertTrue(container.waitForExistence(timeout: 8), app.debugDescription)
        container.tap()
        let selected = named(folder)
        XCTAssertTrue(selected.waitForExistence(timeout: 8), app.debugDescription)
        selected.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "Done"])).firstMatch
        XCTAssertTrue(confirm.isHittable, app.debugDescription)
        confirm.tap()
        func checkPane() {
            XCTAssertTrue(app.buttons["item-B-" + child].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(paneB.value as? String, folder)
        }
        checkPane()
        app.terminate()
        app.launch()
        checkPane()
    }
}
