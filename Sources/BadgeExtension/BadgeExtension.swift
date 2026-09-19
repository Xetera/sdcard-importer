import AppKit
import FinderSync
import os

private let log = Logger(subsystem: "com.xetera.sdcardimporter", category: "badge")

@objc(BadgeExtension)
final class BadgeExtension: FIFinderSync {
    private enum Badge {
        static let imported = "com.xetera.sdcardimporter.imported"
        static let notImported = "com.xetera.sdcardimporter.notimported"
        static let partial = "com.xetera.sdcardimporter.partial"
        static let none = ""
    }

    private var index = BackupIndex()
    private var indexStamp: Date?
    private var observed: Set<URL> = []
    private var destinationStream: FSEventStreamRef?
    private var destinationWatched: URL?

    override init() {
        super.init()

        registerBadgeImage()
        refreshIndex()
        updateWatchedDirectories()
        startWatchingDestination()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(volumesChanged),
            name: NSWorkspace.didMountNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(volumesChanged),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        stopWatchingDestination()
    }

    private func registerBadgeImage() {
        let controller = FIFinderSyncController.default()

        let imported = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 6, dy: 6)).fill()

            NSColor.white.setStroke()
            let check = NSBezierPath()
            check.lineWidth = 8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.move(to: NSPoint(x: rect.width * 0.28, y: rect.height * 0.52))
            check.line(to: NSPoint(x: rect.width * 0.44, y: rect.height * 0.34))
            check.line(to: NSPoint(x: rect.width * 0.74, y: rect.height * 0.68))
            check.stroke()
            return true
        }

        let notImported = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let inset = rect.insetBy(dx: 6, dy: 6)
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: inset).fill()

            NSColor.systemGray.setStroke()
            let ring = NSBezierPath(ovalIn: inset.insetBy(dx: 3, dy: 3))
            ring.lineWidth = 6
            ring.stroke()

            NSColor.systemGray.setFill()
            let dot = NSBezierPath(ovalIn: NSRect(
                x: rect.width * 0.42, y: rect.height * 0.42,
                width: rect.width * 0.16, height: rect.height * 0.16
            ))
            dot.fill()
            return true
        }

        let partial = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let inset = rect.insetBy(dx: 6, dy: 6)
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: inset).fill()

            NSColor.white.setFill()
            let bar = NSBezierPath(roundedRect: NSRect(
                x: rect.width * 0.28, y: rect.height * 0.44,
                width: rect.width * 0.44, height: rect.height * 0.12
            ), xRadius: rect.height * 0.06, yRadius: rect.height * 0.06)
            bar.fill()
            return true
        }

        controller.setBadgeImage(
            imported, label: "Imported", forBadgeIdentifier: Badge.imported
        )
        controller.setBadgeImage(
            notImported, label: "Not imported", forBadgeIdentifier: Badge.notImported
        )
        controller.setBadgeImage(
            partial, label: "Partially imported", forBadgeIdentifier: Badge.partial
        )
    }

    private func badgeIdentifier(for url: URL) -> String {
        let isDirectory =
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard !isDirectory else { return Badge.none }

        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, trackedExtensions.contains(ext) else {
            return Badge.none
        }

        return index.contains(url) ? Badge.imported : Badge.notImported
    }

    private var trackedExtensions: Set<String> {
        SettingsStore.load(from: UserDefaults(suiteName: Ledger.appGroupIdentifier) ?? .standard)
            .extensions
    }

    private func updateWatchedDirectories() {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey],
            options: [.skipHiddenVolumes]
        ) ?? []

        let removable = volumes.filter { url in
            guard let values = try? url.resourceValues(
                forKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey]
            ) else { return false }
            return (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false)
        }

        FIFinderSyncController.default().directoryURLs = Set(removable)
        log.notice(
            "watching \(removable.map(\.path).joined(separator: ", "), privacy: .public)"
        )
    }

    @objc private func workspaceDidWake() {
        refreshIndex(force: true)
        startWatchingDestination()
    }

    @objc private func volumesChanged() {
        updateWatchedDirectories()
        refreshIndex(force: true)
        startWatchingDestination()
        for directory in observed {
            applyBadges(in: directory)
        }
    }

    private func startWatchingDestination() {
        let root = BackupIndex.snapshotURL().deletingLastPathComponent().standardizedFileURL
        if let destinationWatched, destinationWatched == root, destinationStream != nil {
            return
        }
        stopWatchingDestination()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let address = UInt(bitPattern: info)
            DispatchQueue.main.async {
                guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
                Unmanaged<BadgeExtension>.fromOpaque(pointer)
                    .takeUnretainedValue()
                    .destinationDidChange()
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            UInt32(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagWatchRoot
            )
        ) else {
            log.notice("cannot watch \(root.path, privacy: .public)")
            return
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            log.notice("cannot start watch on \(root.path, privacy: .public)")
            return
        }

        destinationStream = stream
        destinationWatched = root
        log.notice("watching destination \(root.path, privacy: .public)")
    }

    private func stopWatchingDestination() {
        guard let destinationStream else { return }
        FSEventStreamStop(destinationStream)
        FSEventStreamInvalidate(destinationStream)
        FSEventStreamRelease(destinationStream)
        self.destinationStream = nil
        destinationWatched = nil
    }

    private func destinationDidChange() {
        refreshIndex(force: true)
        for directory in observed {
            applyBadges(in: directory)
        }
    }

    private func refreshIndex(force: Bool = false) {
        let stamp = BackupIndex.modificationDate(of: BackupIndex.snapshotURL())
        if !force, let stamp, stamp == indexStamp { return }
        index = BackupIndex.loadSnapshot()
        indexStamp = stamp
        log.notice("index loaded: \(self.index.contentKeys.count, privacy: .public) entries")
    }

    private func applyBadges(in directory: URL) {
        let controller = FIFinderSyncController.default()
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            log.notice(
                "cannot enumerate \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            SharedSettings.reportBadgeFailure(
                "Cannot read \(directory.lastPathComponent): \(error.localizedDescription)"
            )
            return
        }
        SharedSettings.reportBadgeFailure(nil)

        var imported = 0
        var pending = 0
        for item in items {
            let identifier = badgeIdentifier(for: item)
            controller.setBadgeIdentifier(identifier, for: item)
            if identifier == Badge.imported { imported += 1 }
            if identifier == Badge.notImported { pending += 1 }
        }
        log.notice(
            "badged \(imported, privacy: .public) imported / \(pending, privacy: .public) pending of \(items.count, privacy: .public) in \(directory.path, privacy: .public)"
        )
    }

    override func beginObservingDirectory(at url: URL) {
        observed.insert(url)
        refreshIndex()
        applyBadges(in: url)
    }

    override func endObservingDirectory(at url: URL) {
        observed.remove(url)
    }

    override func requestBadgeIdentifier(for url: URL) {
        refreshIndex()
        FIFinderSyncController.default().setBadgeIdentifier(
            badgeIdentifier(for: url), for: url
        )
    }

    override var toolbarItemName: String { "SD Card Importer" }
    override var toolbarItemToolTip: String { "Show import status" }
    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "sdcard", accessibilityDescription: nil) ?? NSImage()
    }

    override func menu(for kind: FIMenuKind) -> NSMenu? {
        guard kind == .contextualMenuForItems || kind == .toolbarItemMenu else { return nil }
        let menu = NSMenu(title: "")

        if kind == .contextualMenuForItems {
            refreshIndex()
            let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
            let paths = selected.flatMap { index.destinations(for: $0) }
            let root = SharedSettings.destinationRoot().standardizedFileURL.path

            if paths.isEmpty {
                let item = menu.addItem(
                    withTitle: "Not imported", action: nil, keyEquivalent: ""
                )
                item.isEnabled = false
            } else {
                for path in paths.prefix(5) {
                    var shown = path
                    if shown.hasPrefix(root) {
                        shown = String(shown.dropFirst(root.count))
                        if shown.hasPrefix("/") { shown.removeFirst() }
                    }
                    let item = menu.addItem(
                        withTitle: "Imported to \(shown)",
                        action: #selector(revealFromMenu(_:)),
                        keyEquivalent: ""
                    )
                    item.representedObject = path
                    item.target = self
                }
                if paths.count > 5 {
                    let item = menu.addItem(
                        withTitle: "…and \(paths.count - 5) more", action: nil, keyEquivalent: ""
                    )
                    item.isEnabled = false
                }
            }
            menu.addItem(.separator())
        }

        menu.addItem(
            withTitle: "Refresh Import Status",
            action: #selector(refreshFromMenu(_:)),
            keyEquivalent: ""
        )
        return menu
    }

    @IBAction func revealFromMenu(_ sender: AnyObject?) {
        guard let path = (sender as? NSMenuItem)?.representedObject as? String else { return }
        NSWorkspace.shared.selectFile(
            path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent
        )
    }

    @IBAction func refreshFromMenu(_ sender: AnyObject?) {
        refreshIndex(force: true)
        updateWatchedDirectories()
        startWatchingDestination()
        for directory in observed {
            applyBadges(in: directory)
        }
    }
}
