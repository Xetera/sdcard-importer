import Foundation
import Testing

@testable import SDCardImporterCore

@Test func fingerprintDistinguishesExtensions() {
    let mp4 = LedgerEntry.fingerprint(
        volumeIdentifier: "vol-1",
        relativePath: "DCIM/DJI_001/DJI_0001_D.MP4",
        byteCount: 214_123_387,
        modifiedAt: Date(timeIntervalSince1970: 1_757_000_000)
    )
    let lrf = LedgerEntry.fingerprint(
        volumeIdentifier: "vol-1",
        relativePath: "DCIM/DJI_001/DJI_0001_D.LRF",
        byteCount: 18_869_284,
        modifiedAt: Date(timeIntervalSince1970: 1_757_000_000)
    )
    #expect(mp4 != lrf)
}

@Test func fingerprintIsStableAcrossCalls() {
    let date = Date(timeIntervalSince1970: 1_757_000_000)
    let a = LedgerEntry.fingerprint(
        volumeIdentifier: "vol-1", relativePath: "a.mp4", byteCount: 10, modifiedAt: date
    )
    let b = LedgerEntry.fingerprint(
        volumeIdentifier: "vol-1", relativePath: "a.mp4", byteCount: 10, modifiedAt: date
    )
    #expect(a == b)
}

@Test func ledgerRoundTripsAndDeduplicates() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ledger-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let ledger = Ledger(fileURL: tmp)
    let session = await ledger.beginSession(
        volumeName: "SD_Card",
        volumeIdentifier: "vol-1",
        destinationRoot: URL(fileURLWithPath: "/tmp/dest")
    )

    let fingerprint = LedgerEntry.fingerprint(
        volumeIdentifier: "vol-1", relativePath: "a.mp4", byteCount: 10,
        modifiedAt: Date(timeIntervalSince1970: 1)
    )
    #expect(await ledger.hasCopied(fingerprint: fingerprint) == false)

    await ledger.record(
        LedgerEntry(
            fingerprint: fingerprint,
            volumeName: "SD_Card",
            volumeIdentifier: "vol-1",
            relativePath: "a.mp4",
            sourcePath: "/Volumes/SD_Card/a.mp4",
            destinationPath: "/tmp/dest/a.mp4",
            byteCount: 10,
            sourceModifiedAt: Date(timeIntervalSince1970: 1),
            importedAt: Date(),
            status: .copied,
            failureReason: nil,
            contentKey: LedgerEntry.contentKey(
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 1),
                byteCount: 10,
                relativePath: "a.mp4"
            ),
            sourceFileName: "a.mp4"
        ),
        in: session
    )
    await ledger.finishSession(session)

    #expect(await ledger.hasCopied(fingerprint: fingerprint) == true)
    #expect(await ledger.destinationForCopied(fingerprint: fingerprint) == "/tmp/dest/a.mp4")

    let reloaded = Ledger(fileURL: tmp)
    #expect(await reloaded.hasCopied(fingerprint: fingerprint) == true)
    let totals = await reloaded.totals()
    #expect(totals.files == 1)
    #expect(totals.bytes == 10)
}

@Test func contentKeyIgnoresPathButNotExtension() {
    let created = Date(timeIntervalSince1970: 1_757_000_000)
    let a = LedgerEntry.contentKey(
        createdAt: created, modifiedAt: created, byteCount: 100,
        relativePath: "DCIM/100MEDIA/clip.mp4"
    )
    let moved = LedgerEntry.contentKey(
        createdAt: created, modifiedAt: created, byteCount: 100,
        relativePath: "DCIM/999OTHER/clip.mp4"
    )
    let otherExt = LedgerEntry.contentKey(
        createdAt: created, modifiedAt: created, byteCount: 100,
        relativePath: "DCIM/100MEDIA/clip.lrf"
    )
    #expect(a == moved)
    #expect(a != otherExt)
}

@Test func contentKeyFallsBackToModifiedWhenCreatedMissing() {
    let date = Date(timeIntervalSince1970: 1_757_000_000)
    let withCreated = LedgerEntry.contentKey(
        createdAt: date, modifiedAt: Date(timeIntervalSince1970: 9), byteCount: 5,
        relativePath: "a.mp4"
    )
    let withoutCreated = LedgerEntry.contentKey(
        createdAt: nil, modifiedAt: date, byteCount: 5, relativePath: "a.mp4"
    )
    #expect(withCreated == withoutCreated)
}

