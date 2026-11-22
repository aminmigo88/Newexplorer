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
        XCTAssertTrue(app.buttons["deep-search-A"].exists, app.debugDescription)
        app.buttons["connect-windows-B"].tap()
        XCTAssertTrue(app.textFields["Computer name or IP address"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["find-devices"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["list-shares"].exists, app.debugDescription)
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

        step("Pick Downloads for pane B")
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
        step("Relaunch")
        app.terminate()
        app.launch()
        checkFolder()

        // Pane A reopens On My iPhone, and the added folder still opens after the relaunch.
        XCTAssertTrue(addedFolder.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(app.buttons["Pane A location"].value as? String, "On My iPhone")
        addedFolder.tap()
        XCTAssertTrue(app.buttons["item-A-root-file.txt"].waitForExistence(timeout: 10), app.debugDescription)

        step("Browse Files pick")
        // Single files still open in place from Browse Files locations. A pick the simulator
        // drops stays dropped in that picker, so retry with a fresh launch.
        let selection = app.buttons.matching(NSPredicate(format: "label == %@ AND value == %@", "Pane A location", "Selected files")).firstMatch
        var delivered = false
        for attempt in 1...3 {
            app.buttons["Pane A location"].tap()
            app.buttons["Browse Files locations"].firstMatch.tap()
            enterFixture(in: app)
            if let file = visible("root-file", in: app) {
                XCTContext.runActivity(named: "Picking '\(file.label)' [\(file.identifier)] type \(file.elementType.rawValue) at \(file.frame)") { _ in }
                file.tap()
            }
            let shown = confirm.waitForExistence(timeout: 5)
            XCTContext.runActivity(named: "Open button " + (shown ? (confirm.isEnabled ? "enabled" : "disabled") + " '\(confirm.label)'" : "missing")) { _ in }
            if shown && confirm.isEnabled { confirm.tap() }
            if selection.waitForExistence(timeout: 8) { delivered = true; break }
            XCTContext.runActivity(named: "Picker still shown: \(app.otherElements["Browse View (Picker)"].exists)") { _ in }
            XCTContext.runActivity(named: "File pick not delivered, attempt \(attempt)") { _ in }
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["Pane A location"].waitForExistence(timeout: 15))
        }
        XCTAssertTrue(delivered, "The file pick never reached the pane. " + app.debugDescription)
        XCTAssertTrue(app.buttons["item-A-root-file.txt"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testPhotoFoldersViewerSwipeInfoSendAndArchives() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FILES_FIXTURE"] == "1", "Requires the simulator fixture photos")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launch()

        // Pane A shows this app's own folder; pane B shows Photos. Wait for any saved folder to reopen first.
        let paneA = app.buttons["Pane A location"], paneB = app.buttons["Pane B location"]
        XCTAssertTrue(paneA.waitForExistence(timeout: 15) && paneB.waitForExistence(timeout: 5))
        settle(paneA)
        settle(paneB)
        if (paneA.value as? String) != "App files" {
            paneA.tap()
            app.buttons["App files"].firstMatch.tap()
        }
        XCTAssertTrue(location("A", is: "App files", in: app).waitForExistence(timeout: 10), app.debugDescription)
        let photosChoice = app.buttons["open-photos-B"]
        if !photosChoice.exists { paneB.tap() }
        photosChoice.firstMatch.tap()
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), app.debugDescription)
        let allow = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Full Access", "All Photos")).firstMatch
        XCTAssertTrue(allow.exists, alert.debugDescription)
        allow.tap()

        // Photos opens to its folders.
        XCTAssertTrue(location("B", is: "Photos", in: app).waitForExistence(timeout: 10), app.debugDescription)
        for folder in ["All", "Pictures", "Videos", "Screenshots", "Others"] {
            XCTAssertTrue(app.buttons["item-B-" + folder].waitForExistence(timeout: 15), app.debugDescription)
        }
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "item-B-"))
        // The fixture images have no camera data, so they are in Others and not in Pictures.
        app.buttons["item-B-Pictures"].tap()
        XCTAssertTrue(location("B", is: "Pictures", in: app).waitForExistence(timeout: 10), app.debugDescription)
        let emptyPictures = app.staticTexts["No photos or videos are available to Newexplorer."]
        _ = photos.firstMatch.waitForExistence(timeout: 10) || emptyPictures.waitForExistence(timeout: 2)
        let inPictures = Set(photos.allElementsBoundByIndex.map(\.identifier))
        app.buttons.matching(NSPredicate(format: "label == %@", "Parent folder")).element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["item-B-Others"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["item-B-Others"].tap()
        XCTAssertTrue(location("B", is: "Others", in: app).waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(photos.element(boundBy: 1).waitForExistence(timeout: 45), app.debugDescription)
        let name = String(photos.element(boundBy: 0).identifier.dropFirst("item-B-".count))
        let next = String(photos.element(boundBy: 1).identifier.dropFirst("item-B-".count))
        XCTContext.runActivity(named: "Viewing photos \(name) and \(next)") { _ in }
        XCTAssertFalse(inPictures.contains("item-B-" + name), "\(inPictures)")
        XCTAssertFalse(inPictures.contains("item-B-" + next), "\(inPictures)")

        // The viewer swipes to the next photo and back.
        step("Open a photo in the viewer")
        openViewer(photos.element(boundBy: 0), in: app)
        XCTAssertTrue(app.navigationBars.staticTexts[name].waitForExistence(timeout: 15), app.debugDescription)
        app.swipeLeft()
        XCTAssertTrue(app.navigationBars.staticTexts[next].waitForExistence(timeout: 10), app.debugDescription)
        app.swipeRight()
        XCTAssertTrue(app.navigationBars.staticTexts[name].waitForExistence(timeout: 10), app.debugDescription)

        // Info shows the file and image data.
        step("Viewer Info")
        app.buttons["viewer-info"].tap()
        XCTAssertTrue(app.staticTexts["Dimensions"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", " × ")).firstMatch.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Size"].exists, app.debugDescription)
        app.buttons["info-done"].tap()

        // Send copies the photo into pane A.
        step("Send to pane A")
        let send = app.buttons["viewer-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(send.label.hasPrefix("Send to On My iPhone/"), send.label)
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send)
        waitForExpectations(timeout: 30)
        send.tap()
        let sent = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "viewer-send", "Sent")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["viewer-close"].tap()
        let copied = app.buttons["item-A-" + name]
        XCTAssertTrue(copied.waitForExistence(timeout: 10), app.debugDescription)

        // With Photos in pane B, a file opened in pane A offers no Send.
        step("Open the copy in pane A")
        openViewer(copied, in: app)
        XCTAssertFalse(app.buttons["viewer-send"].exists, app.debugDescription)
        app.buttons["viewer-close"].tap()

        // Long-press Info shows the file's data without opening it.
        step("Long-press Info")
        XCTAssertTrue(copied.waitForExistence(timeout: 10), app.debugDescription)
        menuItem("Info", on: copied, in: app).tap()
        XCTAssertTrue(app.staticTexts["Size"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["info-done"].tap()

        // A ZIP opens like a folder; a file inside opens in the viewer; up leaves the archive.
        step("Create ZIP")
        XCTAssertTrue(copied.waitForExistence(timeout: 10), app.debugDescription)
        menuItem("Create ZIP", on: copied, in: app).tap()
        let zip = app.buttons["item-A-" + name + ".zip"]
        XCTAssertTrue(zip.waitForExistence(timeout: 15), app.debugDescription)
        zip.tap()
        XCTAssertTrue(location("A", is: name + ".zip", in: app).waitForExistence(timeout: 10), app.debugDescription)
        let packed = app.buttons["item-A-" + name]
        XCTAssertTrue(packed.waitForExistence(timeout: 10), app.debugDescription)
        step("Open a file inside the ZIP")
        openViewer(packed, in: app)
        XCTAssertTrue(app.navigationBars.staticTexts[name].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["viewer-close"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "Parent folder")).element(boundBy: 0).tap()
        XCTAssertTrue(location("A", is: "App files", in: app).waitForExistence(timeout: 10), app.debugDescription)

        // Selection starts off; the switch shows the circles and a tap then ticks the row.
        step("Selection switch")
        XCTAssertTrue(copied.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["Select \(name)"].exists)
        app.buttons["select-mode-A"].tap()
        XCTAssertTrue(app.buttons["Select \(name)"].waitForExistence(timeout: 5), app.debugDescription)
        copied.tap()
        let copyOne = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Copy 1")).firstMatch
        XCTAssertTrue(copyOne.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["cut-A"].isEnabled, app.debugDescription)
        app.buttons["select-mode-A"].tap()
        XCTAssertFalse(app.buttons["Select \(name)"].exists)
        XCTAssertFalse(copyOne.exists)
    }

    private func location(_ pane: String, is title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND value == %@", "Pane \(pane) location", title)).firstMatch
    }

    // Waits until a pane's location stops changing, such as a saved folder reopening on launch.
    private func settle(_ pane: XCUIElement) {
        var last = pane.value as? String
        var steady = 0
        for _ in 0..<16 where steady < 4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let now = pane.value as? String
            steady = now == last ? steady + 1 : 0
            last = now
        }
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
            closeMenu(in: app)
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

    // A slow tap can open the picker's menu for an item instead of the item; tap outside to close it.
    private func closeMenu(in app: XCUIApplication) {
        let menu = app.otherElements["LP.CaptionBar.TopCaption"]
        guard menu.exists else { return }
        XCTContext.runActivity(named: "Closing a menu the picker opened") { _ in }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).tap()
        for _ in 0..<6 where menu.exists { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
    }

    // The picker sometimes goes back to its top list after a tap; try the way in again.
    private func enterFixture(in app: XCUIApplication) {
        for attempt in 1...3 {
            closeMenu(in: app)
            if visible("root-file", in: app, timeout: 2) != nil { return }
            showOnMyIPhone(in: app)
            visible("Folder Test Source", in: app)?.tap()
            if visible("root-file", in: app) != nil { return }
            XCTContext.runActivity(named: "Fixture folder not shown, attempt \(attempt)") { _ in }
        }
        XCTFail("The picker never showed the fixture folder. " + app.debugDescription)
    }

    // Marks where a test is, so a failure report shows the step it stopped at.
    private func step(_ name: String) {
        XCTContext.runActivity(named: "Step: " + name) { _ in }
    }

    // The simulator sometimes misses a tap while the list is still settling.
    private func openViewer(_ row: XCUIElement, in app: XCUIApplication) {
        let close = app.buttons["viewer-close"]
        for attempt in 1...3 {
            XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
            row.tap()
            if close.waitForExistence(timeout: 10) { return }
            XCTContext.runActivity(named: "Viewer not open, attempt \(attempt)") { _ in }
        }
        XCTFail("The viewer never opened. " + app.debugDescription)
    }

    // Long-presses until the menu shows the item; a missed press is closed and tried again.
    private func menuItem(_ label: String, on row: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        let item = app.buttons[label]
        for attempt in 1...3 {
            row.press(forDuration: 1.2)
            if item.waitForExistence(timeout: 5) { return item }
            XCTContext.runActivity(named: "No \(label) in the menu, attempt \(attempt)") { _ in }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        }
        XCTFail("The menu never showed \(label). " + app.debugDescription)
        return item
    }
}
