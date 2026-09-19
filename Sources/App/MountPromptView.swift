import AppKit
import SwiftUI

struct MountPromptView: View {
    @Bindable var model: AppModel
    let volume: MountedVolume
    var embedded: Bool = false

    @State private var lastImport: String?
    @State private var loadedHistory = false
    @State private var pendingSize: (files: Int, bytes: Int64, alreadyImported: Int)?
    @State private var loadedSize = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sdcard.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(volume.name)
                        .font(.headline)
                    Text(historyLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Import to")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: destinationBinding) {
                    ForEach(model.settings.destinationChoices, id: \.self) { path in
                        Text(displayName(path)).tag(path)
                    }
                    Divider()
                    Text("Choose…").tag(MountPromptView.choosePath)
                }
                .labelsHidden()
                .controlSize(.small)
            }

            Text(sizeLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if model.canCancelImport {
                    Button("Stop", role: .destructive) { model.cancelImport() }
                } else {
                    Button("Import") { model.beginImport(volumeAt: volume.url) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isBusy || !loadedSize || pendingSize?.files == 0)
                }
                Button(embedded ? "Ignore" : "Not now") { model.ignore(volumeAt: volume.url) }
                Spacer(minLength: 0)
            }
        }
        .padding(embedded ? 0 : 14)
        .frame(width: embedded ? nil : 260)
        .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
        .task {
            guard !loadedHistory else { return }
            loadedHistory = true
            lastImport = await model.lastImportSummary(for: volume)
        }
        .task(id: model.settings.extensions) {
            loadedSize = false
            pendingSize = nil
            let scanned = await model.pendingImportSize(for: volume)
            guard !Task.isCancelled else { return }
            pendingSize = scanned
            loadedSize = true
        }
    }

    private static let choosePath = "\u{0}choose"

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private var sizeLine: String {
        guard let pendingSize else {
            return loadedSize ? "Nothing to import" : "Calculating size…"
        }
        guard pendingSize.files > 0 else {
            return pendingSize.alreadyImported > 0
                ? "All \(pendingSize.alreadyImported) files already imported"
                : "Nothing to import"
        }
        let size = MountPromptView.byteFormatter.string(fromByteCount: pendingSize.bytes)
        let noun = pendingSize.files == 1 ? "file" : "files"
        var line = "\(pendingSize.files) new \(noun) · \(size)"
        if pendingSize.alreadyImported > 0 {
            line += "\n\(pendingSize.alreadyImported) already imported"
        }
        return line
    }

    private var historyLine: String {
        if let lastImport {
            return "Last import: \(lastImport)"
        }
        return loadedHistory ? "Never imported" : "Checking…"
    }

    private var destinationBinding: Binding<String> {
        Binding(
            get: { model.settings.destinationRoot },
            set: { selection in
                if selection == MountPromptView.choosePath {
                    model.chooseDestination()
                } else {
                    model.selectDestination(selection)
                }
            }
        )
    }

    private func displayName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            let trimmed = String(path.dropFirst(home.count))
            return "~" + trimmed
        }
        return url.lastPathComponent.isEmpty ? path : url.path
    }
}
