import Photos
import UniformTypeIdentifiers

// The folders Photos is split into: fixed kinds first, then each album by its name.
// Pictures holds camera shots; Others holds every other image, such as saved or downloaded ones.
enum PhotoFolder: Hashable {
    case all, pictures, videos, screenshots, others
    case album(id: String, name: String)

    var title: String {
        switch self {
        case .all: return "All"
        case .pictures: return "Pictures"
        case .videos: return "Videos"
        case .screenshots: return "Screenshots"
        case .others: return "Others"
        case let .album(_, name): return name
        }
    }
    var id: String {
        switch self {
        case .all: return "photos:all"
        case .pictures: return "photos:pictures"
        case .videos: return "photos:videos"
        case .screenshots: return "photos:screenshots"
        case .others: return "photos:others"
        case let .album(id, _): return "photos:album:" + id
        }
    }
    init?(entry: Entry) {
        switch entry.id {
        case "photos:all": self = .all
        case "photos:pictures": self = .pictures
        case "photos:videos": self = .videos
        case "photos:screenshots": self = .screenshots
        case "photos:others": self = .others
        default:
            guard entry.id.hasPrefix("photos:album:") else { return nil }
            self = .album(id: String(entry.id.dropFirst("photos:album:".count)), name: entry.name)
        }
    }
}

