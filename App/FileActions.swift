import Foundation
import Photos

enum FileAction {
    case createFolder(String)
    case rename(Entry, String)
    case delete([Entry])
}

enum FileActions {
    // Returns a note when part of the action was skipped.
    @discardableResult
    static func perform(_ action: FileAction, at location: Location) async throws -> String? {
        switch location {
        case .selectedFiles: throw ExplorerError("Open the containing folder in this pane to change its contents.")
        case let .place(place):
            guard let root = await Places.shared.root(place) else { throw ExplorerError("Open the top of \(place.title) first.") }
            let appFolders = "App folders can’t be renamed or deleted here. Long-press one to rename or remove it from the list."
            switch action {
            case .createFolder:
                break
            case let .rename(entry, _):
                guard entry.placeRole == .rootItem else { throw ExplorerError(appFolders) }
            case let .delete(entries):
                // Only items stored at the top level live in the saved folder; app folders are skipped.
                let top = entries.filter { $0.placeRole == .rootItem }
                guard !top.isEmpty else { throw ExplorerError(appFolders) }
                try await perform(.delete(top), at: .folder(root, root.url))
                let skipped = entries.count - top.count
                guard skipped > 0 else { return nil }
                return "Deleted \(top.count). Skipped \(skipped) app \(skipped == 1 ? "folder" : "folders"); long-press one to remove it from the list."
            }
            return try await perform(action, at: .folder(root, root.url))
        case let .folder(grant, folder):
            try await Task.detached {
                try withExtendedLifetime(grant) {
                    try Files.write(folder) { parent in
                        switch action {
                        case let .createFolder(name):
                            try Files.fm.createDirectory(at: parent.appendingPathComponent(try safeName(name)), withIntermediateDirectories: false)
                        case let .rename(entry, name):
                            let old = parent.appendingPathComponent(try safeName(entry.name))
                            let new = parent.appendingPathComponent(try safeName(name))
                            if old.path == new.path { return }
                            guard !Files.fm.fileExists(atPath: new.path) else { throw ExplorerError("That name already exists.") }
                            try Files.fm.moveItem(at: old, to: new)
                        case let .delete(entries):
                            for entry in entries {
                                let url = parent.appendingPathComponent(try safeName(entry.name))
                                try Files.fm.removeItem(at: url)
                            }
                        }
                    }
                }
            }.value
            return nil
        case let .share(server, path):
            switch action {
            case let .createFolder(name):
                try await server.client.createDirectory(atPath: server.child(path, try Transfer.windowsName(name)))
            case let .rename(entry, name):
                _ = try Transfer.windowsName(name)
                if entry.name == name { return nil }
                if try await server.entries(path).contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    throw ExplorerError("That name already exists.")
                }
                try await server.client.moveItem(atPath: server.child(path, entry.name), toPath: server.child(path, name))
            case let .delete(entries):
                for entry in entries { try await server.client.removeItem(atPath: server.child(path, try safeName(entry.name))) }
            }
            return nil
        case .archive:
            throw ExplorerError("Archives are read-only. Use Extract here to change their contents.")
        case .photos:
            guard case let .delete(entries) = action, entries.allSatisfy({ !$0.isFolder }) else {
                throw ExplorerError("This operation is unavailable in Photos.")
            }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: entries.map(\.id), options: nil)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            return nil
        }
    }

    static func clearTemporaryFiles() async throws {
        try await Task.detached {
            for url in try Files.fm.contentsOfDirectory(at: Files.fm.temporaryDirectory, includingPropertiesForKeys: nil) {
                guard url.lastPathComponent.hasPrefix("NX-") else { continue }
                try Files.fm.removeItem(at: url)
            }
        }.value
    }
}
