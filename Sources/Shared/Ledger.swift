import Foundation

struct LedgerEntry: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        case copied
        case skippedDuplicate
        case failed
    }

    var id: String { fingerprint }

    let fingerprint: String
    let volumeName: String
    let volumeIdentifier: String
    let relativePath: String
    let sourcePath: String
    let destinationPath: String
    let byteCount: Int64
    let sourceModifiedAt: Date
    let importedAt: Date
    let status: Status
    let failureReason: String?
    let contentKey: String?
    let sourceFileName: String?

    static func fingerprint(
        volumeIdentifier: String,
        relativePath: String,
        byteCount: Int64,
        modifiedAt: Date
    ) -> String {
        let stamp = Int64(modifiedAt.timeIntervalSince1970.rounded())
        return "\(volumeIdentifier)|\(relativePath)|\(byteCount)|\(stamp)"
    }

    static func contentKey(
        createdAt: Date?,
        modifiedAt: Date,
        byteCount: Int64,
        relativePath: String
    ) -> String {
        let stamp = Int64((createdAt ?? modifiedAt).timeIntervalSince1970.rounded())
        let ext = (relativePath as NSString).pathExtension.lowercased()
        return "\(stamp)|\(byteCount)|\(ext)"
    }
}

struct LedgerSession: Codable, Identifiable {
    let id: UUID
    let volumeName: String
    let volumeIdentifier: String
    let destinationRoot: String
    let startedAt: Date
    var finishedAt: Date?
    var entries: [LedgerEntry]

    var copiedCount: Int { entries.filter { $0.status == .copied }.count }
    var skippedCount: Int { entries.filter { $0.status == .skippedDuplicate }.count }
    var failedCount: Int { entries.filter { $0.status == .failed }.count }
    var copiedBytes: Int64 {
        entries.filter { $0.status == .copied }.reduce(0) { $0 + $1.byteCount }
    }
}

actor Ledger {
    private let fileURL: URL
    private var sessions: [LedgerSession]
    private var copiedFingerprints: Set<String>
    private var copiedNamesByContentKey: [String: Set<String>]

    init(fileURL: URL? = nil) {
        let resolved = fileURL ?? Ledger.defaultURL()
        self.fileURL = resolved
        let loaded = Ledger.load(from: resolved)
        self.sessions = loaded
        let copied = loaded.flatMap(\.entries).filter { $0.status == .copied }
        self.copiedFingerprints = Set(copied.map(\.fingerprint))
        var index: [String: Set<String>] = [:]
        for entry in copied {
            guard let key = entry.contentKey else { continue }
            let name = entry.sourceFileName
                ?? (entry.relativePath as NSString).lastPathComponent
            index[key, default: []].insert(name)
        }
        self.copiedNamesByContentKey = index
    }

    static let appGroupIdentifier = "FLDWQ2AC5Y.group.com.xetera.sdcardimporter"

    static func containerURL() -> URL {
        if let shared = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            return shared
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SDCardImporter", isDirectory: true)
    }

    static func defaultURL() -> URL {
        let base = containerURL()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("ledger.json")
    }

    var url: URL { fileURL }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func load(from url: URL) -> [LedgerSession] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder().decode([LedgerSession].self, from: data)) ?? []
    }

    func hasCopied(fingerprint: String) -> Bool {
        copiedFingerprints.contains(fingerprint)
    }

    func hasCopied(contentKey: String, fileName: String) -> Bool {
        copiedNamesByContentKey[contentKey]?.contains(fileName) ?? false
    }

    func destinationForCopied(contentKey: String, fileName: String) -> String? {
        for session in sessions.reversed() {
            for entry in session.entries
            where entry.status == .copied
                && entry.contentKey == contentKey
                && (entry.sourceFileName
                    ?? (entry.relativePath as NSString).lastPathComponent) == fileName {
                return entry.destinationPath
            }
        }
        return nil
    }

    func destinationForCopied(fingerprint: String) -> String? {
        for session in sessions.reversed() {
            for entry in session.entries
            where entry.fingerprint == fingerprint && entry.status == .copied {
                return entry.destinationPath
            }
        }
        return nil
    }

    func beginSession(
        volumeName: String,
        volumeIdentifier: String,
        destinationRoot: URL
    ) -> UUID {
        let session = LedgerSession(
            id: UUID(),
            volumeName: volumeName,
            volumeIdentifier: volumeIdentifier,
            destinationRoot: destinationRoot.path,
            startedAt: Date(),
            finishedAt: nil,
            entries: []
        )
        sessions.append(session)
        persist()
        return session.id
    }

    func record(_ entry: LedgerEntry, in sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].entries.append(entry)
        if entry.status == .copied {
            copiedFingerprints.insert(entry.fingerprint)
            if let key = entry.contentKey {
                let name = entry.sourceFileName
                    ?? (entry.relativePath as NSString).lastPathComponent
                copiedNamesByContentKey[key, default: []].insert(name)
            }
        }
        persist()
    }

    func finishSession(_ sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].finishedAt = Date()
        persist()
    }

    func recentSessions(limit: Int = 25) -> [LedgerSession] {
        Array(sessions.suffix(limit).reversed())
    }

    func lastImport(forVolumeIdentifier identifier: String) -> (date: Date, files: Int, destination: String)? {
        for session in sessions.reversed()
        where session.volumeIdentifier == identifier && session.copiedCount > 0 {
            return (
                session.finishedAt ?? session.startedAt,
                session.copiedCount,
                session.destinationRoot
            )
        }
        return nil
    }

    func allSessions() -> [LedgerSession] { sessions }

    func totals() -> (files: Int, bytes: Int64) {
        let copied = sessions.flatMap(\.entries).filter { $0.status == .copied }
        return (copied.count, copied.reduce(0) { $0 + $1.byteCount })
    }

    private func persist() {
        guard let data = try? Ledger.encoder().encode(sessions) else { return }
        let tmp = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } catch {
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
