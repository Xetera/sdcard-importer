import AppKit
import SwiftUI

@main
struct SDCardImporterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        SwiftUI.Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = AppModel()
    let updater = UpdaterModel()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var monitor: Any?
    private var appearanceObserver: NSKeyValueObservation?
    private var badgeState: (count: Int, title: String, isDark: Bool)?
    private static var imageCache: [ImageKey: NSImage] = [:]

    private struct ImageKey: Hashable {
        let count: Int
        let isDark: Bool
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ExtensionRegistrar.synchronize()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item
        refreshStatusBadge()

        appearanceObserver = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.refreshStatusBadge() }
        }

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        self.popover = popover

        model.onPopoverRequested = { [weak self] in
            self?.showMountPrompt()
        }

        model.onPopoverDismissRequested = { [weak self] in
            self?.popover?.performClose(nil)
        }

        model.onPendingVolumesChanged = { [weak self] in
            self?.refreshStatusBadge()
        }

        model.onStateChanged = { [weak self] in
            self?.refreshStatusBadge()
        }

        model.onImportFinished = { [weak self] summary, volumeName in
            self?.presentCompletion(summary, volumeName: volumeName)
        }

        model.start()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showFullMenu()
        }
    }

    func refreshStatusBadge() {
        guard let button = statusItem?.button else { return }

        let isDark = menuBarIsDark
        let count: Int
        let title: String
        let tooltip: String

        switch model.state {
        case let .importing(snapshot):
            count = 0
            title = " \(Int((snapshot.fraction * 100).rounded()))%"
            tooltip =
                "Importing \(snapshot.completedFiles)/\(snapshot.totalFiles) from \(snapshot.volume)"
        case let .cancelling(volume):
            count = 0
            title = " ⏹"
            tooltip = "Stopping import from \(volume)"
        case let .scanning(volume):
            count = 0
            title = " …"
            tooltip = "Scanning \(volume)"
        default:
            count = model.pendingVolumeList.count
            title = ""
            tooltip = count == 0
                ? "SD Card Importer"
                : "\(count) card\(count == 1 ? "" : "s") ready to import"
        }

        button.toolTip = tooltip

        if let badgeState, badgeState == (count, title, isDark) { return }
        badgeState = (count, title, isDark)
        button.title = title
        button.image = AppDelegate.statusImage(badge: count, isDark: isDark)
    }

    private func presentCompletion(_ summary: ImportSummary, volumeName: String) {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let alert = NSAlert()
        alert.alertStyle = summary.failed == 0 ? .informational : .warning
        if summary.cancelled {
            alert.messageText = "Stopped after \(summary.copied) files from \(volumeName)"
        } else {
            alert.messageText = summary.failed == 0
                ? "Imported \(summary.copied) files from \(volumeName)"
                : "Imported \(summary.copied), \(summary.failed) failed"
        }

        var parts = [formatter.string(fromByteCount: summary.copiedBytes)]
        if summary.cancelled, summary.remaining > 0 {
            parts.append("\(summary.remaining) not copied")
        }
        if summary.skipped > 0 { parts.append("\(summary.skipped) already imported") }
        if let failure = summary.firstFailure { parts.append(failure) }
        parts.append(summary.destinationRoot.path)
        alert.informativeText = parts.joined(separator: "\n")

        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Done")

        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.selectFile(
                nil, inFileViewerRootedAtPath: summary.destinationRoot.path
            )
        }
    }

    private static func statusImage(badge count: Int, isDark: Bool) -> NSImage? {
        let key = ImageKey(count: count, isDark: isDark)
        if let cached = imageCache[key] { return cached }

        guard let base = NSImage(
            systemSymbolName: "sdcard", accessibilityDescription: "SD Card Importer"
        ) else { return nil }
        guard count > 0 else {
            imageCache[key] = base
            return base
        }

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let icon = base.withSymbolConfiguration(config) ?? base
        let dot: CGFloat = 6
        let spacing: CGFloat = 1
        let size = NSSize(
            width: icon.size.width + spacing + dot,
            height: max(icon.size.height, dot)
        )
        let tint: NSColor = isDark ? .white : .black

        let composed = NSImage(size: size, flipped: false) { _ in
            let iconRect = NSRect(
                x: 0,
                y: (size.height - icon.size.height) / 2,
                width: icon.size.width,
                height: icon.size.height
            )
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
            tint.set()
            iconRect.fill(using: .sourceAtop)

            let rect = NSRect(
                x: size.width - dot,
                y: size.height - dot,
                width: dot,
                height: dot
            )
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        composed.isTemplate = false
        imageCache[key] = composed
        return composed
    }

    private var menuBarIsDark: Bool {
        let appearance = statusItem?.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    func showFullMenu() {
        present(NSHostingController(rootView: MenuContent(model: model, updater: updater)))
    }

    func showMountPrompt() {
        guard let volume = model.pendingVolumeList.first else {
            showFullMenu()
            return
        }
        present(NSHostingController(rootView: MountPromptView(model: model, volume: volume)))
    }

    private func present(_ controller: NSViewController, attempt: Int = 0) {
        guard let popover, let button = statusItem?.button else {
            appLog.notice("present: no popover or status button")
            return
        }

        let laidOut = (button.window?.frame.height ?? 0) > 0
            && button.bounds.width > 0
            && !button.isHiddenOrHasHiddenAncestor

        guard laidOut else {
            guard attempt < 40 else {
                appLog.notice("present: status button never laid out, giving up")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.present(controller, attempt: attempt + 1)
            }
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        }

        let frame = button.window?.frame ?? .zero
        appLog.notice(
            "present: active=\(NSApp.isActive, privacy: .public) hidden=\(button.isHiddenOrHasHiddenAncestor, privacy: .public) btnW=\(button.bounds.width, privacy: .public) winFrame=\(NSStringFromRect(frame), privacy: .public)"
        )

        popover.contentViewController = controller
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        appLog.notice("present: shown=\(popover.isShown, privacy: .public)")
    }

    private func installDismissMonitor() {
        removeDismissMonitor()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, let popover = self.popover, popover.isShown else { return }
                popover.performClose(nil)
            }
        }
    }

    private func removeDismissMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            appLog.notice("popoverDidClose")
            self.removeDismissMonitor()
        }
    }

    nonisolated func popoverDidShow(_ notification: Notification) {
        Task { @MainActor in
            appLog.notice("popoverDidShow")
            self.installDismissMonitor()
        }
    }
}