enum PhotosAccess {
    static func authorize() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ExplorerError("Allow access to Photos in Settings to browse your library.")
        }
    }

    static func folders() async throws -> [Entry] {
        try await authorize()
        return await Task.detached {
            let shots = screenshotAlbum().map { PHAsset.fetchAssets(in: $0, options: nil).count } ?? 0
            func row(_ folder: PhotoFolder, _ count: Int?) -> Entry {
                Entry(id: folder.id, name: folder.title, isFolder: true, bytes: nil, date: nil, note: count.map(itemCount))
            }
            var rows = [row(.all, PHAsset.fetchAssets(with: nil).count),
                        row(.pictures, nil),
                        row(.videos, PHAsset.fetchAssets(with: .video, options: nil).count),
                        row(.screenshots, shots),
                        row(.others, nil)]
            var albums: [Entry] = []
            PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { album, _, _ in
                let name = album.localizedTitle ?? "Album"
                albums.append(row(.album(id: album.localIdentifier, name: name), PHAsset.fetchAssets(in: album, options: nil).count))
            }
            rows += albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return rows
        }.value
    }

    static func itemCount(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }

    // Counts for Pictures and Others, which the folder list shows once they are ready.
    static func splitCounts() async -> (pictures: Int, others: Int) {
        await Task.detached {
            let shots = screenshotIDs()
            var pictures = 0, others = 0
            PHAsset.fetchAssets(with: .image, options: nil).enumerateObjects { asset, _, _ in
                if isScreenshot(asset, in: shots) { return }
                if isCameraShot(asset) { pictures += 1 } else { others += 1 }
            }
            return (pictures, others)
        }.value
    }

    // Camera shots carry what the Camera app records: a location, a capture style
    // (Live, HDR, Portrait, Panorama or burst), or the camera's HEIC or RAW format.
    // Apps can't read which app saved an image, so everything else counts as Others.
    static func isCameraShot(_ asset: PHAsset) -> Bool {
        if asset.location != nil || asset.burstIdentifier != nil { return true }
        let styles: PHAssetMediaSubtype = [.photoLive, .photoHDR, .photoDepthEffect, .photoPanorama]
        if !asset.mediaSubtypes.isDisjoint(with: styles) { return true }
        guard let photo = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo }),
              let type = UTType(photo.uniformTypeIdentifier) else { return false }
        return type.conforms(to: .heic) || type.conforms(to: .heif) || type.conforms(to: .rawImage)
    }
    // Uses the same list as the Screenshots folder, plus the screenshot marker.
    private static func isScreenshot(_ asset: PHAsset, in shots: Set<String>) -> Bool {
        asset.mediaSubtypes.contains(.photoScreenshot) || shots.contains(asset.localIdentifier)
    }
    private static func screenshotIDs() -> Set<String> {
        guard let album = screenshotAlbum() else { return [] }
        var ids = Set<String>()
        PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        return ids
    }

    static func list(_ folder: PhotoFolder, limit: Int = 150) async throws -> [Entry] {
        try await authorize()
        return await Task.detached {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets: PHFetchResult<PHAsset>
            var keep: ((PHAsset) -> Bool)?
            switch folder {
            case .all:
                options.fetchLimit = limit
                assets = PHAsset.fetchAssets(with: options)
            case .videos:
                options.fetchLimit = limit
                assets = PHAsset.fetchAssets(with: .video, options: options)
            case .pictures, .others:
                // Sorted while listing, so no fetch limit here.
                let shots = screenshotIDs()
                let camera = folder == .pictures
                keep = { !isScreenshot($0, in: shots) && isCameraShot($0) == camera }
                assets = PHAsset.fetchAssets(with: .image, options: options)
            case .screenshots:
                options.fetchLimit = limit
                guard let album = screenshotAlbum() else { return [] }
                assets = PHAsset.fetchAssets(in: album, options: options)
            case let .album(id, _):
                options.fetchLimit = limit
                guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else { return [] }
                assets = PHAsset.fetchAssets(in: album, options: options)
            }
            var entries: [Entry] = []
            assets.enumerateObjects { asset, _, stop in
                if let keep, !keep(asset) { return }
                if let main = originals(asset).first {
                    entries.append(Entry(id: asset.localIdentifier, name: main.originalFilename,
                                         isFolder: false, bytes: nil, date: asset.creationDate, isPhoto: true))
                }
                if entries.count >= limit { stop.pointee = true }
            }
            return entries
        }.value
    }

    private static func screenshotAlbum() -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumScreenshots, options: nil).firstObject
    }

    private static func originals(_ asset: PHAsset) -> [PHAssetResource] {
        PHAssetResource.assetResources(for: asset).filter {
            [.photo, .video, .pairedVideo, .alternatePhoto, .audio].contains($0.type)
        }
    }
    // Exports one file as Photos shows it: the edited version when there is one,
    // and only the still image of a Live Photo.
    static func export(_ entry: Entry, into folder: URL) async throws -> URL {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [entry.id], options: nil).firstObject
        else { throw ExplorerError("This photo is no longer available.") }
        let resources = PHAssetResource.assetResources(for: asset)
        let isVideo = asset.mediaType == .video
        let originalType: PHAssetResourceType = isVideo ? .video : .photo
        let renderType: PHAssetResourceType = isVideo ? .fullSizeVideo : .fullSizePhoto
        let original = resources.first { $0.type == originalType } ?? originals(asset).first
        let render = resources.first { $0.type == renderType }
        guard let resource = render ?? original else { throw ExplorerError("Photos could not supply this item.") }
        let name = exportName(original: original?.originalFilename ?? entry.name, render: render?.originalFilename)
        let url = folder.appendingPathComponent(try safeName(name))
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return url
    }
    // An edited render keeps the original name with the render's file type: IMG_1234.HEIC → IMG_1234.JPG.
    static func exportName(original: String, render: String?) -> String {
        guard let render else { return original }
        let base = (original as NSString).deletingPathExtension
        let originalType = (original as NSString).pathExtension
        var type = (render as NSString).pathExtension
        guard !type.isEmpty, type.lowercased() != originalType.lowercased() else { return original }
        if !originalType.isEmpty && originalType == originalType.uppercased() { type = type.uppercased() }
        return base + "." + type
    }
    // Pasting into an album folder also adds the new item to that album.
    static func importFile(_ url: URL, into folder: PhotoFolder? = nil) async throws {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) || type.conforms(to: .movie) else {
            throw ExplorerError("Choose a single image or video to import into Photos.")
        }
        var album: PHAssetCollection?
        if case let .album(id, _) = folder {
            try await authorize()
            album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
        } else {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { throw ExplorerError("Allow adding photos in Settings.") }
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: type.conforms(to: .image) ? .photo : .video, fileURL: url, options: nil)
            if let album, let placeholder = request.placeholderForCreatedAsset,
               let change = PHAssetCollectionChangeRequest(for: album) {
                change.addAssets([placeholder] as NSArray)
            }
        }
    }
}
