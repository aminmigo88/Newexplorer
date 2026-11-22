import SwiftUI
import Photos

struct ConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var saved = SavedShares.shared
    @StateObject private var finder = DeviceFinder()
    @State private var host: String
    @State private var share: String
    @State private var user: String
    @State private var password = ""
    @State private var remember = true
    @State private var error: String?
    @State private var busy = false
    @State private var listing = false
    @State private var shares: [String] = []
    @State private var picked: FoundDevice?
    let connected: (Share) -> Void

    init(prefill: SavedShare? = nil, connected: @escaping (Share) -> Void) {
        _host = State(initialValue: prefill?.host ?? "")
        _share = State(initialValue: prefill?.share ?? "")
        _user = State(initialValue: prefill?.user ?? "")
        self.connected = connected
    }

    var body: some View {
        NavigationStack {
            Form {
                if !saved.all.isEmpty {
                    Section {
                        ForEach(saved.all) { item in
                            Button { open(item) } label: {
                                Label(item.title, systemImage: "externaldrive.connected.to.line.below")
                            }.disabled(busy)
                        }
                        .onDelete { offsets in
                            for item in offsets.map({ saved.all[$0] }) { saved.forget(item) }
                        }
                    } header: { Text("Saved shares") } footer: { Text("Swipe left to forget a share and its password.") }
                }
                Section {
                    TextField("Computer name or IP address", text: $host)
                    Button { if finder.running { finder.stop() } else { finder.start() } } label: {
                        HStack {
                            Label(finder.running ? "Finding devices…" : "Find devices", systemImage: "dot.radiowaves.left.and.right")
                            if finder.running { Spacer(); ProgressView() }
                        }
                    }.accessibilityIdentifier("find-devices")
                    ForEach(finder.devices) { device in
                        Button { host = device.host; picked = device } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name ?? device.host)
                                    Text(device.name == nil ? device.kind : device.host + " · " + device.kind)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if host == device.host { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    if let note = finder.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                    TextField("Shared folder name", text: $share)
                } header: { Text("Windows file sharing") } footer: {
                    Text("Find devices looks on this Wi-Fi for Macs and NAS drives that announce file sharing, and for computers that accept it on port 445. A PC whose firewall blocks file sharing won’t appear.")
                }
                Section {
                    TextField("Windows username", text: $user).textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                    Button { listShares() } label: {
                        HStack {
                            Text("Show shared folders")
                            if listing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || listing || host.isEmpty || user.isEmpty)
                    .accessibilityIdentifier("list-shares")
                    ForEach(shares, id: \.self) { name in
                        Button { share = name } label: {
                            HStack {
                                Label(name, systemImage: "folder")
                                Spacer()
                                if share == name { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    Toggle("Remember this share", isOn: $remember)
                } footer: {
                    Text("Use the account password for the shared folder. Your Windows Hello PIN is for signing in on the laptop. A remembered password is kept in this iPhone’s Keychain.")
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button { connect() } label: { if busy { ProgressView() } else { Text("Connect") } }
                    .disabled(busy || host.isEmpty || share.isEmpty || user.isEmpty)
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("Windows share")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
        }
        .onDisappear { finder.stop() }
    }

    // A saved share connects at once when its password is in the Keychain; otherwise it fills the form.
    private func open(_ item: SavedShare) {
        guard let stored = saved.password(for: item) else {
            host = item.host
            share = item.share
            user = item.user
            password = ""
            error = "Enter the password for \(item.title)."
            return
        }
        connect(host: item.host, share: item.share, user: item.user, password: stored, remembering: false, name: item.name)
    }
    private func connect() {
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        connect(host: address, share: share.trimmingCharacters(in: .whitespacesAndNewlines),
                user: user, password: password, remembering: remember, name: picked?.host == address ? picked?.name : nil)
    }
    private func connect(host: String, share: String, user: String, password: String, remembering: Bool, name: String?) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let server = try Share(host: host, share: share, user: user, password: password)
                try await server.client.connectShare(name: server.name)
                // Addresses show the PC's name; a PC reached by IP address is asked for it.
                var known = name
                if known == nil, LocalNetwork.isAddress(host) { known = await LocalNetwork.netbiosName(host) }
                server.displayName = known ?? host
                if remembering { saved.remember(SavedShare(host: host, share: server.name, user: user, name: known), password: password) }
                finder.stop()
                connected(server)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func listShares() {
        listing = true
        error = nil
        let host = self.host.trimmingCharacters(in: .whitespacesAndNewlines), user = self.user, password = self.password
        Task {
            defer { listing = false }
            do {
                shares = try await Share.list(host: host, user: user, password: password)
                if shares.isEmpty { error = "No shared folders were found on \(host)." }
                else if shares.count == 1 { share = shares[0] }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct Receiving: Identifiable {
    let id = UUID()
    var urls: [URL]
}

struct SaveChoice: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let location: Location
}

// Asked when another app hands files to Newexplorer: where to save them.
struct SaveToView: View {
    let urls: [URL]
    let choices: [SaveChoice]
    @ObservedObject var transfers: TransferCenter
    let save: (Location) -> Void
    let cancel: () -> Void
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(urls, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: FileIcon.symbol(for: url.lastPathComponent, isFolder: url.hasDirectoryPath))
                    }
                }
                Section {
                    ForEach(choices) { choice in
                        Button { save(choice.location) } label: { Label(choice.title, systemImage: choice.symbol) }
                            .disabled(transfers.running)
                    }
                } header: { Text("Save to") } footer: {
                    if transfers.running { Text("Waiting for the current copy to finish…") }
                }
            }
            .navigationTitle(urls.count == 1 ? "Save file" : "Save \(urls.count) files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) } }
        }
        .interactiveDismissDisabled()
    }
}

struct PhotoThumbnail: View {
    let id: String
    @State private var picture: UIImage?
    @State private var request = PHInvalidImageRequestID
    var body: some View {
        Group {
            if let picture { Image(uiImage: picture).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 5))
        .onAppear {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 108, height: 108),
                                                            contentMode: .aspectFill, options: options) { image, _ in
                DispatchQueue.main.async { picture = image }
            }
        }
        .onDisappear { PHImageManager.default().cancelImageRequest(request) }
    }
}

struct ReportView: View {
    let report: ScanReport
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Identical file contents") {
                    if report.groups.isEmpty { Text("No duplicate files found.") }
                    ForEach(report.groups.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(report.groups[index].count) copies").font(.headline)
                            ForEach(report.groups[index], id: \.self) { Text($0).font(.callout) }
                        }
                    }
                }
                Section("Empty folders") {
                    if report.emptyFolders.isEmpty { Text("No empty folders found.") }
                    ForEach(report.emptyFolders, id: \.self) { Text($0) }
                }
                Section {
                    LabeledContent("Size of extra copies", value: ByteCountFormatter.string(fromByteCount: report.reclaimable, countStyle: .file))
                    if report.skipped > 0 { Text("\(report.skipped) items could not be checked.") }
                }
            }.navigationTitle("Storage review")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
