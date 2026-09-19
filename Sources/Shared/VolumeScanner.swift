import Foundation

struct DiscoveredFile: Hashable {
    let url: URL
    let relativePath: String
    let byteCount: Int64
    let modifiedAt: Date
    let createdAt: Date?
}

struct ScanResult {
    let files: [DiscoveredFile]
    let totalBytes: Int64
    let skippedExtensions: [String: Int]

    var isEmpty: Bool { files.isEmpty }
}

enum VolumeScanner {
    static func looksLikeCameraCard(_ volume: URL) -> Bool {
        let fm = FileManager.default
        for marker in ["DCIM", "PRIVATE", "CLIP", "XDROOT"] {
            var isDir: ObjCBool = false
            let path = volume.appendingPathComponent(marker).path
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return true
            }
        }
        return false
    }

    static func scan(volume: URL, settings: Settings) -> ScanResult {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
            .creationDateKey, .isHiddenKey,
        ]
        guard let enumerator = fm.enumerator(
            at: volume,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ScanResult(files: [], totalBytes: 0, skippedExtensions: [:])
        }

        let wanted = Set(settings.extensions.map { $0.lowercased() })
        var files: [DiscoveredFile] = []
        var skipped: [String: Int] = [:]
        var total: Int64 = 0
        let base = volume.standardizedFileURL.path

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }

            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty else { continue }
            guard wanted.contains(ext) else {
                skipped[ext, default: 0] += 1
                continue
            }

            let size = Int64(values.fileSize ?? 0)
            guard size > 0 else { continue }

            var relative = url.standardizedFileURL.path
            if relative.hasPrefix(base) {
                relative = String(relative.dropFirst(base.count))
                if relative.hasPrefix("/") { relative.removeFirst() }
            }

            files.append(
                DiscoveredFile(
                    url: url,
                    relativePath: relative,
                    byteCount: size,
                    modifiedAt: values.contentModificationDate ?? Date(),
                    createdAt: values.creationDate
                )
            )
            total += size
        }

        files.sort { $0.relativePath < $1.relativePath }
        return ScanResult(files: files, totalBytes: total, skippedExtensions: skipped)
    }

    static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage {
            return Int64(important)
        }
        let fallback = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return fallback?.volumeAvailableCapacity.map(Int64.init)
    }
}
