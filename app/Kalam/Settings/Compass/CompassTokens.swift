import AppKit
import SwiftUI

// MARK: - Color tokens (Fog card · locked)
// paper F3F3EF · panel/control FCFBF9 · well EFEEEB · hair DFDFD8 · green 1A5C3A
// Palette lab is archive only: compass-spec/palette-lab.html

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let n = UInt32(h, radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((n >> 16) & 0xFF) / 255,
            green: Double((n >> 8) & 0xFF) / 255,
            blue: Double(n & 0xFF) / 255
        )
    }

    static let kPaper = Color(hex: "F3F3EF")
    static let kPanel = Color(hex: "FCFBF9")
    /// Inset well (search, dictionary editor, sample strips). Distinct from paper and panel.
    static let kWell = Color(hex: "EFEEEB")
    /// Fields/chips inside cards — same as panel, never pure white.
    static let kControl = Color.kPanel
    static let kInk = Color(hex: "1F1D17")
    static let kInk2 = Color(hex: "5B564A")
    static let kInk3 = Color(hex: "8F8878")
    static let kHair = Color(hex: "DFDFD8")
    static let kHair2 = Color(hex: "EAEAE3")
    static let kGreen = Color(hex: "1A5C3A")
    static let kGreenD = Color(hex: "0F3C24")
    static let kGreenT = Color.kGreen.opacity(0.08)
    static let kOff = Color(hex: "D4D4CC")
}

// MARK: - Typography (K-31: web-brand families; system fonts are the fallback)
//
// K-31 (2026-08-13, user-authorized deviation from the spec's "LOCKED — do not improvise"
// rule): the Compass settings window carries the landing-page brand typography —
//   .serif  → Instrument Serif    (map/dive display, map-card titles, updates figure)
//   .sans   → Plus Jakarta Sans   (body, UI chrome; variable wght 200–800, exact weights)
//   .mono   → IBM Plex Mono       (kickers, ranks, states, hotkey symbols, code paths)
// Fonts are bundled OFL assets registered at launch (FontRegistration); the system
// design families (New York / SF Pro / SF Mono) remain the degraded fallback path.
//
// NEVER use: Inter, Roboto, Helvetica, Geist, Clash, or any other bundled UI font.
// NEVER use Font.Weight.bold (700) for card headers — mockup is weight 640.
// NEVER use .title / .headline / .body text styles — they fight the fixed utility chrome.
//
// Non-standard weights (560, 640) resolve exactly via the Plus Jakarta Sans wght axis.
// Tracking values are point offsets ≈ CSS em * fontSize (e.g. -0.022em * 32 ≈ -0.70).

enum CompassFont {
    enum Family {
        case serif, sans, mono
    }

    /// Preferred entry point. `weight` is 100…900 (CSS-like). Common: 400 regular, 500 medium,
    /// 560 chapter title, 600 semibold, 640 card header label. Falls back to the system
    /// design family when the bundled face is unavailable.
    static func variable(_ family: Family, size: CGFloat, weight: CGFloat) -> Font {
        let w = min(900, max(100, weight))
        switch family {
        case .serif:
            // Instrument Serif: 400 only (no heavier faces); the italic face is displayItalic.
            if let f = NSFont(name: "InstrumentSerif-Regular", size: size) {
                return Font(f)
            }
        case .sans:
            // Plus Jakarta Sans variable — exact CSS-like weight via the wght variation axis.
            if let base = NSFont(name: "PlusJakartaSans-Regular", size: size) {
                let desc = base.fontDescriptor.addingAttributes([.variation: ["wght": w]])
                if let f = NSFont(descriptor: desc, size: size) {
                    return Font(f)
                }
            }
        case .mono:
            // IBM Plex Mono static faces.
            let name: String
            switch w {
            case ..<450: name = "IBMPlexMono-Regular"
            case ..<550: name = "IBMPlexMono-Medium"
            default: name = "IBMPlexMono-SemiBold"
            }
            if let f = NSFont(name: name, size: size) {
                return Font(f)
            }
        }
        return fallback(family, size: size, weight: w)
    }