@Test func contentKeyMatchIsTiebrokenByFileName() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ledger-content-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let created = Date(timeIntervalSince1970: 1_757_000_000)
    let key = LedgerEntry.contentKey(
        createdAt: created, modifiedAt: created, byteCount: 100, relativePath: "DCIM/A.mp4"
    )

    let ledger = Ledger(fileURL: tmp)
    let session = await ledger.beginSession(
        volumeName: "card", volumeIdentifier: "vol-1",
        destinationRoot: URL(fileURLWithPath: "/tmp/dest")
    )
    await ledger.record(
        LedgerEntry(
            fingerprint: "fp-1",
            volumeName: "card",
            volumeIdentifier: "vol-1",
            relativePath: "DCIM/A.mp4",
            sourcePath: "/Volumes/card/DCIM/A.mp4",
            destinationPath: "/tmp/dest/A.mp4",
            byteCount: 100,
            sourceModifiedAt: created,
            importedAt: Date(),
            status: .copied,
            failureReason: nil,
            contentKey: key,
            sourceFileName: "A.mp4"
        ),
        in: session
    )

    #expect(await ledger.hasCopied(contentKey: key, fileName: "A.mp4") == true)
    #expect(await ledger.hasCopied(contentKey: key, fileName: "B.mp4") == false)
    #expect(
        await ledger.destinationForCopied(contentKey: key, fileName: "A.mp4")
            == "/tmp/dest/A.mp4"
    )

    let reloaded = Ledger(fileURL: tmp)
    #expect(await reloaded.hasCopied(contentKey: key, fileName: "A.mp4") == true)
    #expect(await reloaded.hasCopied(contentKey: key, fileName: "B.mp4") == false)
}

@Test func ledgerDecodesEntriesWithoutContentKey() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ledger-legacy-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let legacy = """
    [{"id":"\(UUID().uuidString)","volumeName":"card","volumeIdentifier":"vol-1",
    "destinationRoot":"/tmp/dest","startedAt":"2026-01-01T00:00:00Z",
    "entries":[{"fingerprint":"fp-legacy","volumeName":"card","volumeIdentifier":"vol-1",
    "relativePath":"DCIM/A.mp4","sourcePath":"/Volumes/card/DCIM/A.mp4",
    "destinationPath":"/tmp/dest/A.mp4","byteCount":100,
    "sourceModifiedAt":"2026-01-01T00:00:00Z","importedAt":"2026-01-01T00:00:00Z",
    "status":"copied"}]}]
    """
    try Data(legacy.utf8).write(to: tmp)

    let ledger = Ledger(fileURL: tmp)
    let totals = await ledger.totals()
    #expect(totals.files == 1)
    #expect(await ledger.hasCopied(fingerprint: "fp-legacy") == true)
}

@Test func scannerHonoursExtensionAllowlist() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("scan-test-\(UUID().uuidString)")
    let dcim = root.appendingPathComponent("DCIM/DJI_001")
    try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try Data(repeating: 0, count: 2048).write(to: dcim.appendingPathComponent("clip.MP4"))
    try Data(repeating: 0, count: 1024).write(to: dcim.appendingPathComponent("clip.LRF"))
    try Data(repeating: 0, count: 16).write(to: dcim.appendingPathComponent("clip.THM"))

    var settings = Settings.default
    settings.extensions = ["mp4"]

    let result = VolumeScanner.scan(volume: root, settings: settings)
    #expect(result.files.count == 1)
    #expect(result.totalBytes == 2048)
    #expect(result.files.first?.relativePath == "DCIM/DJI_001/clip.MP4")
    #expect(result.skippedExtensions["lrf"] == 1)
    #expect(VolumeScanner.looksLikeCameraCard(root))
}

