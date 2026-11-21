import Foundation

// Where a pane was, saved so it reopens in the same folder after a relaunch.
struct PaneSpot: Codable, Equatable {
    enum Kind: String, Codable {
        // App files, the pane's own Files folder, On My iPhone or iCloud Drive itself, a folder in their
        // top level, an added app folder, Newexplorer's folder listed there, Photos, a remembered Windows share.
        case appFiles, folder, place, placeRoot, placeFolder, placeApp, photos, share
    }
    var kind: Kind
    var place: String? = nil
    var id: String? = nil
    var name: String? = nil
    var path: [String] = []

    // The folder names from base down to url, or nil when url isn't inside base.
    static func path(from base: URL, to url: URL) -> [String]? {
        let top = base.standardizedFileURL.pathComponents
        let inner = url.standardizedFileURL.pathComponents
        guard inner.count >= top.count, Array(inner.prefix(top.count)) == top else { return nil }
        return Array(inner.dropFirst(top.count))
    }
    // Goes down the saved path as far as the folders still exist.
    static func descend(_ base: URL, _ path: [String]) -> URL {
        var url = base
        for name in path {
            guard (try? safeName(name)) != nil else { break }
            let next = url.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard Files.fm.fileExists(atPath: next.path, isDirectory: &isFolder), isFolder.boolValue else { break }
            url = next
        }
        return url
    }
}

// What a dragged row carries: the pane it came from and the rows' ids.
enum DragPayload {
    static let prefix = "newexplorer-drag:"
    static func text(pane: String, ids: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: ["pane": pane, "ids": ids]),
              let json = String(data: data, encoding: .utf8) else { return prefix }
        return prefix + json
    }
    static func read(_ text: String) -> (pane: String, ids: [String])? {
        guard text.hasPrefix(prefix), let data = String(text.dropFirst(prefix.count)).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pane = object["pane"] as? String, let ids = object["ids"] as? [String], !ids.isEmpty else { return nil }
        return (pane, ids)
    }
}

// Files another app hands over with Open in or Copy to. iOS puts its own copy in Documents/Inbox,
// which is removed once the file is saved elsewhere; a file opened from Files is used in place.
enum Incoming {
    static var inbox: URL { Location.documents.appendingPathComponent("Inbox") }
    static func isInbox(_ url: URL) -> Bool { Files.isInside(url, inbox) }
    static func entry(for url: URL) -> Entry {
        let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        return Entry(id: url.absoluteString, name: url.lastPathComponent, isFolder: info?.isDirectory == true,
                     bytes: info?.fileSize.map { Int64($0) }, date: info?.contentModificationDate)
    }
    static func discard(_ urls: [URL]) {
        for url in urls where isInbox(url) { try? Files.fm.removeItem(at: url) }
    }
}
