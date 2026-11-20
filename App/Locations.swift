import Foundation
import AMSMB2
import Photos

struct ExplorerError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func safeName(_ name: String) throws -> String {
    guard !name.isEmpty, name != ".", name != "..",
          !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
        throw ExplorerError("A file has a name that cannot be copied safely.")
    }
    return name
}

// Retain the grant while a pane, a transfer or the copy shelf refers to it.
final class FolderGrant {
    let url: URL
    private let scoped: Bool
    init(_ url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }

    func bookmark() throws -> Data {
        try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    static func restore(_ data: Data) throws -> (FolderGrant, stale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (FolderGrant(url), stale)
    }
}

final class Share {
    let client: SMB2Manager
    let name: String
    let host: String
    init(host: String, share: String, user: String, password: String) throws {
        var parts = URLComponents()
        parts.scheme = "smb"
        parts.host = host
        guard !host.isEmpty, !host.contains("/"), !share.isEmpty, !user.isEmpty,
              let url = parts.url,
              let client = SMB2Manager(url: url, credential: URLCredential(user: user, password: password, persistence: .forSession))
        else { throw ExplorerError("Enter a computer name or IP address, share name and username.") }
        self.client = client
        self.host = host
        self.name = try safeName(share)
    }
    func entries(_ path: String) async throws -> [Entry] {
        try await client.contentsOfDirectory(atPath: path).compactMap { row in
            guard let name = row[.nameKey] as? String, (try? safeName(name)) != nil else { return nil }
            let type = row[.fileResourceTypeKey] as? URLFileResourceType
            guard type == .directory || type == .regular else { return nil }
            return Entry(id: name, name: name, isFolder: type == .directory,
                         bytes: (row[.fileSizeKey] as? NSNumber)?.int64Value, date: row[.contentModificationDateKey] as? Date)
        }
    }
    func child(_ base: String, _ name: String) -> String { base == "/" ? "/" + name : base + "/" + name }
}

enum Location {
    case folder(FolderGrant, URL)
    case selectedFiles([FolderGrant])
    case share(Share, String)
    case photos

    static func local(_ url: URL) -> Location { .folder(FolderGrant(url), url) }
    static var appFiles: Location {
        .local(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
    }
    var isAppFiles: Bool {
        guard case let .folder(_, url) = self else { return false }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return url.standardizedFileURL.path == documents.standardizedFileURL.path
    }
    var title: String {
        switch self {
        case let .folder(_, url): return isAppFiles ? "App files" : url.lastPathComponent
        case let .share(server, path): return path == "/" ? server.name : (path as NSString).lastPathComponent
        case .photos: return "Photos"
        case .selectedFiles: return "Selected files"
        }
    }
    var symbol: String {
        switch self {
        case .folder: return "folder"
        case .share: return "network"
        case .photos: return "photo.on.rectangle"
        case .selectedFiles: return "doc.on.doc"
        }
    }
    var parent: Location? {
        switch self {
        case let .folder(grant, url):
            return url.standardizedFileURL.path == grant.url.standardizedFileURL.path ? nil : .folder(grant, url.deletingLastPathComponent())
        case let .share(server, path):
            return path == "/" ? nil : .share(server, (path as NSString).deletingLastPathComponent)
        case .photos, .selectedFiles: return nil
        }
    }
    func subdirectory(_ name: String) -> Location {
        switch self {
        case let .folder(grant, url): return .folder(grant, url.appendingPathComponent(name))
        case let .share(server, path): return .share(server, server.child(path, name))
        case .photos, .selectedFiles: return self
        }
    }
    var isFileSelection: Bool {
        if case .selectedFiles = self { return true }
        return false
    }
    func fileURL(for row: Entry) -> URL? {
        switch self {
        case let .folder(_, url): return url.appendingPathComponent(row.name)
        case let .selectedFiles(grants): return grants.first { $0.url.absoluteString == row.id }?.url
        default: return nil
        }
    }
}

struct Entry: Identifiable {
    let id: String
    let name: String
    let isFolder: Bool
    let bytes: Int64?
    let date: Date?
    var isPhoto = false
}

enum Directory {
    static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
    static func localEntries(_ url: URL) throws -> [Entry] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys)).compactMap { child in
            let info = try? child.resourceValues(forKeys: keys)
            guard info?.isSymbolicLink != true else { return nil }
            let isFolder = info?.isDirectory ?? child.hasDirectoryPath
            if !isFolder && info?.isRegularFile == false { return nil }
            return Entry(id: child.lastPathComponent, name: child.lastPathComponent, isFolder: isFolder,
                         bytes: info?.fileSize.map { Int64($0) }, date: info?.contentModificationDate)
        }
    }
    static func list(_ location: Location) async throws -> [Entry] {
        let items: [Entry]
        switch location {
        case let .folder(grant, url):
            items = try await Task.detached {
                try withExtendedLifetime(grant) { try Files.read(url) { try localEntries($0) } }
            }.value
        case let .share(server, path): items = try await server.entries(path)
        case let .selectedFiles(grants):
            items = grants.map { grant in
                Entry(id: grant.url.absoluteString, name: grant.url.lastPathComponent, isFolder: false, bytes: nil, date: nil)
            }
        case .photos: return try await PhotosAccess.list()
        }
        return items.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
