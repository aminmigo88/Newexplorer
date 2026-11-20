import SwiftUI
import UniformTypeIdentifiers
import QuickLook
import Photos

@MainActor
final class Pane: ObservableObject {
    @Published var location: Location
    @Published var rows: [Entry] = []
    @Published var marked = Set<String>()
    @Published var busy = false
    @Published var message: String?
    @Published var photoLimit = 150
    private var generation = UUID()
    private let savedFolderKey: String
    private var restoreKey: String { savedFolderKey + ".active" }
    @Published private(set) var savedFolderName: String?
    @Published var bookmarkWarning: String?
    @Published var info: String?
    private var placeKey: String { savedFolderKey + ".place" }
    init(label: String) {
        location = .appFiles
        savedFolderKey = "savedFolder." + label
        savedFolderName = UserDefaults.standard.string(forKey: savedFolderKey + ".name")
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
        if case let .folder(old, _) = location, case let .folder(new, _) = next, old === new {
            // Navigating inside a connected folder keeps its saved root.
        } else {
            defaults.set(false, forKey: restoreKey)
        }
        // A pane left in On My iPhone or iCloud Drive reopens it on launch.
        switch next {
        case let .place(place): defaults.set(place.rawValue, forKey: placeKey)
        case let .folder(grant, _) where grant.place != nil: break
        default: defaults.removeObject(forKey: placeKey)
        }
        bookmarkWarning = nil
        info = nil
        location = next
        photoLimit = 150
        await refresh()
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
            let result: [Entry]
            if case .photos = location { result = try await PhotosAccess.list(limit: photoLimit) }
            else { result = try await Directory.list(location) }
            if generation == ticket { rows = result }
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
                        }
                    } label: { Image(systemName: "gearshape") }.disabled(working)
                }.padding(.horizontal, 16)
                let layout = geo.size.width > geo.size.height ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
                layout {
                    pane(first, label: "A")
                    pane(second, label: "B")
                }.disabled(working)
                if let status = transferStatus { Text(status).font(.footnote).padding(.horizontal, 16) }
                else if let shelf {
                    HStack {
                        Label("\(shelf.items.count) selected for copying", systemImage: "doc.on.clipboard")
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
        .alert("Newexplorer", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: { Text(notice ?? "") }
        .sheet(isPresented: $showingReport) { if let report { ReportView(report: report) } }
    }

    private func pane(_ model: Pane, label: String) -> some View {
        PaneView(pane: model, label: label, canPaste: shelf != nil,
                 pick: { picker = FilesPickerRequest(mode: $0, pane: model) },
                 copy: {
                     shelf = Shelf(from: model.location, items: model.rows.filter { model.marked.contains($0.id) })
                     transferStatus = nil
                 }, paste: { transfer(into: model) }, scan: { scan(model) }, archive: { archive($0, extract: $1, pane: model) }, action: { edit($0, pane: model) })
    }
    private func edit(_ action: FileAction, pane: Pane) {
        guard !working else { return }
        working = true
        shelf = nil
        transferStatus = nil
        let location = pane.location
        Task {
            defer { working = false }
            do { try await FileActions.perform(action, at: location) }
            catch { notice = error.localizedDescription }
            await first.refresh()
            await second.refresh()
        }
    }
    private func transfer(into pane: Pane) {
        guard let selection = shelf, !working else { return }
        working = true
        let destination = pane.location
        Task {
            defer { working = false }
            var completed = 0
            do {
                for item in selection.items {
                    transferStatus = "Copying \(completed + 1) of \(selection.items.count) · \(item.name)"
                    try await Transfer.copy(item, from: selection.from, to: destination)
                    completed += 1
                }
                shelf = nil
            } catch {
                shelf = Shelf(from: selection.from, items: Array(selection.items.dropFirst(completed)))
                notice = error.localizedDescription
            }
            transferStatus = "Copied \(completed) of \(selection.items.count) to \(destination.title)"
            await first.refresh()
            await second.refresh()
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
    private func archive(_ row: Entry, extract: Bool, pane: Pane) {
        guard case let .folder(grant, url) = pane.location, !working else { return }
        working = true
        transferStatus = (extract ? "Extracting " : "Compressing ") + "\(row.name)…"
        Task {
            defer { working = false; transferStatus = nil }
            do {
                try await Task.detached {
                    try withExtendedLifetime(grant) {
                        let item = url.appendingPathComponent(row.name)
                        if extract { try ArchiveTools.extract(item) } else { try Files.zip(item) }
                    }
                }.value
                await first.refresh()
                await second.refresh()
            } catch { notice = error.localizedDescription }
        }
    }
}

struct PaneView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var pane: Pane
    @ObservedObject var places = Places.shared
    let label: String
    let canPaste: Bool
    let pick: (FilesPickerMode) -> Void
    let copy, paste, scan: () -> Void
    let archive: (Entry, Bool) -> Void
    let action: (FileAction) -> Void
    @State private var connecting = false
    @State private var preview: URL?
    @State private var showHidden = false
    @State private var query = ""
    @State private var newName = ""
    @State private var renaming: Entry?
    @State private var naming = false
    @State private var deleting = false
    @State private var dateSort = false
    @State private var listNaming: Entry?
    @State private var listName = ""
    @State private var downloading: String?

    private var local: Bool { if case .folder = pane.location { return true }; return false }
    private var photoLocation: Bool { if case .photos = pane.location { return true }; return false }
    private var currentPlace: Place? { if case let .place(place) = pane.location { return place }; return nil }
    private func open(_ location: Location) {
        query = ""
        Task { await pane.open(location) }
    }

    @ViewBuilder private var locationChoices: some View {
        ForEach(Place.allCases, id: \.self) { place in
            Button(place.title, systemImage: place.symbol) { open(.place(place)) }
                .accessibilityIdentifier("place-\(place.rawValue)-" + label)
        }
        Button("Open a folder in this pane", systemImage: "folder") { query = ""; pick(.folder) }
            .accessibilityIdentifier("choose-folder-" + label)
        Button("Browse Files locations", systemImage: "externaldrive") { query = ""; pick(.files) }
            .accessibilityIdentifier("browse-files-" + label)
        Button("Open Photos", systemImage: "photo.on.rectangle") { open(.photos) }
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
        if !query.isEmpty {
            Text("No matches for “\(query)”.").foregroundStyle(.secondary)
            Button("Clear search") { query = "" }
        } else if pane.location.isAppFiles {
            locationChoices
            if !pane.rows.isEmpty {
                Button("Show hidden files") { showHidden = true }
            }
        } else if !pane.rows.isEmpty {
            Button("Show hidden files") { showHidden = true }
        } else if photoLocation {
            Text("No photos or videos are available to Newexplorer.").foregroundStyle(.secondary)
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited { settingsButton }
        } else if currentPlace != nil {
            EmptyView()
        } else if local {
            Text("No files were returned for this folder. Files may show additional locations.").foregroundStyle(.secondary)
            Button("Browse Files locations", systemImage: "externaldrive") { query = ""; pick(.files) }
                .accessibilityIdentifier("browse-empty-" + label)
            Button("Open another folder", systemImage: "folder") { query = ""; pick(.folder) }
        } else {
            Text("This folder is empty.").foregroundStyle(.secondary)
        }
    }
    private var visible: [Entry] {
        let filtered = pane.rows.filter {
            (showHidden || !$0.name.hasPrefix(".")) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
        if dateSort { return filtered.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) } }
        return filtered
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).bold().foregroundStyle(.teal).accessibilityLabel("Pane \(label)")
                Menu {
                    Button("App files", systemImage: "iphone") { open(.appFiles) }
                    if let name = pane.savedFolderName {
                        Button("Reopen \(name)", systemImage: "bookmark") {
                            query = ""
                            Task { await pane.reopenFolder() }
                        }
                    }
                    locationChoices
                } label: {
                    Label(pane.location.title, systemImage: pane.location.symbol).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }.accessibilityLabel("Pane \(label) location").accessibilityValue(pane.location.title)
                Spacer()
                Button {
                    if let parent = pane.location.parent { open(parent) }
                } label: { Image(systemName: "arrow.up") }.disabled(pane.location.parent == nil).accessibilityLabel("Parent folder")
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await pane.refresh() } }
                    Toggle("Show hidden files", isOn: $showHidden)
                        .onChange(of: showHidden) { _, value in if !value { pane.marked.formIntersection(visible.map(\.id)) } }
                    Toggle("Newest first", isOn: $dateSort)
                    Button("Select visible items") { pane.marked = Set(visible.map(\.id)) }
                    Button("Clear selection") { pane.marked.removeAll() }
                    if !photoLocation && !pane.location.isFileSelection {
                        Button("New folder", systemImage: "folder.badge.plus") {
                            renaming = nil
                            newName = ""
                            naming = true
                        }
                    }
                    Button("Delete selected…", systemImage: "trash", role: .destructive) { deleting = true }
                        .disabled(pane.marked.isEmpty || pane.location.isFileSelection)
                    if local { Button("Find duplicates and empty folders", systemImage: "magnifyingglass") { scan() } }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Pane options")
            }.padding(10)
            Divider()
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search this location", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") } }
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
                        Button("Open the top of \(place.title) again") { query = ""; pick(.placeRoot(place)) }
                    } else if !photoLocation {
                        Button("Choose a folder again") { query = ""; pick(.folder) }
                        Button("Browse Files locations") { query = ""; pick(.files) }
                    }
                }.listStyle(.plain)
            } else {
                List {
                    if let warning = pane.bookmarkWarning { Text(warning).font(.footnote) }
                    if let info = pane.info { Text(info).font(.footnote) }
                    if let place = currentPlace { placeHeader(place) }
                    if visible.isEmpty { emptyRows }
                    ForEach(visible) { row in
                        HStack {
                            Button { toggle(row.id) } label: {
                                Image(systemName: pane.marked.contains(row.id) ? "checkmark.circle.fill" : "circle")
                            }.accessibilityLabel("Select \(row.name)").buttonStyle(.borderless)
                            Button {
                                if row.isFolder {
                                    if let place = currentPlace {
                                        if let next = places.location(for: row, in: place) { open(next) }
                                    } else { open(pane.location.subdirectory(row.name)) }
                                } else if let url = pane.location.fileURL(for: row) {
                                    if row.inCloud { download(row, then: url) } else { preview = url }
                                } else { toggle(row.id) }
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
                            } else if !photoLocation && !pane.location.isFileSelection {
                                Button("Rename", systemImage: "pencil") {
                                    renaming = row
                                    newName = row.name
                                    naming = true
                                }
                            }
                            if !pane.location.isFileSelection && (row.placeRole ?? .rootItem) == .rootItem {
                                Button("Delete…", systemImage: "trash", role: .destructive) {
                                    pane.marked = [row.id]
                                    deleting = true
                                }
                            }
                            if local {
                                if !row.isFolder && ["zip", "rar"].contains((row.name as NSString).pathExtension.lowercased()) {
                                    Button("Extract here", systemImage: "folder.badge.plus") { archive(row, true) }
                                }
                                Button("Create ZIP", systemImage: "archivebox") { archive(row, false) }
                            }
                        }
                    }
                    if case .photos = pane.location, pane.rows.count >= pane.photoLimit {
                        Button("Show more photos") { pane.photoLimit += 150; Task { await pane.refresh() } }
                    }
                }.listStyle(.plain)
            }
            Divider()
            HStack {
                Button { copy() } label: { Label(pane.marked.isEmpty ? "Copy" : "Copy \(pane.marked.count)", systemImage: "doc.on.doc") }
                    .disabled(pane.marked.isEmpty)
                Spacer()
                Button { paste() } label: { Label("Paste here", systemImage: "doc.on.clipboard") }.disabled(!canPaste || pane.busy || pane.message != nil || pane.location.isFileSelection)
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
        .quickLookPreview($preview)
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
            if currentPlace != nil { Task { await pane.refresh() } }
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

    @ViewBuilder private func placeHeader(_ place: Place) -> some View {
        if !places.hasRoot(place) {
            Button("Open the top of \(place.title)", systemImage: place.symbol) { query = ""; pick(.placeRoot(place)) }
                .accessibilityIdentifier("place-root-" + label)
        }
        Button("Add app folders", systemImage: "folder.badge.plus") { query = ""; pick(.placeFolders(place)) }
            .accessibilityIdentifier("place-add-" + label)
        if !places.hasFolders(place) {
            Text("Each app’s folder is kept separate by iOS. Add the ones you want once; you can pick several together.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // Opening an iCloud file that is not downloaded waits for the download first.
    private func download(_ row: Entry, then url: URL) {
        downloading = row.id
        Task {
            defer { downloading = nil }
            do {
                try await Task.detached {
                    try? Files.fm.startDownloadingUbiquitousItem(at: url)
                    try Files.read(url) { _ in }
                }.value
                preview = url
                await pane.refresh()
            } catch {
                pane.info = "Couldn’t download \(row.name). \(error.localizedDescription)"
            }
        }
    }
}
