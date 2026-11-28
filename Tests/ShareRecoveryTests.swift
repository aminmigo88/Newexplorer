import XCTest
@testable import Newexplorer

final class ShareRecoveryTests: XCTestCase {
    private struct Offline: Error {}

    private actor Directory: RecoveryDirectory {
        var files = ["part.step": "old", ".NX-unrelated": "untouched"]
        var online = true
        func connect(_ online: Bool) { self.online = online }
        func stage(_ name: String) { files[name] = "new" }
        func names() throws -> [String] {
            guard online else { throw Offline() }
            return Array(files.keys)
        }
        func rename(_ from: String, to: String) throws {
            guard online, files[to] == nil, let value = files.removeValue(forKey: from) else { throw Offline() }
            files[to] = value
        }
        func remove(_ name: String) throws {
            guard online, files.removeValue(forKey: name) != nil else { throw Offline() }
        }
    }

    func testReconnectBeforeAndAfterLostRenameAcknowledgement() async throws {
        let server = try Share(host: "pc", share: "files", user: "tester", password: "")
        let folder = ShareFolder(server, "/Models")
        for renameApplied in [false, true] {
            let journal = try Files.workspace()
            defer { try? Files.fm.removeItem(at: journal) }
            let remote = Directory()
            let transfers = ShareRecovery(directory: journal)
            do {
                try await transfers.perform(in: folder, remote: remote, name: "part.step", upload: true, replacing: true) { stage in
                    await remote.stage(stage)
                } publish: { stage in
                    if renameApplied { try await remote.rename(stage, to: "part.step") }
                    await remote.connect(false)
                    throw Offline()
                }
                XCTFail("The disconnect must reach the transfer caller")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Reopen"))
            }
            await remote.connect(true)
            let relaunched = ShareRecovery(directory: journal)
            try await relaunched.recover(in: folder, remote: remote)
            try await relaunched.recover(in: folder, remote: remote)
            let files = await remote.files
            XCTAssertEqual(files["part.step"], renameApplied ? "new" : "old")
            XCTAssertEqual(files[".NX-unrelated"], "untouched")
            XCTAssertEqual(files.count, renameApplied ? 3 : 2)
            if renameApplied { XCTAssertEqual(files.first { $0.key.hasPrefix("Recovered-") }?.value, "old") }
            XCTAssertEqual(try Files.fm.contentsOfDirectory(atPath: journal.path), [])
        }
    }
}
