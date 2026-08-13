import SwiftUI

/// Static privacy line. Parent owns the rolled value (once per window).
struct PrivacyPill: View {
    var line: PrivacyLine

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 11, weight: .regular))
            Text(line.rawValue)
        }
        .font(CompassFont.mono(CompassType.privacy))
        .textCase(.uppercase)
        .tracking(1.0)
        .foregroundStyle(Color.kInk3)
        .accessibilityElement(children: .combine)
    }
}
