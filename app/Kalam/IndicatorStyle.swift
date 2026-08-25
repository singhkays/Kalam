import Foundation

/// Visual style of the recording indicator (K-48).
/// Raw values are persisted; never rename a case's rawValue.
enum IndicatorStyle: String, CaseIterable, Codable, Sendable {
    case machined
    case whisper
    case caret

    var label: String {
        switch self {
        case .machined: "Machined instrument"
        case .whisper: "Whisper pill"
        case .caret: "At the caret"
        }
    }

    var subtitle: String {
        switch self {
        case .machined:
            "Dark deck, waveform hero, works everywhere"
        case .whisper:
            "Smallest footprint, follows light and dark"
        case .caret:
            "Feedback beside your text, falls back if unfound"
        }
    }

    /// Migrate stored values: anything unknown or absent falls back to machined.
    static func migrating(fromStored raw: String?) -> IndicatorStyle {
        switch raw {
        case "whisper": return .whisper
        case "caret": return .caret
        default: return .machined
        }
    }
}
