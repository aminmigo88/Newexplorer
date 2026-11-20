import SwiftUI
import QuickLook

struct ViewerRequest: Identifiable {
    let id = UUID()
    let entry: Entry
    let source: Location
    // Files open directly. A Photos item is exported to a temporary file first.
    let file: URL?
}

// Full-screen preview with Send, which copies the item into the other pane in one tap.
struct ViewerView: View {
    let request: ViewerRequest
    @ObservedObject var other: Pane
    let otherLabel: String
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var scratch: URL?
    @State private var failure: String?
    @State private var sending = false
    @State private var sent = false
    @State private var sendError: String?

    private var isPhoto: Bool { if case .photos = request.source { return true }; return false }
    private var sourceFolder: URL? { isPhoto ? nil : request.file?.deletingLastPathComponent() }
    private var showsSend: Bool { other.message == nil && SendRule.allows(other.location, sourceFolder: sourceFolder) }

    var body: some View {
        NavigationStack {
            Group {
                if let file { QuickLookView(url: file) }
                else if let failure {
                    ContentUnavailableView("Can’t open \(request.entry.name)", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else { ProgressView("Preparing…") }
            }
            .navigationTitle(request.entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(sending).accessibilityIdentifier("viewer-close")
                }
                if let file {
                    ToolbarItem(placement: .primaryAction) { ShareLink(item: file).labelStyle(.iconOnly) }
                }
            }
            .safeAreaInset(edge: .bottom) { if showsSend { sendBar } }
        }
        .task { await prepare() }
        .onDisappear { discardScratch() }
    }

    private var sendBar: some View {
        VStack(spacing: 6) {
            if let sendError {
                Text(sendError).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Button(action: send) {
                HStack {
                    if sending { ProgressView() }
                    Label(sent ? "Sent to \(otherLabel)" : "Send to \(otherLabel) · \(other.location.title)",
                          systemImage: sent ? "checkmark.circle.fill" : "paperplane.fill")
                        .lineLimit(1)
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(file == nil || sending || sent || other.busy)
            .accessibilityIdentifier("viewer-send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func prepare() async {
        guard file == nil, failure == nil else { return }
        if let given = request.file { file = given; return }
        do {
            let folder = try Files.workspace()
            scratch = folder
            file = try await PhotosAccess.export(request.entry, into: folder)
        } catch { failure = error.localizedDescription }
    }

    private func send() {
        guard let file, !sending, !sent else { return }
        sending = true
        sendError = nil
        let destination = other.location
        let entry = request.entry, source = request.source, photo = isPhoto
        Task {
            do {
                // A Photos item is already exported for the preview, so that file is published.
                if photo { try await Transfer.deliver(file, to: destination) }
                else { try await Transfer.copy(entry, from: source, to: destination) }
                sent = true
                sending = false
                await other.refresh()
            } catch {
                sendError = error.localizedDescription
                sending = false
            }
        }
    }

    private func discardScratch() {
        guard let scratch else { return }
        Task.detached { try? FileManager.default.removeItem(at: scratch) }
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
