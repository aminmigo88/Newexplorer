import XCTest
@testable import Newexplorer

// Saved shares, finding devices, subfolder search, reopening the exact folder,
// received files and file icons.
final class BatchTwoTests: XCTestCase {
    @MainActor func testSavedSharesRememberMatchAndForget() throws {
        let item = SavedShare(host: "laptop.local", share: "Docs", user: "amin")
        defer { SavedShares.shared.forget(item) }
        let stored = SavedShares.shared.remember(item, password: "secret")
        XCTAssertTrue(SavedShares.shared.all.contains(item))
        // An unsigned simulator build may have no Keychain; a signed app stores the password.
        if stored { XCTAssertEqual(SavedShares.shared.password(for: item), "secret") }
        XCTAssertEqual(item.title, "laptop.local/Docs")
        let server = try Share(host: "LAPTOP.local", share: "docs", user: "amin", password: "secret")
        XCTAssertEqual(SavedShares.shared.match(server), item)
        let other = try Share(host: "laptop.local", share: "Docs", user: "guest", password: "")
        XCTAssertNil(SavedShares.shared.match(other))
        SavedShares.shared.forget(item)
        XCTAssertFalse(SavedShares.shared.all.contains(item))
        XCTAssertNil(SavedShares.shared.password(for: item))
    }

    func testSharePathsCompareLikeWindows() {
        XCTAssertTrue(Share.samePath("/Docs/Old", "/docs/old/"))
        XCTAssertFalse(Share.samePath("/Docs/Old", "/Docs/Older"))
        XCTAssertTrue(Share.isInside("/Docs/Old/Sub", "/docs/old"))
        XCTAssertFalse(Share.isInside("/Docs/Older", "/Docs/Old"))
        XCTAssertFalse(Share.isInside("/Docs/Old", "/Docs/Old"))
        XCTAssertTrue(Share.isInside("/Docs", "/"))
    }

    func testTwoConnectionsToOneShareAreTheSamePlace() async throws {
        let first = try Share(host: "LAPTOP.local", share: "Docs", user: "amin", password: "secret")
        let second = try Share(host: "laptop.local", share: "docs", user: "guest", password: "")
        let music = try Share(host: "laptop.local", share: "Music", user: "amin", password: "secret")
        let byName = try Share(host: "localhost", share: "Docs", user: "amin", password: "secret")
        let byAddress = try Share(host: "127.0.0.1", share: "Docs", user: "amin", password: "secret")
        let same = await Share.samePlace(first, second)
        let different = await Share.samePlace(first, music)
        let nameAndAddress = await Share.samePlace(byName, byAddress)
        XCTAssertTrue(same)
        XCTAssertFalse(different)
        XCTAssertTrue(nameAndAddress)
    }

    func testNetBIOSNameQueryAndAnswer() {
        let query = [UInt8](LocalNetwork.netbiosQuery())
        XCTAssertEqual(query.count, 50)
        XCTAssertEqual(query[12], 0x20)
        XCTAssertEqual(String(decoding: query[13..<45], as: UTF8.self), "CK" + String(repeating: "A", count: 30))
        XCTAssertEqual(Array(query[46...]), [0x00, 0x21, 0x00, 0x01])

        func name(_ text: String, suffix: UInt8, group: Bool) -> [UInt8] {
            Array((text + String(repeating: " ", count: 15 - text.count)).utf8) + [suffix, group ? 0x84 : 0x04, 0x00]
        }
        var answer = [UInt8](repeating: 0, count: 56)
        answer.append(3)
        answer += name("WORKGROUP", suffix: 0x00, group: true) + name("DESKTOP-AMIN", suffix: 0x20, group: false)
            + name("DESKTOP-AMIN", suffix: 0x00, group: false)
        XCTAssertEqual(LocalNetwork.parseNetbiosName(Data(answer)), "DESKTOP-AMIN")
        XCTAssertNil(LocalNetwork.parseNetbiosName(Data(answer.prefix(60))))
        XCTAssertNil(LocalNetwork.parseNetbiosName(Data([0, 1, 2])))
    }

