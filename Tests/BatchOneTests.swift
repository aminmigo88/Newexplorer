import XCTest
@testable import Newexplorer

// Copy, move, name conflicts, progress, ZIP and extract, Info and the pane's list.
final class BatchOneTests: XCTestCase {
    private func names(_ folder: URL) throws -> [String] {
        try Files.fm.contentsOfDirectory(atPath: folder.path).sorted()
    }
    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private func file(_ name: String, _ bytes: Int64? = nil) -> Entry {
        Entry(id: name, name: name, isFolder: false, bytes: bytes, date: nil)
    }
    private func folder(_ name: String) -> Entry {
        Entry(id: name, name: name, isFolder: true, bytes: nil, date: nil)
    }
    private func answer(_ choice: ConflictChoice) -> TransferHooks {
        TransferHooks(meter: TransferMeter(), resolve: { _ in choice })
    }

    func testCopyGoesStraightIntoTheDestinationAndLeavesNoStagingItems() async throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        let source = base.appendingPathComponent("Source"), target = base.appendingPathComponent("Target")
        try Files.fm.createDirectory(at: source.appendingPathComponent("Album/Inner"), withIntermediateDirectories: true)
        try Files.fm.createDirectory(at: target, withIntermediateDirectories: false)
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("Album/a.bin"))
        try Data([4]).write(to: source.appendingPathComponent("Album/Inner/b.bin"))
        let meter = TransferMeter()
        let copied = try await Transfer.run(folder("Album"), from: .local(source), to: .local(target), move: false, hooks: TransferHooks(meter: meter))
        XCTAssertTrue(copied)
        // Only the item itself is left in the destination: no hidden staging folder.
        XCTAssertEqual(try names(target), ["Album"])
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("Album/Inner/b.bin")), Data([4]))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("Album/a.bin")), Data([1, 2, 3]))
        XCTAssertEqual(meter.bytes, 4)
        XCTAssertEqual(try names(source), ["Album"])
        let planned = await Transfer.plannedBytes([folder("Album"), file("loose.bin", 6)], from: .local(source))
        XCTAssertEqual(planned, 10)
        let photos = await Transfer.plannedBytes([file("IMG_0001.HEIC")], from: .photos(.all))
        XCTAssertNil(photos)
    }

    func testStreamedCopyCountsEveryByteAndKeepsTheDate() throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        var data = Data(repeating: 7, count: 9 << 20)
        data[0] = 1
        data[data.count - 1] = 2
        var source = base.appendingPathComponent("big.bin")
        try data.write(to: source)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        var values = URLResourceValues()
        values.contentModificationDate = date
        try source.setResourceValues(values)
        let meter = TransferMeter()
        let copy = base.appendingPathComponent("copy.bin")
        // Copies to another drive are streamed in chunks, so progress and Cancel work.
        try Files.copyTree(source, to: copy, clone: false, meter: meter)
        XCTAssertEqual(meter.bytes, Int64(data.count))
        XCTAssertEqual(try Data(contentsOf: copy), data)
        let copied = try copy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(copied.map { Int($0.timeIntervalSince1970) }, 1_600_000_000)
    }

    func testCancelledCopyLeavesNothingBehind() async throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        let target = base.appendingPathComponent("Target")
        try Files.fm.createDirectory(at: target, withIntermediateDirectories: false)
        let source = base.appendingPathComponent("movie.mov")
        try Data(repeating: 1, count: 1 << 20).write(to: source)
        let meter = TransferMeter()
        meter.cancel()
        XCTAssertThrowsError(try Files.copy(source, into: target, as: "movie.mov", replacing: false, meter: meter))
        XCTAssertEqual(try names(target), [])
        do {
            _ = try await Transfer.run(file("movie.mov"), from: .local(base), to: .local(target), move: false, hooks: TransferHooks(meter: meter))
            XCTFail("A cancelled transfer copied something")
        } catch is CancellationError { }
        XCTAssertEqual(try names(target), [])
    }

    func testNameConflictsReplaceKeepBothSkipAndStop() async throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        let source = base.appendingPathComponent("Source"), target = base.appendingPathComponent("Target")
        for url in [source, target] { try Files.fm.createDirectory(at: url, withIntermediateDirectories: false) }
        try Data("new".utf8).write(to: source.appendingPathComponent("notes.txt"))
        try Data("old".utf8).write(to: target.appendingPathComponent("notes.txt"))
        let row = file("notes.txt", 3)
        let from = Location.local(source), to = Location.local(target)

        let skipped = try await Transfer.run(row, from: from, to: to, move: false, hooks: answer(.skip))
        XCTAssertFalse(skipped)
        XCTAssertEqual(try text(target.appendingPathComponent("notes.txt")), "old")

        let kept = try await Transfer.run(row, from: from, to: to, move: false, hooks: answer(.keepBoth))
        XCTAssertTrue(kept)
        XCTAssertEqual(try text(target.appendingPathComponent("notes 2.txt")), "new")
        XCTAssertEqual(try text(target.appendingPathComponent("notes.txt")), "old")

        let replaced = try await Transfer.run(row, from: from, to: to, move: false, hooks: answer(.replace))
        XCTAssertTrue(replaced)
        XCTAssertEqual(try text(target.appendingPathComponent("notes.txt")), "new")
        XCTAssertEqual(try names(target), ["notes 2.txt", "notes.txt"])

        do {
            _ = try await Transfer.run(row, from: from, to: to, move: false, hooks: answer(.stop))
            XCTFail("Stop should end the transfer")
        } catch is TransferStopped { }
        // Without the question, an existing name still fails as before.
        do {
            try await Transfer.copy(row, from: from, to: to)
            XCTFail("Paste should reject an existing name")
        } catch is ExplorerError { }

        // A folder that holds the item can't be replaced by it.
        let outer = base.appendingPathComponent("Outer")
        try Files.fm.createDirectory(at: outer.appendingPathComponent("Sub/Sub"), withIntermediateDirectories: true)
        do {
            _ = try await Transfer.run(folder("Sub"), from: .local(outer.appendingPathComponent("Sub")), to: .local(outer),
                                       move: false, hooks: answer(.replace))
            XCTFail("A folder was replaced by an item inside it")
        } catch is ExplorerError { }
        XCTAssertTrue(Files.fm.fileExists(atPath: outer.appendingPathComponent("Sub/Sub").path))
    }

    func testMoveRenamesSkipsItsOwnFolderAndRefusesItself() async throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        let a = base.appendingPathComponent("A"), b = base.appendingPathComponent("B")
        try Files.fm.createDirectory(at: a.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try Files.fm.createDirectory(at: b, withIntermediateDirectories: false)
        try Data([9]).write(to: a.appendingPathComponent("photo.jpg"))

        let same = try await Transfer.run(file("photo.jpg", 1), from: .local(a), to: .local(a), move: true, hooks: TransferHooks())
        XCTAssertFalse(same)
        XCTAssertTrue(Files.fm.fileExists(atPath: a.appendingPathComponent("photo.jpg").path))

        let moved = try await Transfer.run(file("photo.jpg", 1), from: .local(a), to: .local(b), move: true, hooks: TransferHooks())
        XCTAssertTrue(moved)
        XCTAssertFalse(Files.fm.fileExists(atPath: a.appendingPathComponent("photo.jpg").path))
        XCTAssertEqual(try Data(contentsOf: b.appendingPathComponent("photo.jpg")), Data([9]))
        XCTAssertEqual(try names(b), ["photo.jpg"])

        do {
            _ = try await Transfer.run(folder("Sub"), from: .local(a), to: .local(a.appendingPathComponent("Sub")), move: true, hooks: TransferHooks())
            XCTFail("A folder was moved into itself")
        } catch is ExplorerError { }
        XCTAssertTrue(Files.fm.fileExists(atPath: a.appendingPathComponent("Sub").path))

        XCTAssertTrue(Transfer.canMove(from: .local(a)))
        XCTAssertFalse(Transfer.canMove(from: .photos(.all)))
        XCTAssertFalse(Transfer.canMove(from: .selectedFiles([])))
        do {
            _ = try await Transfer.run(file("x.jpg"), from: .photos(.all), to: .local(b), move: true, hooks: TransferHooks())
            XCTFail("Photos items were moved")
        } catch is ExplorerError { }
    }

    func testMovesRenameOnlyInsideOneStorageArea() {
        let phone = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/AAA/File Provider Storage/Downloads/a.txt")
        let phoneFolder = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/AAA/File Provider Storage/Docs")
        let cloud = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Docs")
        let app = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/BBB/Documents/Saves")
        XCTAssertEqual(Files.storageArea(phone), Files.storageArea(phoneFolder))
        XCTAssertEqual(Files.storageArea(cloud), Files.storageArea(cloud.appendingPathComponent("x/y.txt")))
        XCTAssertNotEqual(Files.storageArea(phone), Files.storageArea(cloud))
        XCTAssertNotEqual(Files.storageArea(phone), Files.storageArea(app))
        XCTAssertEqual(Files.storageArea(app), Files.storageArea(app.appendingPathComponent("slot1.sav")))
    }

    func testUniqueNamesCountUp() {
        let taken: Set = ["photo.jpg", "photo 2.jpg", "Folder", "Pack.zip - extracted", "Report v1.2 final"]
        XCTAssertEqual(Files.uniqueName("photo.jpg") { taken.contains($0) }, "photo 3.jpg")
        XCTAssertEqual(Files.uniqueName("Folder", isFolder: true) { taken.contains($0) }, "Folder 2")
        XCTAssertEqual(Files.uniqueName("Pack.zip - extracted", isFolder: true) { taken.contains($0) }, "Pack.zip - extracted 2")
        XCTAssertEqual(Files.uniqueName("Report v1.2 final") { taken.contains($0) }, "Report v1.2 final 2")
        XCTAssertEqual(Files.uniqueName("new.txt") { taken.contains($0) }, "new.txt")
    }

    @MainActor func testFolderInfoAddsUpSizeAndItems() async throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        let top = base.appendingPathComponent("Folder")
        try Files.fm.createDirectory(at: top.appendingPathComponent("Sub/Empty"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: top.appendingPathComponent("a.bin"))
        try Data([1, 2, 3, 4, 5]).write(to: top.appendingPathComponent("Sub/b.bin"))
        XCTAssertEqual(try Files.measure(top), Files.Measure(files: 2, folders: 2, bytes: 8))

        let sections = try await MediaInfo.folderSections(folder("Folder"), in: .local(base))
        let rows = sections.flatMap(\.rows)
        XCTAssertEqual(rows.first { $0.label == "Contains" }?.value, "2 files, 2 folders")
        XCTAssertEqual(rows.first { $0.label == "Size" }?.value, "8 bytes")
        XCTAssertEqual(rows.first { $0.label == "Kind" }?.value, "Folder")

        // In an archive, folders also come from the paths of the files inside them.
        func item(_ path: String, folder: Bool = false, size: Int64 = 0) -> ArchiveItem {
            ArchiveItem(rawPath: path, path: path, isFolder: folder, size: size, date: nil, encrypted: false)
        }
        let items = [item("Docs/x/y.txt", size: 4), item("Docs/z.txt", size: 6), item("Docs/w", folder: true), item("Other/q.txt", size: 9)]
        XCTAssertEqual(MediaInfo.archiveMeasure(items, under: "Docs"), Files.Measure(files: 2, folders: 2, bytes: 10))

        // Files still in iCloud show what the list knows instead of downloading.
        var cloud = file("report.pdf", 2048)
        cloud.inCloud = true
        let info = MediaInfo.entrySections(cloud, place: "Docs", stored: "In iCloud, not downloaded").flatMap(\.rows)
        XCTAssertEqual(info.first { $0.label == "Stored" }?.value, "In iCloud, not downloaded")
        XCTAssertEqual(info.first { $0.label == "Where" }?.value, "Docs")
    }

    func testOneZipFromSeveralItemsAndUniqueNames() throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        try Files.fm.createDirectory(at: base.appendingPathComponent("Folder/Deep"), withIntermediateDirectories: true)
        try Data("A".utf8).write(to: base.appendingPathComponent("a.txt"))
        try Data("B".utf8).write(to: base.appendingPathComponent("Folder/b.txt"))
        try Data("C".utf8).write(to: base.appendingPathComponent("Folder/Deep/c.txt"))
        let items = [base.appendingPathComponent("a.txt"), base.appendingPathComponent("Folder")]

        let zip = try Files.zip(items, named: "Bundle", in: base)
        XCTAssertEqual(zip.lastPathComponent, "Bundle.zip")
        let paths = Set(try ArchiveTools.items(in: zip).filter { !$0.isFolder }.map(\.path))
        XCTAssertEqual(paths, ["a.txt", "Folder/b.txt", "Folder/Deep/c.txt"])
        XCTAssertEqual(try Files.zip([items[0]], named: "Bundle.zip", in: base).lastPathComponent, "Bundle 2.zip")
        XCTAssertFalse(try names(base).contains { $0.hasPrefix(".NX-") })

        let out = try ArchiveTools.extract(zip)
        XCTAssertEqual(out.lastPathComponent, "Bundle.zip - extracted")
        XCTAssertEqual(try text(out.appendingPathComponent("Folder/Deep/c.txt")), "C")
        XCTAssertEqual(try text(out.appendingPathComponent("a.txt")), "A")
        XCTAssertEqual(try ArchiveTools.extract(zip).lastPathComponent, "Bundle.zip - extracted 2")
        XCTAssertFalse(try names(base).contains { $0.hasPrefix(".NX-") })
    }

    func testExtractAcceptsDotSlashPathsAndTarArchives() throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        let tar = base.appendingPathComponent("pack.tar")
        try tarData([("./", nil), ("./hello.txt", Data("hi".utf8)), ("./Sub/", nil), ("./Sub/deep.txt", Data("deep".utf8))]).write(to: tar)
        XCTAssertTrue(ArchiveTools.isBrowsable(tar.lastPathComponent))
        XCTAssertEqual(Set(try ArchiveTools.items(in: tar).map(\.path)), ["hello.txt", "Sub", "Sub/deep.txt"])
        let out = try ArchiveTools.extract(tar)
        XCTAssertEqual(try text(out.appendingPathComponent("hello.txt")), "hi")
        XCTAssertEqual(try text(out.appendingPathComponent("Sub/deep.txt")), "deep")
    }

    @MainActor func testPlaceDeleteSkipsAppFoldersAndMatchesPanes() async throws {
        let base = try Files.workspace()
        defer {
            try? Files.fm.removeItem(at: base)
            UserDefaults.standard.removeObject(forKey: Places.storeKey)
        }
        let root = base.appendingPathComponent("File Provider Storage")
        let other = base.appendingPathComponent("Game app/Documents")
        try Files.fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Files.fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("old.txt"))
        try Data([2]).write(to: other.appendingPathComponent("game.sav"))
        _ = await Places.shared.add([root, other], to: .onMyIPhone)

        let rows = try await Directory.list(.place(.onMyIPhone))
        let old = try XCTUnwrap(rows.first { $0.name == "old.txt" })
        let added = try XCTUnwrap(rows.first { $0.placeRole == .savedFolder })
        let note = try await FileActions.perform(.delete([old, added]), at: .place(.onMyIPhone))
        XCTAssertTrue(note?.contains("Skipped 1 app folder") == true, note ?? "no note")
        XCTAssertFalse(Files.fm.fileExists(atPath: root.appendingPathComponent("old.txt").path))
        XCTAssertTrue(Files.fm.fileExists(atPath: other.appendingPathComponent("game.sav").path))

        // A pane showing the top folder itself counts as showing On My iPhone, so both reload.
        let place = Location.place(.onMyIPhone).spotKeys
        XCTAssertFalse(place.isDisjoint(with: Location.local(root).spotKeys))
        XCTAssertTrue(place.isDisjoint(with: Location.local(other).spotKeys))
        XCTAssertEqual(Location.local(other).spotKeys, Location.folder(FolderGrant(other), other).spotKeys)
        XCTAssertTrue(Location.local(other).spotKeys.isDisjoint(with: Location.local(other.appendingPathComponent("x")).spotKeys))
        Places.shared.remove(added, from: .onMyIPhone)
    }

    func testPickedFilesShowSizeAndDate() async throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        let picked = base.appendingPathComponent("song.mp3")
        try Data(repeating: 3, count: 7).write(to: picked)
        let rows = try await Directory.list(.selectedFiles([FolderGrant(picked)]))
        XCTAssertEqual(rows.first?.bytes, 7)
        XCTAssertNotNil(rows.first?.date)
    }

    @MainActor func testPaneSortsOnceAndFiltersTheSortedRows() {
        let keys = ["savedFolder.CacheTest.sort", "savedFolder.CacheTest.photoSort"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        let pane = Pane(label: "CacheTest")
        pane.rows = [file("b.txt"), folder("Zed"), file(".hidden"), file("a.txt")]
        XCTAssertEqual(pane.shown.map(\.name), ["Zed", "a.txt", "b.txt"])
        pane.query = "b"
        XCTAssertEqual(pane.shown.map(\.name), ["b.txt"])
        pane.query = ""
        pane.sort(by: .name)
        XCTAssertEqual(pane.shown.map(\.name), ["Zed", "b.txt", "a.txt"])
        pane.showHidden = true
        XCTAssertEqual(pane.shown.count, 4)
        pane.marked = [".hidden", "a.txt"]
        pane.showHidden = false
        XCTAssertEqual(pane.marked, ["a.txt"])
    }

    // A small ustar archive like `tar -cf pack.tar .` makes, where every path starts with "./".
    private func tarData(_ items: [(String, Data?)]) -> Data {
        var out = Data()
        for (path, body) in items {
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ text: String, at offset: Int) {
                let bytes = Array(text.utf8)
                header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            }
            func octal(_ value: Int, digits: Int) -> String {
                let raw = String(value, radix: 8)
                return String(repeating: "0", count: max(0, digits - raw.count)) + raw
            }
            put(path, at: 0)
            put(octal(body == nil ? 0o755 : 0o644, digits: 7), at: 100)
            put(octal(0, digits: 7), at: 108)
            put(octal(0, digits: 7), at: 116)
            put(octal(body?.count ?? 0, digits: 11), at: 124)
            put(octal(1_600_000_000, digits: 11), at: 136)
            header[156] = UInt8(ascii: body == nil ? "5" : "0")
            put("ustar", at: 257)
            put("00", at: 263)
            for index in 148..<156 { header[index] = 0x20 }
            let sum = header.reduce(0) { $0 + Int($1) }
            put(octal(sum, digits: 6), at: 148)
            header[154] = 0
            out.append(contentsOf: header)
            if let body {
                out.append(body)
                out.append(Data(count: (512 - body.count % 512) % 512))
            }
        }
        out.append(Data(count: 1024))
        return out
    }
}
