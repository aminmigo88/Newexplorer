import XCTest
import UIKit
@testable import Newexplorer

final class TransferTests: XCTestCase {
    @MainActor func testDirectFileSelectionCopiesTheChosenURLWhenNamesMatch() async throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        let folders = ["First", "Second", "Output"].map { base.appendingPathComponent($0) }
        for url in folders { try Files.fm.createDirectory(at: url, withIntermediateDirectories: false) }
        let files = folders.prefix(2).map { $0.appendingPathComponent("shared.txt") }
        for (i, url) in files.enumerated() { try Data([UInt8(i)]).write(to: url) }
        let pane = Pane(label: "SelectionTest")
        defer { UserDefaults.standard.removeObject(forKey: "savedFolder.SelectionTest.spot") }
        await pane.finishPicking(files + [files[0]], mode: .files)?.value
        XCTAssertNil(pane.finishPicking([], mode: .files))
        let selection = pane.location
        let entries = pane.rows
        XCTAssertEqual(entries.count, 2)
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

extension TransferTests {
    @MainActor
    func testPlaceCombinesTopLevelAndAddedFoldersAndPastesIntoTopLevel() async throws {
        let base = try Files.workspace()
        defer {
            try? Files.fm.removeItem(at: base)
            UserDefaults.standard.removeObject(forKey: Places.storeKey)
        }
        let root = base.appendingPathComponent("File Provider Storage")
        let other = base.appendingPathComponent("Other app/Documents")
        try Files.fm.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        try Files.fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("top.txt"))
        try Data([2]).write(to: other.appendingPathComponent("game.sav"))

        let result = await Places.shared.add([root, other, other], to: .onMyIPhone)
        XCTAssertEqual(result.roots, [.onMyIPhone])
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.already, 1)

        let rows = try await Directory.list(.place(.onMyIPhone))
        XCTAssertEqual(Set(rows.map(\.name)), ["Downloads", "top.txt", "Documents", Places.appName])
        let added = try XCTUnwrap(rows.first { $0.placeRole == .savedFolder })
        let folder = try XCTUnwrap(Places.shared.location(for: added, in: .onMyIPhone))
        guard case .place(.onMyIPhone)? = folder.parent else { return XCTFail("Up from an added folder should return to On My iPhone") }
        let downloads = try XCTUnwrap(rows.first { $0.name == "Downloads" })
        let inside = try XCTUnwrap(Places.shared.location(for: downloads, in: .onMyIPhone))
        guard case .place(.onMyIPhone)? = inside.parent else { return XCTFail("Up from a top-level folder should return to On My iPhone") }

