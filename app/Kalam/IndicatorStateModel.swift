import CoreGraphics
import Foundation

/// Canonical states of the recording indicator lifecycle (K-48).
/// Raw values may be persisted; never rename a case's rawValue.
enum IndicatorState: String, Sendable {
    case listening
    case pausing
    case transcribing
    case held
    case blocked
}

/// What an indicator surface should show for a given state.
struct IndicatorPresentation: Sendable {
    var message: String
    var primaryActionTitle: String?
    var secondaryActionTitle: String?
    var showsWaveform: Bool
    var showsShimmer: Bool
}

/// Pure state model behind the recording indicator (K-48).
/// Deliberately AppKit-free and SwiftUI-free so it stays unit-testable;
/// views translate these values into pixels.
enum IndicatorStateModel {

    /// Fallback law: held/blocked ALWAYS present in machined form regardless of
    /// style, because actionable states need the full surface. Transient states
    /// render compact for whisper/caret only; machined is never compact.
    static func usesCompactSurface(style: IndicatorStyle, state: IndicatorState) -> Bool {
        switch state {
        case .listening, .pausing, .transcribing:
            return style != .machined
        case .held, .blocked:
            return false
        }
    }

    /// Canonical presentation for a state. Message copy contains no punctuation
    /// beyond the pinned strings below; do not add dashes or mid-dots.
    static func presentation(state: IndicatorState, targetApp: String) -> IndicatorPresentation {
        switch state {
        case .listening:
            IndicatorPresentation(
                message: "",
                primaryActionTitle: nil,
                secondaryActionTitle: nil,
                showsWaveform: true,
                showsShimmer: false
            )
        case .pausing:
            IndicatorPresentation(
                message: "",
                primaryActionTitle: nil,
                secondaryActionTitle: nil,
                showsWaveform: true,
                showsShimmer: false
            )
        case .transcribing:
            IndicatorPresentation(
                message: "Transcribing",
                primaryActionTitle: nil,
                secondaryActionTitle: nil,
                showsWaveform: false,
                showsShimmer: true
            )
        case .held:
            IndicatorPresentation(
                message: "Transcript ready, paste into \(targetApp)?",
                primaryActionTitle: "Paste",
                secondaryActionTitle: "Discard",
                showsWaveform: false,
                showsShimmer: false
            )
        case .blocked:
            IndicatorPresentation(
                message: "Microphone not available",
                primaryActionTitle: nil,
                secondaryActionTitle: "Open Settings",
                showsWaveform: false,
                showsShimmer: false
            )
        }
    }

    /// Pill width for compact surfaces: 200 listening/pausing, 150 transcribing.
    /// held/blocked keep the machined-form width even though they never render
    /// compact, so callers can size without branching on style first.
    static func compactWidth(state: IndicatorState) -> CGFloat {
        switch state {
        case .listening, .pausing: 200
        case .transcribing: 150
        case .held, .blocked: 290
        }
    }
}
