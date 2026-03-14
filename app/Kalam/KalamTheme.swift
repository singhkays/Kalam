import SwiftUI

// MARK: - Kalam Theme Definitions

/// A unified theme for the Kalam app to ensure consistency across Onboarding and Settings.
enum KalamTheme {
    static let accent = Color(red: 46 / 255, green: 140 / 255, blue: 1.0)
    
    // MARK: Backgrounds & Surfaces
    static let panelTint = Color(nsColor: .controlBackgroundColor)
    static let controlTint = Color(nsColor: .controlColor).opacity(0.5)
    /// The deep background for the content area — the darkest semantic layer.
    static let contentBackground = Color(nsColor: .underPageBackgroundColor)
    
    // Card & Well Styling
    /// The elevated card/well surface — visibly lighter than contentBackground in dark mode.
    static let wellBackground = Color(nsColor: .windowBackgroundColor)
    static let wellBorder = Color(nsColor: .separatorColor).opacity(0.55)
    static let wellCornerRadius: CGFloat = 20
    
    static let cardTop = Color(nsColor: .controlBackgroundColor)
    static let cardBottom = Color(nsColor: .controlBackgroundColor)
    static let cardBorder = Color(nsColor: .separatorColor).opacity(0.40)
    static let cardTopHighlight = Color.white.opacity(0.055)
    static let cardCornerRadius: CGFloat = 12
    
    // MARK: Strokes
    static let sidebarEdgeStroke = Color(nsColor: .separatorColor).opacity(0.65)
    static let strokeSubtle = Color(nsColor: .separatorColor).opacity(0.50)
    static let strokeStrong = Color(nsColor: .separatorColor).opacity(0.85)
    
    // MARK: Text Colors
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color.secondary.opacity(0.90)
    
    // MARK: Standard Layout
    static let contentMaxWidth: CGFloat = 580
    static let rowVerticalPadding: CGFloat = 10
    static let rowHorizontalPadding: CGFloat = 12

    // MARK: - Typography
    static let pageTitleFont = Font.title2.bold()
    static let sectionTitleFont = Font.headline
    static let bodyFont = Font.body
    static let bodyStrongFont = Font.body.bold()
    static let calloutFont = Font.callout
    static let footnoteFont = Font.footnote
    static let captionFont = Font.caption
    static let captionStrongFont = Font.caption.bold()
}

// MARK: - Shared Views

/// A deterministic noise overlay used for premium material backgrounds.
struct NoiseView: View {
    var body: some View {
        Canvas { context, size in
            // Deterministic noise for stability
            var rng = NoiseGenerator(seed: 42)
            // Increase density by lowering the divisor (smaller = more points)
            for _ in 0...Int(size.width * size.height / 8) {
                let x = CGFloat(rng.next()) * size.width
                let y = CGFloat(rng.next()) * size.height
                // Points are slightly more opaque
                let opacity = Double.random(in: 0.1...0.2)
                context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.primary.opacity(opacity)))
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
        .opacity(0.8) // General intensity of the noise layer
    }
}

private struct NoiseGenerator {
    var seed: UInt64
    mutating func next() -> Double {
        seed = seed &* 6364136223846793005 &+ 1
        return Double(seed) / Double(UInt64.max)
    }
}

