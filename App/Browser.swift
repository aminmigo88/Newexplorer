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
    init(_ location: Location) { self.location = location }
    func open(_ next: Location) async {
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
        } catch { if generation == ticket { message = error.localizedDescription } }
    }
}

@main
struct NewexplorerApp: App {
    var body: some Scene { WindowGroup { ExplorerView() } }
}

struct ExplorerView: View {
    private static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    @StateObject private var first = Pane(.local(ExplorerView.documents))
    @StateObject private var second = Pane(.local(ExplorerView.documents))
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
        .task { await first.refresh(); await second.refresh() }
        .alert("Newexplorer", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: { Text(notice ?? "") }
        .sheet(isPresented: $showingReport) { if let report { ReportView(report: report) } }
    }

    private func pane(_ model: Pane, label: String) -> some View {
        PaneView(pane: model, label: label, canPaste: shelf != nil,
                 copy: {
                     shelf = Shelf(from: model.location, items: model.rows.filter { model.marked.contains($0.id) })
                     transferStatus = nil
                 }, paste: { transfer(into: model) }, scan: { scan(model) }, archive: { archive($0, extract: $1, pane: model) })
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
    @ObservedObject var pane: Pane
    let label: String
    let canPaste: Bool
    let copy, paste, scan: () -> Void
    let archive: (Entry, Bool) -> Void
    @State private var picking = false
    @State private var connecting = false
    @State private var preview: URL?
    @State private var showHidden = false

    private var local: Bool { if case .folder = pane.location { return true }; return false }
    private var visible: [Entry] { showHidden ? pane.rows : pane.rows.filter { !$0.name.hasPrefix(".") } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).bold().foregroundStyle(.teal).accessibilityLabel("Pane \(label)")
                Menu {
                    Button("My files", systemImage: "iphone") {
                        Task { await pane.open(.local(Files.fm.urls(for: .documentDirectory, in: .userDomainMask)[0])) }
                    }
                    Button("Choose folder…", systemImage: "folder") { picking = true }
                    Button("Photos", systemImage: "photo") { Task { await pane.open(.photos) } }
                    Button("Windows share…", systemImage: "network") { connecting = true }
                } label: {
                    Label(pane.location.title, systemImage: pane.location.symbol).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }.accessibilityLabel("Pane \(label) location")
                Spacer()
                Button {
                    if let parent = pane.location.parent { Task { await pane.open(parent) } }
                } label: { Image(systemName: "arrow.up") }.disabled(pane.location.parent == nil).accessibilityLabel("Parent folder")
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await pane.refresh() } }
                    Toggle("Show hidden files", isOn: $showHidden)
                        .onChange(of: showHidden) { _, value in if !value { pane.marked.formIntersection(visible.map(\.id)) } }
                    if local { Button("Find duplicates and empty folders", systemImage: "magnifyingglass") { scan() } }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Pane options")
            }.padding(10)
            Divider()
            if pane.busy { Spacer(); ProgressView(); Spacer() }
            else if let message = pane.message {
                ScrollView { Text(message).font(.callout).padding() }.frame(maxWidth: .infinity)
            } else {
                List {
                    if visible.isEmpty { Text("No items to show").foregroundStyle(.secondary) }
                    ForEach(visible) { row in
                        HStack {
                            Button { toggle(row.id) } label: {
                                Image(systemName: pane.marked.contains(row.id) ? "checkmark.circle.fill" : "circle")
                            }.accessibilityLabel("Select \(row.name)").buttonStyle(.borderless)
                            Button {
                                if row.isFolder { Task { await pane.open(pane.location.subdirectory(row.name)) } }
                                else if case let .folder(_, url) = pane.location { preview = url.appendingPathComponent(row.name) }
                                else { toggle(row.id) }
                            } label: {
                                HStack {
                                    if row.isPhoto { PhotoThumbnail(id: row.id) }
                                    else { Image(systemName: row.isFolder ? "folder.fill" : "doc").foregroundStyle(row.isFolder ? Color.teal : .secondary) }
                                    VStack(alignment: .leading) {
                                        Text(row.name).foregroundStyle(.primary).lineLimit(2)
                                        if let date = row.date, row.isPhoto { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                                        else if let size = row.bytes, !row.isFolder { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    if row.isFolder { Image(systemName: "chevron.right").font(.caption) }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }.contextMenu {
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
                Button { paste() } label: { Label("Paste here", systemImage: "doc.on.clipboard") }.disabled(!canPaste || pane.busy || pane.message != nil)
            }.font(.subheadline.weight(.semibold)).padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .padding(.horizontal, 6)
        .quickLookPreview($preview)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url): let grant = FolderGrant(url); Task { await pane.open(.folder(grant, url)) }
            case let .failure(error): if (error as NSError).code != NSUserCancelledError { pane.message = error.localizedDescription }
            }
        }
        .sheet(isPresented: $connecting) { ConnectionView { server in Task { await pane.open(.share(server, "/")) } } }
    }
    private func toggle(_ id: String) {
        if !pane.marked.insert(id).inserted { pane.marked.remove(id) }
    }
}
