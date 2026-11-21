import Foundation
import CryptoKit
import ZIPFoundation

enum Files {
    static let fm = FileManager.default
    static func read<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var error: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { item in
            result = Result { try body(item) }
        }
        if let error { throw error }
        guard let result else { throw ExplorerError("Could not open the selected item.") }
        return try result.get()
    }
    static func write<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var error: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &error) { item in
            result = Result { try body(item) }
        }
        if let error { throw error }
        guard let result else { throw ExplorerError("Could not write to this folder.") }
        return try result.get()
    }

    static func workspace() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("NX-" + UUID().uuidString)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    // On the same volume files are cloned, which is instant and takes no extra space.
    // Across volumes, such as a USB drive, they are streamed in chunks so progress and Cancel work.
    static func copyTree(_ source: URL, to target: URL, clone: Bool = true, meter: TransferMeter? = nil) throws {
        try meter?.check()
        let info = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        guard info.isSymbolicLink != true else { throw ExplorerError("Copying symbolic links is unsupported.") }
        if info.isDirectory == true {
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyTree(item, to: target.appendingPathComponent(try safeName(item.lastPathComponent)), clone: clone, meter: meter)
            }
        } else if info.isRegularFile == true {
            if clone {
                try fm.copyItem(at: source, to: target)
                meter?.add(Int64(info.fileSize ?? 0))
            } else {
                try streamCopy(source, to: target, meter: meter)
            }
        } else { throw ExplorerError("Unsupported file type.") }
    }
    static func streamCopy(_ source: URL, to target: URL, meter: TransferMeter?) throws {
        guard fm.createFile(atPath: target.path, contents: nil) else { throw ExplorerError("Couldn’t create “\(target.lastPathComponent)”.") }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
            try meter?.check()
            try output.write(contentsOf: chunk)
            meter?.add(Int64(chunk.count))
        }
        if let date = try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            var values = URLResourceValues()
            values.contentModificationDate = date
            var copy = target
            try? copy.setResourceValues(values)
        }
    }
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let first = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier,
              let second = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier else { return false }
        return first.isEqual(second)
    }
    // The storage an item belongs to: a Files provider's storage, an iCloud container or an app's container.
    // A move renames only inside one of these; between them it copies (a clone on the same volume) and deletes,
    // so iCloud and other providers see a new item instead of a file that left them behind their back.
    static func storageArea(_ url: URL) -> String {
        let parts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        for (index, part) in parts.enumerated() {
            if part == "File Provider Storage" { return parts[...index].joined(separator: "/") }
            if part == "Mobile Documents", index + 1 < parts.count { return parts[...(index + 1)].joined(separator: "/") }
        }
        for (index, part) in parts.enumerated() where (part == "Application" || part == "AppGroup") && index + 1 < parts.count {
            return parts[...(index + 1)].joined(separator: "/")
        }
        return ""
    }
    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
    // A folder can't be copied or moved into itself or one of its subfolders.
    static func guardNotInside(_ source: URL, _ folder: URL) throws {
        if samePath(source, folder) || isInside(folder, source) {
            throw ExplorerError("A folder can’t be copied or moved into itself.")
        }
    }
    // True when item is somewhere inside folder.
    static func isInside(_ item: URL, _ folder: URL) -> Bool {
        let inner = item.standardizedFileURL.resolvingSymlinksInPath().path
        let outer = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return inner.hasPrefix(outer.hasSuffix("/") ? outer : outer + "/")
    }
    // "photo.jpg" becomes "photo 2.jpg", then "photo 3.jpg", until the name is free.
    // A folder keeps its whole name, so "Pack.zip - extracted" becomes "Pack.zip - extracted 2".
    static func uniqueName(_ name: String, isFolder: Bool = false, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        var type = isFolder ? "" : (name as NSString).pathExtension
        if type.count > 12 || type.contains(where: { !$0.isLetter && !$0.isNumber }) { type = "" }
        let base = type.isEmpty ? name : String(name.dropLast(type.count + 1))
        var number = 2
        while true {
            let candidate = type.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(type)"
            if !taken(candidate) { return candidate }
            number += 1
        }
    }
    // Moves a finished item to its final name. An item it replaces is kept aside until the move succeeds.
    static func place(_ item: URL, at final: URL, replacing: Bool) throws {
        guard fm.fileExists(atPath: final.path) else { try fm.moveItem(at: item, to: final); return }
        guard replacing else { throw ExplorerError("“\(final.lastPathComponent)” already exists. Choose a different folder.") }
        let aside = final.deletingLastPathComponent().appendingPathComponent(".NX-old-" + UUID().uuidString)
        try fm.moveItem(at: final, to: aside)
        do { try fm.moveItem(at: item, to: final) } catch {
            try? fm.moveItem(at: aside, to: final)
            throw error
        }
        try? fm.removeItem(at: aside)
    }
    // Copies straight into a hidden folder inside the destination, then gives it its final name.
    static func copy(_ source: URL, into folder: URL, as name: String, replacing: Bool, meter: TransferMeter?) throws {
        var coordination: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], writingItemAt: folder, options: [], error: &coordination) { from, destination in
            do {
                try guardNotInside(from, destination)
                let staging = destination.appendingPathComponent(".NX-" + UUID().uuidString)
                try fm.createDirectory(at: staging, withIntermediateDirectories: false)
                defer { try? fm.removeItem(at: staging) }
                let item = staging.appendingPathComponent(try safeName(name))
                try copyTree(from, to: item, clone: sameVolume(from, destination), meter: meter)
                try place(item, at: destination.appendingPathComponent(try safeName(name)), replacing: replacing)
            } catch { failure = error }
        }
        if let coordination { throw coordination }
        if let failure { throw failure }
    }
    // A move on the same volume only renames, so it is instant.
    static func move(_ source: URL, into folder: URL, as name: String, replacing: Bool) throws {
        try guardNotInside(source, folder)
        let target = folder.appendingPathComponent(try safeName(name))
        let coordinator = NSFileCoordinator()
        var coordination: NSError?
        var failure: Error?
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: target, options: .forReplacing, error: &coordination) { from, to in
            do {
                try place(from, at: to, replacing: replacing)
                coordinator.item(at: from, didMoveTo: to)
            } catch { failure = error }
        }
        if let coordination { throw coordination }
        if let failure { throw failure }
    }
    static func remove(_ url: URL) throws {
        var coordination: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordination) { item in
            do { try fm.removeItem(at: item) } catch { failure = error }
        }
        if let coordination { throw coordination }
        if let failure { throw failure }
    }
    // Gives a finished item in a staging folder its final name in the destination.
    static func publish(_ item: URL, into folder: URL, as name: String, replacing: Bool) throws {
        try write(folder) { destination in
            try place(item, at: destination.appendingPathComponent(try safeName(name)), replacing: replacing)
        }
    }
    // Creates a hidden staging folder inside a destination, so new items never need a temporary copy.
    static func staging(in folder: URL) throws -> URL {
        try write(folder) { destination in
            let staging = destination.appendingPathComponent(".NX-" + UUID().uuidString)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            return staging
        }
    }
    struct Measure: Equatable {
        var files = 0
        var folders = 0
        var bytes: Int64 = 0
    }
    // Adds up a folder's files, subfolders and size without downloading iCloud items.
    static func measure(_ folder: URL, meter: TransferMeter? = nil) throws -> Measure {
        var result = Measure()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return result }
        for case let url as URL in walker {
            try meter?.check()
            guard let info = try? url.resourceValues(forKeys: Set(keys)), info.isSymbolicLink != true else { continue }
            if info.isDirectory == true {
                result.folders += 1
            } else {
                result.files += 1
                result.bytes += Int64(info.fileSize ?? 0)
            }
        }
        return result
    }
    static func publish(_ source: URL, into folder: URL) throws {
        try write(folder) { destination in
            let final = destination.appendingPathComponent(try safeName(source.lastPathComponent))
            guard !fm.fileExists(atPath: final.path) else { throw ExplorerError("“\(final.lastPathComponent)” already exists. Choose a different folder.") }
            let staging = destination.appendingPathComponent(".NX-" + UUID().uuidString)
            defer { try? fm.removeItem(at: staging) }
            try copyTree(source, to: staging)
            try fm.moveItem(at: staging, to: final)
        }
    }
    @discardableResult
    static func zip(_ item: URL) throws -> URL {
        try zip([item], named: item.lastPathComponent + ".zip", in: item.deletingLastPathComponent())
    }
    // One ZIP from one or more items in the same folder, written next to them.
    @discardableResult
    static func zip(_ items: [URL], named requested: String, in folder: URL) throws -> URL {
        guard !items.isEmpty else { throw ExplorerError("Select the items to put in the ZIP.") }
        var name = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Archive" }
        if (name as NSString).pathExtension.lowercased() != "zip" { name += ".zip" }
        name = try safeName(name)
        let scratch = try Files.staging(in: folder)
        defer { try? fm.removeItem(at: scratch) }
        let output = scratch.appendingPathComponent(name)
        let archive = try Archive(url: output, accessMode: .create)
        for item in items {
            // A coordinated read waits for an item still in iCloud to download.
            try read(item) { (_: URL) throws -> Void in
                let base = item.deletingLastPathComponent()
                let info = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isSymbolicLink != true else { return }
                try archive.addEntry(with: item.lastPathComponent, relativeTo: base, compressionMethod: .deflate)
                guard info.isDirectory == true,
                      let walker = fm.enumerator(at: item, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
                let root = item.resolvingSymlinksInPath().path
                for case let child as URL in walker {
                    if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
                    let full = child.resolvingSymlinksInPath().path
                    guard full.hasPrefix(root + "/") else { continue }
                    let relative = item.lastPathComponent + "/" + full.dropFirst(root.count + 1)
                    try archive.addEntry(with: relative, relativeTo: base, compressionMethod: .deflate)
                }
            }
        }
        let final = uniqueName(name) { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
        try publish(output, into: folder, as: final, replacing: false)
        return folder.appendingPathComponent(final)
    }
    static func digest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize()
    }
}

