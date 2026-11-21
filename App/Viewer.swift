import SwiftUI
import QuickLook
import AVKit
import Photos
import UniformTypeIdentifiers

// Set while the viewer is open; the pane refreshes afterwards if iCloud files were downloaded.
final class ViewerOutcome {
    var downloaded = false
}

struct ViewerRequest: Identifiable {
    let id = UUID()
    // The files of the pane's list, in the order shown, so the viewer can swipe through them.
    let items: [Entry]
    let start: Int
    let source: Location
    let outcome: ViewerOutcome
}

@MainActor
final class ViewerModel: ObservableObject {
    let items: [Entry]
    let source: Location
    private let outcome: ViewerOutcome
    @Published var index: Int
    private var scratch: URL?
    private var prepared: [String: URL] = [:]

    init(_ request: ViewerRequest) {
        items = request.items
        source = request.source
        outcome = request.outcome
        index = min(max(request.start, 0), max(request.items.count - 1, 0))
    }

    var current: Entry { items[index] }
    private var isPhotos: Bool { if case .photos = source { return true }; return false }

    // The folder a file sits in on disk. Photos and archive items have none.
    func sourceFolder(for entry: Entry) -> URL? {
        switch source {
        case .photos, .archive: return nil
        default: return source.fileURL(for: entry)?.deletingLastPathComponent()
        }
    }
    func whereText(for entry: Entry) -> String {
        switch source {
        case let .photos(folder): return "Photos · " + (folder?.title ?? "All")
        case let .archive(ref, inner): return inner.isEmpty ? ref.name : ref.name + " / " + inner
        case .selectedFiles: return source.fileURL(for: entry)?.deletingLastPathComponent().lastPathComponent ?? source.title
        default: return source.title
        }
    }

    func page(_ index: Int) -> PageController {
        let entry = items[index]
        return PageController(index: index) { [weak self] in
            guard let self else { return .failure("") }
            do { return try await self.content(for: entry) }
            catch { return .failure(error.localizedDescription) }
        }
    }

    private func content(for entry: Entry) async throws -> PageContent {
        if isPhotos { return try await photoContent(entry) }
        let url = try await file(for: entry)
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audiovisualContent) {
            return .video(AVPlayerItem(url: url))
        }
        return .file(url)
    }

    // Photos show as Photos shows them: the edited version, and a Live Photo as its still image.
    private func photoContent(_ entry: Entry) async throws -> PageContent {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [entry.id], options: nil).firstObject else {
            throw ExplorerError("This photo is no longer available.")
        }
        if asset.mediaType == .video {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            let item: AVPlayerItem = try await withCheckedThrowingContinuation { continuation in
                PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, info in
                    if let item { continuation.resume(returning: item) }
                    else { continuation.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? ExplorerError("Photos could not supply this video.")) }
                }
            }
            return .video(item)
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        let image: UIImage = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 4096, height: 4096),
                                                  contentMode: .aspectFit, options: options) { image, info in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? ExplorerError("Photos could not supply this photo.")) }
            }
        }
        return .image(image)
    }

    // A local file for the item: the file on disk, unpacked from an archive, or exported from Photos.
    func file(for entry: Entry) async throws -> URL {
        if let ready = prepared[entry.id] { return ready }
        let url: URL
        switch source {
        case let .archive(ref, _):
            let folder = try workspace().appendingPathComponent(UUID().uuidString)
            url = try await Task.detached { try ArchiveTools.unpack(entry, from: ref, into: folder) }.value
        case .photos:
            let folder = try workspace().appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = try await PhotosAccess.export(entry, into: folder)
        default:
            guard let local = source.fileURL(for: entry) else { throw ExplorerError("“\(entry.name)” can’t be opened here.") }
            if entry.inCloud {
                // A coordinated read waits for iCloud to download the file.
                try await Task.detached {
                    try? Files.fm.startDownloadingUbiquitousItem(at: local)
                    try Files.read(local) { _ in }
                }.value
                outcome.downloaded = true
            }
            url = local
        }
        prepared[entry.id] = url
        return url
    }

    // What Send copies. A photo or archive file already prepared for viewing is sent from there,
    // so it isn't exported or unpacked again; the result is the same as Copy and Paste.
    func sendSource(for entry: Entry) -> (entry: Entry, from: Location) {
        switch source {
        case .photos, .archive:
            guard let ready = prepared[entry.id] else { break }
            let size = (try? ready.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
            let file = Entry(id: ready.lastPathComponent, name: ready.lastPathComponent, isFolder: false, bytes: size, date: entry.date)
            return (file, .local(ready.deletingLastPathComponent()))
        default: break
        }
        return (entry, source)
    }

    private func workspace() throws -> URL {
        if let scratch { return scratch }
        let made = try Files.workspace()
        scratch = made
        return made
    }
    func cleanup() {
        guard let scratch else { return }
        self.scratch = nil
        prepared.removeAll()
        Task.detached { try? FileManager.default.removeItem(at: scratch) }
    }
}

struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

// Full-screen viewer: swipe for the next or previous file, Info, Share, and Send to the other pane.
struct ViewerView: View {
    @StateObject private var model: ViewerModel
    @ObservedObject private var other: Pane
    private let otherLabel: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var transfers = TransferCenter()
    @State private var sent = Set<String>()
    @State private var problem: String?
    @State private var showingInfo = false
    @State private var sharing: SharedFile?
    @State private var preparingShare = false

    init(request: ViewerRequest, other: Pane, otherLabel: String) {
        _model = StateObject(wrappedValue: ViewerModel(request))
        _other = ObservedObject(wrappedValue: other)
        self.otherLabel = otherLabel
    }

    private var entry: Entry { model.current }
    private var showsSend: Bool {
        other.message == nil && SendRule.allows(other.location, sourceFolder: model.sourceFolder(for: entry))
    }

    var body: some View {
        NavigationStack {
            PagerView(count: model.items.count, index: $model.index, page: model.page)
                .navigationTitle(entry.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }.disabled(transfers.running).accessibilityIdentifier("viewer-close")
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { showingInfo = true } label: { Image(systemName: "info.circle") }
                            .accessibilityLabel("Info").accessibilityIdentifier("viewer-info")
                        Button(action: share) {
                            if preparingShare { ProgressView() } else { Image(systemName: "square.and.arrow.up") }
                        }.disabled(preparingShare).accessibilityLabel("Share").accessibilityIdentifier("viewer-share")
                    }
                }
                .safeAreaInset(edge: .bottom) { bottomBar }
        }
        .onChange(of: model.index) { _, _ in problem = nil }
        .conflictQuestion(transfers)
        .sheet(isPresented: $showingInfo) { InfoView(entry: entry, model: model) }
        .sheet(item: $sharing) { ActivityView(items: [$0.url]).presentationDetents([.medium, .large]) }
        .onDisappear { model.cleanup() }
    }

    @ViewBuilder private var bottomBar: some View {
        if showsSend || problem != nil {
            VStack(spacing: 6) {
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                if transfers.running {
                    TransferBar(center: transfers)
                } else if showsSend {
                    let done = sent.contains(entry.id)
                    Button(action: send) {
                        Label(done ? "Sent to \(otherLabel)" : "Send to \(otherLabel) · \(other.location.title)",
                              systemImage: done ? "checkmark.circle.fill" : "paperplane.fill")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(done || other.busy)
                    .accessibilityIdentifier("viewer-send")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func send() {
        guard !transfers.running else { return }
        let current = entry
        let (item, origin) = model.sendSource(for: current)
        let target = other
        problem = nil
        transfers.start([item], from: origin, to: target.location, move: false) { report in
            if report.done > 0 { sent.insert(current.id) }
            if let failure = report.failure { problem = failure }
            Task { await target.reload() }
        }
    }

    private func share() {
        let current = entry
        preparingShare = true
        problem = nil
        Task {
            defer { preparingShare = false }
            do { sharing = SharedFile(url: try await model.file(for: current)) }
            catch { problem = error.localizedDescription }
        }
    }
}

// Pages are made only for the item shown and its neighbours.
struct PagerView: UIViewControllerRepresentable {
    let count: Int
    @Binding var index: Int
    let page: @MainActor (Int) -> PageController

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                         options: [.interPageSpacing: 16])
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.setViewControllers([page(index)], direction: .forward, animated: false)
        return pager
    }
    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PagerView
        init(_ parent: PagerView) { self.parent = parent }
        func pageViewController(_ pager: UIPageViewController, viewControllerBefore controller: UIViewController) -> UIViewController? {
            guard let current = controller as? PageController, current.index > 0 else { return nil }
            return parent.page(current.index - 1)
        }
        func pageViewController(_ pager: UIPageViewController, viewControllerAfter controller: UIViewController) -> UIViewController? {
            guard let current = controller as? PageController, current.index + 1 < parent.count else { return nil }
            return parent.page(current.index + 1)
        }
        func pageViewController(_ pager: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let current = pager.viewControllers?.first as? PageController else { return }
            parent.index = current.index
        }
    }
}

enum PageContent {
    case file(URL)
    case image(UIImage)
    case video(AVPlayerItem)
    case failure(String)
}

final class PageController: UIViewController {
    let index: Int
    private let load: () async -> PageContent
    private var task: Task<Void, Never>?
    private var player: AVPlayer?
    private var previewSource: QuickLookSource?
    private let spinner = UIActivityIndicatorView(style: .large)

    init(index: Int, load: @escaping () async -> PageContent) {
        self.index = index
        self.load = load
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        spinner.startAnimating()
        let load = self.load
        task = Task { [weak self] in
            let content = await load()
            guard let self, !Task.isCancelled else { return }
            self.spinner.removeFromSuperview()
            self.show(content)
        }
    }
    deinit { task?.cancel() }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        player?.pause()
    }

    private func show(_ content: PageContent) {
        switch content {
        case let .file(url):
            let source = QuickLookSource(url: url)
            previewSource = source
            let preview = QLPreviewController()
            preview.dataSource = source
            embed(preview)
        case let .image(image):
            embed(ZoomImageController(image: image))
        case let .video(item):
            let controller = AVPlayerViewController()
            let player = AVPlayer(playerItem: item)
            controller.player = player
            self.player = player
            embed(controller)
        case let .failure(message):
            let label = UILabel()
            label.text = message.isEmpty ? "This item can’t be shown." : message
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                                         label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
                                         label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)])
        }
    }
    private func embed(_ child: UIViewController) {
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }
}

