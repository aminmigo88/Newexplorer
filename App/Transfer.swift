import Foundation

struct Shelf {
    let id = UUID()
    let from: Location
    let items: [Entry]
    var move = false
    // The folders of items picked from a search inside subfolders.
    var homes: [String: Location] = [:]

    // The items a failed, cancelled or stopped paste didn't finish; nil when none are left.
    func remaining(after finished: Int) -> Shelf? {
        guard finished > 0 else { return self }
        let rest = Array(items.dropFirst(finished))
        guard !rest.isEmpty else { return nil }
        let ids = Set(rest.map(\.id))
        return Shelf(from: from, items: rest, move: move, homes: homes.filter { ids.contains($0.key) })
    }
}

enum ConflictChoice { case replace, keepBoth, skip, stop }

// Thrown when the person chooses Stop in the name conflict question.
struct TransferStopped: Error {}

// Shared with a running transfer: bytes finished so far and the Cancel flag.
final class TransferMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Int64 = 0
    private var stopped = false
    func add(_ bytes: Int64) { lock.lock(); done += bytes; lock.unlock() }
    var bytes: Int64 { lock.lock(); defer { lock.unlock() }; return done }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func check() throws { if isCancelled { throw CancellationError() } }
}

// Turns the running total a transfer callback reports into the bytes added since the last call.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64 = 0
    func delta(to total: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let delta = max(total - last, 0)
        last = max(total, last)
        return delta
    }
}

struct TransferHooks {
    var meter = TransferMeter()
    // Asked when the name already exists. Without it the copy fails, as a single Paste did before.
    var resolve: (@MainActor (String) async -> ConflictChoice)?
}

enum Transfer {
    // Copies one item and fails if its name already exists in the destination.
    static func copy(_ entry: Entry, from origin: Location, to destination: Location) async throws {
        try await run(entry, from: origin, to: destination, move: false, hooks: TransferHooks())
    }

    // Copies or moves one item. Returns false when it was skipped.
    @discardableResult
    static func run(_ entry: Entry, from origin: Location, to destination: Location, move: Bool, hooks: TransferHooks) async throws -> Bool {
        if move, !canMove(from: origin) {
            throw ExplorerError("Items in Photos, archives and picked files can only be copied.")
        }
        if move, case .place = origin, (entry.placeRole ?? .rootItem) != .rootItem {
            throw ExplorerError("App folders can only be copied, not moved.")
        }
        try hooks.meter.check()
        switch destination {
        case .selectedFiles: throw ExplorerError("Choose a destination folder before pasting.")
        case .archive: throw ExplorerError("Archives are read-only. Paste into a folder instead.")
        case let .folder(grant, folder):
            return try await toDisk(entry, from: origin, folder: folder, keep: grant, move: move, hooks: hooks)
        case let .place(place):
            guard let root = await Places.shared.root(place) else { throw ExplorerError("Open the top of \(place.title) before pasting there.") }
            return try await toDisk(entry, from: origin, folder: root.url, keep: root, move: move, hooks: hooks)
        case let .share(server, path):
            return try await toShare(entry, from: origin, server: server, path: path, move: move, hooks: hooks)
        case let .photos(folder):
            try await toPhotos(entry, from: origin, folder: folder, move: move, hooks: hooks)
            return true
        }
    }

    static func canMove(from origin: Location) -> Bool {
        switch origin {
        case .folder, .place, .share: return true
        case .photos, .archive, .selectedFiles: return false
        }
    }

    // Stages the item in a temporary folder; used where the destination needs a local file first.
    static func prepare(_ entry: Entry, from origin: Location, in temporary: URL, meter: TransferMeter? = nil) async throws -> URL {
        try await produce(entry, from: origin, into: temporary, as: try await finalName(entry, from: origin), meter: meter ?? TransferMeter())
    }

    // A local file for sharing: the file itself when it is on disk, otherwise a temporary copy.
    static func localFile(_ entry: Entry, from origin: Location) async throws -> (url: URL, temporary: URL?) {
        if let source = diskSource(entry, origin) {
            if entry.inCloud { try await download(source, keep: origin) }
            return (source, nil)
        }
        let temporary = try Files.workspace()
        do { return (try await prepare(entry, from: origin, in: temporary), temporary) }
        catch { try? Files.fm.removeItem(at: temporary); throw error }
    }

