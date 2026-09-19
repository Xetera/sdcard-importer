import Foundation

struct BackupIndex {
    private(set) var destinationsByKey: [String: [String]]
    private(set) var loadedAt: Date

    var contentKeys: Set<String> { Set(destinationsByKey.keys) }

    init(destinationsByKey: [String: [String]] = [:], loadedAt: Date = .distantPast) {
        self.destinationsByKey = destinationsByKey
        self.loadedAt = loadedAt
    }

    static func key(name: String, byteCount: Int64) -> String {
        let lowered = name.lowercased()
        let ext = (lowered as NSString).pathExtension
        return "\(lowered)|\(byteCount)|\(ext)"
    }

    static func key(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize
        else { return nil }
        return key(name: url.lastPathComponent, byteCount: Int64(size))
    }

    static func load(from root: URL = SharedSettings.destinationRoot()) -> BackupIndex {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return BackupIndex()
        }

        var keys: [String: [String]] = [:]
        for case let url as URL in enumerator {
            guard let key = BackupIndex.key(for: url) else { continue }
            keys[key, default: []].append(url.standardizedFileURL.path)
        }
        return BackupIndex(destinationsByKey: keys, loadedAt: Date())
    }

    func contains(_ url: URL) -> Bool {
        !destinations(for: url).isEmpty
    }

    func destinations(for url: URL) -> [String] {
        guard let key = BackupIndex.key(for: url) else { return [] }
        return destinationsByKey[key] ?? []
    }

    static func modificationDate(of url: URL = SharedSettings.destinationRoot()) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func snapshotURL() -> URL {
        Ledger.containerURL().appendingPathComponent("backup-index.json")
    }

    func writeSnapshot(to url: URL = BackupIndex.snapshotURL()) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(destinationsByKey) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    static func loadSnapshot(from url: URL = BackupIndex.snapshotURL()) -> BackupIndex {
        guard let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return BackupIndex() }
        return BackupIndex(destinationsByKey: keys, loadedAt: Date())
    }
}

enum SharedSettings {
    static let suiteName = Ledger.appGroupIdentifier
    static let destinationKey = "destinationRoot.v1"

    static func destinationRoot() -> URL {
        let defaults = UserDefaults(suiteName: suiteName)
        if let stored = defaults?.string(forKey: destinationKey), !stored.isEmpty {
            return URL(fileURLWithPath: (stored as NSString).expandingTildeInPath, isDirectory: true)
        }
        return realHomeDirectory()
            .appendingPathComponent("Movies/Imports", isDirectory: true)
    }

    static func setDestinationRoot(_ url: URL) {
        UserDefaults(suiteName: suiteName)?.set(url.path, forKey: destinationKey)
    }

    static let badgeFailureKey = "badgeFailure.v1"

    static func reportBadgeFailure(_ message: String?) {
        let defaults = UserDefaults(suiteName: suiteName)
        if let message {
            defaults?.set(message, forKey: badgeFailureKey)
        } else {
            defaults?.removeObject(forKey: badgeFailureKey)
        }
    }

    static func badgeFailure() -> String? {
        let stored = UserDefaults(suiteName: suiteName)?.string(forKey: badgeFailureKey)
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    static func realHomeDirectory() -> URL {
        let path = FileManager.default.homeDirectoryForCurrentUser.path
        guard let range = path.range(of: "/Library/Containers/") else {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: String(path[path.startIndex..<range.lowerBound]), isDirectory: true)
    }
}
