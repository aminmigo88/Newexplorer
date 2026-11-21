import SwiftUI
import Photos
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct InfoRow: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { label }
}

struct InfoSection: Identifiable {
    let title: String
    let rows: [InfoRow]
    var id: String { title }
}

// What an Info sheet shows and how to load it; cleanup runs when the sheet closes.
struct InfoRequest: Identifiable {
    let id = UUID()
    let title: String
    let load: @MainActor () async throws -> [InfoSection]
    var cleanup: (@MainActor () -> Void)? = nil
}

// File data plus EXIF for photos and duration and resolution for videos; size and contents for folders.
struct InfoView: View {
    private let title: String
    private let load: @MainActor () async throws -> [InfoSection]
    private let cleanup: (@MainActor () -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var sections: [InfoSection]?
    @State private var failure: String?

    init(entry: Entry, model: ViewerModel) {
        title = entry.name
        load = { try await MediaInfo.sections(for: entry, in: model) }
        cleanup = nil
    }
    init(_ request: InfoRequest) {
        title = request.title
        load = request.load
        cleanup = request.cleanup
    }

    var body: some View {
        NavigationStack {
            List {
                if let failure {
                    Text(failure).foregroundStyle(.secondary)
                } else if let sections {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in
                                LabeledContent(row.label) {
                                    Text(row.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                                }
                            }
                        }
                    }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("info-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            do { sections = try await load() }
            catch { failure = error.localizedDescription }
        }
        .onDisappear { cleanup?() }
    }
}

enum MediaInfo {
    @MainActor static func sections(for entry: Entry, in model: ViewerModel) async throws -> [InfoSection] {
        let place = model.whereText(for: entry)
        if case .photos = model.source { return try await photoSections(entry, place: place) }
        let url = try await model.file(for: entry)
        var sections = try await fileSections(url, place: place)
        if case .archive = model.source {
            // The unpacked copy is new, so size and date come from the archive.
            sections[0] = InfoSection(title: "File", rows: rows([
                ("Name", entry.name), ("Kind", kind(url)), ("Size", size(entry.bytes)),
                ("Modified", date(entry.date)), ("Where", place)]))
        }
        return sections
    }

    // Info for a row of a pane, opened by a long press.
    @MainActor static func request(for row: Entry, in location: Location) -> InfoRequest {
        if row.isFolder { return InfoRequest(title: row.name) { try await folderSections(row, in: location) } }
        if case .share = location { return InfoRequest(title: row.name) { entrySections(row, place: location.title) } }
        if row.inCloud { return InfoRequest(title: row.name) { entrySections(row, place: location.title, stored: "In iCloud, not downloaded") } }
        let model = ViewerModel(ViewerRequest(items: [row], start: 0, source: location, outcome: ViewerOutcome()))
        return InfoRequest(title: row.name, load: { try await sections(for: row, in: model) }, cleanup: { model.cleanup() })
    }
    // What the list already knows, for files that would have to be downloaded first.
    static func entrySections(_ row: Entry, place: String, stored: String? = nil) -> [InfoSection] {
        [InfoSection(title: "File", rows: rows([
            ("Name", row.name), ("Kind", kind(URL(fileURLWithPath: row.name))), ("Size", size(row.bytes)),
            ("Modified", date(row.date)), ("Stored", stored), ("Where", place)]))]
    }
    // Total size and item count of a folder, wherever it is.
    @MainActor static func folderSections(_ row: Entry, in location: Location) async throws -> [InfoSection] {
        var measure = Files.Measure()
        switch location {
        case let .folder(grant, url):
            let folder = url.appendingPathComponent(try safeName(row.name))
            measure = try await Task.detached { try withExtendedLifetime(grant) { try Files.measure(folder) } }.value
        case let .place(place):
            guard let target = Places.shared.location(for: row, in: place), case let .folder(grant, folder) = target else {
                throw ExplorerError("This folder can’t be opened. Add it again.")
            }
            measure = try await Task.detached { try withExtendedLifetime(grant) { try Files.measure(folder) } }.value
        case let .archive(ref, _):
            let items = try await Task.detached { try ref.items() }.value
            measure = archiveMeasure(items, under: row.id)
        case let .share(server, path):
            measure = try await shareMeasure(server, server.child(path, try safeName(row.name)))
        case .photos(nil):
            guard let folder = PhotoFolder(entry: row) else { throw ExplorerError("This folder is no longer available.") }
            let counts = try await PhotosAccess.counts(folder)
            return [InfoSection(title: "Folder", rows: rows([
                ("Name", row.name), ("Kind", "Photos folder"), ("Photos", counts.photos.formatted()),
                ("Videos", counts.videos.formatted()), ("Where", "Photos")]))]
        default:
            throw ExplorerError("Info isn’t available for this folder.")
        }
        return [InfoSection(title: "Folder", rows: rows([
            ("Name", row.name), ("Kind", "Folder"), ("Size", size(measure.bytes)),
            ("Contains", contents(measure)), ("Modified", date(row.date)), ("Where", location.title)]))]
    }
    static func contents(_ measure: Files.Measure) -> String {
        func count(_ number: Int, _ one: String, _ many: String) -> String { number.formatted() + " " + (number == 1 ? one : many) }
        return count(measure.files, "file", "files") + ", " + count(measure.folders, "folder", "folders")
    }
    // Folders in an archive also come from the paths of the files inside them.
    static func archiveMeasure(_ items: [ArchiveItem], under folder: String) -> Files.Measure {
        let prefix = folder + "/"
        var result = Files.Measure()
        var folders = Set<String>()
        for item in items where item.path.hasPrefix(prefix) {
            let parts = item.path.dropFirst(prefix.count).split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            let depth = item.isFolder ? parts.count : parts.count - 1
            if depth > 0 { for level in 1...depth { folders.insert(parts.prefix(level).joined(separator: "/")) } }
            if !item.isFolder {
                result.files += 1
                result.bytes += item.size
            }
        }
        result.folders = folders.count
        return result
    }
    static func shareMeasure(_ server: Share, _ path: String) async throws -> Files.Measure {
        var result = Files.Measure()
        var pending = [path]
        while let next = pending.popLast() {
            try Task.checkCancellation()
            for child in try await server.entries(next) {
                if child.isFolder {
                    result.folders += 1
                    pending.append(server.child(next, child.name))
                } else {
                    result.files += 1
                    result.bytes += child.bytes ?? 0
                }
            }
        }
        return result
    }

    static func fileSections(_ url: URL, place: String) async throws -> [InfoSection] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .localizedTypeDescriptionKey])
        var sections = [InfoSection(title: "File", rows: rows([
            ("Name", url.lastPathComponent),
            ("Kind", values.localizedTypeDescription ?? kind(url)),
            ("Size", size(values.fileSize.map { Int64($0) })),
            ("Created", date(values.creationDate)),
            ("Modified", date(values.contentModificationDate)),
            ("Where", place)]))]
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            sections.append(imageSection(properties))
        } else if type?.conforms(to: .audiovisualContent) == true, let media = try? await mediaSection(AVURLAsset(url: url)) {
            sections.append(media)
        }
        return sections
    }

    @MainActor static func photoSections(_ entry: Entry, place: String) async throws -> [InfoSection] {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [entry.id], options: nil).firstObject else {
            throw ExplorerError("This photo is no longer available.")
        }
        var kindText = asset.mediaType == .video ? "Video" : "Photo"
        if asset.mediaSubtypes.contains(.photoScreenshot) { kindText = "Screenshot" }
        else if asset.mediaSubtypes.contains(.photoLive) { kindText = "Live Photo" }
        if let type = UTType(filenameExtension: (entry.name as NSString).pathExtension)?.localizedDescription {
            kindText += " · " + type
        }
        var bytes: Int64?
        var media: InfoSection?
        if asset.mediaType == .video {
            let video = try await videoAsset(asset)
            if let url = (video as? AVURLAsset)?.url, let length = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                bytes = Int64(length)
            }
            media = try? await mediaSection(video)
        } else {
            let data = try await imageData(asset)
            bytes = Int64(data.count)
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                media = imageSection(properties)
            }
        }
        // Photos keeps a location even when the file itself has none.
        if let coordinate = asset.location?.coordinate, let section = media, !section.rows.contains(where: { $0.label == "Location" }) {
            media = InfoSection(title: section.title,
                                rows: section.rows + [InfoRow(label: "Location", value: coordinates(coordinate.latitude, coordinate.longitude))])
        }
        var sections = [InfoSection(title: "File", rows: rows([
            ("Name", entry.name), ("Kind", kindText), ("Size", size(bytes)),
            ("Created", date(asset.creationDate)), ("Modified", date(asset.modificationDate)), ("Where", place)]))]
        if let media { sections.append(media) }
        return sections
    }

    private static func imageData(_ asset: PHAsset) async throws -> Data {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? ExplorerError("Photos could not supply this photo.")) }
            }
        }
    }
    private static func videoAsset(_ asset: PHAsset) async throws -> AVAsset {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { video, _, info in
                if let video { continuation.resume(returning: video) }
                else { continuation.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? ExplorerError("Photos could not supply this video.")) }
            }
        }
    }

    static func imageSection(_ properties: [CFString: Any]) -> InfoSection {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        var location: String?
        if let latitude = number(gps[kCGImagePropertyGPSLatitude]), let longitude = number(gps[kCGImagePropertyGPSLongitude]) {
            let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S"
            let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W"
            location = coordinates(south ? -latitude : latitude, west ? -longitude : longitude)
        }
        return InfoSection(title: "Image", rows: rows([
            ("Dimensions", dimensions(number(properties[kCGImagePropertyPixelWidth]), number(properties[kCGImagePropertyPixelHeight]))),
            ("Camera", camera(make: tiff[kCGImagePropertyTIFFMake] as? String, model: tiff[kCGImagePropertyTIFFModel] as? String)),
            ("Lens", exif[kCGImagePropertyExifLensModel] as? String),
            ("Focal length", focalLength(number(exif[kCGImagePropertyExifFocalLength]), equivalent: number(exif[kCGImagePropertyExifFocalLenIn35mmFilm]))),
            ("Aperture", aperture(number(exif[kCGImagePropertyExifFNumber]))),
            ("Shutter speed", shutter(number(exif[kCGImagePropertyExifExposureTime]))),
            ("ISO", (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first.map { "ISO \($0.intValue)" }),
            ("Taken", taken(exif[kCGImagePropertyExifDateTimeOriginal] as? String)),
            ("Location", location)]))
    }

    static func mediaSection(_ asset: AVAsset) async throws -> InfoSection {
        let length = try await asset.load(.duration)
        var pairs: [(String, String?)] = [("Duration", duration(length.seconds))]
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return InfoSection(title: "Audio", rows: rows(pairs))
        }
        let (natural, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let shown = CGRect(origin: .zero, size: natural).applying(transform)
        pairs.append(("Dimensions", dimensions(Double(abs(shown.width)), Double(abs(shown.height)))))
        if rate > 0 { pairs.append(("Frame rate", trimmed(Double(rate)) + " fps")) }
        return InfoSection(title: "Video", rows: rows(pairs))
    }

    // Formatting helpers. Missing values leave their row out.
    static func rows(_ pairs: [(String, String?)]) -> [InfoRow] {
        pairs.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return InfoRow(label: label, value: value)
        }
    }
    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    static func kind(_ url: URL) -> String? { UTType(filenameExtension: url.pathExtension)?.localizedDescription }
    static func size(_ bytes: Int64?) -> String? {
        guard let bytes else { return nil }
        if bytes < 1000 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " (" + bytes.formatted() + " bytes)"
    }
    static func date(_ date: Date?) -> String? { date?.formatted(date: .abbreviated, time: .shortened) }
    static func dimensions(_ width: Double?, _ height: Double?) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(Int(width.rounded())) × \(Int(height.rounded()))"
    }
    static func camera(make: String?, model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = model?.trimmingCharacters(in: .whitespaces) ?? ""
        if model.isEmpty { return make.isEmpty ? nil : make }
        if make.isEmpty || model.lowercased().hasPrefix(make.lowercased()) { return model }
        return make + " " + model
    }
    static func focalLength(_ millimetres: Double?, equivalent: Double?) -> String? {
        guard let millimetres, millimetres > 0 else { return nil }
        var text = trimmed(millimetres) + " mm"
        if let equivalent, equivalent > 0 { text += " (\(Int(equivalent.rounded())) mm equivalent)" }
        return text
    }
    static func aperture(_ number: Double?) -> String? {
        guard let number, number > 0 else { return nil }
        return "ƒ/" + trimmed(number)
    }
    static func shutter(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds >= 1 { return trimmed(seconds) + " s" }
        return "1/\(Int((1 / seconds).rounded())) s"
    }
    static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
    static func coordinates(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.5f° %@, %.5f° %@", abs(latitude), latitude < 0 ? "S" : "N", abs(longitude), longitude < 0 ? "W" : "E")
    }
    static func taken(_ exif: String?) -> String? {
        guard let exif, !exif.isEmpty else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: exif) else { return exif }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    static func duration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}