    /// Real italic face (Instrument Serif Italic) for hero/display emphasis — never faux.
    static func displayItalic(_ size: CGFloat) -> Font {
        if let f = NSFont(name: "InstrumentSerif-Italic", size: size) {
            return Font(f)
        }
        return .system(size: size, design: .serif).italic()
    }

    /// Degraded path: system design font at the probe-verified anchor weight mapping.
    private static func fallback(_ family: Family, size: CGFloat, weight: CGFloat) -> Font {
        let design: NSFontDescriptor.SystemDesign
        switch family {
        case .serif: design = .serif
        case .sans: design = .default
        case .mono: design = .monospaced
        }
        let base = NSFont.systemFont(ofSize: size)
        guard var desc = base.fontDescriptor.withDesign(design) else {
            return systemNamed(family, size: size, weight: weight)
        }
        desc = desc.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: nsWeight(weight)]
        ])
        guard let ns = NSFont(descriptor: desc, size: size) else {
            return systemNamed(family, size: size, weight: weight)
        }
        return Font(ns)
    }

    private static func systemNamed(_ family: Family, size: CGFloat, weight: CGFloat) -> Font {
        let w = nearestWeight(weight)
        switch family {
        case .serif: return .system(size: size, weight: w, design: .serif)
        case .sans: return .system(size: size, weight: w, design: .default)
        case .mono: return .system(size: size, weight: w, design: .monospaced)
        }
    }

    /// CSS weight → NSFontDescriptor weight trait. Probe-verified 2026-08-13 (K-31 plan §5.3):
    /// anchors are the NSFont.Weight raw values; linear between. The old linear formula
    /// (w−400)/500×0.8 rendered 640 → wght ≈ 682 (near-bold) vs the mockup's true 640.
    private static func nsWeight(_ w: CGFloat) -> CGFloat {
        let anchors: [(CGFloat, CGFloat)] = [(400, 0.0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62)]
        let clamped = min(900, max(100, w))
        for i in 0..<(anchors.count - 1) {
            let (w0, t0) = anchors[i]
            let (w1, t1) = anchors[i + 1]
            if clamped >= w0, clamped <= w1 {
                return t0 + (clamped - w0) / (w1 - w0) * (t1 - t0)
            }
        }
        return anchors.last!.1
    }

    private static func nearestWeight(_ w: CGFloat) -> Font.Weight {
        switch w {
        case ..<450: return .regular
        case ..<530: return .medium
        case ..<580: return .semibold // 560 sits nearer semibold than medium for SF
        case ..<650: return .semibold
        case ..<750: return .bold
        default: return .bold
        }
    }

    // Convenience wrappers (weight 400 unless noted)
    static func display(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        variable(.serif, size: size, weight: weight)
    }

    static func body(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        variable(.sans, size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        variable(.mono, size: size, weight: weight)
    }
}

/// Named roles — USE THESE. Do not pick sizes ad hoc in views.
enum CompassType {
    // MARK: Sizes (pt)
    static let mapHero: CGFloat = 32
    static let diveDisplay: CGFloat = 30          // NOT 32
    static let mapCardTitle: CGFloat = 19
    static let mapCardTitleLarge: CGFloat = 22
    static let mapFootTitle: CGFloat = 15
    static let modelName: CGFloat = 20
    static let updatesFigure: CGFloat = 44

    static let windowBody: CGFloat = 13.5
    static let barWordmark: CGFloat = 12
    static let backButton: CGFloat = 12.5
    static let needCTA: CGFloat = 14
    static let mapLede: CGFloat = 13.5
    static let diveLede: CGFloat = 13.5

    static let mapKicker: CGFloat = 11
    static let diveKicker: CGFloat = 9.5
    static let cardHeaderLabel: CGFloat = 11
    static let cardHeaderState: CGFloat = 9.5
    static let privacy: CGFloat = 9.5

