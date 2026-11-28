import Foundation

// The journal is local to this installation and contains paths only. Each record is
// written atomically before the first remote change. A directory listing must succeed
// before recovery infers that any remote path is absent.
struct ShareFolder: Codable, Equatable {
    let host: String
    let share: String
    let user: String
    let path: String

    init(_ server: Share, _ folder: String) {
        host = server.host.lowercased()
        share = server.name.lowercased()
        user = server.user.lowercased()
        path = Share.pathKey(folder)
    }
}

protocol RecoveryDirectory {
    func names() async throws -> [String]
    func rename(_ from: String, to: String) async throws
    func remove(_ name: String) async throws
}

struct SMBDirectory: RecoveryDirectory {
    let server: Share
    let path: String
    func names() async throws -> [String] {
        try await server.client.contentsOfDirectory(atPath: path).compactMap { $0[.nameKey] as? String }
    }
    func rename(_ from: String, to: String) async throws {
        try await server.client.moveItem(atPath: server.child(path, from), toPath: server.child(path, to))
    }
    func remove(_ name: String) async throws {
        try await server.client.removeItem(atPath: server.child(path, name))
    }
}

actor ShareRecovery {
    static let shared = ShareRecovery(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SMBRecovery", isDirectory: true))

    struct Record: Codable {
        let id: UUID
        let folder: ShareFolder
        let name: String
        let upload: Bool
        let replacing: Bool
        var published = false
        var stage: String { ".NX-" + id.uuidString }
        var backup: String { ".NX-old-" + id.uuidString }
        // When the server applied a rename but the reply was lost, keep both versions.
        var recovered: String { "Recovered-" + id.uuidString }
    }

    private let directory: URL
    private var active = Set<UUID>()
    init(directory: URL) { self.directory = directory }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    private func save(_ record: Record) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: file(record.id), options: .atomic)
    }
    private func records() throws -> [Record] {
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        return try files.filter { $0.pathExtension == "json" }.map {
            try JSONDecoder().decode(Record.self, from: Data(contentsOf: $0))
        }
    }

    func perform(in folder: ShareFolder, remote: RecoveryDirectory, name: String, upload: Bool, replacing: Bool,
                 prepare: (String) async throws -> Void, publish: (String) async throws -> Void) async throws {
        // A pending record can also belong to another pane or a previous app session.
        try await recover(in: folder, remote: remote)
        let final = try safeName(name)
        if try records().contains(where: { $0.folder == folder && $0.name.caseInsensitiveCompare(final) == .orderedSame }) {
            throw ExplorerError("Another transfer is updating “\(final)”.")
        }
        var record = Record(id: UUID(), folder: folder, name: final, upload: upload, replacing: replacing)
        try save(record)
        active.insert(record.id)
        defer { active.remove(record.id) }
        do {
            try await prepare(record.stage)
            if replacing { try await remote.rename(final, to: record.backup) }
            try await publish(record.stage)
        } catch {
            let transferError = error
            do { try await reconcile(record, remote) }
            catch {
                throw ExplorerError("Transfer interrupted for “\(final)”. Reopen this shared folder to recover it. " + transferError.localizedDescription)
            }
            throw transferError
        }
        // Publication was acknowledged. If housekeeping fails it can be retried
        // independently, without copying again or losing the move source.
        record.published = true
        do {
            try save(record)
            if replacing { try await remote.remove(record.backup) }
            try FileManager.default.removeItem(at: file(record.id))
        } catch { /* The durable record is reconciled on the next successful listing. */ }
    }

    func recover(in folder: ShareFolder, remote: RecoveryDirectory) async throws {
        for record in try records() where record.folder == folder {
            // An earlier await may have let another pane finish this record.
            guard !active.contains(record.id), FileManager.default.fileExists(atPath: file(record.id).path) else { continue }
            active.insert(record.id)
            defer { active.remove(record.id) }
            try await reconcile(record, remote)
        }
    }

    private func reconcile(_ record: Record, _ remote: RecoveryDirectory) async throws {
        let names = try await remote.names()
        func present(_ name: String) -> Bool { names.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        if record.replacing && present(record.backup) {
            if !present(record.name) {
                try await remote.rename(record.backup, to: record.name)
            } else if record.published {
                try await remote.remove(record.backup)
            } else {
                try await remote.rename(record.backup, to: record.recovered)
            }
        }
        if record.upload && present(record.stage) { try await remote.remove(record.stage) }
        try FileManager.default.removeItem(at: file(record.id))
    }
}
