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
    static func copyTree(_ source: URL, to target: URL) throws {
        let info = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard info.isSymbolicLink != true else { throw ExplorerError("Copying symbolic links is unsupported.") }
        if info.isDirectory == true {
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyTree(item, to: target.appendingPathComponent(try safeName(item.lastPathComponent)))
            }
        } else if info.isRegularFile == true {
            try fm.copyItem(at: source, to: target)
        } else { throw ExplorerError("Unsupported file type.") }
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
    static func zip(_ item: URL) throws {
        let scratch = try workspace()
        defer { try? fm.removeItem(at: scratch) }
        let output = scratch.appendingPathComponent(item.lastPathComponent + ".zip")
        try read(item) { try fm.zipItem(at: $0, to: output, compressionMethod: .deflate) }
        try publish(output, into: item.deletingLastPathComponent())
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
