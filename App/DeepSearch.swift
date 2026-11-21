import Foundation

// Search inside subfolders: names that contain the text anywhere below the pane's location.
// Each result keeps the folder it is in, so it can be opened, copied, moved or sent from the results.
struct Found {
    let entry: Entry
    let home: Location
}

enum DeepSearch {
    static let limit = 500

    static func supports(_ location: Location) -> Bool {
        switch location {
        case .folder, .place, .share, .archive: return true
        case .photos, .selectedFiles: return false
        }
    }

    static func run(_ text: String, in location: Location, hidden: Bool) async throws -> [Found] {
        switch location {
        case let .folder(grant, url):
            return try await local(text, below: url, grant: grant, hidden: hidden)
        case let .place(place):
            var results: [Found] = []
            for (grant, url, label) in await placeFolders(place) {
                results += try await local(text, below: url, grant: grant, hidden: hidden, label: label)
                if results.count >= limit { break }
            }
            return Array(results.prefix(limit))
        case let .share(server, path):
            return try await share(text, server: server, below: path, hidden: hidden)
        case let .archive(ref, inner):
            let items = try await Task.detached { try ref.items() }.value
            return archive(text, ref: ref, items: items, below: inner, hidden: hidden)
        case .photos, .selectedFiles:
            return []
        }
    }

    // The top level of On My iPhone or iCloud Drive and each folder added to it.
    @MainActor private static func placeFolders(_ place: Place) async -> [(FolderGrant, URL, String)] {
        var folders: [(FolderGrant, URL, String)] = []
        if let root = Places.shared.root(place) { folders.append((root, root.url, "")) }
        guard let rows = try? await Places.shared.entries(for: place) else { return folders }
        for row in rows where row.placeRole == .savedFolder || row.placeRole == .thisApp {
            if case let .folder(grant, url)? = Places.shared.location(for: row, in: place) { folders.append((grant, url, row.name)) }
        }
        return folders
    }

    static func note(_ folders: [String]) -> String {
        folders.isEmpty ? "In this folder" : "In " + folders.joined(separator: " / ")
    }

    // Files still in iCloud are found by name without being downloaded.
    private static func local(_ text: String, below folder: URL, grant: FolderGrant, hidden: Bool, label: String = "") async throws -> [Found] {
        let stop = TransferMeter()
        let matches: [(Entry, URL)] = try await withTaskCancellationHandler {
            try await Task.detached {
                try withExtendedLifetime(grant) { try scan(text, below: folder, hidden: hidden, label: label, stop: stop) }
            }.value
        } onCancel: { stop.cancel() }
        return matches.map { Found(entry: $0.0, home: .folder(grant, $0.1)) }
    }
    static func scan(_ text: String, below folder: URL, hidden: Bool, label: String = "", stop: TransferMeter? = nil) throws -> [(Entry, URL)] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
        guard let walker = Files.fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
                                               errorHandler: { _, _ in true }) else { return [] }
        let top = folder.standardizedFileURL.pathComponents.count
        var results: [(Entry, URL)] = []
        for case let url as URL in walker {
            try stop?.check()
            let raw = url.lastPathComponent
            let stub = Directory.cloudStubName(raw)
            let info = try? url.resourceValues(forKeys: Set(keys))
            if info?.isSymbolicLink == true { continue }
            let isFolder = stub == nil && info?.isDirectory == true
            if !hidden && stub == nil && raw.hasPrefix(".") {
                if isFolder { walker.skipDescendants() }
                continue
            }
            let name = stub ?? raw
            guard name.localizedCaseInsensitiveContains(text) else { continue }
            let parent = url.deletingLastPathComponent()
            let folders = (label.isEmpty ? [] : [label]) + parent.standardizedFileURL.pathComponents.dropFirst(top)
            let entry = Entry(id: (folders + [name]).joined(separator: "/"), name: name, isFolder: isFolder,
                              bytes: isFolder ? nil : info?.fileSize.map { Int64($0) }, date: info?.contentModificationDate,
                              note: note(folders),
                              inCloud: stub != nil || info?.ubiquitousItemDownloadingStatus == .notDownloaded)
            results.append((entry, parent))
            if results.count >= limit { break }
        }
        return results
    }

    // A share is walked folder by folder; very large shares stop after a few thousand folders.
    private static func share(_ text: String, server: Share, below path: String, hidden: Bool) async throws -> [Found] {
        var results: [Found] = []
        var pending: [(String, [String])] = [(path, [])]
        var visited = 0
        while visited < 3000, let next = pending.popLast() {
            let (folder, names) = next
            try Task.checkCancellation()
            visited += 1
            for child in try await server.entries(folder) {
                if !hidden && child.name.hasPrefix(".") { continue }
                let inner = server.child(folder, child.name)
                if child.name.localizedCaseInsensitiveContains(text) {
                    let entry = Entry(id: (names + [child.name]).joined(separator: "/"), name: child.name, isFolder: child.isFolder,
                                      bytes: child.bytes, date: child.date, note: note(names))
                    results.append(Found(entry: entry, home: .share(server, folder)))
                    if results.count >= limit { return results }
                }
                if child.isFolder { pending.insert((inner, names + [child.name]), at: 0) }
            }
        }
        return results
    }

    static func archive(_ text: String, ref: ArchiveRef, items: [ArchiveItem], below inner: String, hidden: Bool) -> [Found] {
        let prefix = inner.isEmpty ? "" : inner + "/"
        var results: [Found] = []
        var folders = Set<String>()
        // Folders come from directory entries and from the paths of the files inside them.
        for item in items where item.path.hasPrefix(prefix) {
            let parts = item.path.dropFirst(prefix.count).split(separator: "/").map(String.init)
            for depth in 1..<max(parts.count, 1) { folders.insert(parts.prefix(depth).joined(separator: "/")) }
            if item.isFolder { folders.insert(parts.joined(separator: "/")); continue }
            guard let name = parts.last, name.localizedCaseInsensitiveContains(text), hidden || !parts.contains(where: { $0.hasPrefix(".") }) else { continue }
            let above = Array(parts.dropLast())
            let entry = Entry(id: item.rawPath, name: name, isFolder: false, bytes: item.size, date: item.date,
                              note: note(above))
            results.append(Found(entry: entry, home: .archive(ref, (prefix + above.joined(separator: "/")).trimmingCharacters(in: CharacterSet(charactersIn: "/")))))
        }
        for folder in folders.sorted() {
            let parts = folder.split(separator: "/").map(String.init)
            guard let name = parts.last, name.localizedCaseInsensitiveContains(text), hidden || !parts.contains(where: { $0.hasPrefix(".") }) else { continue }
            let above = Array(parts.dropLast())
            let entry = Entry(id: prefix + folder, name: name, isFolder: true, bytes: nil, date: nil, note: note(above))
            results.append(Found(entry: entry, home: .archive(ref, (prefix + above.joined(separator: "/")).trimmingCharacters(in: CharacterSet(charactersIn: "/")))))
        }
        return Array(results.prefix(limit))
    }
}