@Test func backupIndexMatchesHandCopiedFiles() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("backup-index-\(UUID().uuidString)")
    let nested = root.appendingPathComponent("2026-09-15/SD_Card")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try Data(repeating: 0, count: 2048).write(to: nested.appendingPathComponent("clip.MP4"))

    let index = BackupIndex.load(from: root)

    let card = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("card-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: card) }

    let sameName = card.appendingPathComponent("clip.MP4")
    try Data(repeating: 1, count: 2048).write(to: sameName)
    #expect(index.contains(sameName))

    let sameNameOtherSize = card.appendingPathComponent("other.MP4")
    try Data(repeating: 0, count: 4096).write(to: sameNameOtherSize)
    #expect(index.contains(sameNameOtherSize) == false)

    let sizeMatchDifferentName = card.appendingPathComponent("renamed.MP4")
    try Data(repeating: 0, count: 2048).write(to: sizeMatchDifferentName)
    #expect(index.contains(sizeMatchDifferentName) == false)

    let destinations = index.destinations(for: sameName)
    #expect(destinations.count == 1)
    #expect(destinations.first?.hasSuffix("2026-09-15/SD_Card/clip.MP4") == true)
    #expect(index.destinations(for: sizeMatchDifferentName).isEmpty)
}

@Test func backupIndexRecordsEveryMatchingDestination() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("backup-dupes-\(UUID().uuidString)")
    let first = root.appendingPathComponent("2026-09-15")
    let second = root.appendingPathComponent("2026-09-16")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try Data(repeating: 0, count: 512).write(to: first.appendingPathComponent("clip.MP4"))
    try Data(repeating: 0, count: 512).write(to: second.appendingPathComponent("clip.MP4"))

    let index = BackupIndex.load(from: root)
    let card = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("card-dupes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: card) }

    let probe = card.appendingPathComponent("clip.MP4")
    try Data(repeating: 9, count: 512).write(to: probe)
    #expect(index.destinations(for: probe).count == 2)
}

@Test func backupIndexKeyIsCaseInsensitive() {
    let upper = BackupIndex.key(name: "CLIP.MP4", byteCount: 10)
    let lower = BackupIndex.key(name: "clip.mp4", byteCount: 10)
    #expect(upper == lower)
}

@Test func backupIndexSnapshotRoundTrips() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("snapshot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try Data(repeating: 0, count: 2048).write(to: root.appendingPathComponent("clip.MP4"))

    let snapshot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("snapshot-file-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: snapshot) }

    let original = BackupIndex.load(from: root)
    original.writeSnapshot(to: snapshot)

    let restored = BackupIndex.loadSnapshot(from: snapshot)
    #expect(restored.contentKeys == original.contentKeys)

    let card = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("snapshot-card-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: card) }

    let probe = card.appendingPathComponent("clip.MP4")
    try Data(repeating: 1, count: 2048).write(to: probe)
    #expect(restored.contains(probe))
    #expect(restored.destinations(for: probe).first?.hasSuffix("clip.MP4") == true)
}

@Test func backupIndexSnapshotIsEmptyWhenMissing() {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("no-snapshot-\(UUID().uuidString).json")
    #expect(BackupIndex.loadSnapshot(from: missing).contentKeys.isEmpty)
}

@Test func backupIndexIsEmptyForMissingRoot() {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
    #expect(BackupIndex.load(from: missing).contentKeys.isEmpty)
}

@Test func badgeFailureRoundTrips() {
    SharedSettings.reportBadgeFailure(nil)
    #expect(SharedSettings.badgeFailure() == nil)

    SharedSettings.reportBadgeFailure("Cannot read SD_Card: denied")
    #expect(SharedSettings.badgeFailure() == "Cannot read SD_Card: denied")

    SharedSettings.reportBadgeFailure(nil)
    #expect(SharedSettings.badgeFailure() == nil)
}

@Test func destinationRootResolvesOutsideSandboxContainer() {
    let path = SharedSettings.destinationRoot().path
    #expect(path.contains("/Library/Containers/") == false)
}

@Test func destinationIsAlwaysTheChosenRoot() {
    var settings = Settings.default
    settings.destinationRoot = "/tmp/Imports"

    var components = DateComponents()
    components.year = 2026
    components.month = 9
    components.day = 15
    let date = Calendar.current.date(from: components)!

    #expect(settings.destination(forVolumeNamed: "SD_Card", date: date).path == "/tmp/Imports")
}