struct ScanReport {
    var groups: [[String]] = []
    var emptyFolders: [String] = []
    var skipped = 0
    var reclaimable: Int64 = 0
    static func scan(_ root: URL) throws -> ScanReport {
        var report = ScanReport()
        var sizes: [Int64: [URL]] = [:]
        func relative(_ url: URL) -> String { url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/") }
        func collect(_ directory: URL) throws {
            let contents = try Files.fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(Directory.keys))
            if contents.isEmpty && directory != root { report.emptyFolders.append(relative(directory)) }
            for url in contents {
                do {
                    let info = try url.resourceValues(forKeys: Directory.keys)
                    if info.isSymbolicLink == true { continue }
                    if info.isDirectory == true { try collect(url) }
                    else if info.isRegularFile == true, let size = info.fileSize, size > 0 { sizes[Int64(size), default: []].append(url) }
                } catch { report.skipped += 1 }
            }
        }
        try collect(root)
        for (size, candidates) in sizes where candidates.count > 1 {
            var hashes: [Data: [String]] = [:]
            for url in candidates {
                do { hashes[Data(try Files.digest(url)), default: []].append(relative(url)) }
                catch { report.skipped += 1 }
            }
            for matches in hashes.values where matches.count > 1 {
                report.groups.append(matches.sorted())
                report.reclaimable += size * Int64(matches.count - 1)
            }
        }
        report.groups.sort { $0[0] < $1[0] }
        report.emptyFolders.sort()
        return report
    }
}
