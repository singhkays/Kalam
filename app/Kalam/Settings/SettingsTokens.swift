import AppKit
import CoreText
import SwiftUI

// MARK: - Color tokens (adaptive per appearance · v1.7 dark mode)
// Same `Color.k*` names, now resolving per appearance via the NSColor-provider
// pattern from OnboardingDeckTokens.adaptive. Light values are byte-identical to
// the old static literals, so light-mode rendering is unchanged. Dark values
// come verbatim from the v1.7 mockup token table (kalam-compass-v1.7.html).
//
// Deliberate exceptions: `kGreenT` goes through `adaptiveWash` (alpha differs
// per mode: 0.07 light / 0.14 dark), NOT `kGreen.opacity(0.07)`; the dead shell
// tokens (`kShell*`, `kGreenBright`, `kHairOnShell`, `kEtched`, zero call sites
// outside token files) stay exactly as-is.

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

    /// Resolve a dynamic NSColor-backed SwiftUI Color for the current appearance.
    /// Internal (not private): Task 3 reuses these for wash/shadow twins.
    static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }

    /// Per-appearance wash: base hue token with a different alpha per mode.
    /// Internal (not private): Task 3 reuses this for wash/shadow twins.
    static func adaptiveWash(light: String, dark: String, lightAlpha: Double, darkAlpha: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light)).withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        })
    }

    // MARK: Light surfaces
    /// Card / window surface (onboarding card FAFAF7).
    static let kPaper = adaptive(light: "FAFAF7", dark: "181816")
    /// Control fill — pure white, matching onboarding control fills.
    static let kPanel = adaptive(light: "FFFFFF", dark: "20201C")
    /// Inset well (search, dictionary editor, sample strips).
    static let kWell = adaptive(light: "F1F0EA", dark: "131311")
    /// Fields/chips inside cards — same as panel.
    static let kControl = Color.kPanel

    // MARK: Ink ramp (WCAG AA safe at all sizes)
    static let kInk = adaptive(light: "1A1A18", dark: "F5F4EE")
    /// Secondary text. Was #3D3C38 (F-02) — AppKit rendered it as near-ink.
    /// Lifted to the mockup's *visible* taupe so ledes/details match the HTML (Part 19).
    static let kInk2 = adaptive(light: "5B574C", dark: "D5D3C8")
    /// 5.32:1 on paper, 5.56:1 on panel — passes AA for normal text.
    static let kInk3 = adaptive(light: "6B6860", dark: "9E9C92")

    // MARK: Hairlines
    static let kHair = adaptive(light: "E5E5E1", dark: "2C2C28")
    static let kHair2 = adaptive(light: "EFEEE9", dark: "262622")

    // MARK: Accent (the one constant — matches onboarding exactly)
    static let kGreen = adaptive(light: "1A5C3A", dark: "2A9D5C")
    static let kGreenD = adaptive(light: "0F3C24", dark: "1E6B3E")
    /// 7% green tint in light, 14% in dark (mockup body.dark wash row).
    static let kGreenT = adaptiveWash(light: "1A5C3A", dark: "2A9D5C", lightAlpha: 0.07, darkAlpha: 0.14)
    /// Accent for dark shell surfaces (3.45:1 on kShell) — status dots, selected rows on shell.
    static let kGreenBright = Color(hex: "2E7D4F")

    // MARK: Status (from onboarding; passes AA on soft backgrounds)
    static let kWarn = adaptive(light: "8A5610", dark: "E5A54B")
    static let kWarnSoft = adaptive(light: "FAF0DF", dark: "2E2313")
    static let kBad = adaptive(light: "983226", dark: "FB7185")
    static let kBadSoft = adaptive(light: "F8E9E5", dark: "2E1A17")

    // MARK: Disabled
    static let kOff = adaptive(light: "D6D8DC", dark: "3C3C38")

    // MARK: Washes + shadows with per-appearance twins (v1.7 Task 3)
    // Light values are byte-identical to the old literals; dark values come
    // verbatim from the mockup `body.dark` override block (kalam-compass-v1.7.html).
    /// Resting card shadow: black @4% light / @35% dark (mockup `.mcard` / `body.dark .mcard`).
    static let kRestShadow = adaptiveWash(light: "000000", dark: "000000", lightAlpha: 0.04, darkAlpha: 0.35)
    /// Hover-lift shadow: black @10% light / @50% dark (mockup `.mcard:hover` / `body.dark .mcard:hover`).
    static let kHoverShadow = adaptiveWash(light: "000000", dark: "000000", lightAlpha: 0.10, darkAlpha: 0.50)
    /// Selected-chip shadow: black @6% light / @40% dark (mockup `.seg span.on` / `body.dark .seg span.on`).
    static let kChipShadow = adaptiveWash(light: "000000", dark: "000000", lightAlpha: 0.06, darkAlpha: 0.40)
    /// Bar hairline: black @10% light / white @8% dark (mockup `.bar` / `body.dark .bar`).
    static let kBarHair = adaptiveWash(light: "000000", dark: "FFFFFF", lightAlpha: 0.10, darkAlpha: 0.08)
    /// Contents rail divider: black @8% light / white @8% dark (mockup `.contents` / `body.dark .contents`).
    static let kRailHair = adaptiveWash(light: "000000", dark: "FFFFFF", lightAlpha: 0.08, darkAlpha: 0.08)
    /// Dictionary row actions (`dact`): ink3 @70% light / @80% dark (mockup `.dact` / `body.dark .dact`).
    static let kDact = adaptiveWash(light: "6B6860", dark: "9E9C92", lightAlpha: 0.7, darkAlpha: 0.8)
    /// Cleanup sample strikethrough: ink @45% both modes (mockup `.sample .txt s` + dark row).
    static let kStrike = adaptiveWash(light: "1A1A18", dark: "F5F4EE", lightAlpha: 0.45, darkAlpha: 0.45)
    /// Incomplete-model warn wash: orange @6% light / amber @8% dark (mockup `.repoWarn` / `body.dark .repoWarn`).
    static let kWarnWash = adaptiveWash(light: "FF9500", dark: "E5A54B", lightAlpha: 0.06, darkAlpha: 0.08)
    /// Warn wash edge: orange @22% light / amber @30% dark (mockup `.repoWarn` border rows).
    static let kWarnWashEdge = adaptiveWash(light: "FF9500", dark: "E5A54B", lightAlpha: 0.22, darkAlpha: 0.30)
    /// Repo-guard warn wash: orange @8% light / amber @8% dark (mockup `.repoWarn` background, verbatim).
    static let kRepoWarn = adaptiveWash(light: "FF9500", dark: "E5A54B", lightAlpha: 0.08, darkAlpha: 0.08)
    // MARK: Selected/active green overlays (Task 3b — mockup dark alphas run
    // hotter than light; a shared hue with per-mode alpha, mirroring kGreenT)
    /// Active wizard step wash: green @3% light / luminous @6% dark (mockup `.wstep.active` + dark row).
    static let kStepWash = adaptiveWash(light: "1A5C3A", dark: "2A9D5C", lightAlpha: 0.03, darkAlpha: 0.06)
    /// Selected model-card wash: green @5% / luminous @10% (mockup `.scard.sel` + dark row).
    static let kCardWash = adaptiveWash(light: "1A5C3A", dark: "2A9D5C", lightAlpha: 0.05, darkAlpha: 0.10)
    /// Selected model-card edge: green @22% / luminous @35% (mockup `.scard.sel` border + dark row).
    static let kCardEdge = adaptiveWash(light: "1A5C3A", dark: "2A9D5C", lightAlpha: 0.22, darkAlpha: 0.35)
    /// Present-file chip wash: green @8% / luminous @14% (mockup `.chip.ok` + dark row).
    static let kChipWash = adaptiveWash(light: "1A5C3A", dark: "2A9D5C", lightAlpha: 0.08, darkAlpha: 0.14)
    /// Present-file chip edge: green @20% / luminous @25% (mockup `.chip.ok` border + dark row).
    static let kChipEdge = adaptiveWash(light: "1A5C3A", dark: "2A9D5C", lightAlpha: 0.20, darkAlpha: 0.25)
    /// Missing-file chip edge: bad @12% light (as-built, do not touch) / luminous rose @25% dark (mockup `.chip.miss` dark row).
    static let kChipMissEdge = adaptiveWash(light: "983226", dark: "FB7185", lightAlpha: 0.12, darkAlpha: 0.25)
    /// Map hover edge: green @35% / luminous @45% (mockup `.mcard:hover` + `body.dark .grid .mcard:hover`).
    static let kHoverEdge = adaptiveWash(light: "1A5C3A", dark: "2A9D5C", lightAlpha: 0.35, darkAlpha: 0.45)
    /// Attention edge: green @42% / luminous @50% (mockup `.mcard.attention` + dark row; replaces `attentionHairOpacity` at call sites below).
    static let kAttentionEdge = adaptiveWash(light: "1A5C3A", dark: "2A9D5C", lightAlpha: 0.42, darkAlpha: 0.50)

    // MARK: Dark shell chrome (onboarding shell / rail)
    static let kShell = Color(hex: "1A1A18")
    static let kShell2 = Color(hex: "141412")
    static let kShellInk = Color(hex: "F3EFE7")
    static let kShellInk2 = Color(hex: "D8D5CC")
    static let kShellInk3 = Color(hex: "8E8B82")
    /// Hairline visible on shell.
    static let kHairOnShell = Color.white.opacity(0.12)
    /// Recessed "inset" hairline for dark chrome — a groove, not a raised line (part 5).
    static let kEtched = Color.black.opacity(0.35)
}