    // Bytes a transfer will move, when every item's size is known.
    static func plannedBytes(_ items: [Entry], from origin: Location) async -> Int64? {
        var total: Int64 = 0
        for item in items {
            if !item.isFolder {
                guard let bytes = item.bytes else { return nil }
                total += bytes
                continue
            }
            switch origin {
            case .folder, .place:
                guard let url = origin.fileURL(for: item),
                      let size = try? await Task.detached(operation: { try withExtendedLifetime(origin) { try Files.measure(url) } }).value
                else { return nil }
                total += size.bytes
            case let .archive(ref, _):
                guard let items = try? await Task.detached(operation: { try ref.items() }).value else { return nil }
                total += items.filter { !$0.isFolder && $0.path.hasPrefix(item.id + "/") }.reduce(0) { $0 + $1.size }
            default:
                return nil
            }
        }
        return total
    }

    // MARK: Destinations

    private static func toDisk(_ entry: Entry, from origin: Location, folder: URL, keep: AnyObject, move: Bool, hooks: TransferHooks) async throws -> Bool {
        defer { withExtendedLifetime(keep) {} }
        let wanted = try await finalName(entry, from: origin)
        let source = diskSource(entry, origin)
        if let source {
            try Files.guardNotInside(source, folder)
            // Moving an item into the folder it is already in changes nothing.
            if move, Files.samePath(source.deletingLastPathComponent(), folder) { return false }
        }
        var name = wanted
        var replacing = false
        if Files.fm.fileExists(atPath: folder.appendingPathComponent(wanted).path) {
            switch try await ask(hooks, wanted) {
            case .replace: replacing = true
            case .keepBoth: name = Files.uniqueName(wanted, isFolder: entry.isFolder) { Files.fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
            case .skip: return false
            case .stop: throw TransferStopped()
            }
        }
        if replacing, let source {
            let target = folder.appendingPathComponent(name)
            // Replacing an item with itself changes nothing; replacing a folder that holds the item would lose it.
            if Files.samePath(source, target) { return false }
            if Files.isInside(source, target) { throw ExplorerError("“\(name)” can’t be replaced by an item that is inside it.") }
        }
        let meter = hooks.meter
        if let source {
            let inCloud = entry.inCloud
            let fast = move && Files.sameVolume(source, folder) && Files.storageArea(source) == Files.storageArea(folder)
            let size = entry.bytes ?? 0
            try await Task.detached {
                try withExtendedLifetime(origin) {
                    if inCloud { try? Files.fm.startDownloadingUbiquitousItem(at: source) }
                    if fast {
                        try Files.move(source, into: folder, as: name, replacing: replacing)
                        meter.add(size)
                    } else {
                        try Files.copy(source, into: folder, as: name, replacing: replacing, meter: meter)
                        if move { try Files.remove(source) }
                    }
                }
            }.value
            return true
        }
        // Photos, archive and share items are written straight into a hidden folder in the destination.
        let staging = try Files.staging(in: folder)
        defer { try? Files.fm.removeItem(at: staging) }
        let produced = try await produce(entry, from: origin, into: staging, as: name, meter: meter)
        try await Task.detached { try Files.publish(produced, into: folder, as: name, replacing: replacing) }.value
        if move { try await removeSource(entry, origin) }
        return true
    }

    private static func toShare(_ entry: Entry, from origin: Location, server: Share, path: String, move: Bool, hooks: TransferHooks) async throws -> Bool {
        let wanted = try windowsName(try await finalName(entry, from: origin))
        // The item's path when it is on this same computer and shared folder, even through the other pane's connection.
        var item: String?
        if case let .share(source, sourcePath) = origin, await Share.samePlace(source, server) {
            let here = server.child(sourcePath, try safeName(entry.name))
            if move {
                // Moving an item into the folder it is already in changes nothing.
                if Share.samePath(sourcePath, path) { return false }
                if Share.samePath(path, here) || Share.isInside(path, here) {
                    throw ExplorerError("A folder can’t be moved into itself.")
                }
            }
            item = here
        }
        let existing = try await server.entries(path).map(\.name)
        func taken(_ name: String) -> Bool { existing.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        var name = wanted
        var replacing = false
        if taken(wanted) {
            switch try await ask(hooks, wanted) {
            case .replace: replacing = true
            case .keepBoth: name = Files.uniqueName(wanted, isFolder: entry.isFolder, taken: taken)
            case .skip: return false
            case .stop: throw TransferStopped()
            }
        }
        let final = server.child(path, name)
        if replacing, let item {
            // Replacing an item with itself changes nothing; replacing a folder that holds the item would lose it.
            if Share.samePath(item, final) { return false }
            if Share.isInside(item, final) { throw ExplorerError("“\(name)” can’t be replaced by an item that is inside it.") }
        }
        // On the same share a move is a rename on the computer: no download and upload.
        let remote = SMBDirectory(server: server, path: path)
        let folder = ShareFolder(server, path)
        if move, let item {
            try await ShareRecovery.shared.perform(in: folder, remote: remote, name: name, upload: false,
                                                   replacing: replacing, prepare: { _ in try hooks.meter.check() }) { _ in
                try await server.client.moveItem(atPath: item, toPath: final)
            }
            hooks.meter.add(entry.bytes ?? 0)
            return true
        }
        // Files on disk upload directly; other items get a temporary local copy first.
        let temporary = try Files.workspace()
        defer { try? Files.fm.removeItem(at: temporary) }
        let local: URL
        if let source = diskSource(entry, origin) {
            if entry.inCloud { try await download(source, keep: origin) }
            local = source
        } else {
            local = try await produce(entry, from: origin, into: temporary, as: name, meter: hooks.meter)
        }
        try await ShareRecovery.shared.perform(in: folder, remote: remote, name: name, upload: true, replacing: replacing) { stage in
            try await withExtendedLifetimeAsync(origin) {
                try await upload(local, server: server, path: server.child(path, stage), meter: hooks.meter)
            }
            try hooks.meter.check()
        } publish: { stage in
            try await remote.rename(stage, to: name)
        }
        if move { try await removeSource(entry, origin) }
        return true
    }

    private static func toPhotos(_ entry: Entry, from origin: Location, folder: PhotoFolder?, move: Bool, hooks: TransferHooks) async throws {
        guard !entry.isFolder else { throw ExplorerError("Choose a single image or video to import into Photos.") }
        // Photos imports from the app's own temporary folder; on the same volume that copy is a clone.
        let temporary = try Files.workspace()
        defer { try? Files.fm.removeItem(at: temporary) }
        let local = try await produce(entry, from: origin, into: temporary, as: try await finalName(entry, from: origin), meter: hooks.meter)
        try await PhotosAccess.importFile(local, into: folder)
        if move { try await removeSource(entry, origin) }
    }

    // MARK: Sources

    private static func diskSource(_ entry: Entry, _ origin: Location) -> URL? {
        switch origin {
        case .folder, .selectedFiles, .place: return origin.fileURL(for: entry)
        default: return nil
        }
    }

    private static func finalName(_ entry: Entry, from origin: Location) async throws -> String {
        if case .photos = origin { return try PhotosAccess.exportFileName(entry) }
        return try safeName(entry.name)
    }

    // Writes the item into a local folder under the given name.
    private static func produce(_ entry: Entry, from origin: Location, into folder: URL, as name: String, meter: TransferMeter) async throws -> URL {
        let output = folder.appendingPathComponent(try safeName(name))
        switch origin {
        case .folder, .selectedFiles, .place:
            guard let url = origin.fileURL(for: entry) else { throw ExplorerError("Select this file again in Files.") }
            let inCloud = entry.inCloud
            try await Task.detached {
                try withExtendedLifetime(origin) {
                    // A coordinated read waits for iCloud to download the item.
                    if inCloud { try? Files.fm.startDownloadingUbiquitousItem(at: url) }
                    try Files.read(url) { try Files.copyTree($0, to: output, clone: Files.sameVolume($0, folder), meter: meter) }
                }
            }.value
            return output
        case let .share(server, path):
            try await download(entry, server: server, from: path, to: output, meter: meter)
            return output
        case .photos:
            guard !entry.isFolder else { throw ExplorerError("Open the Photos folder and select the items to copy.") }
            let exported = try await PhotosAccess.export(entry, into: folder)
            meter.add(Int64((try? exported.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
            return try rename(exported, to: output)
        case let .archive(ref, _):
            let unpacked = try await Task.detached { try ArchiveTools.unpack(entry, from: ref, into: folder, meter: meter) }.value
            return try rename(unpacked, to: output)
        }
    }

    private static func rename(_ item: URL, to target: URL) throws -> URL {
        if item.lastPathComponent == target.lastPathComponent { return item }
        try Files.fm.moveItem(at: item, to: target)
        return target
    }

    private static func removeSource(_ entry: Entry, _ origin: Location) async throws {
        switch origin {
        case let .share(server, path):
            try await server.client.removeItem(atPath: server.child(path, try safeName(entry.name)))
        default:
            guard let source = diskSource(entry, origin) else { return }
            try await Task.detached { try withExtendedLifetime(origin) { try Files.remove(source) } }.value
        }
    }

    private static func download(_ url: URL, keep: Location) async throws {
        try await Task.detached {
            try withExtendedLifetime(keep) {
                try? Files.fm.startDownloadingUbiquitousItem(at: url)
                try Files.read(url) { _ in }
            }
        }.value
    }

    private static func ask(_ hooks: TransferHooks, _ name: String) async throws -> ConflictChoice {
        guard let resolve = hooks.resolve else { throw ExplorerError("“\(name)” already exists. Choose a different folder.") }
        return await resolve(name)
    }

    private static func withExtendedLifetimeAsync<T>(_ value: T, _ body: () async throws -> Void) async throws {
        try await body()
        withExtendedLifetime(value) {}
    }

    // MARK: Windows shares

    static func windowsName(_ name: String) throws -> String {
        _ = try safeName(name)
        let reserved = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        guard name.rangeOfCharacter(from: CharacterSet(charactersIn: ":*?\"<>|").union(.controlCharacters)) == nil,
              !name.hasSuffix("."), !name.hasSuffix(" "), !reserved.contains(String(name.prefix(while: { $0 != "." })).uppercased()) else {
            throw ExplorerError("Windows cannot store the name “\(name)”.")
        }
        return name
    }
    static func download(_ entry: Entry, server: Share, from parent: String, to output: URL, meter: TransferMeter) async throws {
        try meter.check()
        let path = server.child(parent, try safeName(entry.name))
        if entry.isFolder {
            try Files.fm.createDirectory(at: output, withIntermediateDirectories: false)
            for child in try await server.entries(path) {
                try await download(child, server: server, from: path, to: output.appendingPathComponent(child.name), meter: meter)
            }
        } else {
            guard !Files.fm.fileExists(atPath: output.path) else { throw ExplorerError("Two filenames would collide locally.") }
            let counter = ByteCounter()
            do {
                try await server.client.downloadItem(atPath: path, to: output, progress: { bytes, _ in
                    meter.add(counter.delta(to: bytes))
                    return !meter.isCancelled
                })
            } catch {
                if meter.isCancelled { throw CancellationError() }
                throw error
            }
            try meter.check()
            if let expected = entry.bytes, Int64(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1) != expected {
                throw ExplorerError("The remote file changed size during the transfer.")
            }
        }
    }
    private static func upload(_ url: URL, server: Share, path: String, meter: TransferMeter) async throws {
        try meter.check()
        let info = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if info.isDirectory == true {
            try await server.client.createDirectory(atPath: path)
            for child in try Files.fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try await upload(child, server: server, path: server.child(path, try windowsName(child.lastPathComponent)), meter: meter)
            }
        } else {
            let counter = ByteCounter()
            do {
                try await server.client.uploadItem(at: url, toPath: path, progress: { bytes in
                    meter.add(counter.delta(to: bytes))
                    return !meter.isCancelled
                })
            } catch {
                if meter.isCancelled { throw CancellationError() }
                throw error
            }
            try meter.check()
            let attrs = try await server.client.attributesOfItem(atPath: path)
            guard let count = attrs[.fileSizeKey] as? NSNumber, count.int64Value == Int64(info.fileSize ?? -1) else {
                throw ExplorerError("The uploaded file size could not be verified.")
            }
        }
    }
}
