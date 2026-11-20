import Photos
import UniformTypeIdentifiers

enum PhotosAccess {
    static func list(limit: Int = 150) async throws -> [Entry] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ExplorerError("Allow access to Photos in Settings to browse your library.")
        }
        return await Task.detached {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = limit
            let assets = PHAsset.fetchAssets(with: options)
            var entries: [Entry] = []
            assets.enumerateObjects { asset, _, _ in
                let resources = originals(asset)
                if let main = resources.first {
                    entries.append(Entry(id: asset.localIdentifier, name: main.originalFilename,
                                         isFolder: false, bytes: nil, date: asset.creationDate, isPhoto: true))
                }
            }
            return entries
        }.value
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
    static func importFile(_ url: URL) async throws {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) || type.conforms(to: .movie) else {
            throw ExplorerError("Choose a single image or video to import into Photos.")
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExplorerError("Allow adding photos in Settings.") }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: type.conforms(to: .image) ? .photo : .video, fileURL: url, options: nil)
        }
    }
}
