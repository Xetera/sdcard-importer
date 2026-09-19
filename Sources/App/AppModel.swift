import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import os

let appLog = Logger(subsystem: "com.xetera.sdcardimporter", category: "app")

@MainActor
@Observable
final class AppModel {
    enum State: Equatable {
        case idle
        case awaitingConfirmation(volume: String)
        case scanning(volume: String)
        case importing(ImportProgressSnapshot)
        case cancelling(volume: String)
        case finished(volume: String, copied: Int, failed: Int)
        case failed(String)
    }

    struct ImportProgressSnapshot: Equatable {
        var volume: String
        var completedFiles: Int
        var totalFiles: Int
        var skippedFiles: Int
        var copiedBytes: Int64
        var totalBytes: Int64
        var currentFile: String?
        var fraction: Double
    }

    var state: State = .idle {
        didSet { onStateChanged?() }
    }
    var settings: Settings {
        didSet { SettingsStore.save(settings) }
    }
    var recentSessions: [LedgerSession] = []
    var totalsFiles: Int = 0
    var totalsBytes: Int64 = 0
    var launchAtLoginEnabled: Bool = false
    var lastError: String?

    var onPopoverRequested: (() -> Void)?
    var onPopoverDismissRequested: (() -> Void)?
    var onPendingVolumesChanged: (() -> Void)?
    var onStateChanged: (() -> Void)?
    var onImportFinished: ((ImportSummary, String) -> Void)?

    private var systemProgress: Progress?

    private var pendingVolumes: [URL: MountedVolume] = [:] {
        didSet { onPendingVolumesChanged?() }
    }

    private let ledger = Ledger()
    private let notifications = NotificationCoordinator()
    private var watcher: VolumeWatcher?
    private var activeImport: Task<Void, Never>?
    private var ignoredVolumes: Set<String> = []
    private var knownVolumesByBSD: [String: Set<String>] = [:]

    init() {
        self.settings = SettingsStore.load()
        SharedSettings.setDestinationRoot(settings.destinationURL)
    }

    func start() {
        notifications.onImportRequested = { [weak self] url in
            Task { @MainActor in self?.beginImport(volumeAt: url) }
        }
        notifications.onEjectRequested = { [weak self] url in
            Task { @MainActor in self?.eject(url) }
        }
        notifications.onRevealRequested = { url in
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        }
        notifications.configure()

        watcher = VolumeWatcher(
            onMount: { [weak self] volume in
                Task { @MainActor in self?.handleMount(volume) }
            },
            onUnmount: { [weak self] bsd in
                Task { @MainActor in self?.handleUnmount(bsdName: bsd) }
            }
        )
        watcher?.onWorkspaceUnmount = { [weak self] url in
            Task { @MainActor in self?.handleUnmount(url: url) }
        }
        watcher?.start()
        appLog.notice("watcher started")

        refreshLaunchAtLoginStatus()
        Task { await refreshLedgerSummary() }
    }

    func handleMount(_ volume: MountedVolume) {
        appLog.notice(
            "handleMount \(volume.name, privacy: .public) at \(volume.url.path, privacy: .public) removable=\(volume.isRemovable, privacy: .public) ejectable=\(volume.isEjectable, privacy: .public) internal=\(volume.isInternal, privacy: .public)"
        )

        if let bsd = volume.bsdName {
            knownVolumesByBSD[bsd, default: []].insert(volume.identifier)
        }

        guard !ignoredVolumes.contains(volume.identifier) else {
            appLog.notice("skip: previously ignored")
            return
        }

        guard pendingVolumes[volume.url] == nil else {
            appLog.notice("skip: already pending")
            return
        }
        if settings.requireRemovable && !volume.isCandidate {
            appLog.notice("skip: not a removable candidate")
            return
        }
        if settings.requireDCIM && !VolumeScanner.looksLikeCameraCard(volume.url) {
            appLog.notice("skip: no DCIM/PRIVATE/CLIP/XDROOT")
            return
        }

        pendingVolumes[volume.url] = volume

        if settings.autoImportWithoutPrompt {
            appLog.notice("auto-importing")
            beginImport(volumeAt: volume.url)
        } else {
            appLog.notice("presenting mount prompt")
            state = .awaitingConfirmation(volume: volume.name)
            onPopoverRequested?()
        }
    }

