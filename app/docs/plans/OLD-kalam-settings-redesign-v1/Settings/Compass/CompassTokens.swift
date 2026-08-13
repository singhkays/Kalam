import SwiftUI

// MARK: - Color tokens (always light paper; no Asset-catalog greens)
// Default = "Fog card" (locked production surface set). Explorer: compass-spec/palette-lab.html
// Final pair TBD from mockup Surfaces bar feedback (Warm paper / Cool mist / Stone lift / Gallery / Porcelain / Parchment).

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
    /// Inset wells (search, dictionary editor, sample strips). Same as paper by default — recessed vs panel, not a fourth hue.
    /// Inset well — darker than panel, distinct from window paper (Warm paper default).
    static let kWell = Color(hex: "EFEEEB")
    /// Raised chrome inside cards (fields, chips). Matches panel — not pure white.
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

enum CompassFont {
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }

    static func body(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }

    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}

enum CompassLayout {
    static let window = CGSize(width: 980, height: 660)
    static let bar: CGFloat = 46
    static let contentsWidth: CGFloat = 248
    static let mapPad = EdgeInsets(top: 22, leading: 30, bottom: 24, trailing: 30)
    static let diveMainPad = EdgeInsets(top: 32, leading: 36, bottom: 34, trailing: 36)
    static let contentsPad = EdgeInsets(top: 24, leading: 16, bottom: 16, trailing: 16)
    static let gridGap: CGFloat = 13
    static let cardRadius: CGFloat = 14
    static let mapCardRadius: CGFloat = 16
    static let mapCardMin: CGFloat = 122
    static let mapCardMinLarge: CGFloat = 132
    static let mapCardPad = EdgeInsets(top: 15, leading: 17, bottom: 14, trailing: 17)
    static let diveCardHeaderPad = EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)
    static let diveRowPad = EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)
    static let contentsRowPad = EdgeInsets(top: 12, leading: 12, bottom: 11, trailing: 12)
    static let contentsRowRadius: CGFloat = 11
    static let contentsRowLeftInset: CGFloat = 38
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

enum CompassType {
    static let hero: CGFloat = 32
    static let mapCardTitle: CGFloat = 19
    static let mapCardTitleLarge: CGFloat = 22
    static let mapCardKicker: CGFloat = 9.5
    static let mapCardBody: CGFloat = 12
    static let mapOpenHint: CGFloat = 12
    static let diveDisplay: CGFloat = 32
    static let diveLede: CGFloat = 13.5
    static let rowTitle: CGFloat = 13.5
    static let rowDetail: CGFloat = 11.5
    static let monoAnnotation: CGFloat = 9.5
    static let privacy: CGFloat = 9.5
    static let updatesFigure: CGFloat = 44
    static let modelName: CGFloat = 20
}
