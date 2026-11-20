import Foundation
import FileProvider

// The On My iPhone and iCloud Drive lists that both panes share. Files returns only
// the top-level folder of each location, and every app folder shown inside it is a
// separate grant, so the list combines the saved top level with the app folders the
// user added once.
@MainActor
final class Places: ObservableObject {
    static let shared = Places()
    nonisolated static let storeKey = "places.v1"

    struct Saved {
        let id: String
        var name: String
        var bookmark: Data
        var grant: FolderGrant? = nil
    }

    struct AddResult {
        var added = 0, already = 0, failed = 0
        var roots: [Place] = []
    }

    @Published private(set) var revision = 0
    private var roots: [Place: Saved] = [:]
    private var folders: [Place: [Saved]] = [:]

    private init() { load() }

    func root(_ place: Place) -> FolderGrant? { roots[place]?.grant }
    func hasRoot(_ place: Place) -> Bool { root(place) != nil }
    func hasFolders(_ place: Place) -> Bool { !(folders[place] ?? []).isEmpty }

    @discardableResult
    func setRoot(_ url: URL) throws -> Place? {
        guard let place = Place.root(of: url) else { return nil }
        let grant = FolderGrant(url, place: place, isPlaceRoot: true)
        roots[place] = Saved(id: place.rawValue, name: place.title, bookmark: try grant.bookmark(), grant: grant)
        save()
        return place
    }

    func add(_ urls: [URL], to place: Place) async -> AddResult {
        var result = AddResult()
        for url in urls {
            if Place.root(of: url) != nil {
                if let root = try? setRoot(url) { result.roots.append(root) } else { result.failed += 1 }
                continue
            }
            let path = url.standardizedFileURL.path
            if (folders[place] ?? []).contains(where: { $0.grant?.url.standardizedFileURL.path == path }) {
                result.already += 1
                continue
            }
            let grant = FolderGrant(url, place: place, isPlaceRoot: false)
            guard let bookmark = try? grant.bookmark() else { result.failed += 1; continue }
            grant.title = await Self.displayName(for: url)
            folders[place, default: []].append(Saved(id: UUID().uuidString, name: grant.title ?? url.lastPathComponent, bookmark: bookmark, grant: grant))
            result.added += 1
        }
        save()
        return result
    }

    func rename(_ row: Entry, in place: Place, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = folders[place]?.firstIndex(where: { "saved:" + $0.id == row.id }) else { return }
        folders[place]?[index].name = name
        folders[place]?[index].grant?.title = name
        save()
    }

    func remove(_ row: Entry, from place: Place) {
        folders[place]?.removeAll { "saved:" + $0.id == row.id }
        save()
    }

    func entries(for place: Place) async throws -> [Entry] {
        var rows: [Entry] = []
        if let grant = root(place) {
            let top = grant.url
            let children = try await Task.detached {
                try withExtendedLifetime(grant) { try Files.read(top) { try Directory.localEntries($0) } }
            }.value
            rows += children.map { child in
                let url = top.appendingPathComponent(child.name)
                return Entry(id: url.path, name: child.name, isFolder: child.isFolder, bytes: child.bytes, date: child.date,
                             url: url, inCloud: child.inCloud, placeRole: .rootItem)
            }
        }
        for saved in folders[place] ?? [] {
            let available = saved.grant != nil
            rows.append(Entry(id: "saved:" + saved.id, name: saved.name, isFolder: true, bytes: nil, date: nil, url: saved.grant?.url,
                              note: available ? nil : "Can't be opened. Long-press to remove it.",
                              placeRole: available ? .savedFolder : .unavailable))
        }
        if place == .onMyIPhone {
            rows.append(Entry(id: Location.documents.path, name: Self.appName, isFolder: true, bytes: nil, date: nil,
                              url: Location.documents, note: "This app", placeRole: .thisApp))
        }
        return rows
    }

    func location(for row: Entry, in place: Place) -> Location? {
        guard let url = row.url else { return nil }
        switch row.placeRole {
        case .rootItem?:
            return root(place).map { Location.folder($0, url) }
        case .savedFolder?:
            return folders[place]?.first { "saved:" + $0.id == row.id }?.grant.map { Location.folder($0, $0.url) }
        case .thisApp?:
            let grant = FolderGrant(url, place: place, isPlaceRoot: false)
            return .folder(grant, url)
        default:
            return nil
        }
    }

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Newexplorer"
    }

    // App folders come back as their "Documents" folder, so look for the name Files shows.
    static func displayName(for url: URL) async -> String {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.localizedNameKey, .ubiquitousItemContainerDisplayNameKey])
        if name == "Documents", let container = values?.ubiquitousItemContainerDisplayName, !container.isEmpty { return container }
        if let localized = values?.localizedName, !localized.isEmpty, localized != name { return localized }
        if name == "Documents", let identifier = await providerItemIdentifier(for: url), identifier.hasPrefix("#") {
            return readableName(bundleID: String(identifier.dropFirst()))
        }
        return name
    }

    // On My iPhone identifies an app's folder as "#" followed by the app's bundle ID.
    private static func providerItemIdentifier(for url: URL) async -> String? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { item, _, _ in once.resume(item?.rawValue) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { once.resume(nil) }
        }
    }

    nonisolated static func readableName(bundleID: String) -> String {
        let generic: Set<String> = ["ios", "iphone", "ipad", "app", "mobile", "client"]
        let parts = bundleID.split(separator: ".").map(String.init)
        guard var name = parts.last(where: { !generic.contains($0.lowercased()) }) ?? parts.last else { return bundleID }
        if name == name.lowercased(), let first = name.first { name = first.uppercased() + name.dropFirst() }
        return name
    }

    private func load() {
        let store = UserDefaults.standard.dictionary(forKey: Self.storeKey) ?? [:]
        for place in Place.allCases {
            let entry = store[place.rawValue] as? [String: Any] ?? [:]
            if let data = entry["root"] as? Data {
                roots[place] = Self.restored(Saved(id: place.rawValue, name: place.title, bookmark: data), place: place, isRoot: true)
            }
            folders[place] = (entry["folders"] as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String, let name = item["name"] as? String, let data = item["bookmark"] as? Data else { return nil }
                return Self.restored(Saved(id: id, name: name, bookmark: data), place: place, isRoot: false)
            }
        }
        persist()
    }

    private static func restored(_ saved: Saved, place: Place, isRoot: Bool) -> Saved {
        var saved = saved
        guard let restored = try? FolderGrant.restore(saved.bookmark, place: place, isPlaceRoot: isRoot) else { return saved }
        if !isRoot { restored.0.title = saved.name }
        saved.grant = restored.0
        if restored.stale, let fresh = try? restored.0.bookmark() { saved.bookmark = fresh }
        return saved
    }

    private func save() {
        persist()
        revision += 1
    }

    private func persist() {
        var store: [String: Any] = [:]
        for place in Place.allCases {
            var entry: [String: Any] = [:]
            if let root = roots[place] { entry["root"] = root.bookmark }
            entry["folders"] = (folders[place] ?? []).map { ["id": $0.id, "name": $0.name, "bookmark": $0.bookmark] as [String: Any] }
            store[place.rawValue] = entry
        }
        UserDefaults.standard.set(store, forKey: Self.storeKey)
    }
}

// Resumes a continuation once, whichever of the answer or the timeout comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
    func resume(_ value: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
