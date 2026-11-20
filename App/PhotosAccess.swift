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
    static func export(_ entry: Entry, into folder: URL) async throws -> URL {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [entry.id], options: nil).firstObject
        else { throw ExplorerError("This photo is no longer available.") }
        let resources = originals(asset)
        guard !resources.isEmpty else { throw ExplorerError("Photos could not supply an original.") }
        if asset.mediaSubtypes.contains(.photoLive), !resources.contains(where: { $0.type == .pairedVideo }) {
            throw ExplorerError("Photos could not supply the Live Photo’s motion component.")
        }
        let multiple = resources.count > 1
        let output = folder.appendingPathComponent(try safeName(entry.name) + (multiple ? " - originals" : ""))
        if multiple { try Files.fm.createDirectory(at: output, withIntermediateDirectories: false) }
        var used = Set<String>()
        for (index, resource) in resources.enumerated() {
            var name = try safeName(resource.originalFilename)
            while !used.insert(name.lowercased()).inserted { name = "\(index + 1)-" + name }
            let url = multiple ? output.appendingPathComponent(name) : output
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
        return output
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
