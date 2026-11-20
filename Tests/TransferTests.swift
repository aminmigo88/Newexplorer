import XCTest
@testable import Newexplorer

final class TransferTests: XCTestCase {
    func testDirectFileSelectionCopiesTheChosenURLWhenNamesMatch() async throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        let folders = ["First", "Second", "Output"].map { base.appendingPathComponent($0) }
        for url in folders { try Files.fm.createDirectory(at: url, withIntermediateDirectories: false) }
        let files = folders.prefix(2).map { $0.appendingPathComponent("shared.txt") }
        for (i, url) in files.enumerated() { try Data([UInt8(i)]).write(to: url) }
        let selection = Location.selectedFiles(files.map(FolderGrant.init))
        let entries = try await Directory.list(selection)
        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
        let second = try XCTUnwrap(entries.first { $0.id == files[1].absoluteString })
        try await Transfer.copy(second, from: selection, to: .local(folders[2]))
        XCTAssertEqual(try Data(contentsOf: folders[2].appendingPathComponent("shared.txt")), Data([1]))
    }
    func testCopyFolderAndRejectSecondPasteWithoutChangingEitherCopy() async throws {
        let sandbox = try Files.workspace()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let folder = sandbox.appendingPathComponent("Camera")
        let target = sandbox.appendingPathComponent("Laptop")
        for url in [folder, target] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        let original = Data([0, 15, 255])
        try original.write(to: folder.appendingPathComponent("capture.bin"))
        let row = try XCTUnwrap(try Directory.localEntries(sandbox).first { $0.name == "Camera" })
        try await Transfer.copy(row, from: .local(sandbox), to: .local(target))
        try Data([4]).write(to: folder.appendingPathComponent("capture.bin"))
        do {
            try await Transfer.copy(row, from: .local(sandbox), to: .local(target))
            XCTFail("Paste should reject an existing destination")
        } catch is ExplorerError { }
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("Camera/capture.bin")), original)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("capture.bin")), Data([4]))
    }

    func testStorageScanChecksBytesAndSkipsSymlinks() throws {
        let root = try Files.workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, byte): (String, UInt8) in [("one", 4), ("two", 4), ("other", 5)] {
            try Data([byte]).write(to: root.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: false)
        let result = try ScanReport.scan(root)
        XCTAssertEqual(result.groups, [["one", "two"]])
        XCTAssertEqual(result.reclaimable, 1)
        XCTAssertEqual(result.emptyFolders, ["empty"])
    }
}

extension TransferTests {
    func testArchiveRoundTrips() throws {
        let root = try Files.workspace()
        defer { try? Files.fm.removeItem(at: root) }
        let file = root.appendingPathComponent("field notes.txt")
        let body = Data("field notes".utf8)
        try body.write(to: file)
        try Files.zip(file)
        try ArchiveTools.extract(root.appendingPathComponent("field notes.txt.zip"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("field notes.txt.zip - extracted/field notes.txt")), body)

        // libarchive's test_read_format_rar5_stored fixture, also shipped by LibArchive Swift.
        let sample = "UmFyIRoHAQAzkrXlCgEFBgAFAQGAgAA4MAZjLAIDC50ABJ0ApIMCtEOglYAAAQ5oZWxsb3dvcmxkLnR4dAoDE34Oq1tW6Q4aaGVsbG8gbGliYXJjaGl2ZSB0ZXN0IHN1aXRlIQodd1ZRAwUEAA=="
        let rar = root.appendingPathComponent("sample.rar")
        try XCTUnwrap(Data(base64Encoded: sample)).write(to: rar)
        try ArchiveTools.extract(rar)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("sample.rar - extracted/helloworld.txt"), encoding: .utf8), "hello libarchive test suite!\n")
    }
}

extension TransferTests {
    func testCreateRenameAndDeleteOnlySelectedFolder() async throws {
        let root = try Files.workspace()
        defer { try? Files.fm.removeItem(at: root) }
        let location = Location.local(root)
        try Data([7]).write(to: root.appendingPathComponent("keep.bin"))
        try await FileActions.perform(.createFolder("Drafts"), at: location)
        let row = try XCTUnwrap(try Directory.localEntries(root).first { $0.name == "Drafts" })
        try await FileActions.perform(.rename(row, "Finished"), at: location)
        let renamed = try XCTUnwrap(try Directory.localEntries(root).first { $0.name == "Finished" })
        do {
            try await FileActions.perform(.rename(renamed, "keep.bin"), at: location)
            XCTFail("Rename must reject an existing destination")
        } catch is ExplorerError { }
        do {
            try await FileActions.perform(.createFolder("../escape"), at: location)
            XCTFail("Names must not escape the selected folder")
        } catch is ExplorerError { }
        try await FileActions.perform(.delete([renamed]), at: location)
        XCTAssertEqual(try Directory.localEntries(root).map(\.name), ["keep.bin"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("keep.bin")), Data([7]))
    }
}
