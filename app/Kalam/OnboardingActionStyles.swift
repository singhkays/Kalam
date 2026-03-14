import SwiftUI

enum OnboardingStyleMetrics {
    static let minimumDisclosureTapTarget: CGFloat = 44
    static let compactButtonHeight: CGFloat = 32
    static let regularButtonHeight: CGFloat = 36
    static let compactHorizontalPadding: CGFloat = 14
    static let compactVerticalPadding: CGFloat = 5
    static let regularHorizontalPadding: CGFloat = 20
    static let regularVerticalPadding: CGFloat = 7
    static let compactGlassHorizontalPadding: CGFloat = 11
    static let compactGlassVerticalPadding: CGFloat = 6
    static let glassCornerRadius: CGFloat = 12
    static let compactPremiumCornerRadius: CGFloat = 12
    static let regularPremiumCornerRadius: CGFloat = 14
}

struct OnboardingGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.bold())
            .foregroundStyle(.primary.opacity(configuration.isPressed ? 0.72 : 0.92))
            .padding(.horizontal, OnboardingStyleMetrics.compactGlassHorizontalPadding)
            .padding(.vertical, OnboardingStyleMetrics.compactGlassVerticalPadding)
            .frame(minHeight: OnboardingStyleMetrics.compactButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: OnboardingStyleMetrics.glassCornerRadius)
                    .fill(.ultraThinMaterial.opacity(configuration.isPressed ? 0.72 : 0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OnboardingStyleMetrics.glassCornerRadius)
                    .stroke(Color.primary.opacity(0.16), lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(configuration.isPressed ? 0.08 : 0.14), radius: configuration.isPressed ? 2 : 6, y: 2)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct OnboardingPremiumButtonStyle: ButtonStyle {
    var isCompact: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isCompact ? .footnote.bold() : .headline.bold())
            .foregroundStyle(isEnabled ? .white : .white.opacity(0.6))
            .padding(.horizontal, isCompact ? OnboardingStyleMetrics.compactHorizontalPadding : OnboardingStyleMetrics.regularHorizontalPadding)
            .padding(.vertical, isCompact ? OnboardingStyleMetrics.compactVerticalPadding : OnboardingStyleMetrics.regularVerticalPadding)
            .frame(minHeight: isCompact ? OnboardingStyleMetrics.compactButtonHeight : OnboardingStyleMetrics.regularButtonHeight)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: isCompact ? OnboardingStyleMetrics.compactPremiumCornerRadius : OnboardingStyleMetrics.regularPremiumCornerRadius)
                        .fill(isEnabled ? AnyShapeStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color(nsColor: .controlAccentColor),
                                    Color(nsColor: .controlAccentColor).opacity(0.82)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        ) : AnyShapeStyle(.quaternary))

                    RoundedRectangle(cornerRadius: isCompact ? OnboardingStyleMetrics.compactPremiumCornerRadius : OnboardingStyleMetrics.regularPremiumCornerRadius)
                        .strokeBorder(isEnabled ? .white.opacity(0.2) : .white.opacity(0.05), lineWidth: 1)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: isCompact ? OnboardingStyleMetrics.compactPremiumCornerRadius : OnboardingStyleMetrics.regularPremiumCornerRadius))
            .shadow(color: isEnabled ? Color(nsColor: .controlAccentColor).opacity(configuration.isPressed ? 0.22 : 0.34) : .clear, radius: configuration.isPressed ? 2 : 6, x: 0, y: 2)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1.0)
            .opacity(configuration.isPressed && isEnabled ? 0.92 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: configuration.isPressed)
            .animation(.default, value: isEnabled)
    }
}