    func testSubnetScanCoversTheIPhonesOwnNetwork() {
        func address(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { a << 24 | b << 16 | c << 8 | d }
        let home = LocalNetwork.hosts(address: address(192, 168, 1, 23), mask: 0xFFFF_FF00)
        XCTAssertEqual(home.count, 253)
        XCTAssertEqual(home.first, "192.168.1.1")
        XCTAssertEqual(home.last, "192.168.1.254")
        XCTAssertFalse(home.contains("192.168.1.23"))
        // A larger network is cut to the iPhone's own 254 addresses.
        XCTAssertEqual(LocalNetwork.hosts(address: address(10, 0, 7, 9), mask: 0xFFFF_0000).count, 253)
        XCTAssertEqual(LocalNetwork.hosts(address: address(10, 0, 0, 1), mask: 0xFFFF_FFFC), ["10.0.0.2"])
        XCTAssertEqual(LocalNetwork.hosts(address: address(10, 0, 0, 1), mask: 0xFFFF_FFFF), [])
        XCTAssertEqual(LocalNetwork.text(address(172, 16, 0, 254)), "172.16.0.254")
    }

    func testSubfolderSearchFindsNamesAndKeepsTheirFolder() async throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        for folder in ["A/B", ".hidden"] { try Files.fm.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true) }
        try Data("1".utf8).write(to: base.appendingPathComponent("A/report.txt"))
        try Data("22".utf8).write(to: base.appendingPathComponent("A/B/Report Final.pdf"))
        try Data("3".utf8).write(to: base.appendingPathComponent(".hidden/report-old.txt"))
        try Data("4".utf8).write(to: base.appendingPathComponent("A/notes.txt"))

        let found = try await DeepSearch.run("report", in: .local(base), hidden: false)
        XCTAssertEqual(Set(found.map(\.entry.name)), ["report.txt", "Report Final.pdf"])
        let deep = try XCTUnwrap(found.first { $0.entry.name == "Report Final.pdf" })
        XCTAssertEqual(deep.entry.note, "In A / B")
        XCTAssertEqual(deep.entry.bytes, 2)
        XCTAssertEqual(deep.home.fileURL(for: deep.entry)?.standardizedFileURL, base.appendingPathComponent("A/B/Report Final.pdf").standardizedFileURL)
        let withHidden = try await DeepSearch.run("report", in: .local(base), hidden: true)
        XCTAssertEqual(withHidden.count, 3)

