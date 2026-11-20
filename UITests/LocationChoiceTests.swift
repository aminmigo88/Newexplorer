import XCTest

final class LocationChoiceTests: XCTestCase {
    func testEmptyPanesOfferLocationsAndRequestPhotoAccessOnDemand() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launch()
        let photos = app.buttons["open-photos-A"]
        XCTAssertTrue(photos.waitForExistence(timeout: 15))
        for pane in ["A", "B"] {
            for choice in ["choose-folder-", "open-photos-", "connect-windows-"] {
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
}
