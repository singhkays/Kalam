import AppKit
import SwiftUI

// MARK: - Onboarding deck adaptive tokens (v3 adoption, Task 1)
//
// Deck-scoped semantic colors that resolve per appearance. The shared `Color.k*`
// tokens in SettingsTokens.swift are static light-only literals and are also used
// by the settings UI — this file deliberately does NOT touch them.
//
// Light values follow the landing-page design language (Option B, 2026-08-21):
// the card IS the window ground (#FAFAF7, edge-to-edge) and the rail is the
// site's instrument-panel dark (#222220 — DictationEngine/CleanupDemo panels),
// i.e. dark means "the machine", never window chrome. Dark values come from
// the v3.0 handoff §2 (Obsidian Studio): charcoal card fills the window, rail
// stays #1F1F1C.
//
// Contrast targets (from v3.0 handoff): dark body #D5D3C8 on card #181816,
// rail labels #52B788 (~6.5:1 on #222220), muted silver #8E8B82.

enum OnboardingDeckTokens {
    /// Resolve a dynamic NSColor-backed SwiftUI Color for the current appearance.
    private static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
    }

    // MARK: Surfaces
    /// Card surface — warm cream / charcoal slate.
    static let card = adaptive(light: "FAFAF7", dark: "181816")
    /// Control wells & tiles inside the card — white / dark matte slate.
    static let tile = adaptive(light: "FFFFFF", dark: "20201C")
    /// Inset wells (callout neutral background, footer bar).
    static let well = adaptive(light: "F1F0EA", dark: "131311")
    /// Card footer bar.
    /// Dark 2026-08-22: was #131311 — matching the rail, it rendered as a
    /// TWIN dark band and the window bottom read as "2 bars, 2 rows" (user
    /// QA). Footers are USER ACTION space; per this file's own rule, dark
    /// means "the machine" — and there is only one machine band (the rail).
    /// Dissolved into the card ground (#181816): actions sit on the card
    /// under their divider, the rail stands alone as the base. Light keeps
    /// its subtle F4F3EE bar.
    static let footer = adaptive(light: "F4F3EE", dark: "181816")

    // MARK: Inks
    static let ink = adaptive(light: "1A1A18", dark: "F5F4EE")
    static let ink2 = adaptive(light: "5B574C", dark: "D5D3C8")
    static let ink3 = adaptive(light: "6B6860", dark: "9E9C92")

    // MARK: Hairlines
    static let hair = adaptive(light: "E5E5E1", dark: "2C2C28")
    static let hair2 = adaptive(light: "EFEEE9", dark: "262622")

    // MARK: Accent
    /// Forest green / luminous emerald.
    static let accent = adaptive(light: "1A5C3A", dark: "2A9D5C")
    /// Accent soft background (chips, selected rows).
    static let accentSoft = adaptive(light: "1A5C3A", dark: "2A9D5C").opacity(0.10)
    /// Accent for dark-shell surfaces (rail ticks/labels) — v3.0 spec pins the
    /// luminous sage emerald in BOTH modes (≥4.5:1 on the #222220 band).
    static let accentOnShell = adaptive(light: "52B788", dark: "52B788")
    /// Broken-gate tints for the rail specifically — bright variants that hold
    /// contrast on the dark instrument band in either appearance.
    static let railWarn = adaptive(light: "E5A54B", dark: "E5A54B")
    static let railBad = adaptive(light: "FB7185", dark: "FB7185")

    // MARK: Status
    static let warn = adaptive(light: "8A5610", dark: "E5A54B")
    static let warnSoft = adaptive(light: "FAF0DF", dark: "2E2313")
    static let bad = adaptive(light: "983226", dark: "FB7185")
    static let badSoft = adaptive(light: "F8E9E5", dark: "2E1A17")

    // MARK: Rail inks (on the dark instrument band)
    // (The shell padding token was retired with Option B — the deck has no
    // dark frame; card + rail are the only surfaces.)
    /// Rail surface — the landing page's instrument-panel dark (#222220,
    /// same value as DictationEngine/CleanupDemo panels). Against the #FAFAF7
    /// card ground the band reads unmistakably, and no shell padding remains
    /// for it to blur into (Option B; two earlier values sat within ~2-4% of
    /// the old padding and vanished against it).
    /// Dark 2026-08-22: #1F1F1C sat ~lighter than the #181816 card — the pair
    /// read as "same color with a bar between" (user QA), and lighter-on-dark
    /// wrongly elevates a BASE band. #131311 matches the deck's own dark
    /// footer/well depth: the band recedes, the top hairline reads as the
    /// card's lit bottom edge. Light keeps the strong #222220 contrast.
    static let shell2 = adaptive(light: "222220", dark: "131311")
    static let shellInk = adaptive(light: "F3EFE7", dark: "F5F4EE")
    static let shellInk2 = adaptive(light: "D8D5CC", dark: "D5D3C8")
    static let shellInk3 = adaptive(light: "8E8B82", dark: "8E8B82")

    // MARK: Control chrome
    /// Boxed-control recipe (hotkey onboarding card UX): tile/well core + defined edge + inset
    /// top highlight + whisper rest shadow. `controlEdge` carries real
    /// contrast in EACH appearance — the plain `hair` token is a ~2% step
    /// on the light card, which made boxed controls vanish in light mode.
    static let controlEdge = adaptive(light: "D8D5CC", dark: "383833")
    /// Lit top edge: a white sheen reads on charcoal; an ink crease on cream.
    static let controlTopHighlight = adaptive(light: "3D3C38", dark: "FFFFFF").opacity(0.06)
    /// Whisper rest shadow under boxed controls (settings v1.2 visual alignment rest-shadow scale).
    static let controlRestShadow = Color.black.opacity(0.05)
}

// MARK: - Mechanical mapping table (for the sweep)
//
// Old (static)        → New (adaptive)
// Color.kPaper        → OnboardingDeckTokens.card
// Color.kPanel        → OnboardingDeckTokens.tile
// Color.kWell         → OnboardingDeckTokens.well
// Color.kInk          → OnboardingDeckTokens.ink
// Color.kInk2         → OnboardingDeckTokens.ink2
// Color.shInk3        → OnboardingDeckTokens.ink3
// Color.kHair         → OnboardingDeckTokens.hair
// Color.kHair2        → OnboardingDeckTokens.hair2
// Color.kGreen        → OnboardingDeckTokens.accent
// Color.kGreenT       → OnboardingDeckTokens.accentSoft
// Color.kWarn         → OnboardingDeckTokens.warn
// Color.kWarnSoft     → OnboardingDeckTokens.warnSoft
// Color.kBad          → OnboardingDeckTokens.bad
// Color.kBadSoft      → OnboardingDeckTokens.badSoft
// Color.kShell        → OnboardingDeckTokens.shell (RETIRED — Option B
//                        removed the window shell; no replacement)
// Color.kShell2       → OnboardingDeckTokens.shell2
// Color.kShellInk     → OnboardingDeckTokens.shellInk
// Color.kShellInk2    → OnboardingDeckTokens.shellInk2
// Color.kShellInk3    → OnboardingDeckTokens.shellInk3
