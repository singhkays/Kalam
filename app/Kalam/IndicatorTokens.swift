import SwiftUI

/// Single source of indicator geometry, color, and typography (plan §5.1).
/// Values mirror the shipped AppKit surfaces exactly so both content paths can
/// be diffed during the parity pass. Change both worlds together or not at all.
enum IndicatorTokens {
    // MARK: Geometry (the controller owns window chrome sizing)
    static let machinedWidth: CGFloat = IndicatorStateModel.machinedFormWidth
    static let deckHeight: CGFloat = 72
    static let compactHeight: CGFloat = 34
    static let pillHeight: CGFloat = 30
    static let caretChipWidth: CGFloat = 84
    static let cornerRadius: CGFloat = 14
    static let pillCornerRadius: CGFloat = 15
    static let hPadding: CGFloat = 12
    static let waveformHeight: CGFloat = 39
    static let waveformTopSpacing: CGFloat = 4
    static let topRowHeight: CGFloat = 20
    static let topRowTopPadding: CGFloat = 7

    // MARK: Waveform bars
    static let barWidth: CGFloat = 2.5
    static let barGap: CGFloat = 1.5
    static let entryFraction: CGFloat = 0.98
    static let waveformVPadding: CGFloat = 4
    static let barAlphaFloor: CGFloat = 0.45
    static let barAlphaCeiling: CGFloat = 0.95

    // MARK: Level glyph
    static let glyphSize = CGSize(width: 14, height: 12)
    static let glyphBarWidth: CGFloat = 2.5
    static let glyphBarGap: CGFloat = 2.0
    static let glyphMinBarHeight: CGFloat = 3.0

    // MARK: Ring (contrast-remedy spec)
    static let ringLineWidth: CGFloat = 1.5
    static let ringGlowWidth: CGFloat = 6
    static let ringGlowOpacity: Double = 0.38
    static let ringStaticOpacity: Double = 0.48
    static let ringListeningPeriod: Double = 3.6
    static let ringTranscribingPeriod: Double = 2.4

    /// Ring gating law (D-2, owner correction 2026-09-09): the moving ring is
    /// transcribing-only — the whisper pill's listening state shows no ring and
    /// no glow. Matches the AppKit gate in transition(to:).
    static func ringPeriod(style: IndicatorStyle, canonicalState: IndicatorState?) -> Double? {
        canonicalState == .transcribing ? ringTranscribingPeriod : nil
    }

    /// Owner finding 2026-09-09: the SwiftUI glow twin rendered the full stadium
    /// perimeter at constant opacity (only the arc rotated), a constant blur
    /// ring the mockup never had. The glow is arc-bound: visible exactly when
    /// the ring is visible, and nowhere else.
    static func ringGlowVisible(style: IndicatorStyle, canonicalState: IndicatorState?) -> Bool {
        ringPeriod(style: style, canonicalState: canonicalState) != nil
    }

    // MARK: Shimmer + recording dot
    static let shimmerDotSize: CGFloat = 4
    static let shimmerDotSpacing: CGFloat = 3
    static let shimmerOpacityFloor: Double = 0.55
    static let shimmerCycleDuration: Double = 0.6
    static let shimmerStagger: Double = 0.2
    static let recordingDotSize: CGFloat = 7

    // MARK: Color (K-48 machined palette — every surface is always dark)
    static let brandGreen = Color(red: 82 / 255.0, green: 183 / 255.0, blue: 136 / 255.0)
    static let obsidian = Color(white: 0.11)
    static let surfaceBorder = Color.white.opacity(0.14)
    static let rimStroke = Color.black.opacity(0.18)

    // MARK: Typography (deck 13pt row + 11pt timer; compact 12pt + 10.5pt)
    static func appNameFont(compact: Bool) -> Font {
        .system(size: compact ? 12 : 13, weight: .semibold)
    }

    static func timerFont(compact: Bool) -> Font {
        .system(size: compact ? 10.5 : 11, weight: .medium).monospacedDigit()
    }

    static let messageFont = Font.system(size: 13, weight: .semibold)
    static let buttonFont = Font.system(size: 11, weight: .semibold)
    static let chipTimerFont = Font.system(size: 10.5, weight: .medium).monospacedDigit()
}