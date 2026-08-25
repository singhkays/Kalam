import SwiftUI

struct PaperSegment<T: Hashable>: View {
    @Binding var selection: T
    var options: [(T, String)]
    var disabled: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                let on = selection == value
                Button {
                    guard !disabled else { return }
                    withAnimation(SettingsLayout.hoverAnim) {
                        selection = value
                    }
                } label: {
                    Text(title)
                        .font(SettingsFont.body(SettingsType.segment, weight: on ? SettingsType.wMock600 : SettingsType.wRegular))
                        .foregroundStyle(on ? Color.kInk : Color.kInk3)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .frame(minWidth: 72)
                        .background(on ? Color.kPanel : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: SettingsLayout.radiusChip)
                                .stroke(on ? Color.kHair : Color.clear)
                        )
                        .cornerRadius(SettingsLayout.radiusChip)
                        .shadow(color: on ? Color.black.opacity(0.06) : .clear, radius: 1, y: 1)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(Color.kWell)
        .overlay(
            RoundedRectangle(cornerRadius: SettingsLayout.radiusButton)
                .stroke(Color.kHair)
        )
        .cornerRadius(SettingsLayout.radiusButton)
        .opacity(disabled ? SettingsLayout.dimOpacity : 1)
        .allowsHitTesting(!disabled)
    }
}