    static let rowTitle: CGFloat = 13.5
    static let rowDetail: CGFloat = 11.5
    static let mapCardKicker: CGFloat = 9.5
    static let mapCardBody: CGFloat = 12
    static let mapOpenHint: CGFloat = 12
    static let mapCardNum: CGFloat = 9.5
    static let mapCardState: CGFloat = 9

    static let contentsIndex: CGFloat = 10
    static let contentsTitle: CGFloat = 13
    static let contentsSubtitle: CGFloat = 10.5
    static let contentsState: CGFloat = 10

    static let modeTitle: CGFloat = 13.5
    static let modeDetail: CGFloat = 11.5
    static let micName: CGFloat = 13.5
    static let micRank: CGFloat = 11
    static let statusTag: CGFloat = 10

    static let btnLabel: CGFloat = 12.5
    static let segment: CGFloat = 12
    static let hotkeyChip: CGFloat = 12.5
    static let hotkeyMenu: CGFloat = 13
    static let dictSearch: CGFloat = 13
    static let dictField: CGFloat = 13.5
    static let dictSpoken: CGFloat = 13
    static let dictTyped: CGFloat = 13.5
    static let dictLabel: CGFloat = 9
    static let coverChip: CGFloat = 11
    static let whyLabel: CGFloat = 9
    static let whyBody: CGFloat = 12.5
    static let sampleWellLabel: CGFloat = 8.5
    static let sampleWellBody: CGFloat = 11.5
    static let trackSampleWellLabel: CGFloat = 1.53 // 0.18em * 8.5
    static let emptyTitle: CGFloat = 15
    static let emptyBody: CGFloat = 13

    // MARK: Tracking (points) ≈ CSS letter-spacing em × size
    static let trackMapHero: CGFloat = -0.70      // -0.022em * 32
    static let trackDiveDisplay: CGFloat = -0.66  // -0.022em * 30
    static let trackMapCardTitle: CGFloat = -0.23 // -0.012em * 19
    static let trackMapFootTitle: CGFloat = -0.15 // -0.01em * 15
    static let trackModelName: CGFloat = -0.20    // -0.01em * 20
    static let trackUpdatesFigure: CGFloat = -1.32 // -0.03em * 44
    static let trackBarWordmark: CGFloat = -0.10  // -0.008em * 12
    static let trackRowTitle: CGFloat = -0.07     // -0.005em * 13.5
    static let trackContentsTitle: CGFloat = -0.07 // -0.005em * 13
    static let trackMapKicker: CGFloat = 2.86     // 0.26em * 11
    static let trackDiveKicker: CGFloat = 2.28    // 0.24em * 9.5
    static let trackCardHeaderLabel: CGFloat = 0.55 // 0.05em * 11
    static let trackPrivacy: CGFloat = 0.95       // 0.1em * 9.5
    static let trackMapCardKicker: CGFloat = 1.52 // 0.16em * 9.5
    static let trackMonoState: CGFloat = 1.14     // 0.12em * 9.5 approx
    static let trackStatusTag: CGFloat = 0.80

    // MARK: Weights (100…900)
    static let wRegular: CGFloat = 400
    static let wMedium: CGFloat = 500
    static let wChapter: CGFloat = 560      // contents title idle
    static let wSemibold: CGFloat = 600
    static let wCardHeader: CGFloat = 640  // NOT 700 bold
    static let wBold: CGFloat = 700        // avoid in Compass UI

    // MARK: Named styles (font only — apply tracking in the view)

