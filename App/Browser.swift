import SwiftUI
import UniformTypeIdentifiers
import QuickLook
import Photos

@MainActor
final class Pane: ObservableObject {
    @Published var location: Location
    @Published var rows: [Entry] = [] { didSet { resort() } }
    @Published var query = "" {
        didSet {
            refilter()
            // A search covers the whole Photos folder, not only the photos loaded so far.
            if !query.isEmpty, case .photos(.some) = location, !photosComplete { Task { await loadAllPhotos() } }
        }
    }
    @Published var showHidden = false {
        didSet {
            refilter()
            if !showHidden { marked.formIntersection(shown.map(\.id)) }
        }
    }
    // The rows as shown: sorted once when the rows or the order change, filtered when the search changes.
    @Published private(set) var shown: [Entry] = []
    private var sorted: [Entry] = []
    @Published var marked = Set<String>()
    @Published var busy = false
    @Published var message: String?
    @Published var photoLimit = 150
    @Published var loadingMore = false
    // True when every photo of the open Photos folder is in the list.
    @Published private(set) var photosComplete = true
    private var generation = UUID()
    private let savedFolderKey: String
    private var restoreKey: String { savedFolderKey + ".active" }
    @Published private(set) var savedFolderName: String?
    @Published var bookmarkWarning: String?
    @Published var info: String?
    @Published var selecting = false
    // Photos keep their own order, newest first unless changed.
    @Published private(set) var fileSort: ListOrder
    @Published private(set) var photoSort: ListOrder
    private var placeKey: String { savedFolderKey + ".place" }
    init(label: String) {
        location = .appFiles
        savedFolderKey = "savedFolder." + label
        let defaults = UserDefaults.standard
        savedFolderName = defaults.string(forKey: savedFolderKey + ".name")
        fileSort = ListOrder(stored: defaults.string(forKey: savedFolderKey + ".sort"), fallback: ListOrder(key: .name))
        photoSort = ListOrder(stored: defaults.string(forKey: savedFolderKey + ".photoSort"), fallback: ListOrder(key: .date))
    }
    var isPhotos: Bool { if case .photos = location { return true }; return false }
    var isPhotosTop: Bool { if case .photos(nil) = location { return true }; return false }
    private func resort() {
        sorted = isPhotosTop ? rows : sortOrder.sorted(rows)
        refilter()
    }
    private func refilter() {
        shown = sorted.filter {
            (showHidden || !$0.name.hasPrefix(".")) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }
    var sortOrder: ListOrder { isPhotos ? photoSort : fileSort }
    // iOS gives no sizes for photos, so the Photos list offers the other keys.
    var sortKeys: [SortKey] { isPhotos ? [.name, .date, .kind] : SortKey.allCases }
    // Choosing the current key again reverses the order.
    func sort(by key: SortKey) {
        let current = sortOrder
        let next = ListOrder(key: key, reversed: key == current.key ? !current.reversed : false)
        if isPhotos {
            photoSort = next
            UserDefaults.standard.set(next.stored, forKey: savedFolderKey + ".photoSort")
            // Photos are listed in pages, so a new order is fetched from Photos itself.
            if case .photos(.some) = location { Task { await refresh() } }
        } else {
            fileSort = next
            UserDefaults.standard.set(next.stored, forKey: savedFolderKey + ".sort")
        }
        resort()
    }
    func setSelecting(_ on: Bool) {
        selecting = on
        if !on { marked.removeAll() }
    }
    func start() async {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: placeKey), let place = Place(rawValue: raw) { await open(.place(place)) }
        else if defaults.bool(forKey: restoreKey) { await reopenFolder() }
        else { await refresh() }
    }
    func reopenFolder() async {
        let defaults = UserDefaults.standard
        do {
            guard let data = defaults.data(forKey: savedFolderKey) else { throw ExplorerError("Select the folder in Files again.") }
            let (grant, stale) = try FolderGrant.restore(data)
            await useFolder(grant, saveBookmark: stale)
        } catch {
            defaults.set(false, forKey: restoreKey)
            message = "Choose the saved folder again in Files. \(error.localizedDescription)"
        }
    }
    func useFolder(_ grant: FolderGrant, saveBookmark: Bool) async {
        // The top of On My iPhone or iCloud Drive opens as the combined list.
        if Place.root(of: grant.url) != nil {
            do {
                if let place = try Places.shared.setRoot(grant.url) { await open(.place(place)) }
            } catch {
                message = "Couldn’t keep access to \(grant.url.lastPathComponent). \(error.localizedDescription)"
            }
            return
        }
        await open(.folder(grant, grant.url))
        guard case let .folder(current, _) = location, current === grant, message == nil else { return }
        let defaults = UserDefaults.standard
        if saveBookmark {
            do {
                defaults.set(try grant.bookmark(), forKey: savedFolderKey)
                savedFolderName = grant.url.lastPathComponent
                defaults.set(savedFolderName, forKey: savedFolderKey + ".name")
            } catch {
                bookmarkWarning = "Folder opened for this session. Files could not save a shortcut."
                return
            }
        }
        defaults.set(true, forKey: restoreKey)
    }
    func addToPlace(_ place: Place, _ urls: [URL]) async {
        let result = await Places.shared.add(urls, to: place)
        await open(.place(place))
        var parts: [String] = []
        if result.added > 0 { parts.append(result.added == 1 ? "Added 1 folder." : "Added \(result.added) folders.") }
        for root in result.roots { parts.append("\(root.title) top level saved.") }
        if result.already > 0 { parts.append(result.already == 1 ? "1 was already in the list." : "\(result.already) were already in the list.") }
        if result.failed > 0 { parts.append("\(result.failed) couldn’t be saved. Add again.") }
        info = parts.isEmpty ? nil : parts.joined(separator: " ")
    }
    func open(_ next: Location) async {
        let defaults = UserDefaults.standard
        if case let .folder(old, _) = location.base, case let .folder(new, _) = next.base, old === new {
            // Navigating inside a connected folder, or into an archive there, keeps its saved root.
        } else {
            defaults.set(false, forKey: restoreKey)
        }
        // A pane left in On My iPhone or iCloud Drive reopens it on launch.
        switch next.base {
        case let .place(place): defaults.set(place.rawValue, forKey: placeKey)
        case let .folder(grant, _) where grant.place != nil: break
        default: defaults.removeObject(forKey: placeKey)
        }
        bookmarkWarning = nil
        info = nil
        query = ""
        location = next
        photoLimit = 150
        photosComplete = true
        await refresh()
    }
    // Adds the next photos below the ones shown, so the list keeps its place.
    func loadMorePhotos() async { await loadPhotos(limit: photoLimit == .max ? nil : photoLimit + 150) }
    // Searching needs the whole folder, so the rest of it is loaded in the background.
    func loadAllPhotos() async { await loadPhotos(limit: nil) }
    private func loadPhotos(limit: Int?) async {
        guard case let .photos(folder?) = location, !loadingMore, !busy, !photosComplete else { return }
        loadingMore = true
        defer { loadingMore = false }
        let ticket = generation
        do {
            let result = try await PhotosAccess.list(folder, limit: limit, oldestFirst: photoSort.key == .date && photoSort.reversed)
            guard generation == ticket else { return }
            // Int.max marks a folder loaded in full, so a reload keeps all of it.
            photoLimit = limit ?? .max
            photosComplete = limit == nil || result.count < photoLimit
            rows = result
        } catch {
            if generation == ticket { info = "Couldn’t load more photos. \(error.localizedDescription)" }
        }
    }
    // Lists the location. Photos come in date order from Photos itself; sorting by name or kind needs them all.
    private func fetch() async throws -> [Entry] {
        guard case let .photos(folder) = location else { return try await Directory.list(location) }
        guard let folder else { return try await PhotosAccess.folders() }
        let order = photoSort
        let limit = order.key != .date || photoLimit == .max ? nil : photoLimit
        let result = try await PhotosAccess.list(folder, limit: limit, oldestFirst: order.key == .date && order.reversed)
        photosComplete = limit == nil || result.count < photoLimit
        return result
    }
    // Reloads in place after a change, keeping the list's position and the selection that still exists.
    func reload() async {
        guard !busy else { return }
        let ticket = generation
        do {
            let result = try await fetch()
            guard generation == ticket else { return }
            message = nil
            rows = result
            marked.formIntersection(result.map(\.id))
            if case .photos(nil) = location { countPhotoFolders(ticket) }
        } catch {
            if generation == ticket { message = "Couldn’t open \(location.title). \(error.localizedDescription)" }
        }
    }
    // Pictures and Others need a look at every image, so their counts arrive after the list.
    private func countPhotoFolders(_ ticket: UUID) {
        Task {
            let counts = await PhotosAccess.splitCounts()
            guard generation == ticket, case .photos(nil) = location else { return }
            rows = rows.map { row in
                var row = row
                if row.id == PhotoFolder.pictures.id { row.note = PhotosAccess.itemCount(counts.pictures) }
                if row.id == PhotoFolder.others.id { row.note = PhotosAccess.itemCount(counts.others) }
                return row
            }
        }
    }
    func refresh() async {
        let ticket = UUID()
        generation = ticket
        busy = true
        rows = []
        marked.removeAll()
        message = nil
        defer { if generation == ticket { busy = false } }
        do {
            let result = try await fetch()
            if generation == ticket { rows = result }
            if case .photos(nil) = location, generation == ticket { countPhotoFolders(ticket) }
        } catch {
            if generation == ticket { message = "Couldn’t open \(location.title). \(error.localizedDescription)" }
        }
    }
}

