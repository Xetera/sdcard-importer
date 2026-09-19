import Foundation

struct ImportProgress {
    let completedFiles: Int
    let totalFiles: Int
    let skippedFiles: Int
    let copiedBytes: Int64
    let totalBytes: Int64
    let currentFile: String?

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(copiedBytes) / Double(totalBytes))
    }
}

struct ImportSummary {
    let sessionID: UUID
    let copied: Int
    let skipped: Int
    let failed: Int
    let copiedBytes: Int64
    let destinationRoot: URL
    let firstFailure: String?
    let cancelled: Bool
    let remaining: Int
}

enum ImportError: LocalizedError {
    case insufficientSpace(needed: Int64, available: Int64)
    case destinationUnwritable(URL, underlying: String)

    var errorDescription: String? {
        switch self {
        case let .insufficientSpace(needed, available):
            let f = ByteCountFormatter()
            f.countStyle = .file
            return """
            Not enough free space: need \(f.string(fromByteCount: needed)), \
            \(f.string(fromByteCount: available)) available.
            """
        case let .destinationUnwritable(url, underlying):
            return "Cannot write to \(url.path): \(underlying)"
        }
    }
}

struct Importer {
    let ledger: Ledger
    let settings: Settings

    func run(
        volume: URL,
        volumeName: String,
        volumeIdentifier: String,
        scan: ScanResult,
        progress: @escaping @Sendable (ImportProgress) -> Void
    ) async throws -> ImportSummary {
        let destinationRoot = settings.destination(forVolumeNamed: volumeName)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        } catch {
            throw ImportError.destinationUnwritable(
                destinationRoot, underlying: error.localizedDescription
            )
        }

        let existing = BackupIndex.load(from: destinationRoot)

        var pending: [DiscoveredFile] = []
        var duplicates: [(DiscoveredFile, String, String?)] = []
        for file in scan.files {
            let fingerprint = LedgerEntry.fingerprint(
                volumeIdentifier: volumeIdentifier,
                relativePath: file.relativePath,
                byteCount: file.byteCount,
                modifiedAt: file.modifiedAt
            )
            let matches = existing.destinations(for: file.url)
            if matches.isEmpty {
                pending.append(file)
            } else {
                duplicates.append((file, fingerprint, matches.first))
            }
        }

        let neededBytes = pending.reduce(0) { $0 + $1.byteCount }
        if let free = VolumeScanner.freeBytes(at: destinationRoot), neededBytes > free {
            throw ImportError.insufficientSpace(needed: neededBytes, available: free)
        }

        let sessionID = await ledger.beginSession(
            volumeName: volumeName,
            volumeIdentifier: volumeIdentifier,
            destinationRoot: destinationRoot
        )

        for (file, fingerprint, previous) in duplicates {
            await ledger.record(
                LedgerEntry(
                    fingerprint: fingerprint,
                    volumeName: volumeName,
                    volumeIdentifier: volumeIdentifier,
                    relativePath: file.relativePath,
                    sourcePath: file.url.path,
                    destinationPath: previous ?? "",
                    byteCount: file.byteCount,
                    sourceModifiedAt: file.modifiedAt,
                    importedAt: Date(),
                    status: .skippedDuplicate,
                    failureReason: nil,
                    contentKey: LedgerEntry.contentKey(
                        createdAt: file.createdAt,
                        modifiedAt: file.modifiedAt,
                        byteCount: file.byteCount,
                        relativePath: file.relativePath
                    ),
                    sourceFileName: file.url.lastPathComponent
                ),
                in: sessionID
            )
        }

        var copiedBytes: Int64 = 0
        var copied = 0
        var failed = 0
        var firstFailure: String?

        progress(
            ImportProgress(
                completedFiles: 0,
                totalFiles: pending.count,
                skippedFiles: duplicates.count,
                copiedBytes: 0,
                totalBytes: neededBytes,
                currentFile: pending.first?.url.lastPathComponent
            )
        )

        var cancelled = false
        var processed = 0

        for file in pending {
            if Task.isCancelled {
                cancelled = true
                break
            }
            processed += 1

            let fingerprint = LedgerEntry.fingerprint(
                volumeIdentifier: volumeIdentifier,
                relativePath: file.relativePath,
                byteCount: file.byteCount,
                modifiedAt: file.modifiedAt
            )
            let target = uniqueDestination(for: file, root: destinationRoot)

            do {
                try fm.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try fm.copyItem(at: file.url, to: target)

                let written = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                guard written == file.byteCount else {
                    try? fm.removeItem(at: target)
                    throw NSError(
                        domain: "SDCardImporter", code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "size mismatch after copy (\(written ?? -1) vs \(file.byteCount))"
                        ]
                    )
                }

                try? fm.setAttributes(
                    [.modificationDate: file.modifiedAt], ofItemAtPath: target.path
                )

                copied += 1
                copiedBytes += file.byteCount
                await ledger.record(
                    LedgerEntry(
                        fingerprint: fingerprint,
                        volumeName: volumeName,
                        volumeIdentifier: volumeIdentifier,
                        relativePath: file.relativePath,
                        sourcePath: file.url.path,
                        destinationPath: target.path,
                        byteCount: file.byteCount,
                        sourceModifiedAt: file.modifiedAt,
                        importedAt: Date(),
                        status: .copied,
                        failureReason: nil,
                        contentKey: LedgerEntry.contentKey(
                            createdAt: file.createdAt,
                            modifiedAt: file.modifiedAt,
                            byteCount: file.byteCount,
                            relativePath: file.relativePath
                        ),
                        sourceFileName: file.url.lastPathComponent
                    ),
                    in: sessionID
                )
            } catch {
                failed += 1
                if firstFailure == nil {
                    firstFailure = "\(file.url.lastPathComponent): \(error.localizedDescription)"
                }
                await ledger.record(
                    LedgerEntry(
                        fingerprint: fingerprint,
                        volumeName: volumeName,
                        volumeIdentifier: volumeIdentifier,
                        relativePath: file.relativePath,
                        sourcePath: file.url.path,
                        destinationPath: target.path,
                        byteCount: file.byteCount,
                        sourceModifiedAt: file.modifiedAt,
                        importedAt: Date(),
                        status: .failed,
                        failureReason: error.localizedDescription,
                        contentKey: LedgerEntry.contentKey(
                            createdAt: file.createdAt,
                            modifiedAt: file.modifiedAt,
                            byteCount: file.byteCount,
                            relativePath: file.relativePath
                        ),
                        sourceFileName: file.url.lastPathComponent
                    ),
                    in: sessionID
                )
            }

            progress(
                ImportProgress(
                    completedFiles: copied + failed,
                    totalFiles: pending.count,
                    skippedFiles: duplicates.count,
                    copiedBytes: copiedBytes,
                    totalBytes: neededBytes,
                    currentFile: file.url.lastPathComponent
                )
            )
        }

        await ledger.finishSession(sessionID)

        BackupIndex.load(from: destinationRoot).writeSnapshot()

        return ImportSummary(
            sessionID: sessionID,
            copied: copied,
            skipped: duplicates.count,
            failed: failed,
            copiedBytes: copiedBytes,
            destinationRoot: destinationRoot,
            firstFailure: firstFailure,
            cancelled: cancelled,
            remaining: pending.count - processed
        )
    }

    private func uniqueDestination(for file: DiscoveredFile, root: URL) -> URL {
        let candidate = root.appendingPathComponent(file.url.lastPathComponent)
        let fm = FileManager.default
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let existingSize = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init)
        if existingSize != file.byteCount {
            try? fm.removeItem(at: candidate)
        }
        return candidate
    }
}
