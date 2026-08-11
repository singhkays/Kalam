import SwiftUI

// Shared helpers used by multiple settings tab views (K-04 extraction).

extension Notification.Name {
    static let selectModelsSettingsTab = Notification.Name("selectModelsSettingsTab")
}

extension View {
    func settingsCardSurface(cornerRadius: CGFloat = KalamTheme.wellCornerRadius)
        -> some View
    {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(KalamTheme.wellBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(KalamTheme.wellBorder, lineWidth: 1)
            )
            .overlay(alignment: .top) {
                // Subtle top-edge highlight — lifts the card surface without a drop shadow
                Rectangle()
                    .fill(KalamTheme.cardTopHighlight)
                    .frame(height: 1)
                    .clipShape(
                        .rect(
                            topLeadingRadius: cornerRadius,
                            topTrailingRadius: cornerRadius
                        ))
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
