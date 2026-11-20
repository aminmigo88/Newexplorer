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

// Files shows On My iPhone and iCloud Drive as single locations, but returns only
// their top-level folder; the folder name tells which location a pick was.
enum Place: String, CaseIterable {
    case onMyIPhone, iCloudDrive
    var title: String { self == .onMyIPhone ? "On My iPhone" : "iCloud Drive" }
    var symbol: String { self == .onMyIPhone ? "iphone.gen3" : "icloud" }
    var rootName: String { self == .onMyIPhone ? "File Provider Storage" : "com~apple~CloudDocs" }
    static func root(of url: URL) -> Place? {
        let name = url.standardizedFileURL.lastPathComponent
        return allCases.first { $0.rootName == name }
    }
}

enum PlaceRole { case rootItem, savedFolder, thisApp, unavailable }

// Retain the grant while a pane, a transfer or the copy shelf refers to it.
final class FolderGrant {
    let url: URL
    let place: Place?
    let isPlaceRoot: Bool
    var title: String?
    private let scoped: Bool
    convenience init(_ url: URL) { self.init(url, place: nil, isPlaceRoot: false) }
    init(_ url: URL, place: Place?, isPlaceRoot: Bool) {
        self.url = url
        self.place = place
        self.isPlaceRoot = isPlaceRoot
        scoped = url.startAccessingSecurityScopedResource()
    }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }

    func bookmark() throws -> Data {
        try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    static func restore(_ data: Data, place: Place? = nil, isPlaceRoot: Bool = false) throws -> (FolderGrant, stale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (FolderGrant(url, place: place, isPlaceRoot: isPlaceRoot), stale)
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
    case place(Place)

    static func local(_ url: URL) -> Location { .folder(FolderGrant(url), url) }
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var appFiles: Location { .local(documents) }
    var isAppFiles: Bool {
        guard case let .folder(_, url) = self else { return false }
        return url.standardizedFileURL.path == Location.documents.standardizedFileURL.path
    }
    var title: String {
        switch self {
        case let .folder(grant, url):
            if isAppFiles { return "App files" }
            if let title = grant.title, url.standardizedFileURL.path == grant.url.standardizedFileURL.path { return title }
            return url.lastPathComponent
        case let .share(server, path): return path == "/" ? server.name : (path as NSString).lastPathComponent
        case .photos: return "Photos"
        case .selectedFiles: return "Selected files"
        case let .place(place): return place.title
        }
    }
    var symbol: String {
        switch self {
        case .folder: return "folder"
        case .share: return "network"
        case .photos: return "photo.on.rectangle"
        case .selectedFiles: return "doc.on.doc"
        case let .place(place): return place.symbol
        }
    }
    // Folders opened from On My iPhone or iCloud Drive lead back up to that list.
    var parent: Location? {
        switch self {
        case let .folder(grant, url):
            let top = grant.url.standardizedFileURL.path
            if url.standardizedFileURL.path == top { return grant.place.map { Location.place($0) } }
            let up = url.deletingLastPathComponent()
            if grant.isPlaceRoot, let place = grant.place, up.standardizedFileURL.path == top { return .place(place) }
            return .folder(grant, up)
        case let .share(server, path):
            return path == "/" ? nil : .share(server, (path as NSString).deletingLastPathComponent)
        case .photos, .selectedFiles, .place: return nil
        }
    }
    func subdirectory(_ name: String) -> Location {
        switch self {
        case let .folder(grant, url): return .folder(grant, url.appendingPathComponent(name))
        case let .share(server, path): return .share(server, server.child(path, name))
        case .photos, .selectedFiles, .place: return self
        }
    }
    var isFileSelection: Bool {
        if case .selectedFiles = self { return true }
        return false
    }
    var isPlace: Bool {
        if case .place = self { return true }
        return false
    }
    func fileURL(for row: Entry) -> URL? {
        switch self {
        case let .folder(_, url): return url.appendingPathComponent(row.name)
        case let .selectedFiles(grants): return grants.first { $0.url.absoluteString == row.id }?.url
        case .place: return row.url
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
    var url: URL? = nil
    var note: String? = nil
    var inCloud = false
    var placeRole: PlaceRole? = nil
}

enum Directory {
    static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
    static func localEntries(_ url: URL) throws -> [Entry] {
        let rows: [Entry] = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys)).compactMap { child in
            let info = try? child.resourceValues(forKeys: keys)
            guard info?.isSymbolicLink != true else { return nil }
            let raw = child.lastPathComponent
            if let name = cloudStubName(raw) {
                return Entry(id: name, name: name, isFolder: false, bytes: nil, date: info?.contentModificationDate, inCloud: true)
            }
            let isFolder = info?.isDirectory ?? child.hasDirectoryPath
            if !isFolder && info?.isRegularFile == false { return nil }
            return Entry(id: raw, name: raw, isFolder: isFolder, bytes: info?.fileSize.map { Int64($0) },
                         date: info?.contentModificationDate, inCloud: info?.ubiquitousItemDownloadingStatus == .notDownloaded)
        }
        // A file that finished downloading can briefly sit next to its stub.
        var seen = Set<String>()
        return rows.filter { !$0.inCloud }.filter { seen.insert($0.id).inserted }
            + rows.filter { $0.inCloud }.filter { seen.insert($0.id).inserted }
    }
    // iCloud can list a file that is not downloaded as a hidden ".name.icloud" stub.
    static func cloudStubName(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else { return nil }
        return String(name.dropFirst().dropLast(7))
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
        case let .place(place): items = try await Places.shared.entries(for: place)
        case .photos: return try await PhotosAccess.list()
        }
        return items.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
