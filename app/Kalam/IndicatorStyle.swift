import Foundation

/// Visual style of the recording indicator (K-48).
/// Raw values are persisted; never rename a case's rawValue.
/// The at-the-caret chip was removed 2026-09-12 (rejected: AX
/// BoundsForRange only resolves in native NSText fields; Chromium/Electron
/// fall back to the deck everywhere, so the style promised what it could not
/// deliver). Stored "caret" values migrate to machined via migrating().
enum IndicatorStyle: String, CaseIterable, Codable, Sendable {
    case machined
    case whisper

    var label: String {
        switch self {
        case .machined: "Machined instrument"
        case .whisper: "Whisper pill"
        }
    }

    var subtitle: String {
        switch self {
        case .machined:
            "Dark deck, waveform hero, works everywhere"
        case .whisper:
            "Smallest footprint, follows light and dark"
        }
    }

    /// Migrate stored values: anything unknown or absent falls back to machined.
    static func migrating(fromStored raw: String?) -> IndicatorStyle {
        guard let raw else { return .machined }
        return IndicatorStyle(rawValue: raw) ?? .machined
    }
}