        let contents = try await Directory.list(folder)
        let save = try XCTUnwrap(contents.first { $0.name == "game.sav" })
        try await Transfer.copy(save, from: folder, to: .place(.onMyIPhone))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("game.sav")), Data([2]))

        let top = try XCTUnwrap(rows.first { $0.name == "top.txt" })
        try await FileActions.perform(.delete([top]), at: .place(.onMyIPhone))
        XCTAssertFalse(Files.fm.fileExists(atPath: root.appendingPathComponent("top.txt").path))
        do {
            try await FileActions.perform(.delete([added]), at: .place(.onMyIPhone))
            XCTFail("App folders must only be removable from the list")
        } catch is ExplorerError { }

        Places.shared.rename(added, in: .onMyIPhone, to: "Game")
        let renamed = try await Directory.list(.place(.onMyIPhone))
        XCTAssertTrue(renamed.contains { $0.name == "Game" && $0.placeRole == .savedFolder })
        Places.shared.remove(added, from: .onMyIPhone)
        let remaining = try await Directory.list(.place(.onMyIPhone))
        XCTAssertFalse(remaining.contains { $0.placeRole == .savedFolder })
        XCTAssertTrue(Files.fm.fileExists(atPath: other.appendingPathComponent("game.sav").path))
    }

    func testCloudStubsListUnderTheirRealName() throws {
        let root = try Files.workspace()
        defer { try? Files.fm.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent(".report.pdf.icloud"))
        try Data([3]).write(to: root.appendingPathComponent("local.txt"))
        let rows = try Directory.localEntries(root)
        XCTAssertEqual(Set(rows.map(\.name)), ["report.pdf", "local.txt"])
        XCTAssertEqual(rows.first { $0.name == "report.pdf" }?.inCloud, true)
        XCTAssertEqual(rows.first { $0.name == "local.txt" }?.inCloud, false)
        XCTAssertEqual(Places.readableName(bundleID: "com.google.ios.youtube"), "Youtube")
        XCTAssertEqual(Places.readableName(bundleID: "com.udemy.ios"), "Udemy")
    }

    func testSortKeepsFoldersOnTopAndOrdersEachKey() {
        func file(_ name: String, _ bytes: Int64?, _ day: Double?) -> Entry {
            Entry(id: name, name: name, isFolder: false, bytes: bytes, date: day.map { Date(timeIntervalSince1970: $0 * 86_400) })
        }
        let rows = [file("b.txt", 10, 3), Entry(id: "Zeta", name: "Zeta", isFolder: true, bytes: nil, date: Date(timeIntervalSince1970: 9 * 86_400)),
                    file("A.pdf", 300, 1), file("c.jpg", nil, nil),
                    Entry(id: "alpha", name: "alpha", isFolder: true, bytes: nil, date: nil), file("d.TXT", 5, 2)]
        func names(_ key: SortKey, reversed: Bool = false) -> [String] { ListOrder(key: key, reversed: reversed).sorted(rows).map(\.name) }
        XCTAssertEqual(names(.name), ["alpha", "Zeta", "A.pdf", "b.txt", "c.jpg", "d.TXT"])
        XCTAssertEqual(names(.name, reversed: true), ["Zeta", "alpha", "d.TXT", "c.jpg", "b.txt", "A.pdf"])
        XCTAssertEqual(names(.date), ["Zeta", "alpha", "b.txt", "d.TXT", "A.pdf", "c.jpg"])
        XCTAssertEqual(names(.date, reversed: true), ["Zeta", "alpha", "A.pdf", "d.TXT", "b.txt", "c.jpg"])
        XCTAssertEqual(names(.size), ["alpha", "Zeta", "A.pdf", "b.txt", "d.TXT", "c.jpg"])
        XCTAssertEqual(names(.size, reversed: true), ["alpha", "Zeta", "d.TXT", "b.txt", "A.pdf", "c.jpg"])
        XCTAssertEqual(names(.kind), ["alpha", "Zeta", "c.jpg", "A.pdf", "b.txt", "d.TXT"])
        XCTAssertEqual(names(.kind, reversed: true), ["alpha", "Zeta", "b.txt", "d.TXT", "A.pdf", "c.jpg"])
        XCTAssertEqual(ListOrder(stored: "size.reversed", fallback: ListOrder(key: .name)), ListOrder(key: .size, reversed: true))
        XCTAssertEqual(ListOrder(stored: nil, fallback: ListOrder(key: .date)), ListOrder(key: .date))
        XCTAssertEqual(ListOrder(stored: "bogus", fallback: ListOrder(key: .name)), ListOrder(key: .name))
        XCTAssertEqual(ListOrder(key: .kind, reversed: true).stored, "kind.reversed")
    }

    @MainActor func testEachPaneRemembersItsSortAndPhotosKeepTheirOwn() {
        let keys = ["savedFolder.SortTest.sort", "savedFolder.SortTest.photoSort"]
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        let pane = Pane(label: "SortTest")
        XCTAssertEqual(pane.sortOrder, ListOrder(key: .name))
        XCTAssertEqual(pane.photoSort, ListOrder(key: .date))
        pane.sort(by: .size)
        XCTAssertEqual(pane.sortOrder, ListOrder(key: .size))
        pane.sort(by: .size)
        XCTAssertEqual(pane.sortOrder, ListOrder(key: .size, reversed: true))
        pane.sort(by: .kind)
        XCTAssertEqual(pane.sortOrder, ListOrder(key: .kind))
        let reopened = Pane(label: "SortTest")
        XCTAssertEqual(reopened.sortOrder, ListOrder(key: .kind))
        XCTAssertEqual(reopened.photoSort, ListOrder(key: .date))
        XCTAssertFalse(reopened.selecting)
        reopened.marked = ["x"]
        reopened.setSelecting(true)
        reopened.setSelecting(false)
        XCTAssertTrue(reopened.marked.isEmpty)
    }

    @MainActor func testSendSkipsPhotosICloudDriveAndTheSameFolder() throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        let other = base.appendingPathComponent("Other")
        try Files.fm.createDirectory(at: other, withIntermediateDirectories: false)
        XCTAssertTrue(SendRule.allows(.local(base), sourceFolder: nil))
        XCTAssertTrue(SendRule.allows(.local(base), sourceFolder: other))
        XCTAssertFalse(SendRule.allows(.local(base), sourceFolder: base))
        XCTAssertFalse(SendRule.allows(.photos(nil), sourceFolder: nil))
        XCTAssertFalse(SendRule.allows(.photos(.videos), sourceFolder: nil))
        XCTAssertFalse(SendRule.allows(.selectedFiles([]), sourceFolder: nil))
        XCTAssertFalse(SendRule.allows(.place(.iCloudDrive), sourceFolder: nil))
        let cloud = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Docs")
        XCTAssertFalse(SendRule.allows(.local(cloud), sourceFolder: nil))
        XCTAssertFalse(SendRule.allows(.folder(FolderGrant(base, place: .iCloudDrive, isPlaceRoot: false), other), sourceFolder: nil))
    }

    func testPhotoExportKeepsItsNameWithTheEditedType() {
        XCTAssertEqual(PhotosAccess.exportName(original: "IMG_1234.HEIC", render: nil), "IMG_1234.HEIC")
        XCTAssertEqual(PhotosAccess.exportName(original: "IMG_1234.HEIC", render: "FullSizeRender.jpg"), "IMG_1234.JPG")
        XCTAssertEqual(PhotosAccess.exportName(original: "IMG_1234.HEIC", render: "FullSizeRender.heic"), "IMG_1234.HEIC")
        XCTAssertEqual(PhotosAccess.exportName(original: "clip.mp4", render: "FullSizeRender.mov"), "clip.mov")
    }

    func testArchiveBrowsesLikeAFolderAndUnpacksOnlyWhatIsAsked() async throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        let docs = base.appendingPathComponent("Docs")
        try Files.fm.createDirectory(at: docs.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try Data("inner".utf8).write(to: docs.appendingPathComponent("inner.txt"))
        try Data("deep".utf8).write(to: docs.appendingPathComponent("Sub/deep.txt"))
        try Files.zip(docs)
        let ref = ArchiveRef(url: base.appendingPathComponent("Docs.zip"), parent: .local(base))

        let top = try await Directory.list(.archive(ref, ""))
        XCTAssertEqual(top.map(\.name), ["Docs"])
        XCTAssertEqual(top.first?.isFolder, true)
        let inside = try await Directory.list(.archive(ref, "Docs"))
        XCTAssertEqual(inside.map(\.name), ["Sub", "inner.txt"])
        let inner = try XCTUnwrap(inside.first { $0.name == "inner.txt" })
        XCTAssertEqual(inner.bytes, 5)

        // One file unpacks on its own.
        let scratch = try Files.workspace()
        defer { try? Files.fm.removeItem(at: scratch) }
        let unpacked = try ArchiveTools.unpack(inner, from: ref, into: scratch)
        XCTAssertEqual(try String(contentsOf: unpacked, encoding: .utf8), "inner")

        // Copying a folder out of the archive brings what is inside it.
        let out = base.appendingPathComponent("Out")
        try Files.fm.createDirectory(at: out, withIntermediateDirectories: false)
        try await Transfer.copy(try XCTUnwrap(inside.first { $0.name == "Sub" }), from: .archive(ref, "Docs"), to: .local(out))
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Sub/deep.txt"), encoding: .utf8), "deep")
        XCTAssertFalse(Files.fm.fileExists(atPath: out.appendingPathComponent("inner.txt").path))

        // Archives are read-only, and going up leaves the archive.
        do {
            try await FileActions.perform(.createFolder("New"), at: .archive(ref, ""))
            XCTFail("An archive accepted a new folder.")
        } catch {}
        do {
            try await Transfer.copy(inner, from: .archive(ref, "Docs"), to: .archive(ref, ""))
            XCTFail("An archive accepted a paste.")
        } catch {}
        XCTAssertEqual(Location.archive(ref, "Docs/Sub").parent?.title, "Docs")
        XCTAssertEqual(Location.archive(ref, "Docs").parent?.title, "Docs.zip")
        XCTAssertEqual(Location.archive(ref, "").parent?.title, base.lastPathComponent)
    }

    func testArchivePathsAndImplicitFolders() {
        XCTAssertEqual(ArchiveTools.normalized("./a/b/"), "a/b")
        XCTAssertNil(ArchiveTools.normalized("/etc/passwd"))
        XCTAssertNil(ArchiveTools.normalized("a/../b"))
        XCTAssertNil(ArchiveTools.normalized("a//b"))
        XCTAssertTrue(ArchiveTools.isBrowsable("Pack.ZIP"))
        XCTAssertTrue(ArchiveTools.isBrowsable("backup.tar.gz"))
        XCTAssertTrue(ArchiveTools.isBrowsable("song.rar"))
        XCTAssertFalse(ArchiveTools.isBrowsable("archive.7z"))
        XCTAssertFalse(ArchiveTools.isBrowsable("notes.gz"))
        let items = [ArchiveItem(rawPath: "x/y/z.txt", path: "x/y/z.txt", isFolder: false, size: 3, date: nil, encrypted: false),
                     ArchiveItem(rawPath: "top.txt", path: "top.txt", isFolder: false, size: 1, date: nil, encrypted: true)]
        let root = ArchiveTools.children(of: "", in: items)
        XCTAssertEqual(Set(root.map(\.name)), ["x", "top.txt"])
        XCTAssertEqual(root.first { $0.name == "x" }?.isFolder, true)
        XCTAssertEqual(root.first { $0.name == "top.txt" }?.note, "Password-protected")
        XCTAssertEqual(ArchiveTools.children(of: "x", in: items).map(\.name), ["y"])
        XCTAssertEqual(ArchiveTools.children(of: "x/y", in: items).map(\.id), ["x/y/z.txt"])
    }

    func testPhotoFoldersRoundTripAndLeadBackToTheList() {
        func row(_ id: String, _ name: String) -> Entry { Entry(id: id, name: name, isFolder: true, bytes: nil, date: nil) }
        XCTAssertEqual(PhotoFolder(entry: row("photos:screenshots", "Screenshots")), .screenshots)
        XCTAssertEqual(PhotoFolder(entry: row("photos:others", "Others")), .others)
        XCTAssertEqual(PhotoFolder.others.title, "Others")
        XCTAssertEqual(PhotosAccess.itemCount(1), "1 item")
        XCTAssertEqual(PhotosAccess.itemCount(12), "12 items")
        XCTAssertEqual(PhotoFolder(entry: row("photos:album:AB12/L0/040", "WhatsApp")), .album(id: "AB12/L0/040", name: "WhatsApp"))
        XCTAssertNil(PhotoFolder(entry: row("IMG_0001", "IMG_0001.JPG")))
        XCTAssertEqual(PhotoFolder.album(id: "AB12/L0/040", name: "WhatsApp").id, "photos:album:AB12/L0/040")
        XCTAssertEqual(Location.photos(.album(id: "A", name: "WhatsApp")).title, "WhatsApp")
        XCTAssertEqual(Location.photos(.videos).parent?.title, "Photos")
        XCTAssertNil(Location.photos(nil).parent)
    }

    func testInfoFormatsCameraData() throws {
        XCTAssertEqual(MediaInfo.shutter(1.0 / 120), "1/120 s")
        XCTAssertEqual(MediaInfo.shutter(2), "2 s")
        XCTAssertEqual(MediaInfo.aperture(1.78), "ƒ/1.8")
        XCTAssertEqual(MediaInfo.aperture(2), "ƒ/2")
        XCTAssertEqual(MediaInfo.focalLength(6.86, equivalent: 24), "6.9 mm (24 mm equivalent)")
        XCTAssertEqual(MediaInfo.coordinates(36.806667, 10.18153), "36.80667° N, 10.18153° E")
        XCTAssertEqual(MediaInfo.coordinates(-33.8688, -70.6), "33.86880° S, 70.60000° W")
        XCTAssertEqual(MediaInfo.camera(make: "Apple", model: "iPhone 17 Pro Max"), "Apple iPhone 17 Pro Max")
        XCTAssertEqual(MediaInfo.camera(make: "Canon", model: "Canon EOS R5"), "Canon EOS R5")
        XCTAssertEqual(MediaInfo.duration(83), "1:23")
        XCTAssertEqual(MediaInfo.duration(3723), "1:02:03")
        XCTAssertEqual(MediaInfo.size(512), "512 bytes")
        XCTAssertEqual(MediaInfo.dimensions(4032, 3024), "4032 × 3024")
        XCTAssertNil(MediaInfo.dimensions(nil, 3024))
        XCTAssertEqual(MediaInfo.rows([("A", "1"), ("B", nil), ("C", "")]).map(\.label), ["A"])
    }

    func testInfoReadsImageFiles() async throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        let file = base.appendingPathComponent("dot.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3, height: 2), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        }
        try XCTUnwrap(image.pngData()).write(to: file)
        let sections = try await MediaInfo.fileSections(file, place: "Test")
        XCTAssertEqual(sections.map(\.title), ["File", "Image"])
        XCTAssertEqual(sections[0].rows.first { $0.label == "Name" }?.value, "dot.png")
        XCTAssertEqual(sections[0].rows.first { $0.label == "Where" }?.value, "Test")
        XCTAssertEqual(sections[1].rows.first { $0.label == "Dimensions" }?.value, "3 × 2")
    }
}