        // A result copies from its own folder.
        let target = base.appendingPathComponent("Target")
        try Files.fm.createDirectory(at: target, withIntermediateDirectories: false)
        let copied = try await Transfer.run(deep.entry, from: deep.home, to: .local(target), move: false, hooks: TransferHooks())
        XCTAssertTrue(copied)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("Report Final.pdf")), Data("22".utf8))

        // Inside an archive the results point at the folder they are in.
        let ref = ArchiveRef(url: base.appendingPathComponent("x.zip"), parent: .local(base))
        let items = [ArchiveItem(rawPath: "Docs/Sub/deep report.txt", path: "Docs/Sub/deep report.txt", isFolder: false, size: 4, date: nil, encrypted: false),
                     ArchiveItem(rawPath: "Docs/Reports/", path: "Docs/Reports", isFolder: true, size: 0, date: nil, encrypted: false),
                     ArchiveItem(rawPath: "Other.txt", path: "Other.txt", isFolder: false, size: 1, date: nil, encrypted: false)]
        let inside = DeepSearch.archive("report", ref: ref, items: items, below: "Docs", hidden: false)
        XCTAssertEqual(Set(inside.map(\.entry.name)), ["deep report.txt", "Reports"])
        let file = try XCTUnwrap(inside.first { !$0.entry.isFolder })
        XCTAssertEqual(file.entry.id, "Docs/Sub/deep report.txt")
        guard case let .archive(_, folder) = file.home else { return XCTFail("The result should be in the archive") }
        XCTAssertEqual(folder, "Docs/Sub")
        XCTAssertTrue(DeepSearch.supports(.local(base)))
        XCTAssertFalse(DeepSearch.supports(.photos(.all)))
    }

    @MainActor func testTransfersTakeEachResultFromItsOwnFolder() async throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        let one = base.appendingPathComponent("One"), two = base.appendingPathComponent("Two"), target = base.appendingPathComponent("Target")
        for url in [one, two, target] { try Files.fm.createDirectory(at: url, withIntermediateDirectories: false) }
        try Data("a".utf8).write(to: one.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: two.appendingPathComponent("b.txt"))
        let items = [Entry(id: "One/a.txt", name: "a.txt", isFolder: false, bytes: 1, date: nil),
                     Entry(id: "Two/b.txt", name: "b.txt", isFolder: false, bytes: 1, date: nil)]
        let homes: [String: Location] = ["One/a.txt": .local(one), "Two/b.txt": .local(two)]
        let center = TransferCenter()
        let done = expectation(description: "transfer finished")
        var result: TransferCenter.Report?
        center.start(items, from: .local(base), homes: homes, to: .local(target), move: true) { report in
            result = report
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 20)
        XCTAssertEqual(result?.done, 2)
        XCTAssertNil(result?.failure)
        XCTAssertEqual(Set(try Files.fm.contentsOfDirectory(atPath: target.path)), ["a.txt", "b.txt"])
        XCTAssertFalse(Files.fm.fileExists(atPath: one.appendingPathComponent("a.txt").path))
        XCTAssertFalse(Files.fm.fileExists(atPath: two.appendingPathComponent("b.txt").path))
    }

    @MainActor func testPaneReopensTheExactFolderAfterARelaunch() async throws {
        let base = URL(fileURLWithPath: "/tmp/spot")
        XCTAssertEqual(PaneSpot.path(from: base, to: base.appendingPathComponent("a/b")), ["a", "b"])
        XCTAssertEqual(PaneSpot.path(from: base, to: base), [])
        XCTAssertNil(PaneSpot.path(from: base.appendingPathComponent("a"), to: base))
        let spot = PaneSpot(kind: .placeFolder, place: "onMyIPhone", id: "X1", path: ["Saves", "2024"])
        XCTAssertEqual(try JSONDecoder().decode(PaneSpot.self, from: try JSONEncoder().encode(spot)), spot)

        // A folder inside App files is reopened, as deep as it still exists.
        let keys = ["savedFolder.SpotTest.spot", "savedFolder.SpotTest.active", "savedFolder.SpotTest.place",
                    "savedFolder.SpotTest.sort", "savedFolder.SpotTest.photoSort"]
        let documents = Location.documents
        let folder = documents.appendingPathComponent("Spot Test Folder")
        defer {
            try? Files.fm.removeItem(at: folder)
            keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        }
        try Files.fm.createDirectory(at: folder.appendingPathComponent("Inner"), withIntermediateDirectories: true)
        XCTAssertEqual(PaneSpot.descend(documents, ["Spot Test Folder", "Inner", "Gone"]).lastPathComponent, "Inner")
        let first = Pane(label: "SpotTest")
        await first.open(.folder(FolderGrant(documents), folder.appendingPathComponent("Inner")))
        let reopened = Pane(label: "SpotTest")
        await reopened.start()
        guard case let .folder(_, url) = reopened.location else { return XCTFail("The pane should reopen a folder") }
        XCTAssertEqual(url.standardizedFileURL, folder.appendingPathComponent("Inner").standardizedFileURL)
        XCTAssertEqual(reopened.location.parent?.title, "Spot Test Folder")
        let saved = try XCTUnwrap(UserDefaults.standard.data(forKey: "savedFolder.SpotTest.spot"))
        XCTAssertEqual(try JSONDecoder().decode(PaneSpot.self, from: saved), PaneSpot(kind: .appFiles, path: ["Spot Test Folder", "Inner"]))
    }

    func testReceivedFilesAndInbox() throws {
        let inbox = Incoming.inbox
        XCTAssertTrue(Incoming.isInbox(inbox.appendingPathComponent("scan.pdf")))
        XCTAssertFalse(Incoming.isInbox(Location.documents.appendingPathComponent("scan.pdf")))
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        let file = base.appendingPathComponent("song.m4a")
        try Data(repeating: 1, count: 12).write(to: file)
        let entry = Incoming.entry(for: file)
        XCTAssertEqual(entry.name, "song.m4a")
        XCTAssertEqual(entry.bytes, 12)
        XCTAssertFalse(entry.isFolder)
        // Files outside the Inbox are never removed.
        Incoming.discard([file])
        XCTAssertTrue(Files.fm.fileExists(atPath: file.path))
    }

    func testFileIconsFollowTheType() {
        XCTAssertEqual(FileIcon.symbol(for: "Holiday", isFolder: true), "folder.fill")
        XCTAssertEqual(FileIcon.symbol(for: "a.jpg", isFolder: false), "photo")
        XCTAssertEqual(FileIcon.symbol(for: "b.mov", isFolder: false), "film")
        XCTAssertEqual(FileIcon.symbol(for: "c.mp3", isFolder: false), "music.note")
        XCTAssertEqual(FileIcon.symbol(for: "d.pdf", isFolder: false), "doc.richtext")
        XCTAssertEqual(FileIcon.symbol(for: "e.zip", isFolder: false), "archivebox")
        XCTAssertEqual(FileIcon.symbol(for: "f.txt", isFolder: false), "doc.text")
        XCTAssertEqual(FileIcon.symbol(for: "g.swift", isFolder: false), "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(FileIcon.symbol(for: "h.qqqzzz", isFolder: false), "doc")
        XCTAssertTrue(FileIcon.hasThumbnail("IMG_1.HEIC"))
        XCTAssertTrue(FileIcon.hasThumbnail("clip.mov"))
        XCTAssertTrue(FileIcon.hasThumbnail("manual.pdf"))
        XCTAssertFalse(FileIcon.hasThumbnail("notes.txt"))
        XCTAssertFalse(FileIcon.hasThumbnail("song.mp3"))
    }
}