    /// Map hero “Everything is ready.”
    static var styleMapHero: Font { CompassFont.display(mapHero, weight: wRegular) }
    /// Map hero italic emphasis (“Everything is *ready.*”) — real Instrument Serif Italic.
    static var styleMapHeroItalic: Font { CompassFont.displayItalic(mapHero) }
    /// Dive “How Kalam hears you.”
    static var styleDiveDisplay: Font { CompassFont.display(diveDisplay, weight: wRegular) }
    /// Dive display italic emphasis (“How Kalam *hears you.*”) — real Instrument Serif Italic.
    static var styleDiveDisplayItalic: Font { CompassFont.displayItalic(diveDisplay) }
    static var styleMapCardTitle: Font { CompassFont.display(mapCardTitle, weight: wRegular) }
    static var styleMapCardTitleLarge: Font { CompassFont.display(mapCardTitleLarge, weight: wRegular) }
    static var styleMapFootTitle: Font { CompassFont.display(mapFootTitle, weight: wRegular) }
    static var styleModelName: Font { CompassFont.display(modelName, weight: wRegular) }
    static var styleUpdatesFigure: Font { CompassFont.display(updatesFigure, weight: wRegular) }

    static var styleBarWordmark: Font { CompassFont.body(barWordmark, weight: wSemibold) }
    static var styleBackButton: Font { CompassFont.body(backButton, weight: wMedium) }
    static var styleNeedCTA: Font { CompassFont.body(needCTA, weight: 560) }
    static var styleLede: Font { CompassFont.body(diveLede, weight: wRegular) }
    static var styleRowTitle: Font { CompassFont.body(rowTitle, weight: wSemibold) }
    static var styleRowDetail: Font { CompassFont.body(rowDetail, weight: wRegular) }
    static var styleModeTitle: Font { CompassFont.body(modeTitle, weight: wSemibold) }
    static var styleModeDetail: Font { CompassFont.body(modeDetail, weight: wRegular) }
    /// Mic device names — regular 13.5 (not semibold)
    static var styleMicName: Font { CompassFont.body(micName, weight: wRegular) }
    static var styleBtnLabel: Font { CompassFont.body(btnLabel, weight: wRegular) }
    static var styleDictField: Font { CompassFont.body(dictField, weight: wRegular) }
    static var styleDictTyped: Font { CompassFont.body(dictTyped, weight: wRegular) }
    static var styleEmptyTitle: Font { CompassFont.body(emptyTitle, weight: wSemibold) }
    static var styleEmptyBody: Font { CompassFont.body(emptyBody, weight: wRegular) }
    static var styleWhyBody: Font { CompassFont.body(whyBody, weight: wRegular) }
    static var styleHotkeyChipText: Font { CompassFont.body(hotkeyChip, weight: wMedium) }
    static var styleHotkeyMenu: Font { CompassFont.body(hotkeyMenu, weight: wRegular) }
    static var styleSegment: Font { CompassFont.body(segment, weight: wRegular) }
    static var styleSegmentOn: Font { CompassFont.body(segment, weight: 560) }

    /// Contents nav title (idle 560, selected still 560; maintenance idle 500, selected 600)
    static func styleContentsTitle(selected: Bool, maintenance: Bool) -> Font {
        if maintenance {
            return CompassFont.body(contentsTitle, weight: selected ? wSemibold : wMedium)
        }
        return CompassFont.body(contentsTitle, weight: wChapter)
    }

    static var styleContentsSubtitle: Font { CompassFont.body(contentsSubtitle, weight: wRegular) }

    /// BEHAVIOR / MICROPHONE PRIORITY — weight 640, tracked, uppercase in the view
    static var styleCardHeaderLabel: Font { CompassFont.body(cardHeaderLabel, weight: wCardHeader) }

