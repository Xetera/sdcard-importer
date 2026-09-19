import Foundation
import UserNotifications

enum NotificationIDs {
    static let cardCategory = "SDCARD_DETECTED"
    static let doneCategory = "IMPORT_FINISHED"
    static let importAction = "IMPORT_NOW"
    static let ignoreAction = "IGNORE_CARD"
    static let ejectAction = "EJECT_VOLUME"
    static let revealAction = "REVEAL_FOLDER"
    static let volumePathKey = "volumePath"
    static let destinationKey = "destinationPath"
}

@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    var onImportRequested: ((URL) -> Void)?
    var onEjectRequested: ((URL) -> Void)?
    var onRevealRequested: ((URL) -> Void)?

    private var available: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    func configure() {
        guard available else {
            FileHandle.standardError.write(
                Data("notifications unavailable: not running from a signed .app bundle\n".utf8)
            )
            return
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let cardCategory = UNNotificationCategory(
            identifier: NotificationIDs.cardCategory,
            actions: [
                UNNotificationAction(
                    identifier: NotificationIDs.importAction,
                    title: "Import",
                    options: [.foreground]
                ),
                UNNotificationAction(
                    identifier: NotificationIDs.ignoreAction,
                    title: "Ignore",
                    options: [.destructive]
                ),
            ],
            intentIdentifiers: [],
            options: []
        )

        let doneCategory = UNNotificationCategory(
            identifier: NotificationIDs.doneCategory,
            actions: [
                UNNotificationAction(
                    identifier: NotificationIDs.revealAction,
                    title: "Show in Finder",
                    options: [.foreground]
                ),
                UNNotificationAction(
                    identifier: NotificationIDs.ejectAction,
                    title: "Eject",
                    options: []
                ),
            ],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([cardCategory, doneCategory])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                FileHandle.standardError.write(
                    Data("notification authorization failed: \(error)\n".utf8)
                )
            } else if !granted {
                FileHandle.standardError.write(Data("notification authorization denied\n".utf8))
            }
        }
    }

    func promptForCard(volume: MountedVolume, fileCount: Int, totalBytes: Int64) {
        guard available else { return }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let content = UNMutableNotificationContent()
        content.title = "SD card detected: \(volume.name)"
        content.body = "\(fileCount) new video files, \(formatter.string(fromByteCount: totalBytes))."
        content.categoryIdentifier = NotificationIDs.cardCategory
        content.userInfo = [NotificationIDs.volumePathKey: volume.url.path]
        content.sound = .default

        post(content, id: "card-\(volume.identifier)")
    }

    func announceFinished(summary: ImportSummary, volume: URL, volumeName: String, offerEject: Bool) {
        guard available else { return }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let content = UNMutableNotificationContent()
        content.title = summary.failed == 0
            ? "Imported \(summary.copied) files from \(volumeName)"
            : "Imported \(summary.copied), \(summary.failed) failed"
        var parts = [formatter.string(fromByteCount: summary.copiedBytes)]
        if summary.skipped > 0 { parts.append("\(summary.skipped) already imported") }
        if let failure = summary.firstFailure { parts.append(failure) }
        content.body = parts.joined(separator: " · ")
        content.categoryIdentifier = offerEject ? NotificationIDs.doneCategory : ""
        content.userInfo = [
            NotificationIDs.volumePathKey: volume.path,
            NotificationIDs.destinationKey: summary.destinationRoot.path,
        ]
        content.sound = .default

        post(content, id: "done-\(summary.sessionID.uuidString)")
    }

    func notifyFailure(_ message: String, volumeName: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Import failed: \(volumeName)"
        content.body = message
        content.sound = .default
        post(content, id: "fail-\(UUID().uuidString)")
    }

    private func post(_ content: UNNotificationContent, id: String) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                FileHandle.standardError.write(Data("notification post failed: \(error)\n".utf8))
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let volumePath = info[NotificationIDs.volumePathKey] as? String
        let destinationPath = info[NotificationIDs.destinationKey] as? String

        Task { @MainActor [weak self] in
            guard let self else { return }

            let volume = volumePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            let destination = destinationPath.map { URL(fileURLWithPath: $0, isDirectory: true) }

            switch action {
            case NotificationIDs.importAction, UNNotificationDefaultActionIdentifier:
                if let volume { self.onImportRequested?(volume) }
            case NotificationIDs.ejectAction:
                if let volume { self.onEjectRequested?(volume) }
            case NotificationIDs.revealAction:
                if let destination { self.onRevealRequested?(destination) }
            default:
                break
            }
        }

        completionHandler()
    }
}