    func handleUnmount(bsdName: String) {
        let identifiers = knownVolumesByBSD[bsdName]
        appLog.notice(
            "handleUnmount \(bsdName, privacy: .public) known=\(identifiers?.count ?? 0, privacy: .public)"
        )

        for identifier in identifiers ?? [] {
            ignoredVolumes.remove(identifier)
        }
        knownVolumesByBSD.removeValue(forKey: bsdName)

        for (url, volume) in pendingVolumes where volume.bsdName == bsdName {
            pendingVolumes.removeValue(forKey: url)
        }

        pruneUnmountedVolumes()
    }

    func handleUnmount(url: URL) {
        if let volume = pendingVolumes[url] {
            ignoredVolumes.remove(volume.identifier)
            pendingVolumes.removeValue(forKey: url)
        }
        for (bsd, identifiers) in knownVolumesByBSD {
            for identifier in identifiers where identifier == url.path {
                ignoredVolumes.remove(identifier)
                knownVolumesByBSD.removeValue(forKey: bsd)
            }
        }
        pruneUnmountedVolumes()
    }

    private func pruneUnmountedVolumes() {
        let fm = FileManager.default
        for (url, volume) in pendingVolumes where !fm.fileExists(atPath: url.path) {
            appLog.notice("pruning vanished volume \(volume.name, privacy: .public)")
            ignoredVolumes.remove(volume.identifier)
            pendingVolumes.removeValue(forKey: url)
        }
        if pendingVolumes.isEmpty, case .awaitingConfirmation = state {
            state = .idle
        }
    }

    func forgetIgnored(identifier: String) {
        ignoredVolumes.remove(identifier)
    }

    var pendingVolumeList: [MountedVolume] {
        pendingVolumes.values.sorted { $0.name < $1.name }
    }

    func rescanAttachedVolumes() {
        ignoredVolumes.removeAll()
        let volumes = VolumeWatcher.currentVolumes()
        appLog.notice("rescan: \(volumes.count, privacy: .public) mounted volumes")
        for volume in volumes where volume.isCandidate {
            handleMount(volume)
        }
    }

    func ignore(volumeAt url: URL) {
        if let volume = pendingVolumes[url] {
            appLog.notice("ignoring \(volume.name, privacy: .public)")
            ignoredVolumes.insert(volume.identifier)
        }
        pendingVolumes.removeValue(forKey: url)
        state = .idle
        onPopoverDismissRequested?()
    }

    func beginImport(volumeAt url: URL) {
        guard activeImport == nil else { return }
        guard let volume = pendingVolumes[url] else { return }

        let importer = Importer(ledger: ledger, settings: settings)
        let settings = settings
        let offerEject = settings.offerEjectWhenDone

        state = .scanning(volume: volume.name)
        onPopoverRequested?()

        activeImport = Task { [weak self] in
            let scan = await Task.detached(priority: .userInitiated) {
                VolumeScanner.scan(volume: volume.url, settings: settings)
            }.value

            guard let self else { return }

            if scan.isEmpty {
                await MainActor.run {
                    self.state = .finished(volume: volume.name, copied: 0, failed: 0)
                    self.pendingVolumes.removeValue(forKey: volume.url)
                    self.activeImport = nil
                }
                return
            }

            await MainActor.run {
                self.beginSystemProgress(
                    volumeName: volume.name,
                    totalBytes: scan.totalBytes,
                    destination: settings.destination(forVolumeNamed: volume.name)
                )
                self.state = .importing(
                    ImportProgressSnapshot(
                        volume: volume.name,
                        completedFiles: 0,
                        totalFiles: scan.files.count,
                        skippedFiles: 0,
                        copiedBytes: 0,
                        totalBytes: scan.totalBytes,
                        currentFile: nil,
                        fraction: 0
                    )
                )
            }

            do {
                let summary = try await importer.run(
                    volume: volume.url,
                    volumeName: volume.name,
                    volumeIdentifier: volume.identifier,
                    scan: scan,
                    progress: { progress in
                        Task { @MainActor in
                            self.systemProgress?.completedUnitCount = progress.copiedBytes
                            self.state = .importing(
                                ImportProgressSnapshot(
                                    volume: volume.name,
                                    completedFiles: progress.completedFiles,
                                    totalFiles: progress.totalFiles,
                                    skippedFiles: progress.skippedFiles,
                                    copiedBytes: progress.copiedBytes,
                                    totalBytes: progress.totalBytes,
                                    currentFile: progress.currentFile,
                                    fraction: progress.fraction
                                )
                            )
                        }
                    }
                )

                await MainActor.run {
                    self.endSystemProgress()
                    self.state = .finished(
                        volume: volume.name, copied: summary.copied, failed: summary.failed
                    )
                    self.pendingVolumes.removeValue(forKey: volume.url)
                    self.notifications.announceFinished(
                        summary: summary,
                        volume: volume.url,
                        volumeName: volume.name,
                        offerEject: offerEject
                    )
                    self.onImportFinished?(summary, volume.name)
                    self.activeImport = nil
                }
                await self.refreshLedgerSummary()
            } catch {
                await MainActor.run {
                    self.endSystemProgress()
                    let message = error.localizedDescription
                    self.state = .failed(message)
                    self.lastError = message
                    self.notifications.notifyFailure(message, volumeName: volume.name)
                    self.activeImport = nil
                }
            }
        }
    }

