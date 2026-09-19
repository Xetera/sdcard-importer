import AppKit
import DiskArbitration
import Foundation
import os

let watcherLog = Logger(subsystem: "com.xetera.sdcardimporter", category: "watcher")

struct MountedVolume: Hashable, Identifiable {
    var id: String { identifier }

    let url: URL
    let name: String
    let identifier: String
    let isRemovable: Bool
    let isEjectable: Bool
    let isInternal: Bool
    let bsdName: String?

    var isCandidate: Bool {
        isRemovable || isEjectable
    }
}

final class VolumeWatcher: @unchecked Sendable {
    private var session: DASession?
    private let queue = DispatchQueue(label: "sdcardimporter.diskarbitration")
    private let onMount: @Sendable (MountedVolume) -> Void
    private let onUnmount: @Sendable (String) -> Void
    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?

    var onWorkspaceUnmount: (@Sendable (URL) -> Void)?

    init(
        onMount: @escaping @Sendable (MountedVolume) -> Void,
        onUnmount: @escaping @Sendable (String) -> Void
    ) {
        self.onMount = onMount
        self.onUnmount = onUnmount
    }

    func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session

        let context = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(
            session,
            nil,
            { disk, context in
                guard let context else { return }
                let watcher = Unmanaged<VolumeWatcher>.fromOpaque(context).takeUnretainedValue()
                let bsd = DADiskGetBSDName(disk).map { String(cString: $0) } ?? "?"
                guard let volume = VolumeWatcher.describe(disk) else {
                    watcherLog.notice("appeared \(bsd, privacy: .public): no volume path, ignored")
                    return
                }
                watcherLog.notice(
                    "appeared \(bsd, privacy: .public) -> \(volume.url.path, privacy: .public)"
                )
                let handler = watcher.onMount
                DispatchQueue.main.async { handler(volume) }
            },
            context
        )

        DARegisterDiskDisappearedCallback(
            session,
            nil,
            { disk, context in
                guard let context else { return }
                let watcher = Unmanaged<VolumeWatcher>.fromOpaque(context).takeUnretainedValue()
                guard let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }) else {
                    watcherLog.notice("disappeared: no BSD name, ignored")
                    return
                }
                watcherLog.notice("disappeared \(bsd, privacy: .public)")
                let handler = watcher.onUnmount
                DispatchQueue.main.async { handler(bsd) }
            },
            context
        )

        let watchedKeys = [kDADiskDescriptionVolumePathKey] as CFArray
        DARegisterDiskDescriptionChangedCallback(
            session,
            nil,
            watchedKeys,
            { disk, _, context in
                guard let context else { return }
                let watcher = Unmanaged<VolumeWatcher>.fromOpaque(context).takeUnretainedValue()
                let bsd = DADiskGetBSDName(disk).map { String(cString: $0) } ?? "?"
                guard let volume = VolumeWatcher.describe(disk) else {
                    watcherLog.notice("changed \(bsd, privacy: .public): path cleared")
                    let handler = watcher.onUnmount
                    DispatchQueue.main.async { handler(bsd) }
                    return
                }
                watcherLog.notice(
                    "changed \(bsd, privacy: .public) -> \(volume.url.path, privacy: .public)"
                )
                let handler = watcher.onMount
                DispatchQueue.main.async { handler(volume) }
            },
            context
        )

        DASessionSetDispatchQueue(session, queue)

        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            else { return }
            watcherLog.notice("workspace didMount \(url.path, privacy: .public)")
            guard let volume = VolumeWatcher.currentVolumes().first(where: {
                $0.url.standardizedFileURL == url.standardizedFileURL
            }) else { return }
            self.onMount(volume)
        }

        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            else { return }
            watcherLog.notice("workspace didUnmount \(url.path, privacy: .public)")
            self.onWorkspaceUnmount?(url)
        }
    }

    func stop() {
        if let mountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(mountObserver)
        }
        if let unmountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(unmountObserver)
        }
        mountObserver = nil
        unmountObserver = nil

        guard let session else { return }
        DASessionSetDispatchQueue(session, nil)
        self.session = nil
    }

    deinit { stop() }

    static func describe(_ disk: DADisk) -> MountedVolume? {
        guard let description = DADiskCopyDescription(disk) as? [CFString: Any] else { return nil }
        guard let path = description[kDADiskDescriptionVolumePathKey] as? URL else { return nil }

        let name = description[kDADiskDescriptionVolumeNameKey] as? String
            ?? path.lastPathComponent
        let removable = description[kDADiskDescriptionMediaRemovableKey] as? Bool ?? false
        let ejectable = description[kDADiskDescriptionMediaEjectableKey] as? Bool ?? false
        let deviceInternal = description[kDADiskDescriptionDeviceInternalKey] as? Bool ?? false
        let bsd = DADiskGetBSDName(disk).map { String(cString: $0) }

        let uuid = (description[kDADiskDescriptionVolumeUUIDKey].map {
            CFUUIDCreateString(kCFAllocatorDefault, ($0 as! CFUUID)) as String
        }) ?? bsd ?? path.path

        return MountedVolume(
            url: path,
            name: name,
            identifier: uuid,
            isRemovable: removable,
            isEjectable: ejectable,
            isInternal: deviceInternal,
            bsdName: bsd
        )
    }

    static func currentVolumes() -> [MountedVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeIsInternalKey, .volumeUUIDStringKey,
        ]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) ?? []

        return mounted.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return MountedVolume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                identifier: values.volumeUUIDString ?? url.path,
                isRemovable: values.volumeIsRemovable ?? false,
                isEjectable: values.volumeIsEjectable ?? false,
                isInternal: values.volumeIsInternal ?? false,
                bsdName: nil
            )
        }
    }
}
