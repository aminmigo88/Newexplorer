import SwiftUI

// One part of a pane's address, such as "On My iPhone", "Downloads" or "Photos". Tapping it opens its target.
struct Crumb: Identifiable {
    let id: Int
    let title: String
    let target: Location?
}

extension Location {
    // The full path of what the pane shows: On My iPhone/Downloads/Documents, MSI/shared/Movies, Photos/Others.
    @MainActor var crumbs: [Crumb] {
        var parts: [(String, Location?)] = []
        switch self {
        case let .folder(grant, url):
            parts = Self.folderParts(grant, url)
        case let .place(place):
            parts = [(place.title, .place(place))]
        case let .share(server, path):
            parts = [(server.displayName, nil), (server.name, .share(server, "/"))]
            var current = "/"
            for name in path.split(separator: "/").map(String.init) {
                current = server.child(current, name)
                parts.append((name, .share(server, current)))
            }
        case let .photos(folder):
            parts = [("Photos", .photos(nil))]
            if let folder { parts.append((folder.title, .photos(folder))) }
        case .selectedFiles:
            parts = [("Selected files", nil)]
        case let .archive(ref, inner):
            parts = ref.parent.crumbs.map { ($0.title, $0.target) }
            parts.append((ref.name, .archive(ref, "")))
            var current = ""
            for name in inner.split(separator: "/").map(String.init) {
                current = current.isEmpty ? name : current + "/" + name
                parts.append((name, .archive(ref, current)))
            }
        }
        return parts.enumerated().map { Crumb(id: $0.offset, title: $0.element.0, target: $0.element.1) }
    }
    @MainActor var addressText: String { crumbs.map(\.title).joined(separator: "/") }

    @MainActor private static func folderParts(_ grant: FolderGrant, _ url: URL) -> [(String, Location?)] {
        var parts: [(String, Location?)]
        if Files.samePath(grant.url, Location.documents) {
            // Newexplorer's own folder, where Files shows it.
            let place = grant.place ?? .onMyIPhone
            parts = [(place.title, .place(place)), (Places.appName, .folder(grant, grant.url))]
        } else if let place = grant.place {
            parts = [(place.title, .place(place))]
            if !grant.isPlaceRoot { parts.append((grant.title ?? grant.url.lastPathComponent, .folder(grant, grant.url))) }
        } else {
            parts = pickedFolderParts(grant)
        }
        var current = grant.url
        for name in PaneSpot.path(from: grant.url, to: url) ?? [] {
            current = current.appendingPathComponent(name)
            parts.append((name, .folder(grant, current)))
        }
        return parts
    }

    // A folder opened with "Open a folder in this pane" shows its path from On My iPhone or iCloud Drive.
    @MainActor private static func pickedFolderParts(_ grant: FolderGrant) -> [(String, Location?)] {
        let name = grant.title ?? grant.url.lastPathComponent
        for place in Place.allCases {
            guard let root = Places.shared.root(place), Files.isInside(grant.url, root.url),
                  let names = PaneSpot.path(from: root.url, to: grant.url) else { continue }
            var parts: [(String, Location?)] = [(place.title, Location.place(place))]
            var current = root.url
            for folder in names.dropLast() {
                current = current.appendingPathComponent(folder)
                parts.append((folder, Location.folder(root, current)))
            }
            parts.append((name, Location.folder(grant, grant.url)))
            return parts
        }
        var parts: [(String, Location?)] = []
        let path = grant.url.standardizedFileURL.path
        if let range = path.range(of: "/Mobile Documents/com~apple~CloudDocs/") {
            parts.append((Place.iCloudDrive.title, Location.place(.iCloudDrive)))
            for folder in path[range.upperBound...].split(separator: "/").map(String.init).dropLast() {
                parts.append((folder, nil))
            }
        }
        parts.append((name, Location.folder(grant, grant.url)))
        return parts
    }
}

// The pane's address: tap a part to go back to it. The current folder is in bold at the end.
struct AddressBar: View {
    let crumbs: [Crumb]
    let open: (Location) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(crumbs) { crumb in
                        if crumb.id > 0 { Text("/").foregroundStyle(.tertiary) }
                        if crumb.id == crumbs.count - 1 {
                            Text(crumb.title).fontWeight(.semibold).lineLimit(1)
                        } else if let target = crumb.target {
                            Button(crumb.title) { open(target) }.lineLimit(1).buttonStyle(.borderless)
                        } else {
                            Text(crumb.title).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Color.clear.frame(width: 1, height: 1).id("end")
                }
            }
            .onAppear { proxy.scrollTo("end", anchor: .trailing) }
            .onChange(of: crumbs.map(\.title)) { _, _ in proxy.scrollTo("end", anchor: .trailing) }
        }
        .font(.subheadline)
    }
}

// Tab mode: Chrome-style tabs along the bottom, one for each pane.
struct PaneTabs: View {
    @ObservedObject var first: Pane
    @ObservedObject var second: Pane
    @Binding var active: Int

    var body: some View {
        HStack(spacing: 6) {
            tab(first, index: 0)
            tab(second, index: 1)
        }
        .padding(.horizontal, 10)
    }
    private func tab(_ pane: Pane, index: Int) -> some View {
        let selected = active == index
        return Button { active = index } label: {
            HStack(spacing: 6) {
                Image(systemName: pane.location.symbol)
                Text(pane.location.crumbs.last?.title ?? pane.location.title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.footnote.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(selected ? AnyShapeStyle(.background) : AnyShapeStyle(.quaternary),
                        in: UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
            .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).stroke(selected ? Color.teal : .clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
        .accessibilityLabel("Tab " + pane.location.addressText)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("tab-\(index)")
    }
}
