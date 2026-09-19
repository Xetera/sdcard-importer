import Foundation

enum MediaCategory: String, CaseIterable, Codable {
    case video
    case image

    var extensions: [String] {
        switch self {
        case .video: return ["mp4", "mov", "mxf", "avi", "m4v", "insv"]
        case .image: return ["jpg", "jpeg", "png"]
        }
    }

    var title: String {
        switch self {
        case .video: return "Videos"
        case .image: return "Images"
        }
    }
}

struct Settings: Codable, Equatable {
    var destinationRoot: String
    var extensions: Set<String>
    var requireDCIM: Bool
    var requireRemovable: Bool
    var autoImportWithoutPrompt: Bool
    var offerEjectWhenDone: Bool
    var recentDestinations: [String] = []

    static let recentDestinationLimit = 5

    init(
        destinationRoot: String,
        extensions: Set<String>,
        requireDCIM: Bool,
        requireRemovable: Bool,
        autoImportWithoutPrompt: Bool,
        offerEjectWhenDone: Bool,
        recentDestinations: [String] = []
    ) {
        self.destinationRoot = destinationRoot
        self.extensions = extensions
        self.requireDCIM = requireDCIM
        self.requireRemovable = requireRemovable
        self.autoImportWithoutPrompt = autoImportWithoutPrompt
        self.offerEjectWhenDone = offerEjectWhenDone
        self.recentDestinations = recentDestinations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Settings.default
        destinationRoot =
            try container.decodeIfPresent(String.self, forKey: .destinationRoot)
            ?? fallback.destinationRoot
        extensions =
            try container.decodeIfPresent(Set<String>.self, forKey: .extensions)
            ?? fallback.extensions
        requireDCIM =
            try container.decodeIfPresent(Bool.self, forKey: .requireDCIM) ?? fallback.requireDCIM
        requireRemovable =
            try container.decodeIfPresent(Bool.self, forKey: .requireRemovable)
            ?? fallback.requireRemovable
        autoImportWithoutPrompt =
            try container.decodeIfPresent(Bool.self, forKey: .autoImportWithoutPrompt)
            ?? fallback.autoImportWithoutPrompt
        offerEjectWhenDone =
            try container.decodeIfPresent(Bool.self, forKey: .offerEjectWhenDone)
            ?? fallback.offerEjectWhenDone
        recentDestinations =
            try container.decodeIfPresent([String].self, forKey: .recentDestinations) ?? []
    }

    mutating func useDestination(_ path: String) {
        destinationRoot = path
        var updated = recentDestinations.filter { $0 != path }
        updated.insert(path, at: 0)
        recentDestinations = Array(updated.prefix(Settings.recentDestinationLimit))
    }

    var destinationChoices: [String] {
        var choices = recentDestinations.filter { $0 != destinationRoot }
        choices.insert(destinationRoot, at: 0)
        return Array(choices.prefix(Settings.recentDestinationLimit))
    }

    static let knownExtensions = MediaCategory.allCases.flatMap(\.extensions)

    func includes(_ category: MediaCategory) -> Bool {
        !extensions.isDisjoint(with: category.extensions)
    }

    mutating func setIncluded(_ category: MediaCategory, _ included: Bool) {
        if included {
            extensions.formUnion(category.extensions)
        } else {
            extensions.subtract(category.extensions)
        }
    }

    static let `default` = Settings(
        destinationRoot: FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Imports", isDirectory: true).path,
        extensions: Set(MediaCategory.video.extensions + MediaCategory.image.extensions),
        requireDCIM: true,
        requireRemovable: true,
        autoImportWithoutPrompt: false,
        offerEjectWhenDone: true
    )

    var destinationURL: URL {
        URL(fileURLWithPath: (destinationRoot as NSString).expandingTildeInPath, isDirectory: true)
    }

    func destination(forVolumeNamed name: String, date: Date = Date()) -> URL {
        destinationURL
    }
}

enum SettingsStore {
    private static let key = "settings.v1"

    static func load(from defaults: UserDefaults = .standard) -> Settings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data)
        else { return .default }
        return decoded
    }

    static func save(_ settings: Settings, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
        SharedSettings.setDestinationRoot(settings.destinationURL)
    }
}