// MARK: - Typography (aligned to onboarding · 2026-08-13)
//
// Families:
//   .serif       → Instrument Serif (bundled brand face, OFL; fallback New York)
//   .default     → SF Pro Text (body, UI chrome)
//   .monospaced  → SF Mono (kickers, ranks, states, hotkey symbols, code paths)
//
// NEVER use: Inter, Roboto, Helvetica, Geist, Clash.
// NEVER use Font.Weight.bold (700) for card headers — headers are mono kickers now.
// NEVER use .title / .headline / .body text styles — they fight the fixed utility chrome.
//
// Non-standard weights (560, 600) use SettingsFont.variable via NSFontDescriptor.
// Tracking values are point offsets ≈ CSS em * fontSize (Instrument Serif: -0.012/-0.014em).

enum SettingsFont {
    enum Family {
        case serif, sans, mono
    }

    // MARK: Brand serif — Instrument Serif (SIL OFL 1.1, bundled in Fonts/)
    static let brandRegular = "InstrumentSerif-Regular"
    /// PostScript name — NOT `brandItalic`: that name belongs to the Font factory
    /// below (the v1.2 stub declared both and the String shadowed the function).
    static let brandItalicName = "InstrumentSerif-Italic"
    private static let registrationLock = NSLock()
    nonisolated(unsafe) private static var didAttemptRegistration = false