    func cancelImport() {
        guard let activeImport, !activeImport.isCancelled else { return }
        appLog.notice("cancelling active import")
        if case let .importing(snapshot) = state {
            state = .cancelling(volume: snapshot.volume)
        }
        activeImport.cancel()
    }

    var canCancelImport: Bool {
        switch state {
        case .importing, .scanning: return activeImport != nil
        default: return false
        }
    }

    private func beginSystemProgress(volumeName: String, totalBytes: Int64, destination: URL) {
        endSystemProgress()
        let progress = Progress(parent: nil, userInfo: [
            .fileOperationKindKey: Progress.FileOperationKind.copying,
            .fileURLKey: destination,
        ])
        progress.kind = .file
        progress.isCancellable = true
        progress.isPausable = false
        progress.cancellationHandler = { [weak self] in
            Task { @MainActor in self?.cancelImport() }
        }
        progress.totalUnitCount = totalBytes
        progress.completedUnitCount = 0
        progress.publish()
        systemProgress = progress
    }

    private func endSystemProgress() {
        systemProgress?.unpublish()
        systemProgress = nil
    }

    func eject(_ url: URL) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            lastError = nil
        } catch {
            lastError = "Could not eject \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    var badgeFailure: String? {
        SharedSettings.badgeFailure()
    }

    func refreshLedgerSummary() async {
        let sessions = await ledger.recentSessions()
        let totals = await ledger.totals()
        recentSessions = sessions
        totalsFiles = totals.files
        totalsBytes = totals.bytes
    }

    func revealLedgerFile() {
        Task {
            let url = await ledger.url
            await MainActor.run {
                _ = NSWorkspace.shared.selectFile(
                    url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path
                )
            }
        }
    }

    func openDestination() {
        NSWorkspace.shared.open(settings.destinationURL)
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.destinationURL
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            settings.useDestination(url.path)
        }
    }

    func selectDestination(_ path: String) {
        settings.useDestination(path)
    }

    func pendingImportSize(
        for volume: MountedVolume
    ) async -> (files: Int, bytes: Int64, alreadyImported: Int) {
        let settings = settings
        return await Task.detached(priority: .userInitiated) {
            let scan = VolumeScanner.scan(volume: volume.url, settings: settings)
            let existing = BackupIndex.load(
                from: settings.destination(forVolumeNamed: volume.name)
            )
            existing.writeSnapshot()
            var files = 0
            var bytes: Int64 = 0
            var alreadyImported = 0
            for file in scan.files {
                if existing.contains(file.url) {
                    alreadyImported += 1
                } else {
                    files += 1
                    bytes += file.byteCount
                }
            }
            return (files, bytes, alreadyImported)
        }.value
    }

    func lastImportSummary(for volume: MountedVolume) async -> String? {
        guard let last = await ledger.lastImport(forVolumeIdentifier: volume.identifier) else {
            return nil
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: last.date, relativeTo: Date())
        return "\(last.files) files \(when)"
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = "Login item change failed: \(error.localizedDescription)"
        }
        refreshLaunchAtLoginStatus()
    }

    var statusSummary: String {
        switch state {
        case .idle:
            return "Watching for cards"
        case let .scanning(volume):
            return "Scanning \(volume)…"
        case let .awaitingConfirmation(volume):
            return "\(volume) ready to import"
        case let .importing(snapshot):
            return "Importing \(snapshot.completedFiles)/\(snapshot.totalFiles) from \(snapshot.volume)"
        case let .cancelling(volume):
            return "Stopping \(volume)…"
        case let .finished(volume, copied, failed):
            return failed == 0
                ? "Imported \(copied) from \(volume)"
                : "Imported \(copied), \(failed) failed"
        case let .failed(message):
            return message
        }
    }

    var isBusy: Bool {
        switch state {
        case .importing, .scanning, .cancelling: return true
        default: return false
        }
    }
}
