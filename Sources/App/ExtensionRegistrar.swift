import Foundation

enum ExtensionRegistrar {
    static let extensionIdentifier = "com.xetera.sdcardimporter.badges"

    private static var pluginKitURL: URL {
        URL(fileURLWithPath: "/usr/bin/pluginkit")
    }

    private static var extensionURL: URL? {
        Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("BadgeExtension.appex", isDirectory: true)
    }

    static func synchronize() {
        guard let extensionURL, FileManager.default.fileExists(atPath: extensionURL.path) else {
            SharedSettings.reportBadgeFailure("BadgeExtension.appex missing from app bundle")
            return
        }

        let state = registrationState()

        if state.registeredPath == extensionURL.path, state.enabled {
            SharedSettings.reportBadgeFailure(nil)
            return
        }

        if state.registeredPath != nil, state.registeredPath != extensionURL.path {
            _ = run(arguments: ["-r", state.registeredPath!])
        }

        let added = run(arguments: ["-a", extensionURL.path])
        guard added.status == 0 else {
            SharedSettings.reportBadgeFailure(
                "Could not register extension: \(added.output)"
            )
            return
        }

        let enabled = run(arguments: ["-e", "use", "-i", extensionIdentifier])
        guard enabled.status == 0 else {
            SharedSettings.reportBadgeFailure(
                "Could not enable extension: \(enabled.output)"
            )
            return
        }

        appLog.notice("registered badge extension at \(extensionURL.path, privacy: .public)")
        SharedSettings.reportBadgeFailure(nil)
    }

    private struct RegistrationState {
        var registeredPath: String?
        var enabled: Bool
    }

    private static func registrationState() -> RegistrationState {
        let result = run(arguments: ["-m", "-v", "-i", extensionIdentifier])
        guard result.status == 0 else {
            return RegistrationState(registeredPath: nil, enabled: false)
        }

        for line in result.output.split(separator: "\n") {
            guard line.contains(extensionIdentifier) else { continue }
            let enabled = line.trimmingCharacters(in: .whitespaces).hasPrefix("+")
            let fields = line.split(separator: "\t")
            guard let last = fields.last, fields.count >= 2 else {
                return RegistrationState(registeredPath: nil, enabled: enabled)
            }
            let path = last.trimmingCharacters(in: .whitespaces)
            return RegistrationState(
                registeredPath: path.hasPrefix("/") ? path : nil,
                enabled: enabled
            )
        }

        return RegistrationState(registeredPath: nil, enabled: false)
    }

    private static func run(arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = pluginKitURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (1, error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
