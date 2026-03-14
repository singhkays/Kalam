import Foundation

enum TextCleanupGrammarMode: String, CaseIterable, Codable, Identifiable {
    case off
    case light
    case full

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .light:
            return "Light"
        case .full:
            return "Full"
        }
    }
}

struct TextCleanupConfiguration: Equatable, Codable {
    static let defaults = TextCleanupConfiguration(
        enabled: true,
        removeFillers: true,
        backtrack: true,
        listFormatting: true,
        punctuation: true,
        grammarMode: .light,
        grammarTimeoutMs: 100
    )

    var enabled: Bool
    var removeFillers: Bool
    var backtrack: Bool
    var listFormatting: Bool
    var punctuation: Bool
    var grammarMode: TextCleanupGrammarMode
    var grammarTimeoutMs: Int

    var boundedGrammarTimeoutMs: Int {
        min(400, max(25, grammarTimeoutMs))
    }

    private enum Keys {
        static let enabled = "textCleanup.enabled"
        static let removeFillers = "textCleanup.removeFillers"
        static let backtrack = "textCleanup.backtrack"
        static let listFormatting = "textCleanup.listFormatting"
        static let punctuation = "textCleanup.punctuation"
        static let grammarMode = "textCleanup.grammarMode"
        static let grammarTimeoutMs = "textCleanup.grammarTimeoutMs"
    }

    static func load(from defaults: UserDefaults = .standard) -> TextCleanupConfiguration {
        let modeRaw = defaults.string(forKey: Keys.grammarMode)
        let mode = modeRaw.flatMap(TextCleanupGrammarMode.init(rawValue:)) ?? Self.defaults.grammarMode

        return TextCleanupConfiguration(
            enabled: bool(forKey: Keys.enabled, defaults: defaults, fallback: Self.defaults.enabled),
            removeFillers: bool(forKey: Keys.removeFillers, defaults: defaults, fallback: Self.defaults.removeFillers),
            backtrack: bool(forKey: Keys.backtrack, defaults: defaults, fallback: Self.defaults.backtrack),
            listFormatting: bool(forKey: Keys.listFormatting, defaults: defaults, fallback: Self.defaults.listFormatting),
            punctuation: bool(forKey: Keys.punctuation, defaults: defaults, fallback: Self.defaults.punctuation),
            grammarMode: mode,
            grammarTimeoutMs: 100
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(removeFillers, forKey: Keys.removeFillers)
        defaults.set(backtrack, forKey: Keys.backtrack)
        defaults.set(listFormatting, forKey: Keys.listFormatting)
        defaults.set(punctuation, forKey: Keys.punctuation)
        defaults.set(grammarMode.rawValue, forKey: Keys.grammarMode)
        defaults.set(100, forKey: Keys.grammarTimeoutMs)
    }

    private static func bool(forKey key: String, defaults: UserDefaults, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    private static func int(forKey key: String, defaults: UserDefaults, fallback: Int) -> Int {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.integer(forKey: key)
    }
}