@main
struct NewexplorerApp: App {
    var body: some Scene { WindowGroup { ExplorerView() } }
}

struct ExplorerView: View {
    @StateObject private var first = Pane(label: "A")
    @StateObject private var second = Pane(label: "B")
    @StateObject private var transfers = TransferCenter()
    @State private var picker: FilesPickerRequest?
    @State private var shelf: Shelf?
    @State private var transferStatus: String?
    @State private var notice: String?
    @State private var report: ScanReport?
    @State private var showingReport = false
    @State private var working = false

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "rectangle.split.2x1.fill").foregroundStyle(.teal)
                    Text("Newexplorer").font(.title2.bold())
                    Spacer()
                    if working { ProgressView() }
                    Menu {
                        Text("Version " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                        Button("Clear temporary transfer files") {
                            working = true
                            Task {
                                defer { working = false }
                                do { try await FileActions.clearTemporaryFiles(); notice = "Temporary transfer files cleared." }
                                catch { notice = error.localizedDescription }
                            }
                        }.disabled(transfers.running)
                    } label: { Image(systemName: "gearshape") }.disabled(working)
                }.padding(.horizontal, 16)
                let layout = geo.size.width > geo.size.height ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
                layout {
                    pane(first, label: "A")
                    pane(second, label: "B")
                }.disabled(working)
                if transfers.running { TransferBar(center: transfers) }
                else if let status = transferStatus {
                    HStack {
                        Text(status)
                        Spacer()
                        Button("OK") { transferStatus = nil }
                    }.font(.footnote).padding(.horizontal, 16)
                }
                else if let shelf {
                    HStack {
                        Label("\(shelf.items.count) selected for \(shelf.move ? "moving" : "copying")",
                              systemImage: shelf.move ? "scissors" : "doc.on.clipboard")
                        Spacer()
                        Button("Clear") { self.shelf = nil }
                    }.font(.footnote).padding(.horizontal, 16)
                }
            }.padding(.vertical, 6)
        }
        .tint(.teal)
        .task { async let a: Void = first.start(); async let b: Void = second.start(); _ = await (a, b) }
        .sheet(item: $picker) { request in
            FilesPicker(mode: request.mode) { urls in
                picker = nil
                guard let url = urls.first else { return }
                switch request.mode {
                case .folder:
                    let grant = FolderGrant(url)
                    Task { await request.pane.useFolder(grant, saveBookmark: true) }
                case .files:
                    var seen = Set<URL>()
                    let grants = urls.filter { seen.insert($0).inserted }.map(FolderGrant.init)
                    Task { await request.pane.open(.selectedFiles(grants)) }
                case let .placeRoot(place), let .placeFolders(place):
                    Task { await request.pane.addToPlace(place, urls) }
                }
            }
        }
        .conflictQuestion(transfers)
        .alert("Newexplorer", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: { Text(notice ?? "") }
        .sheet(isPresented: $showingReport) { if let report { ReportView(report: report) } }
    }

    private func pane(_ model: Pane, label: String) -> some View {
        let other = model === first ? second : first
        return PaneView(pane: model, other: other, label: label, canPaste: shelf != nil && !transfers.running,
                        transferring: transfers.running,
                        pick: { picker = FilesPickerRequest(mode: $0, pane: model) },
                        copy: { move in
                            shelf = Shelf(from: model.location, items: model.rows.filter { model.marked.contains($0.id) }, move: move)
                            transferStatus = nil
                        },
                        paste: { transfer(into: model) },
                        scan: { scan(model) },
                        send: { items in send(items, from: model, to: other) },
                        archive: { archive($0, extract: $1, pane: model) },
                        compress: { compress($0, named: $1, pane: model) },
                        action: { edit($0, pane: model) })
    }

    // Reloads, in place, only the panes that show one of the changed locations.
    private func reloadPanes(showing locations: [Location]) async {
        let keys = locations.reduce(into: Set<String>()) { $0.formUnion($1.spotKeys) }
        for pane in [first, second] where !keys.isDisjoint(with: pane.location.spotKeys) { await pane.reload() }
    }
    private func summary(_ report: TransferCenter.Report, move: Bool, to destination: Location) -> String {
        var parts = ["\(move ? "Moved" : "Copied") \(report.done) to \(destination.title)"]
        if report.skipped > 0 { parts.append("skipped \(report.skipped)") }
        if report.cancelled { parts.append("cancelled") }
        if report.stopped { parts.append("stopped") }
        return parts.joined(separator: " · ")
    }
    private func transfer(into pane: Pane) {
        guard let selection = shelf, !transfers.running else { return }
        let destination = pane.location
        transferStatus = nil
        transfers.start(selection.items, from: selection.from, to: destination, move: selection.move) { report in
            if report.failure == nil && !report.cancelled && !report.stopped && shelf?.id == selection.id { shelf = nil }
            transferStatus = summary(report, move: selection.move, to: destination)
            if let failure = report.failure { notice = failure }
            Task { await reloadPanes(showing: selection.move ? [destination, selection.from] : [destination]) }
        }
    }
    private func send(_ items: [Entry], from source: Pane, to target: Pane) {
        guard !transfers.running, !items.isEmpty else { return }
        let origin = source.location, destination = target.location
        transferStatus = nil
        transfers.start(items, from: origin, to: destination, move: false) { report in
            transferStatus = summary(report, move: false, to: destination)
            if let failure = report.failure { notice = failure }
            Task { await reloadPanes(showing: [destination]) }
        }
    }
    private func edit(_ action: FileAction, pane: Pane) {
        guard !working else { return }
        working = true
        transferStatus = nil
        let location = pane.location
        Task {
            defer { working = false }
            do { if let note = try await FileActions.perform(action, at: location) { notice = note } }
            catch { notice = error.localizedDescription }
            if case .delete = action { shelf = nil }
            await reloadPanes(showing: [location])
        }
    }
    private func scan(_ pane: Pane) {
        guard case let .folder(grant, url) = pane.location, !working else { return }
        working = true
        transferStatus = "Checking \(pane.location.title)…"
        Task {
            defer { working = false; transferStatus = nil }
            do {
                report = try await Task.detached {
                    try withExtendedLifetime(grant) { try Files.read(url) { try ScanReport.scan($0) } }
                }.value
                showingReport = true
            } catch { notice = error.localizedDescription }
        }
    }
    // The folder that holds a row's file, for actions that write next to it.
    private func container(of row: Entry, in location: Location) async -> (URL, AnyObject)? {
        switch location {
        case let .folder(grant, url): return (url, grant)
        case let .place(place):
            guard row.placeRole == .rootItem, let root = await Places.shared.root(place) else { return nil }
            return (root.url, root)
        default: return nil
        }
    }
    private func archive(_ row: Entry, extract: Bool, pane: Pane) {
        guard !working else { return }
        let location = pane.location
        working = true
        transferStatus = (extract ? "Extracting " : "Compressing ") + "\(row.name)…"
        Task {
            defer { working = false; transferStatus = nil }
            guard let spot = await container(of: row, in: location) else { return }
            let (folder, keep) = spot
            do {
                try await Task.detached {
                    try withExtendedLifetime(keep) {
                        let item = folder.appendingPathComponent(row.name)
                        if extract { try ArchiveTools.extract(item) } else { try Files.zip(item) }
                    }
                }.value
                await reloadPanes(showing: [location])
            } catch { notice = error.localizedDescription }
        }
    }
    private func compress(_ rows: [Entry], named name: String, pane: Pane) {
        guard !working, let row = rows.first else { return }
        let location = pane.location
        working = true
        transferStatus = "Compressing \(rows.count) \(rows.count == 1 ? "item" : "items")…"
        Task {
            defer { working = false; transferStatus = nil }
            guard let spot = await container(of: row, in: location),
                  rows.allSatisfy({ $0.placeRole == nil || $0.placeRole == .rootItem }) else {
                notice = "Only items stored in this folder can be put in a ZIP here."
                return
            }
            let (folder, keep) = spot
            do {
                try await Task.detached {
                    try withExtendedLifetime(keep) {
                        try Files.zip(rows.map { folder.appendingPathComponent($0.name) }, named: name, in: folder)
                    }
                }.value
                pane.setSelecting(false)
                await reloadPanes(showing: [location])
            } catch { notice = error.localizedDescription }
        }
    }
}