final class QuickLookSource: NSObject, QLPreviewControllerDataSource {
    let url: URL
    init(url: URL) { self.url = url }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
}

// A photo that fits the screen, zooms with two fingers and double-tap, and pages when not zoomed.
final class ZoomImageController: UIViewController, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let imageView: UIImageView
    private var laidOutSize = CGSize.zero

    init(image: UIImage) {
        imageView = UIImageView(image: image)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.decelerationRate = .fast
        imageView.contentMode = .scaleAspectFit
        scroll.addSubview(imageView)
        view.addSubview(scroll)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scroll.bounds.size != laidOutSize else { return }
        laidOutSize = scroll.bounds.size
        fit()
    }
    private func fit() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0,
              laidOutSize.width > 0, laidOutSize.height > 0 else { return }
        scroll.zoomScale = 1
        let scale = min(laidOutSize.width / image.size.width, laidOutSize.height / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        scroll.contentSize = fitted
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = max(4, 1 / scale)
        center()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }
    private func center() {
        let bounds = scroll.bounds.size
        let content = scroll.contentSize
        let x = max(0, (bounds.width - content.width) / 2)
        let y = max(0, (bounds.height - content.height) / 2)
        scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }
    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if scroll.zoomScale > 1 {
            scroll.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                   width: size.width, height: size.height), animated: true)
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
