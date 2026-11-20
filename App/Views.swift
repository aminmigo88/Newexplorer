import SwiftUI
import Photos

struct ConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var share = ""
    @State private var user = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    let connected: (Share) -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("Windows file sharing") {
                    TextField("Computer name or IP address", text: $host)
                    TextField("Shared folder name", text: $share)
                }
                Section {
                    TextField("Windows username", text: $user).textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                } footer: { Text("Use the account password for the shared folder. Your Windows Hello PIN is for signing in on the laptop.") }
                if let error { Text(error).foregroundStyle(.red) }
                Button {
                    busy = true
                    error = nil
                    Task {
                        defer { busy = false }
                        do {
                            let server = try Share(host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   share: share, user: user, password: password)
                            try await server.client.connectShare(name: server.name)
                            connected(server)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                } label: { if busy { ProgressView() } else { Text("Connect") } }
                .disabled(busy || host.isEmpty || share.isEmpty || user.isEmpty)
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("Windows share")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
        }
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
