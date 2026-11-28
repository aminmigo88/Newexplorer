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
    let user: String
    // The PC's name for addresses and Send, such as MSI; the address it was reached at until a name is known.
    var displayName: String
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
        self.user = user
        self.displayName = host
        self.name = try safeName(share)
    }
    // Share paths compare the way Windows compares them: without regard to case or extra slashes.
    static func pathKey(_ path: String) -> String {
        "/" + path.split(separator: "/").map { $0.lowercased() }.joined(separator: "/")
    }
    static func samePath(_ a: String, _ b: String) -> Bool { pathKey(a) == pathKey(b) }
    // True when path is somewhere inside folder.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        let inner = pathKey(path), outer = pathKey(folder)
        return inner != outer && (outer == "/" || inner.hasPrefix(outer + "/"))
    }
    // Two connections reach the same files when they go to the same computer and shared folder,
    // as when both panes opened the same share. A name and an address are compared by address.
    static func samePlace(_ a: Share, _ b: Share) async -> Bool {
        if a === b { return true }
        guard a.name.caseInsensitiveCompare(b.name) == .orderedSame else { return false }
        if a.host.caseInsensitiveCompare(b.host) == .orderedSame { return true }
        let first = await LocalNetwork.addresses(a.host)
        guard !first.isEmpty else { return false }
        return !first.isDisjoint(with: await LocalNetwork.addresses(b.host))
    }
    // A computer that doesn't answer on the file-sharing port fails here within 5 seconds,
    // instead of after the SMB library's 60-second wait.
    static func checkAnswering(_ host: String) async throws {
        guard await LocalNetwork.isOpen(host, port: 445, timeout: 5) else {
            throw ExplorerError("The computer isn’t answering. Check that it’s on, awake and on the same Wi-Fi, and that Local Network is allowed for Newexplorer in Settings.")
        }
    }
    // The shared folders a computer offers to this account, without the hidden ones that end in $.
    static func list(host: String, user: String, password: String) async throws -> [String] {
        var parts = URLComponents()
        parts.scheme = "smb"
        parts.host = host
        guard !host.isEmpty, !host.contains("/"), !user.isEmpty, let url = parts.url,
              let client = SMB2Manager(url: url, credential: URLCredential(user: user, password: password, persistence: .forSession))
        else { throw ExplorerError("Enter a computer name or IP address and username.") }
        try await checkAnswering(host)
        let shares = try await client.listShares()
        return shares.map { $0.name }.filter { !$0.hasSuffix("$") && (try? safeName($0)) != nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    func entries(_ path: String) async throws -> [Entry] {
        try await ShareRecovery.shared.recover(in: ShareFolder(self, path), remote: SMBDirectory(server: self, path: path))
        return try await client.contentsOfDirectory(atPath: path).compactMap { row in
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
    // nil lists the Photos folders; a folder lists its photos and videos.
    case photos(PhotoFolder?)
    case place(Place)
    // An archive browsed like a folder; the string is the folder path inside it.
    case archive(ArchiveRef, String)

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
        case let .photos(folder): return folder?.title ?? "Photos"
        case .selectedFiles: return "Selected files"
        case let .place(place): return place.title
        case let .archive(ref, inner): return inner.isEmpty ? ref.name : (inner as NSString).lastPathComponent
        }
    }
    var symbol: String {
        switch self {
        case .folder: return "folder"
        case .share: return "network"
        case .photos: return "photo.on.rectangle"
        case .selectedFiles: return "doc.on.doc"
        case let .place(place): return place.symbol
        case .archive: return "archivebox"
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
        case let .photos(folder): return folder == nil ? nil : .photos(nil)
        case let .archive(ref, inner):
            return inner.isEmpty ? ref.parent : .archive(ref, (inner as NSString).deletingLastPathComponent)
        case .selectedFiles, .place: return nil
        }
    }
    // The folder, place or selection an archive was opened from.
    var base: Location {
        if case let .archive(ref, _) = self { return ref.parent.base }
        return self
    }
    func subdirectory(_ name: String) -> Location {
        switch self {
        case let .folder(grant, url): return .folder(grant, url.appendingPathComponent(name))
        case let .share(server, path): return .share(server, server.child(path, name))
        case let .archive(ref, inner): return .archive(ref, inner.isEmpty ? name : inner + "/" + name)
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
    var isArchive: Bool {
        if case .archive = self { return true }
        return false
    }
    // Keys naming what a pane shows, so only panes showing a changed place are reloaded.
    @MainActor var spotKeys: Set<String> {
        func folderKey(_ url: URL) -> String { "folder:" + url.standardizedFileURL.resolvingSymlinksInPath().path }
        switch self {
        case let .folder(_, url):
            var keys: Set<String> = [folderKey(url)]
            for place in Place.allCases {
                if let root = Places.shared.root(place), Files.samePath(root.url, url) { keys.insert("place:" + place.rawValue) }
            }
            return keys
        case let .place(place):
            var keys: Set<String> = ["place:" + place.rawValue]
            if let root = Places.shared.root(place) { keys.insert(folderKey(root.url)) }
            return keys
        case let .share(server, path): return ["share:\(server.host)/\(server.name)\(path)"]
        case let .photos(folder): return ["photos:" + (folder?.id ?? "")]
        case let .archive(ref, inner): return ["archive:" + ref.url.path + "#" + inner]
        case .selectedFiles: return []
        }
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
                let info = try? grant.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey])
                return Entry(id: grant.url.absoluteString, name: grant.url.lastPathComponent, isFolder: false,
                             bytes: info?.fileSize.map { Int64($0) }, date: info?.contentModificationDate,
                             inCloud: info?.ubiquitousItemDownloadingStatus == .notDownloaded)
            }
        case let .place(place): items = try await Places.shared.entries(for: place)
        case let .photos(folder):
            if let folder { return try await PhotosAccess.list(folder) }
            return try await PhotosAccess.folders()
        case let .archive(ref, inner):
            items = try await Task.detached { ArchiveTools.children(of: inner, in: try ref.items()) }.value
        }
        return items.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

enum SortKey: String, CaseIterable {
    case name, date, size, kind
    var title: String { rawValue.capitalized }
    // Name and Kind start A to Z, Date starts newest first, Size starts largest first.
    func direction(reversed: Bool) -> String {
        switch self {
        case .name, .kind: return reversed ? "Z to A" : "A to Z"
        case .date: return reversed ? "Oldest first" : "Newest first"
        case .size: return reversed ? "Smallest first" : "Largest first"
        }
    }
}

struct ListOrder: Equatable {
    var key: SortKey
    var reversed = false

    init(key: SortKey, reversed: Bool = false) {
        self.key = key
        self.reversed = reversed
    }
    init(stored: String?, fallback: ListOrder) {
        let parts = (stored ?? "").split(separator: ".").map(String.init)
        if let first = parts.first, let key = SortKey(rawValue: first) {
            self.key = key
            self.reversed = parts.dropFirst().first == "reversed"
        } else {
            self = fallback
        }
    }
    var stored: String { key.rawValue + (reversed ? ".reversed" : "") }

    // Folders stay on top. Missing dates or sizes go last; ties fall back to the name.
    func sorted(_ rows: [Entry]) -> [Entry] {
        rows.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            if let first = precedes(a, b) { return first }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    private func precedes(_ a: Entry, _ b: Entry) -> Bool? {
        switch key {
        case .name: return ordered(a.name, b.name)
        case .kind: return ordered(kind(a), kind(b))
        case .date: return later(a.date, b.date)
        case .size: return later(a.isFolder ? nil : a.bytes, b.isFolder ? nil : b.bytes)
        }
    }
    private func kind(_ row: Entry) -> String { row.isFolder ? "" : (row.name as NSString).pathExtension.lowercased() }
    private func ordered(_ x: String, _ y: String) -> Bool? {
        let result = x.localizedStandardCompare(y)
        return result == .orderedSame ? nil : (result == .orderedAscending) != reversed
    }
    private func later<T: Comparable>(_ x: T?, _ y: T?) -> Bool? {
        switch (x, y) {
        case let (.some(x), .some(y)): return x == y ? nil : (x > y) != reversed
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return nil
        }
    }
}

// Send drops a copy into the other pane only where a paste makes sense:
// not into Photos, iCloud Drive, a file selection, or the folder the file is already in.
enum SendRule {
    @MainActor static func allows(_ destination: Location, sourceFolder: URL?) -> Bool {
        switch destination {
        case .photos, .selectedFiles, .archive: return false
        case .share: return true
        case let .place(place):
            guard place != .iCloudDrive, let root = Places.shared.root(place) else { return false }
            return !same(root.url, sourceFolder)
        case let .folder(grant, url):
            if grant.place == .iCloudDrive || inICloudDrive(grant.url) || inICloudDrive(url) { return false }
            return !same(url, sourceFolder)
        }
    }
    static func inICloudDrive(_ url: URL) -> Bool {
        url.standardizedFileURL.path.contains("/Library/Mobile Documents/")
    }
    private static func same(_ folder: URL, _ other: URL?) -> Bool {
        guard let other else { return false }
        return folder.standardizedFileURL.resolvingSymlinksInPath().path == other.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
