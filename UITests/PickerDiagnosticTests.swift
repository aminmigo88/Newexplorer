import XCTest

// DIAGNOSTIC BUILD ONLY: try each picker variant on the same fixture file.
final class PickerDiagnosticTests: XCTestCase {
    private func run(_ name: String, _ env: [String: String]) -> Bool {
        let app = XCUIApplication()
        app.launchEnvironment = env
        app.launch()
        let browse = app.buttons["browse-files-A"]
        XCTAssertTrue(browse.waitForExistence(timeout: 15), app.debugDescription)
        browse.tap()
        openFixtureFolder(app)
        let file = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "root-file")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 8), app.debugDescription)
        file.tap()
        let picked = app.buttons["item-A-root-file.txt"]
        var tappedOpen = false
        var openEnabled = false
        let selectedAfterTap = file.exists && file.isSelected
        if !picked.waitForExistence(timeout: 3) {
            let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "Done"])).firstMatch
            if open.exists {
                openEnabled = open.isEnabled
                open.tap()
                tappedOpen = true
            }
        }
        let ok = picked.waitForExistence(timeout: 12)
        let pickerStillShown = app.otherElements["Browse View (Picker)"].exists
        XCTContext.runActivity(named: "NXRESULT \(name) picked=\(ok) selectedAfterTap=\(selectedAfterTap) tappedOpen=\(tappedOpen) openEnabled=\(openEnabled) pickerStillShown=\(pickerStillShown)") { _ in }
        app.terminate()
        return ok
    }

    func test1ModalMulti() { XCTAssertTrue(run("modal-multi", [:])) }
    func test2ModalMultiItem() { XCTAssertTrue(run("modal-multi-item", ["NX_TYPES": "item"])) }
    func test3ModalMultiCopy() { XCTAssertTrue(run("modal-multi-copy", ["NX_COPY": "1"])) }
    func test4ModalSingle() { XCTAssertTrue(run("modal-single", ["NX_MULTI": "0"])) }
    func test5ModalMultiFullScreen() { XCTAssertTrue(run("modal-multi-fullscreen", ["NX_FULL": "1"])) }
    func test6Importer() { XCTAssertTrue(run("swiftui-fileImporter-multi", ["NX_IMPORTER": "1"])) }
    func test7EmbeddedSheet() { XCTAssertTrue(run("embedded-sheet-0.2.2", ["NX_EMBED": "1"])) }

    private func openFixtureFolder(_ app: XCUIApplication) {
        let rootFile = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "root-file")).firstMatch
        if rootFile.waitForExistence(timeout: 3) { return }
        let folder = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR label BEGINSWITH %@", "Folder Test Source", "Folder Test Source")).firstMatch
        if !folder.waitForExistence(timeout: 2) {
            let device = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "On My iPhone", "On My iPhone,")).firstMatch
            if !device.exists {
                let browse = app.buttons["Browse"].firstMatch
                if browse.exists { browse.tap() }
            }
            if device.waitForExistence(timeout: 5) { device.tap() }
        }
        XCTAssertTrue(folder.waitForExistence(timeout: 8), app.debugDescription)
        folder.tap()
    }
}
