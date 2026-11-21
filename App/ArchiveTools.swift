import Foundation
import LibArchive

enum ArchiveTools {
    static func extract(_ archive: URL) throws {
        let scratch = try Files.workspace()
        defer { try? Files.fm.removeItem(at: scratch) }
        let output = scratch.appendingPathComponent(archive.lastPathComponent + " - extracted")
        try Files.read(archive) { input in
            let reader = ArchiveReader()
            let entries = try reader.entries(at: input)
            var seen = Set<String>()
            var total: Int64 = 0
            let free = try scratch.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
            for entry in entries {
                guard (entry.fileType == .regular || entry.fileType == .directory),
                      entry.hardlinkTarget == nil, entry.symlinkTarget == nil,
                      !entry.isDataEncrypted, !entry.isMetadataEncrypted else {
                    throw ExplorerError("This archive contains an encrypted item, link or unsupported file type.")
                }
                let parts = entry.path.split(separator: "/")
                guard !entry.path.hasPrefix("/"), !parts.isEmpty,
                      parts.allSatisfy({ (try? safeName(String($0))) != nil }),
                      seen.insert(parts.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()).inserted
                else { throw ExplorerError("The archive contains conflicting or unsupported paths.") }
                let sum = total.addingReportingOverflow(entry.size)
                guard entry.size >= 0, !sum.overflow, free.map({ sum.partialValue < Int64($0) }) ?? true
                else { throw ExplorerError("There is insufficient temporary space to extract this archive.") }
                total = sum.partialValue
            }
            try reader.extract(input, to: output, options: [.noOverwrite, .preserveModificationTime, .safeWrites])
        }
        try Files.publish(output, into: archive.deletingLastPathComponent())
    }
}

// An archive opened like a folder. Its listing is read once and kept while the pane shows it.
final class ArchiveRef {
    let url: URL
    // Where the archive file lives; holds the folder access while the archive is browsed.
    let parent: Location
    private let lock = NSLock()
    private var cached: [ArchiveItem]?
    init(url: URL, parent: Location) {
        self.url = url
        self.parent = parent
    }
    var name: String { url.lastPathComponent }
    func items() throws -> [ArchiveItem] {
        lock.lock()
        if let cached { lock.unlock(); return cached }
        lock.unlock()
        let loaded = try withExtendedLifetime(parent) {
            try Files.read(url) { try ArchiveTools.items(in: $0) }
        }
        lock.lock()
        cached = loaded
        lock.unlock()
        return loaded
    }
}

struct ArchiveItem {
    let rawPath: String
    let path: String
    let isFolder: Bool
    let size: Int64
    let date: Date?
    let encrypted: Bool
}

extension ArchiveTools {
    static let browsableTypes: Set<String> = ["zip", "rar", "tar", "tgz", "iso"]
    static func isBrowsable(_ name: String) -> Bool {
        let lower = name.lowercased()
        return browsableTypes.contains((lower as NSString).pathExtension) || lower.hasSuffix(".tar.gz")
    }

    // Entries with unsafe paths, links or special files are left out of the listing.
    static func items(in archive: URL) throws -> [ArchiveItem] {
        try ArchiveReader().entries(at: archive).compactMap { entry in
            guard entry.fileType == .regular || entry.fileType == .directory,
                  entry.symlinkTarget == nil, entry.hardlinkTarget == nil,
                  let path = normalized(entry.path) else { return nil }
            return ArchiveItem(rawPath: entry.path, path: path, isFolder: entry.fileType == .directory,
                               size: max(entry.size, 0), date: entry.modificationDate,
                               encrypted: entry.isDataEncrypted || entry.isMetadataEncrypted)
        }
    }
    static func normalized(_ raw: String) -> String? {
        var path = raw
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ (try? safeName($0)) != nil }) else { return nil }
        return parts.joined(separator: "/")
    }

    // Folders come from directory entries and from the paths of the files inside them.
    static func children(of inner: String, in items: [ArchiveItem]) -> [Entry] {
        let prefix = inner.isEmpty ? "" : inner + "/"
        var folders: [String: Entry] = [:]
        var files: [Entry] = []
        var seen = Set<String>()
        for item in items where item.path.hasPrefix(prefix) && item.path.count > prefix.count {
            let parts = item.path.dropFirst(prefix.count).split(separator: "/")
            guard let first = parts.first else { continue }
            let name = String(first)
            if parts.count > 1 || item.isFolder {
                if folders[name] == nil || (parts.count == 1 && folders[name]?.date == nil) {
                    folders[name] = Entry(id: prefix + name, name: name, isFolder: true, bytes: nil,
                                          date: parts.count == 1 ? item.date : nil)
                }
            } else if seen.insert(name).inserted {
                files.append(Entry(id: item.rawPath, name: name, isFolder: false, bytes: item.size, date: item.date,
                                   note: item.encrypted ? "Password-protected" : nil))
            }
        }
        return Array(folders.values) + files
    }

    // Unpacks one file, or one folder with everything inside it, without extracting the rest.
    static func unpack(_ entry: Entry, from ref: ArchiveRef, into folder: URL) throws -> URL {
        let items = try ref.items()
        let target = folder.appendingPathComponent(try safeName(entry.name))
        let files: [(ArchiveItem, URL)]
        var folders: [URL] = []
        if entry.isFolder {
            let prefix = entry.id + "/"
            let inside = items.filter { $0.path.hasPrefix(prefix) }
            folders = [target] + inside.filter(\.isFolder).map { target.appendingPathComponent(String($0.path.dropFirst(prefix.count))) }
            files = inside.filter { !$0.isFolder }.map { ($0, target.appendingPathComponent(String($0.path.dropFirst(prefix.count)))) }
        } else {
            guard let item = items.first(where: { $0.rawPath == entry.id && !$0.isFolder }) else {
                throw ExplorerError("“\(entry.name)” is no longer in the archive.")
            }
            files = [(item, target)]
        }
        guard files.allSatisfy({ !$0.0.encrypted }) else {
            throw ExplorerError("“\(entry.name)” is password-protected. Newexplorer can’t open password-protected archives.")
        }
        let needed = files.reduce(Int64(0)) { $0 + $1.0.size }
        if let free = try folder.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           needed >= Int64(free) {
            throw ExplorerError("There is not enough free space to open “\(entry.name)”.")
        }
        try withExtendedLifetime(ref.parent) {
            try Files.read(ref.url) { archive in
                let reader = ArchiveReader()
                try Files.fm.createDirectory(at: folder, withIntermediateDirectories: true)
                for directory in folders { try Files.fm.createDirectory(at: directory, withIntermediateDirectories: true) }
                for (item, output) in files {
                    try Files.fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard Files.fm.createFile(atPath: output.path, contents: nil) else {
                        throw ExplorerError("Couldn’t unpack “\(output.lastPathComponent)”.")
                    }
                    let handle = try FileHandle(forWritingTo: output)
                    defer { try? handle.close() }
                    try reader.readDataBlocks(forEntryPath: item.rawPath, in: archive) { block in
                        guard block.offset >= 0 else { throw ExplorerError("The archive is damaged.") }
                        try handle.seek(toOffset: UInt64(block.offset))
                        try handle.write(contentsOf: block.data)
                    }
                }
            }
        }
        return target
    }
}
