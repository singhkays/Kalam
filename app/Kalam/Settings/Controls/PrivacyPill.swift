import SwiftUI

/// Static privacy line. Parent owns the rolled value (once per window).
/// v1 light chrome (mockup `.priv-pill`): quiet ink-3 text, no chip.
struct PrivacyPill: View {
    var line: PrivacyLine

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: SettingsIcon.s12, weight: SettingsIcon.weight))
            Text(line.rawValue)
        }
        .font(SettingsType.stylePrivacy)
        .textCase(.uppercase)
        .compassTracking(SettingsType.trackPrivacy)
        .foregroundStyle(Color.kInk3)
        .accessibilityElement(children: .combine)
    }
}