struct MenuContent: View {
    @Bindable var model: AppModel
    @ObservedObject var updater: UpdaterModel
    @State private var showingLedger = false

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if case let .importing(snapshot) = model.state {
                progressSection(snapshot)
            }

            ForEach(model.pendingVolumeList) { volume in
                MountPromptView(model: model, volume: volume, embedded: true)
                Divider()
            }

            destinationSection
            Divider()
            optionsSection
            Divider()
            ledgerSection
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
        .task { await model.refreshLedgerSummary() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sdcard")
            Text(model.statusSummary)
                .font(.callout)
                .lineLimit(2)
            Spacer()
        }
    }

    private func progressLine(_ snapshot: AppModel.ImportProgressSnapshot) -> String {
        var line = "\(snapshot.completedFiles)/\(snapshot.totalFiles) · "
            + Self.byteFormatter.string(fromByteCount: snapshot.copiedBytes) + " of "
            + Self.byteFormatter.string(fromByteCount: snapshot.totalBytes)
        if snapshot.skippedFiles > 0 {
            line += " · \(snapshot.skippedFiles) already imported"
        }
        return line
    }

    private func progressSection(_ snapshot: AppModel.ImportProgressSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: snapshot.fraction)
            Text(progressLine(snapshot))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let current = snapshot.currentFile {
                Text(current)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Spacer()
                Button("Stop", role: .destructive) { model.cancelImport() }
                    .controlSize(.small)
                    .disabled(!model.canCancelImport)
            }
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Destination").font(.caption.weight(.semibold))
            HStack {
                Text(model.settings.destinationRoot)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button("Change…") { model.chooseDestination() }
                    .controlSize(.small)
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("File types").font(.caption.weight(.semibold))
            HStack(spacing: 12) {
                ForEach(MediaCategory.allCases, id: \.self) { category in
                    Toggle(
                        category.title,
                        isOn: Binding(
                            get: { model.settings.includes(category) },
                            set: { on in model.settings.setIncluded(category, on) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
            }

            Toggle("Only cards with DCIM", isOn: $model.settings.requireDCIM)
            Toggle("Only removable volumes", isOn: $model.settings.requireRemovable)
            Toggle("Import without asking", isOn: $model.settings.autoImportWithoutPrompt)
            Toggle("Offer eject when done", isOn: $model.settings.offerEjectWhenDone)
        }
        .toggleStyle(.checkbox)
        .font(.caption)
    }

    private var ledgerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Ledger").font(.caption.weight(.semibold))
                Spacer()
                Button(showingLedger ? "Hide" : "Show") { showingLedger.toggle() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            Text(
                "\(model.totalsFiles) files · "
                    + Self.byteFormatter.string(fromByteCount: model.totalsBytes)
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if showingLedger {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.recentSessions) { session in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(session.volumeName).font(.caption.weight(.medium))
                                Text(
                                    "\(session.copiedCount) copied · \(session.skippedCount) skipped"
                                        + (session.failedCount > 0 ? " · \(session.failedCount) failed" : "")
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                Text(session.destinationRoot)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                    }
                }
                .frame(maxHeight: 140)

                Button("Reveal ledger.json") { model.revealLedgerFile() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
    }

    private func errorRow(_ message: String, tint: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            ScrollView {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(tint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 90)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Copy error")
        }
        .font(.caption2)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                )
            )
            .toggleStyle(.checkbox)
            .font(.caption)

            if let error = model.lastError {
                errorRow(error, tint: .red, icon: "exclamationmark.octagon.fill")
            }

            if let badgeFailure = model.badgeFailure {
                errorRow(
                    "Finder badges: \(badgeFailure)",
                    tint: .orange,
                    icon: "exclamationmark.triangle.fill"
                )
            }

            HStack {
                Button("Rescan") { model.rescanAttachedVolumes() }
                    .controlSize(.small)
                Button("Open folder") { model.openDestination() }
                    .controlSize(.small)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }

            HStack {
                CheckForUpdatesButton(updater: updater)
                Spacer()
            }
        }
    }
}