    static var styleMapKicker: Font { CompassFont.mono(mapKicker, weight: wSemibold) }
    static var styleDiveKicker: Font { CompassFont.mono(diveKicker, weight: wMedium) }
    static var stylePrivacy: Font { CompassFont.mono(privacy, weight: wRegular) }
    static var styleCardHeaderState: Font { CompassFont.mono(cardHeaderState, weight: wRegular) }
    static var styleMapCardKicker: Font { CompassFont.mono(mapCardKicker, weight: wRegular) }
    static var styleMapCardNum: Font { CompassFont.mono(mapCardNum, weight: wRegular) }
    static var styleMapCardState: Font { CompassFont.mono(mapCardState, weight: wRegular) }
    static var styleContentsIndex: Font { CompassFont.mono(contentsIndex, weight: wRegular) }
    static var styleContentsState: Font { CompassFont.mono(contentsState, weight: wRegular) }
    static var styleMicRank: Font { CompassFont.mono(micRank, weight: wRegular) }
    static var styleStatusTag: Font { CompassFont.mono(statusTag, weight: wRegular) }
    static var styleDictSpoken: Font { CompassFont.mono(dictSpoken, weight: wRegular) }
    static var styleDictLabel: Font { CompassFont.mono(dictLabel, weight: wRegular) }
    static var styleCoverChip: Font { CompassFont.mono(coverChip, weight: wRegular) }
    static var styleWhyLabel: Font { CompassFont.mono(whyLabel, weight: wRegular) }
    static var styleSampleWellLabel: Font { CompassFont.mono(sampleWellLabel, weight: wRegular) }
    static var styleHotkeySymbol: Font { CompassFont.mono(hotkeyChip, weight: wMedium) }
    static var stylePathMono: Font { CompassFont.mono(11, weight: wRegular) }
}

// MARK: - Tracking helper

extension Text {
    /// Apply a Compass tracking value (points). Text-preserving overload so
    /// `Text + Text` concatenation keeps working after `.compassTracking`.
    func compassTracking(_ points: CGFloat) -> Text {
        tracking(points)
    }
}

extension View {
    /// Apply a Compass tracking value (points).
    func compassTracking(_ points: CGFloat) -> some View {
        self.tracking(points)
    }
}

enum CompassLayout {
    static let window = CGSize(width: 980, height: 660)
    static let bar: CGFloat = 46
    static let contentsWidth: CGFloat = 248
    static let mapPad = EdgeInsets(top: 22, leading: 30, bottom: 24, trailing: 30)
    static let diveMainPad = EdgeInsets(top: 24, leading: 36, bottom: 28, trailing: 36)
    static let contentsPad = EdgeInsets(top: 24, leading: 16, bottom: 16, trailing: 16)
    static let gridGap: CGFloat = 13
    static let cardRadius: CGFloat = 14
    static let mapCardRadius: CGFloat = 16
    static let mapCardMin: CGFloat = 122
    static let mapCardMinLarge: CGFloat = 132
    static let mapCardPad = EdgeInsets(top: 15, leading: 17, bottom: 14, trailing: 17)
    static let diveCardHeaderPad = EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)
    static let diveRowPad = EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)
    static let contentsRowPad = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    static let contentsRowRadius: CGFloat = 11
    static let contentsIndexWidth: CGFloat = 18
    static let contentsTitleLine: CGFloat = 18
    static let toggleSize = CGSize(width: 40, height: 23)
    static let toggleKnob: CGFloat = 18
    static let toggleTravel: CGFloat = 17
    static let toggleInset: CGFloat = 2.5
    static let segmentPad = EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
    static let segmentRadius: CGFloat = 8
    static let keycapPad = EdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9)
    static let keycapRadius: CGFloat = 6
    static let searchRadius: CGFloat = 9
    static let wellRadius: CGFloat = 10
    static let wellSplitOpacity: Double = 0.22
    static let attentionHairOpacity: Double = 0.42
    static let hoverLift: CGFloat = -2
    static let hoverShadowRadius: CGFloat = 26
    static let hoverShadowY: CGFloat = 10
    static let hoverAnim: Animation = .timingCurve(0.22, 1, 0.36, 1, duration: 0.3)
    static let dimOpacity: Double = 0.48
    static let disabledPrimaryOpacity: Double = 0.42
    static let rejectFlashNanos: UInt64 = 800_000_000
}
