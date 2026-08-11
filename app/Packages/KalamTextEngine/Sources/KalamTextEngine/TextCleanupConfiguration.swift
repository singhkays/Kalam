import Foundation

public enum TextCleanupGrammarMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case off
    case light
    case full

    public var id: String { rawValue }

    public var displayName: String {
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

public struct TextCleanupConfiguration: Equatable, Codable, Sendable {
    public static let defaults = TextCleanupConfiguration(
        enabled: true,
        removeFillers: true,
        backtrack: true,
        listFormatting: true,
        punctuation: true,
        grammarMode: .light,
        grammarTimeoutMs: 100
    )

    public var enabled: Bool
    public var removeFillers: Bool
    public var backtrack: Bool
    public var listFormatting: Bool
    public var punctuation: Bool
    public var grammarMode: TextCleanupGrammarMode
    public var grammarTimeoutMs: Int

    public init(
        enabled: Bool,
        removeFillers: Bool,
        backtrack: Bool,
        listFormatting: Bool,
        punctuation: Bool,
        grammarMode: TextCleanupGrammarMode,
        grammarTimeoutMs: Int
    ) {
        self.enabled = enabled
        self.removeFillers = removeFillers
        self.backtrack = backtrack
        self.listFormatting = listFormatting
        self.punctuation = punctuation
        self.grammarMode = grammarMode
        self.grammarTimeoutMs = grammarTimeoutMs
    }

    public var boundedGrammarTimeoutMs: Int {
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

    public static func load(from defaults: UserDefaults = .standard) -> TextCleanupConfiguration {
        let modeRaw = defaults.string(forKey: Keys.grammarMode)
        let mode = modeRaw.flatMap(TextCleanupGrammarMode.init(rawValue:)) ?? Self.defaults.grammarMode

        return TextCleanupConfiguration(
            enabled: bool(forKey: Keys.enabled, defaults: defaults, fallback: Self.defaults.enabled),
            removeFillers: bool(forKey: Keys.removeFillers, defaults: defaults, fallback: Self.defaults.removeFillers),
            backtrack: bool(forKey: Keys.backtrack, defaults: defaults, fallback: Self.defaults.backtrack),
            listFormatting: bool(forKey: Keys.listFormatting, defaults: defaults, fallback: Self.defaults.listFormatting),
            punctuation: bool(forKey: Keys.punctuation, defaults: defaults, fallback: Self.defaults.punctuation),
            grammarMode: mode,
            grammarTimeoutMs: int(forKey: Keys.grammarTimeoutMs, defaults: defaults, fallback: Self.defaults.grammarTimeoutMs)
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(removeFillers, forKey: Keys.removeFillers)
        defaults.set(backtrack, forKey: Keys.backtrack)
        defaults.set(listFormatting, forKey: Keys.listFormatting)
        defaults.set(punctuation, forKey: Keys.punctuation)
        defaults.set(grammarMode.rawValue, forKey: Keys.grammarMode)
        defaults.set(boundedGrammarTimeoutMs, forKey: Keys.grammarTimeoutMs)
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
