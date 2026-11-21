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

// File data plus EXIF for photos and duration and resolution for videos.
struct InfoView: View {
    let entry: Entry
    let model: ViewerModel
    @Environment(\.dismiss) private var dismiss
    @State private var sections: [InfoSection]?
    @State private var failure: String?

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
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("info-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            do { sections = try await MediaInfo.sections(for: entry, in: model) }
            catch { failure = error.localizedDescription }
        }
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