    /// Register the bundled brand fonts with Core Text (the macOS path).
    /// Safe to call repeatedly; runs once per process.
    static func ensureBrandFontRegistered() {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        guard !didAttemptRegistration else { return }
        didAttemptRegistration = true
        for name in [brandRegular, brandItalicName] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Preferred entry point. `weight` is 100…900 (CSS-like). Common: 400 regular, 500 medium,
    /// 560 chapter title, 600 semibold. Serif ignores weight — Instrument Serif ships 400 only.
    static func variable(_ family: Family, size: CGFloat, weight: CGFloat) -> Font {
        guard let ns = resolved(family, size: size, weight: weight) else {
            return fallback(family, size: size, weight: weight)
        }
        return Font(ns)
    }

    /// Test seam (settings v1.2 visual alignment): resolves the NSFont behind the SwiftUI `Font` for a family.
    /// SwiftUI `Font` is opaque (no `NSFont(_ font:)` initializer), so @testable
    /// assertions resolve through here instead.
    static func resolved(_ family: Family, size: CGFloat, weight: CGFloat) -> NSFont? {
        switch family {
        case .serif:
            ensureBrandFontRegistered()
            return NSFont(name: brandRegular, size: size)
        case .sans, .mono:
            let design: NSFontDescriptor.SystemDesign = family == .sans ? .default : .monospaced
            let base = NSFont.systemFont(ofSize: size)
            guard var desc = base.fontDescriptor.withDesign(design) else {
                return nil
            }
            desc = desc.addingAttributes([
                .traits: [NSFontDescriptor.TraitKey.weight: nsWeight(weight)]
            ])
            return NSFont(descriptor: desc, size: size)
        }
    }

    /// Italic brand serif — uses the real italic cut, not a synthetic slant.
    static func brandItalic(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        ensureBrandFontRegistered()
        if let ns = NSFont(name: brandItalicName, size: size) {
            return Font(ns)
        }
        return Font.system(size: size, weight: nearestWeight(weight), design: .serif).italic()
    }

    private static func nsWeight(_ w: CGFloat) -> CGFloat {
        // Anchor-piecewise (probe-verified 2026-08-13, settings web-font work): CSS 100…900 onto
        // NSFontWeightApprox such that common weights land on the exact named
        // SF instances — 300→-0.16 (SFNS-Light), 400→0, 500→0.23 (SFNS-Medium),
        // 600→0.3 (Semibold), 700→0.4 (Bold), 800→0.56, 900→0.62, linear between.
        // (Part 21: 300/Light is in play for secondary + former-500 roles.)
        let clamped = min(900, max(100, w))
        switch clamped {
        case ..<350: return -0.4 // Font.Weight.light.rawValue — exact SFNS-Light (wght 300, Part 21)
        case ..<400: return 0.0
        case ..<500: return 0.23 * (clamped - 400) / 100
        case ..<600: return 0.23 + 0.07 * (clamped - 500) / 100
        case ..<700: return 0.30 + 0.10 * (clamped - 600) / 100
        case ..<800: return 0.40 + 0.16 * (clamped - 700) / 100
        case ..<900: return 0.56 + 0.06 * (clamped - 800) / 100
        default: return 0.62
        }
    }

    private static func fallback(_ family: Family, size: CGFloat, weight: CGFloat) -> Font {
        let w = nearestWeight(weight)
        switch family {
        case .serif: return .system(size: size, weight: w, design: .serif)
        case .sans: return .system(size: size, weight: w, design: .default)
        case .mono: return .system(size: size, weight: w, design: .monospaced)
        }
    }

    private static func nearestWeight(_ w: CGFloat) -> Font.Weight {
        switch w {
        case ..<350: return .light // Part 21: 300/Light is legal SF Pro
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

    /// Book serif (New York) — small serif roles (card titles, foot, model name).
    /// New York has an optical-size axis designed for 12–24pt, so small serif text
    /// stays legible where the condensed Instrument Serif would squeeze (2026-08-13, part 3).
    static func book(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        guard let ns = resolvedBook(size, weight: weight) else {
            return fallback(.serif, size: size, weight: weight)
        }
        return Font(ns)
    }

    /// Test seam (settings v1.2 visual alignment): the New York font behind `book(_:weight:)`.
    static func resolvedBook(_ size: CGFloat, weight: CGFloat = 400) -> NSFont? {
        let base = NSFont.systemFont(ofSize: size)
        guard var desc = base.fontDescriptor.withDesign(.serif) else {
            return nil
        }
        // New York *Text* optical size (v1.3.2 Part 17). Display optical at 19pt
        // has thicker stems and reads as Semibold even when the face is Regular.
        var attrs: [NSFontDescriptor.AttributeName: Any] = [
            .traits: [NSFontDescriptor.TraitKey.weight: nsWeight(weight)],
        ]
        attrs[NSFontDescriptor.AttributeName(rawValue: String(kCTFontOpticalSizeAttribute))] = size
        desc = desc.addingAttributes(attrs)
        return NSFont(descriptor: desc, size: size)
    }

    static func displayItalic(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        brandItalic(size, weight: weight)
    }

    static func body(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        variable(.sans, size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        variable(.mono, size: size, weight: weight)
    }
}

/// Named roles — USE THESE. Do not pick sizes ad hoc in views.
enum SettingsType {
    // MARK: Sizes (pt)
    static let mapHero: CGFloat = 36            // sized up for Instrument Serif (part 4)
    static let diveDisplay: CGFloat = 34          // sized up for Instrument Serif (part 4); was 30 for New York
    /// Map card titles — reduced a half-size (Part 22): New York has no Light cut,
    /// so less ink comes from size + open tracking. Mockup 19.
    static let mapCardTitle: CGFloat = 17.5
    /// Attention-large title — Part 22 (mockup 22).
    static let mapCardTitleLarge: CGFloat = 20.5
    /// Map foot title — Part 22 (mockup 15).
    static let mapFootTitle: CGFloat = 14.5
    static let modelName: CGFloat = 20
    static let updatesFigure: CGFloat = 48        // sized up for Instrument Serif (part 4)

    static let windowBody: CGFloat = 13.5
    static let barWordmark: CGFloat = 13.5        // window wordmark, more presence (part 5)
    static let backButton: CGFloat = 12.5
    static let needCTA: CGFloat = 14
    static let mapLede: CGFloat = 13.5
    static let diveLede: CGFloat = 13.5

    static let mapKicker: CGFloat = 11
    static let diveKicker: CGFloat = 11           // page eyebrow, matches map kicker (part 5)
    static let cardHeaderLabel: CGFloat = 11     // mono kicker size (v1.3.8: 9.5 → 11 for presence)
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
    static let emptyTitle: CGFloat = 15
    static let emptyBody: CGFloat = 13

    // MARK: Tracking (points) ≈ CSS letter-spacing em × size
    // Instrument Serif display tracking follows onboarding (-0.012/-0.014em).
    static let trackMapHero: CGFloat = -0.50      // -0.014em * 36 (Instrument Serif)
    static let trackDiveDisplay: CGFloat = -0.41  // -0.012em * 34 (Instrument Serif)
    static let trackMapCardTitle: CGFloat = 0    // open tracking = less ink (Part 22; was -0.23)
    static let trackMapFootTitle: CGFloat = -0.15 // -0.01em * 15
    static let trackModelName: CGFloat = -0.20    // -0.01em * 20
    static let trackUpdatesFigure: CGFloat = -1.44 // -0.03em * 48
    static let trackBarWordmark: CGFloat = -0.11  // -0.008em * 13.5
    static let trackRowTitle: CGFloat = -0.07     // -0.005em * 13.5
    static let trackContentsTitle: CGFloat = -0.07 // -0.005em * 13
    static let trackMapKicker: CGFloat = 2.86     // 0.26em * 11
    static let trackDiveKicker: CGFloat = 2.86    // 0.26em * 11 — matches map kicker (part 5)
    static let trackCardHeaderLabel: CGFloat = 1.76 // 0.16em * 11 (v1.3.8)
    static let trackPrivacy: CGFloat = 0.95       // 0.1em * 9.5
    static let trackMapCardKicker: CGFloat = 1.52 // 0.16em * 9.5
    static let trackMonoState: CGFloat = 1.14     // 0.12em * 9.5 approx
    static let trackStatusTag: CGFloat = 0.80

    // MARK: Weights (100…900)
    // Part 21 — one more AppKit step. 300/Light is legal SF Pro
    // (Font.Weight.light). Use it for secondary + former-500 roles.
    //   mockup 400 → Swift 400 (serif/display stay here; no Instrument Light)
    //   mockup 400 body/lede/detail → Swift 300
    //   mockup 500 → Swift 300   (wMock500)
    //   mockup 560/600 → Swift 400  (wMock600)
    static let wLight: CGFloat = 300
    static let wRegular: CGFloat = 400
    static let wMedium: CGFloat = 400
    static let wChapter: CGFloat = 400
    static let wSemibold: CGFloat = 400
    static let wBold: CGFloat = 700         // avoid in settings UI
    static let wMock500: CGFloat = 300
    static let wMock600: CGFloat = 400

    // MARK: Named styles (font only — apply tracking in the view)

    /// Map hero “Everything is ready.”
    static var styleMapHero: Font { SettingsFont.display(mapHero, weight: wRegular) }
    /// Map hero italic suffix — real Instrument Serif italic.
    static var styleMapHeroItalic: Font { SettingsFont.displayItalic(mapHero) }
    /// Dive “How Kalam hears you.”
    static var styleDiveDisplay: Font { SettingsFont.display(diveDisplay, weight: wRegular) }
    /// Dive display italic suffix.
    static var styleDiveDisplayItalic: Font { SettingsFont.displayItalic(diveDisplay) }
    /// Map card title — New York (book serif, optical sizing for 12–24pt). F-01 part 3.
    static var styleMapCardTitle: Font { SettingsFont.book(mapCardTitle, weight: wRegular) }
    /// Map card title, attention-large — New York.
    static var styleMapCardTitleLarge: Font { SettingsFont.book(mapCardTitleLarge, weight: wRegular) }
    /// Map foot title — New York.
    static var styleMapFootTitle: Font { SettingsFont.book(mapFootTitle, weight: wRegular) }
    /// Model name — New York.
    static var styleModelName: Font { SettingsFont.book(modelName, weight: wRegular) }
    static var styleUpdatesFigure: Font { SettingsFont.display(updatesFigure, weight: wRegular) }

    static var styleBarWordmark: Font { SettingsFont.body(barWordmark, weight: wMock600) }
    static var styleBackButton: Font { SettingsFont.body(backButton, weight: wMock500) }
    static var styleNeedCTA: Font { SettingsFont.body(needCTA, weight: wMock600) }
    static var styleLede: Font { SettingsFont.body(diveLede, weight: wLight) }
    /// Compensated 400 (mockup `.row .nm` 560/600 — AppKit paints a step heavier, Part 20/21).
    static var styleRowTitle: Font { SettingsFont.body(rowTitle, weight: wMock600) }
    static var styleRowDetail: Font { SettingsFont.body(rowDetail, weight: wLight) }
    static var styleModeTitle: Font { SettingsFont.body(modeTitle, weight: wMock600) }
    static var styleModeDetail: Font { SettingsFont.body(modeDetail, weight: wLight) }
    /// Mic device names — compensated 500 (mockup 600, F-08; AppKit step, Part 20).
    static var styleMicName: Font { SettingsFont.body(micName, weight: wMock600) }
    static var styleBtnLabel: Font { SettingsFont.body(btnLabel, weight: wRegular) }
    static var styleDictField: Font { SettingsFont.body(dictField, weight: wRegular) }
    static var styleDictTyped: Font { SettingsFont.body(dictTyped, weight: wRegular) }
    static var styleEmptyTitle: Font { SettingsFont.body(emptyTitle, weight: wMock600) }
    static var styleEmptyBody: Font { SettingsFont.body(emptyBody, weight: wRegular) }
    static var styleWhyBody: Font { SettingsFont.body(whyBody, weight: wRegular) }
    static var styleHotkeyChipText: Font { SettingsFont.body(hotkeyChip, weight: wMedium) }
    static var styleHotkeyMenu: Font { SettingsFont.body(hotkeyMenu, weight: wRegular) }
    static var styleSegment: Font { SettingsFont.body(segment, weight: wRegular) }
    static var styleSegmentOn: Font { SettingsFont.body(segment, weight: wMock600) }

    /// Contents nav title — compensated (mockup 560/500 → 500/400, Part 20).
    static func styleContentsTitle(selected: Bool, maintenance: Bool) -> Font {
        if maintenance {
            return SettingsFont.body(contentsTitle, weight: selected ? wMock600 : wMock500)
        }
        return SettingsFont.body(contentsTitle, weight: wMock600)
    }

    static var styleContentsSubtitle: Font { SettingsFont.body(contentsSubtitle, weight: wLight) }

    /// Card section labels (BEHAVIOR, MICROPHONE PRIORITY, KEY…) — mono kicker grammar,
    /// matching onboarding .kick (was SF Pro weight 640, F-06). Uppercase in the view.
    /// v1.3.8: 11pt mono; weight 300 = compensated mockup 500 (Part 21 table).
    static var styleCardHeaderLabel: Font { SettingsFont.mono(cardHeaderLabel, weight: wLight) }

    /// Page eyebrows (THE MAP / dive section labels) — 11pt mono, compensated 400
    /// (mockup 500 → Swift 400, Part 20).
    static var styleMapKicker: Font { SettingsFont.mono(mapKicker, weight: wMock500) }
    static var styleDiveKicker: Font { SettingsFont.mono(diveKicker, weight: wMock500) }
    static var stylePrivacy: Font { SettingsFont.mono(privacy, weight: wRegular) }
    static var styleCardHeaderState: Font { SettingsFont.mono(cardHeaderState, weight: wRegular) }
    static var styleMapCardKicker: Font { SettingsFont.mono(mapCardKicker, weight: wRegular) }
    static var styleMapCardNum: Font { SettingsFont.mono(mapCardNum, weight: wRegular) }
    static var styleMapCardState: Font { SettingsFont.mono(mapCardState, weight: wRegular) }
    static var styleContentsIndex: Font { SettingsFont.mono(contentsIndex, weight: wRegular) }
    static var styleContentsState: Font { SettingsFont.mono(contentsState, weight: wRegular) }
    static var styleMicRank: Font { SettingsFont.mono(micRank, weight: wRegular) }
    static var styleStatusTag: Font { SettingsFont.mono(statusTag, weight: wRegular) }
    static var styleDictSpoken: Font { SettingsFont.mono(dictSpoken, weight: wRegular) }
    static var styleDictLabel: Font { SettingsFont.mono(dictLabel, weight: wRegular) }
    static var styleCoverChip: Font { SettingsFont.mono(coverChip, weight: wRegular) }
    static var styleWhyLabel: Font { SettingsFont.mono(whyLabel, weight: wRegular) }
    static var styleSampleWellLabel: Font { SettingsFont.mono(sampleWellLabel, weight: wRegular) }
    static var styleHotkeySymbol: Font { SettingsFont.mono(hotkeyChip, weight: wMedium) }
    static var stylePathMono: Font { SettingsFont.mono(11, weight: wRegular) }
}

// MARK: - Tracking helper

extension View {
    /// Apply a settings tracking value (points).
    func compassTracking(_ points: CGFloat) -> some View {
        self.tracking(points)
    }
}

extension Text {
    /// `Text + Text` concatenation keeps working after `.compassTracking`.
    /// (Live-side compile shim: the v1.2 stub file dropped this overload; the
    /// dive displays concatenate two tracked `Text` pieces — settings v1.2 visual alignment.)
    func compassTracking(_ points: CGFloat) -> Text {
        self.tracking(points)
    }
}

extension View {
    /// macOS `Button` (even `.plain`) applies semibold to label text.
    /// Call on every Text that must render as Regular. A Font probe is not enough.
    func compassRegular() -> some View {
        self.fontWeight(.regular)
    }
}

extension View {
    /// Row top edge (v1.3.8): between rows → crisp `kHair2` divider; on the FIRST row of a
    /// card → the header's soft shadow wash (mockup `.row + .row` — no border under headers).
    /// Drawn as a deterministic gradient fade: `.shadow()` on a 1pt rect renders as a hard
    /// ~1px line (no soft falloff), so a LinearGradient is the honest way to paint the wash.
    func rowTopEdge(first: Bool = false) -> some View {
        overlay(alignment: .top) {
            if first {
                HeaderWash()
            } else {
                Divider().background(Color.kHair2)
            }
        }
    }
}

/// The header shadow wash as a standalone layer. `rowTopEdge` paints it as an
/// overlay (above everything — right for plain rows). Ringed first rows
/// (Trigger radio, Engine incomplete) paint it as a *background* layer beneath
/// their tint instead, so the ring stays crisp on top and the shadow still
/// shows in every selection state. Single source for both orderings.
struct HeaderWash: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: SettingsLayout.cardHeaderShadowColor, location: 0.0),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 3.5) // v1.3.8g: 5 → 3.5pt per user QA ("tiny bit smaller")
    }
}

