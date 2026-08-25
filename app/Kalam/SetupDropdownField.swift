import SwiftUI

/// Shared setup-screen dropdown trigger (decimal and time punctuation corruption): a grounded control well —
/// solid deck tile fill + deck hairline at the shared 8pt button radius —
/// replacing the translucent material that resolved to nearly the charcoal
/// card color and read as a plain label. Compact chip height matches the
/// Settings trigger recipe (12h-pad / 5v-pad / mono 12.5 / 10pt chevron).
struct SetupDropdownField<T: Equatable & Identifiable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button(label(option)) {
                    selection = option
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(label(selection))
                    .font(SettingsFont.mono(12.5))
                    .foregroundStyle(OnboardingDeckTokens.ink)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(OnboardingDeckTokens.ink3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            // hotkey onboarding card UX boxed-control recipe: well core separates from the card
            // ground in both appearances; defined edge + lit top + shadow
            // make it read as a press target.
            .background(OnboardingDeckTokens.well)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(OnboardingDeckTokens.controlEdge, lineWidth: 1)
            )
            .background(
                Rectangle()
                    .fill(OnboardingDeckTokens.controlTopHighlight)
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false),
                alignment: .top
            )
            .shadow(color: OnboardingDeckTokens.controlRestShadow, radius: 2, y: 1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // accessibility labels for icon-only buttons: expose the control to VoiceOver as a labeled pop-up button.
        .accessibilityLabel(Text(label(selection)))
        .accessibilityHint("Opens a menu of options.")
    }
}
