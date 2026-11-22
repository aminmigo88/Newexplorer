import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

// An icon for each kind of file, shown until a thumbnail is ready and wherever there is none.
enum FileIcon {
    static func symbol(for name: String, isFolder: Bool) -> String {
        if isFolder { return "folder.fill" }
        if ArchiveTools.isBrowsable(name) { return "archivebox" }
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .audiovisualContent) && !type.conforms(to: .audio) { return "film" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .archive) { return "archivebox" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json) || type.conforms(to: .xml) {
            return "chevron.left.forwardslash.chevron.right"
        }
        if type.conforms(to: .text) || type.conforms(to: .compositeContent) { return "doc.text" }
        return "doc"
    }
    // Photos, videos and PDFs get a thumbnail; other files keep their type icon.
    static func hasThumbnail(_ name: String) -> Bool {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
            || (type.conforms(to: .audiovisualContent) && !type.conforms(to: .audio))
    }
}

// Thumbnails made once per file version and kept while the app runs.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let images = NSCache<NSString, UIImage>()
    private init() { images.countLimit = 600 }
    func image(_ key: String) -> UIImage? { images.object(forKey: key as NSString) }
    func store(_ image: UIImage, _ key: String) { images.setObject(image, forKey: key as NSString) }
}

// A QuickLook thumbnail for a photo, video or PDF on this iPhone, otherwise the icon for its type.
// Files still in iCloud keep their icon, so listing a folder never downloads them.
struct FileThumbnail: View {
    let row: Entry
    let url: URL?
    @Environment(\.displayScale) private var scale
    @State private var picture: UIImage?

    private var key: String? {
        guard false, let url, !row.isFolder, !row.inCloud, FileIcon.hasThumbnail(row.name) else { return nil }
        return url.path + "|" + String(row.date?.timeIntervalSince1970 ?? 0) + "|" + String(row.bytes ?? -1)
    }
    var body: some View {
        Group {
            if let picture { Image(uiImage: picture).resizable().scaledToFill() }
            else {
                Image(systemName: FileIcon.symbol(for: row.name, isFolder: row.isFolder))
                    .foregroundStyle(row.isFolder ? Color.teal : .secondary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: key) { await load() }
    }
    private func load() async {
        guard let key, let url else { picture = nil; return }
        if let cached = ThumbnailCache.shared.image(key) { picture = cached; return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 36, height: 36), scale: scale,
                                                   representationTypes: .thumbnail)
        guard let made = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return }
        ThumbnailCache.shared.store(made.uiImage, key)
        if !Task.isCancelled { picture = made.uiImage }
    }
}