enum SettingsLayout {
    static let window = CGSize(width: 980, height: 660)
    static let bar: CGFloat = 46
    static let contentsWidth: CGFloat = 248
    static let mapPad = EdgeInsets(top: 22, leading: 30, bottom: 24, trailing: 30)
    static let diveMainPad = EdgeInsets(top: 24, leading: 36, bottom: 28, trailing: 36)
    static let contentsPad = EdgeInsets(top: 24, leading: 16, bottom: 16, trailing: 16)
    static let gridGap: CGFloat = 13

    // MARK: Radius scale (onboarding-aligned, F-09)
    // card 13 · control 10 · button/input 8 · chip 5 · tag 4 · pill ∞
    static let radiusCard: CGFloat = 13
    static let radiusControl: CGFloat = 10
    static let radiusButton: CGFloat = 8
    static let radiusChip: CGFloat = 5
    static let radiusTag: CGFloat = 4
    static let radiusPill: CGFloat = 999

    static let cardRadius = radiusCard
    static let mapCardRadius = radiusCard
    static let contentsRowRadius = radiusControl
    static let segmentRadius = radiusButton
    static let keycapRadius = radiusButton
    static let searchRadius = radiusButton
    static let wellRadius = radiusButton

    static let mapCardMin: CGFloat = 122
    static let mapCardMinLarge: CGFloat = 132
    static let mapCardPad = EdgeInsets(top: 15, leading: 17, bottom: 14, trailing: 17)
    static let heroCardPad = EdgeInsets(top: 20, leading: 26, bottom: 22, trailing: 26)
    static let diveCardHeaderPad = EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)
    /// Card-header edge shadow (v1.3.8 — replaces the hairline): `0 3px 2px -2px rgba(40,36,28,.35)`.
    // v1.3.8 header edge shadow (2026-08-14, final): CSS `0 3px 2px -2px rgba(40,36,28,.35)`.
    // AppKit renders shadows heavier; the wash is a 5pt gradient (rowTopEdge(first:)) on the
    // FIRST row of each card — the mockup has no border under the header (`.row + .row` only).
    // Peak 0.10 — deliberately softer than the CSS 0.35 per user QA (2026-08-14, round 2).
    // Dark twin 0.28 black (softened from the mockup's 0.55 `body.dark .row.first`:
    // AppKit renders the wash heavier and 0.55 read as a hard black line in dark).
    static let cardHeaderShadowColor = Color.adaptiveWash(light: "28241C", dark: "000000", lightAlpha: 0.10, darkAlpha: 0.28)
    static let diveRowPad = EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)
    static let contentsRowPad = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    static let contentsIndexWidth: CGFloat = 18
    static let contentsTitleLine: CGFloat = 18

    // MARK: Toggle geometry (onboarding-aligned, F-05): 34×20 · thumb 16 · inset 2
    static let toggleSize = CGSize(width: 34, height: 20)
    static let toggleKnob: CGFloat = 16
    static let toggleTravel: CGFloat = 13
    static let toggleInset: CGFloat = 2

    static let segmentPad = EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
    static let keycapPad = EdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9)
    static let wellSplitOpacity: Double = 0.22
    static let attentionHairOpacity: Double = 0.42

    // MARK: Card shadow on paper (v1 light mockups; dark twin per body.dark shadow rows)
    static let cardRestShadow = Color.kRestShadow
    static let cardRestShadowRadius: CGFloat = 2
    static let cardRestShadowY: CGFloat = 1

    static let hoverLift: CGFloat = -2
    static let hoverShadowRadius: CGFloat = 26
    static let hoverShadowY: CGFloat = 10
    static let hoverAnim: Animation = .timingCurve(0.22, 1, 0.36, 1, duration: 0.3)
    static let dimOpacity: Double = 0.48
    static let disabledPrimaryOpacity: Double = 0.42
    static let rejectFlashNanos: UInt64 = 800_000_000
}

// MARK: - Icon scale (light, precise strokes — onboarding stroke 1.4 ≈ SF Symbols medium)

enum SettingsIcon {
    static let s12: CGFloat = 12
    static let s14: CGFloat = 14
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24
    static let weight: Font.Weight = .medium
}
