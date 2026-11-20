import Foundation
import LibArchive

enum ArchiveTools {
    static func extract(_ archive: URL) throws {
        let scratch = try Files.workspace()
        defer { try? Files.fm.removeItem(at: scratch) }
        let output = scratch.appendingPathComponent(archive.lastPathComponent + " - extracted")
        try Files.read(archive) { input in
            let reader = ArchiveReader()
            let entries = try reader.entries(at: input)
            var seen = Set<String>()
            var total: Int64 = 0
            let free = try scratch.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
            for entry in entries {
                guard (entry.fileType == .regular || entry.fileType == .directory),
                      entry.hardlinkTarget == nil, entry.symlinkTarget == nil,
                      !entry.isDataEncrypted, !entry.isMetadataEncrypted else {
                    throw ExplorerError("This archive contains an encrypted item, link or unsupported file type.")
                }
                let parts = entry.path.split(separator: "/")
                guard !entry.path.hasPrefix("/"), !parts.isEmpty,
                      parts.allSatisfy({ (try? safeName(String($0))) != nil }),
                      seen.insert(parts.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()).inserted
                else { throw ExplorerError("The archive contains conflicting or unsupported paths.") }
                let sum = total.addingReportingOverflow(entry.size)
                guard entry.size >= 0, !sum.overflow, free.map({ sum.partialValue < Int64($0) }) ?? true
                else { throw ExplorerError("There is insufficient temporary space to extract this archive.") }
                total = sum.partialValue
            }
            try reader.extract(input, to: output, options: [.noOverwrite, .preserveModificationTime, .safeWrites])
        }
        try Files.publish(output, into: archive.deletingLastPathComponent())
    }
}
