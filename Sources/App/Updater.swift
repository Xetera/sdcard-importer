import Sparkle
import SwiftUI

@MainActor
final class UpdaterModel: ObservableObject {
    private let controller: SPUStandardUpdaterController

    @Published private(set) var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updater: UpdaterModel

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
            .controlSize(.small)
    }
}
