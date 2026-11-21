import Foundation

struct Shelf {
    let from: Location
    let items: [Entry]
}

enum Transfer {
    static func copy(_ entry: Entry, from origin: Location, to destination: Location) async throws {
        let temporary = try Files.workspace()
        defer { try? Files.fm.removeItem(at: temporary) }
        let prepared = try await prepare(entry, from: origin, in: temporary)
        try await deliver(prepared, to: destination)
    }

    // Stages the item in a temporary folder before it is published anywhere.
    static func prepare(_ entry: Entry, from origin: Location, in temporary: URL) async throws -> URL {
        let item = temporary.appendingPathComponent(try safeName(entry.name))
        let prepared: URL
        switch origin {
        case .folder, .selectedFiles, .place:
            guard let url = origin.fileURL(for: entry) else { throw ExplorerError("Select this file again in Files.") }
            let inCloud = entry.inCloud
            try await Task.detached {
                try withExtendedLifetime(origin) {
                    // A coordinated read waits for iCloud to download the item.
                    if inCloud { try? Files.fm.startDownloadingUbiquitousItem(at: url) }
                    try Files.read(url) { try Files.copyTree($0, to: item) }
                }
            }.value
            prepared = item
        case let .share(server, path):
            try await download(entry, server: server, from: path, to: item)
            prepared = item
        case .photos:
            guard !entry.isFolder else { throw ExplorerError("Open the Photos folder and select the items to copy.") }
            prepared = try await PhotosAccess.export(entry, into: temporary)
        case let .archive(ref, _):
            prepared = try await Task.detached { try ArchiveTools.unpack(entry, from: ref, into: temporary) }.value
        }
        return prepared
    }

    // Publishes a staged item under its final name in the destination.
    static func deliver(_ prepared: URL, to destination: Location) async throws {
        switch destination {
        case .selectedFiles: throw ExplorerError("Choose a destination folder before pasting.")
        case let .folder(grant, folder):
            try await Task.detached { try withExtendedLifetime(grant) { try Files.publish(prepared, into: folder) } }.value
        case let .place(place):
            guard let root = await Places.shared.root(place) else { throw ExplorerError("Open the top of \(place.title) before pasting there.") }
            try await Task.detached { try withExtendedLifetime(root) { try Files.publish(prepared, into: root.url) } }.value
        case let .share(server, path):
            let name = try windowsName(prepared.lastPathComponent)
            let final = server.child(path, name)
            let staging = server.child(path, ".NX-" + UUID().uuidString)
            if try await server.entries(path).contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw ExplorerError("“\(name)” already exists on the share.")
            }
            do {
                try await upload(prepared, server: server, path: staging)
                try await server.client.moveItem(atPath: staging, toPath: final)
            } catch {
                try? await server.client.removeItem(atPath: staging)
                throw error
            }
        case let .photos(folder):
            try await PhotosAccess.importFile(prepared, into: folder)
        case .archive:
            throw ExplorerError("Archives are read-only. Paste into a folder instead.")
        }
    }

    static func windowsName(_ name: String) throws -> String {
        _ = try safeName(name)
        let reserved = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        guard name.rangeOfCharacter(from: CharacterSet(charactersIn: ":*?\"<>|").union(.controlCharacters)) == nil,
              !name.hasSuffix("."), !name.hasSuffix(" "), !reserved.contains(String(name.prefix(while: { $0 != "." })).uppercased()) else {
            throw ExplorerError("Windows cannot store the name “\(name)”.")
        }
        return name
    }
    private static func download(_ entry: Entry, server: Share, from parent: String, to output: URL) async throws {
        let path = server.child(parent, try safeName(entry.name))
        if entry.isFolder {
            try Files.fm.createDirectory(at: output, withIntermediateDirectories: false)
            for child in try await server.entries(path) {
                try await download(child, server: server, from: path, to: output.appendingPathComponent(child.name))
            }
        } else {
            guard !Files.fm.fileExists(atPath: output.path) else { throw ExplorerError("Two filenames would collide locally.") }
            try await server.client.downloadItem(atPath: path, to: output, progress: nil)
            if let expected = entry.bytes, Int64(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1) != expected {
                throw ExplorerError("The remote file changed size during the transfer.")
            }
        }
    }
    private static func upload(_ url: URL, server: Share, path: String) async throws {
        let info = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if info.isDirectory == true {
            try await server.client.createDirectory(atPath: path)
            for child in try Files.fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try await upload(child, server: server, path: server.child(path, try windowsName(child.lastPathComponent)))
            }
        } else {
            try await server.client.uploadItem(at: url, toPath: path, progress: nil)
            let attrs = try await server.client.attributesOfItem(atPath: path)
            guard let count = attrs[.fileSizeKey] as? NSNumber, count.int64Value == Int64(info.fileSize ?? -1) else {
                throw ExplorerError("The uploaded file size could not be verified.")
            }
        }
    }
}