struct PaneView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var pane: Pane
    @ObservedObject var places = Places.shared
    @ObservedObject var other: Pane
    let label: String
    let canPaste: Bool
    let transferring: Bool
    let pick: (FilesPickerMode) -> Void
    // true for Cut, false for Copy.
    let copy: (Bool) -> Void
    let paste, scan: () -> Void
    let send: ([Entry]) -> Void
    let archive: (Entry, Bool) -> Void
    let compress: ([Entry], String) -> Void
    let action: (FileAction) -> Void
    @State private var connecting = false
    @State private var viewing: ViewerRequest?
    @State private var viewerOutcome: ViewerOutcome?
    @State private var info: InfoRequest?
    @State private var sharing: SharedFile?
    @State private var shareTemporary: URL?
    @State private var zipNaming = false
    @State private var zipName = ""
    @State private var newName = ""
    @State private var renaming: Entry?
    @State private var naming = false
    @State private var deleting = false
    @State private var listNaming: Entry?
    @State private var listName = ""
    @State private var downloading: String?

    private var local: Bool { if case .folder = pane.location { return true }; return false }
    private var photoLocation: Bool { if case .photos = pane.location { return true }; return false }
    // The Photos folder list itself, before a folder is opened.
    private var photosTop: Bool { if case .photos(nil) = pane.location { return true }; return false }
    private var archiveLocation: Bool { pane.location.isArchive }
    private func selectable(_ row: Entry) -> Bool { !(photosTop && row.isFolder) }
    private var currentPlace: Place? { if case let .place(place) = pane.location { return place }; return nil }
    private var otherLabel: String { label == "A" ? "B" : "A" }
    private var selectedRows: [Entry] { pane.rows.filter { pane.marked.contains($0.id) } }
    private func open(_ location: Location) {
        Task { await pane.open(location) }
    }
    private func choose(_ mode: FilesPickerMode) {
        pane.query = ""
        pick(mode)
    }
    // The folder a row's file is in, so Send isn't offered into that same folder.
    private func sourceFolder(_ row: Entry) -> URL? {
        switch pane.location {
        case .photos, .archive, .share: return nil
        default: return pane.location.fileURL(for: row)?.deletingLastPathComponent()
        }
    }
    private func canSend(_ row: Entry) -> Bool {
        guard !transferring, selectable(row), row.placeRole != .unavailable, other.message == nil, !other.busy else { return false }
        return SendRule.allows(other.location, sourceFolder: sourceFolder(row))
    }
    // Extract and Create ZIP write next to the item, so they need a folder on disk.
    private func writesNext(to row: Entry) -> Bool {
        local || (currentPlace != nil && row.placeRole == .rootItem)
    }

    @ViewBuilder private var locationChoices: some View {
        ForEach(Place.allCases, id: \.self) { place in
            Button(place.title, systemImage: place.symbol) { open(.place(place)) }
                .accessibilityIdentifier("place-\(place.rawValue)-" + label)
        }
        Button("Open a folder in this pane", systemImage: "folder") { choose(.folder) }
            .accessibilityIdentifier("choose-folder-" + label)
        Button("Browse Files locations", systemImage: "externaldrive") { choose(.files) }
            .accessibilityIdentifier("browse-files-" + label)
        Button("Open Photos", systemImage: "photo.on.rectangle") { open(.photos(nil)) }
            .accessibilityIdentifier("open-photos-" + label)
        Button("Connect to Windows", systemImage: "network") { connecting = true }
            .accessibilityIdentifier("connect-windows-" + label)
    }

    private var settingsButton: some View {
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
    }

    @ViewBuilder private var emptyRows: some View {
        if !pane.query.isEmpty {
            Text("No matches for “\(pane.query)”.").foregroundStyle(.secondary)
            Button("Clear search") { pane.query = "" }
        } else if pane.location.isAppFiles {
            locationChoices
            if !pane.rows.isEmpty {
                Button("Show hidden files") { pane.showHidden = true }
            }
        } else if !pane.rows.isEmpty {
            Button("Show hidden files") { pane.showHidden = true }
        } else if photoLocation {
            Text("No photos or videos are available to Newexplorer.").foregroundStyle(.secondary)
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited { settingsButton }
        } else if currentPlace != nil {
            EmptyView()
        } else if local {
            Text("No files were returned for this folder. Files may show additional locations.").foregroundStyle(.secondary)
            Button("Browse Files locations", systemImage: "externaldrive") { choose(.files) }
                .accessibilityIdentifier("browse-empty-" + label)
            Button("Open another folder", systemImage: "folder") { choose(.folder) }
        } else {
            Text("This folder is empty.").foregroundStyle(.secondary)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).bold().foregroundStyle(.teal).accessibilityLabel("Pane \(label)")
                Menu {
                    Button("App files", systemImage: "iphone") { open(.appFiles) }
                    if let name = pane.savedFolderName {
                        Button("Reopen \(name)", systemImage: "bookmark") {
                            Task { await pane.reopenFolder() }
                        }
                    }
                    locationChoices
                } label: {
                    Label(pane.location.title, systemImage: pane.location.symbol).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }.accessibilityLabel("Pane \(label) location").accessibilityValue(pane.location.title)
                Spacer()
                Button { pane.setSelecting(!pane.selecting) } label: {
                    Image(systemName: pane.selecting ? "checkmark.circle.fill" : "checkmark.circle")
                }.accessibilityLabel(pane.selecting ? "Stop selecting in pane \(label)" : "Select items in pane \(label)")
                .accessibilityIdentifier("select-mode-" + label)
                Button {
                    if let parent = pane.location.parent { open(parent) }
                } label: { Image(systemName: "arrow.up") }.disabled(pane.location.parent == nil).accessibilityLabel("Parent folder")
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await pane.refresh() } }
                    Toggle("Show hidden files", isOn: $pane.showHidden)
                    if !photosTop {
                        Menu {
                            ForEach(pane.sortKeys, id: \.self) { key in
                                let order = pane.sortOrder
                                Button { pane.sort(by: key) } label: {
                                    if key == order.key { Label(key.title + " · " + key.direction(reversed: order.reversed), systemImage: "checkmark") }
                                    else { Text(key.title) }
                                }.accessibilityIdentifier("sort-\(key.rawValue)-" + label)
                            }
                        } label: { Label("Sort by", systemImage: "arrow.up.arrow.down") }
                    }
                    Button("Select visible items") { pane.selecting = true; pane.marked = Set(pane.shown.filter(selectable).map(\.id)) }
                    Button("Clear selection") { pane.marked.removeAll() }
                    if local || currentPlace != nil {
                        Button("Compress selected items…", systemImage: "archivebox") {
                            let rows = selectedRows
                            zipName = rows.count == 1 ? rows[0].name + ".zip" : "Archive.zip"
                            zipNaming = true
                        }.disabled(pane.marked.isEmpty)
                    }
                    if !photoLocation && !pane.location.isFileSelection && !archiveLocation {
                        Button("New folder", systemImage: "folder.badge.plus") {
                            renaming = nil
                            newName = ""
                            naming = true
                        }
                    }
                    Button("Delete selected…", systemImage: "trash", role: .destructive) { deleting = true }
                        .disabled(pane.marked.isEmpty || pane.location.isFileSelection || archiveLocation)
                    if local { Button("Find duplicates and empty folders", systemImage: "magnifyingglass") { scan() } }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Pane options")
            }.padding(10)
            Divider()
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search this location", text: $pane.query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !pane.query.isEmpty { Button { pane.query = "" } label: { Image(systemName: "xmark.circle.fill") } }
            }.font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6)
            if pane.busy { Spacer(); ProgressView(); Spacer() }
            else if let message = pane.message {
                List {
                    Text(message).font(.callout)
                    if photoLocation && PHPhotoLibrary.authorizationStatus(for: .readWrite) == .denied {
                        settingsButton
                    }
                    Button("Try again") { Task { await pane.refresh() } }
                    if let place = currentPlace {
                        Button("Open the top of \(place.title) again") { choose(.placeRoot(place)) }
                    } else if archiveLocation, let parent = pane.location.parent {
                        Button("Go back") { open(parent) }
                    } else if !photoLocation {
                        Button("Choose a folder again") { choose(.folder) }
                        Button("Browse Files locations") { choose(.files) }
                    }
                }.listStyle(.plain)
            } else {
                List {
                    if let warning = pane.bookmarkWarning { Text(warning).font(.footnote) }
                    if let info = pane.info { Text(info).font(.footnote) }
                    if let place = currentPlace { placeHeader(place) }
                    if pane.shown.isEmpty { emptyRows }
                    ForEach(pane.shown) { row in
                        HStack {
                            if pane.selecting && selectable(row) {
                                Button { toggle(row.id) } label: {
                                    Image(systemName: pane.marked.contains(row.id) ? "checkmark.circle.fill" : "circle")
                                }.accessibilityLabel("Select \(row.name)").buttonStyle(.borderless)
                            }
                            Button {
                                if pane.selecting && selectable(row) { toggle(row.id) } else { activate(row) }
                            } label: {
                                HStack {
                                    if row.isPhoto { PhotoThumbnail(id: row.id) }
                                    else { Image(systemName: row.isFolder ? "folder.fill" : "doc").foregroundStyle(row.isFolder ? Color.teal : .secondary) }
                                    VStack(alignment: .leading) {
                                        Text(row.name).foregroundStyle(.primary).lineLimit(2)
                                        if let note = row.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                                        else if let date = row.date, row.isPhoto { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                                        else if let size = row.bytes, !row.isFolder { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    if downloading == row.id { ProgressView() }
                                    else if row.inCloud { Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary).accessibilityLabel("Not downloaded") }
                                    if row.isFolder { Image(systemName: "chevron.right").font(.caption) }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("item-" + label + "-" + row.name)
                        }.contextMenu {
                            if canSend(row) {
                                Button("Send to \(otherLabel) · \(other.location.title)", systemImage: "paperplane") { send([row]) }
                            }
                            if !row.isFolder && selectable(row) && row.placeRole != .unavailable {
                                Button("Share", systemImage: "square.and.arrow.up") { share(row) }
                            }
                            if row.placeRole != .unavailable {
                                Button("Info", systemImage: "info.circle") { info = MediaInfo.request(for: row, in: pane.location) }
                            }
                            if let place = currentPlace, let role = row.placeRole, role != .rootItem {
                                if role == .savedFolder || role == .unavailable {
                                    Button("Rename in list", systemImage: "pencil") {
                                        listName = row.name
                                        listNaming = row
                                    }
                                    Button("Remove from list", systemImage: "minus.circle", role: .destructive) {
                                        places.remove(row, from: place)
                                    }
                                }
                            } else if !photoLocation && !pane.location.isFileSelection && !archiveLocation {
                                Button("Rename", systemImage: "pencil") {
                                    renaming = row
                                    newName = row.name
                                    naming = true
                                }
                            }
                            if !pane.location.isFileSelection && !archiveLocation && selectable(row) && (row.placeRole ?? .rootItem) == .rootItem {
                                Button("Delete…", systemImage: "trash", role: .destructive) {
                                    pane.marked = [row.id]
                                    deleting = true
                                }
                            }
                            if writesNext(to: row) {
                                if !row.isFolder && ArchiveTools.isBrowsable(row.name) {
                                    Button("Extract here", systemImage: "folder.badge.plus") { archive(row, true) }
                                }
                                Button("Create ZIP", systemImage: "archivebox") { archive(row, false) }
                            }
                        }
                    }
                    if case .photos(.some) = pane.location, !pane.photosComplete {
                        if pane.query.isEmpty {
                            Button { Task { await pane.loadMorePhotos() } } label: {
                                HStack {
                                    Text("Show more photos")
                                    if pane.loadingMore { Spacer(); ProgressView() }
                                }
                            }.disabled(pane.loadingMore).accessibilityIdentifier("show-more-" + label)
                        } else {
                            // A search covers the whole folder, so the rest of it is loaded first.
                            Button { Task { await pane.loadAllPhotos() } } label: {
                                HStack {
                                    Text(pane.loadingMore ? "Searching all photos…" : "Search all photos")
                                    if pane.loadingMore { Spacer(); ProgressView() }
                                }
                            }.disabled(pane.loadingMore).accessibilityIdentifier("search-all-" + label)
                        }
                    }
                }.listStyle(.plain)
            }
            Divider()
            HStack(spacing: 16) {
                Button { copy(false) } label: { Label(pane.marked.isEmpty ? "Copy" : "Copy \(pane.marked.count)", systemImage: "doc.on.doc") }
                    .disabled(pane.marked.isEmpty).accessibilityIdentifier("copy-" + label)
                Button { copy(true) } label: { Label("Cut", systemImage: "scissors") }
                    .disabled(pane.marked.isEmpty || !Transfer.canMove(from: pane.location)).accessibilityIdentifier("cut-" + label)
                Spacer()
                Button { paste() } label: { Label("Paste here", systemImage: "doc.on.clipboard") }
                    .disabled(!canPaste || pane.busy || pane.message != nil || pane.location.isFileSelection || archiveLocation)
                    .accessibilityIdentifier("paste-" + label)
            }.font(.subheadline.weight(.semibold)).padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .padding(.horizontal, 6)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, photoLocation, !pane.busy,
                  pane.message != nil || pane.rows.isEmpty else { return }
            Task { await pane.refresh() }
        }
        .fullScreenCover(item: $viewing, onDismiss: {
            if viewerOutcome?.downloaded == true { Task { await pane.reload() } }
            viewerOutcome = nil
        }) { request in
            ViewerView(request: request, other: other, otherLabel: otherLabel)
        }
        .sheet(item: $info) { InfoView($0) }
        .sheet(item: $sharing, onDismiss: {
            if let temporary = shareTemporary { try? Files.fm.removeItem(at: temporary) }
            shareTemporary = nil
        }) { ActivityView(items: [$0.url]).presentationDetents([.medium, .large]) }
        .alert("Compress selected items", isPresented: $zipNaming) {
            TextField("ZIP name", text: $zipName)
            Button("Cancel", role: .cancel) { }
            Button("Create ZIP") { compress(selectedRows, zipName) }
                .disabled(zipName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: { Text("One ZIP with the \(pane.marked.count) selected items is made in this folder.") }
        .alert(renaming == nil ? "New folder" : "Rename", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                if let row = renaming { action(.rename(row, newName)) }
                else { action(.createFolder(newName)) }
            }.disabled(newName.isEmpty)
        }
        .alert("Name in list", isPresented: Binding(get: { listNaming != nil }, set: { if !$0 { listNaming = nil } })) {
            TextField("Name", text: $listName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                if let row = listNaming, let place = currentPlace { places.rename(row, in: place, to: listName) }
            }.disabled(listName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onChange(of: places.revision) { _, _ in
            if currentPlace != nil { Task { await pane.reload() } }
        }
        .onChange(of: deleting) { _, shown in
            if !shown && !pane.selecting { pane.marked.removeAll() }
        }
        .confirmationDialog("Delete \(pane.marked.count) selected items?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { action(.delete(pane.rows.filter { pane.marked.contains($0.id) })) }
        } message: {
            Text(photoLocation ? "Deleting from Photos also deletes the items from iCloud Photos and synced devices. Photos controls recovery in Recently Deleted." : "Files and folders will be permanently removed from this location. Check your selection before continuing.")
        }
        .sheet(isPresented: $connecting) { ConnectionView { server in open(.share(server, "/")) } }
    }
    private func toggle(_ id: String) {
        if !pane.marked.insert(id).inserted { pane.marked.remove(id) }
    }
    private func activate(_ row: Entry) {
        if row.isFolder {
            if let place = currentPlace {
                if let next = places.location(for: row, in: place) { open(next) }
            } else if photosTop {
                if let folder = PhotoFolder(entry: row) { open(.photos(folder)) }
            } else { open(pane.location.subdirectory(row.name)) }
        } else if !photoLocation && !archiveLocation && ArchiveTools.isBrowsable(row.name), let url = pane.location.fileURL(for: row) {
            openArchive(row, at: url)
        } else if photoLocation || archiveLocation || pane.location.fileURL(for: row) != nil {
            // The viewer swipes through the files of this list in the order shown.
            let files = pane.shown.filter { !$0.isFolder }
            let outcome = ViewerOutcome()
            viewerOutcome = outcome
            viewing = ViewerRequest(items: files, start: files.firstIndex { $0.id == row.id } ?? 0, source: pane.location, outcome: outcome)
        } else {
            // Files that can't be previewed here, such as on a Windows share, are selected instead.
            pane.selecting = true
            toggle(row.id)
        }
    }

    @ViewBuilder private func placeHeader(_ place: Place) -> some View {
        if !places.hasRoot(place) {
            Button("Open the top of \(place.title)", systemImage: place.symbol) { choose(.placeRoot(place)) }
                .accessibilityIdentifier("place-root-" + label)
        }
        Button("Add app folders", systemImage: "folder.badge.plus") { choose(.placeFolders(place)) }
            .accessibilityIdentifier("place-add-" + label)
        if !places.hasFolders(place) {
            Text("Each app’s folder is kept separate by iOS. Add the ones you want once; you can pick several together.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // Shares the file itself, or a temporary copy for Photos, archive and Windows share items.
    private func share(_ row: Entry) {
        guard downloading == nil else { return }
        let location = pane.location
        downloading = row.id
        Task {
            defer { downloading = nil }
            do {
                let (url, temporary) = try await Transfer.localFile(row, from: location)
                shareTemporary = temporary
                sharing = SharedFile(url: url)
            } catch {
                pane.info = "Couldn’t share \(row.name). \(error.localizedDescription)"
            }
        }
    }

    // An archive opens like a folder; one still in iCloud downloads first.
    private func openArchive(_ row: Entry, at url: URL) {
        let parent = pane.location
        guard row.inCloud else { open(.archive(ArchiveRef(url: url, parent: parent), "")); return }
        downloading = row.id
        Task {
            defer { downloading = nil }
            do {
                try await Task.detached {
                    try? Files.fm.startDownloadingUbiquitousItem(at: url)
                    try Files.read(url) { _ in }
                }.value
                open(.archive(ArchiveRef(url: url, parent: parent), ""))
            } catch {
                pane.info = "Couldn’t download \(row.name). \(error.localizedDescription)"
            }
        }
    }
}
