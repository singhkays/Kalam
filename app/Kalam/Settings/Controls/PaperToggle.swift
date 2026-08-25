import AppKit
import SwiftUI

struct PaperToggle: View {
    @Binding var isOn: Bool
    var disabled: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            guard !disabled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.kGreen : Color.kOff)
                    .frame(
                        width: SettingsLayout.toggleSize.width,
                        height: SettingsLayout.toggleSize.height
                    )
                Circle()
                    .fill(Color.white)
                    .frame(width: SettingsLayout.toggleKnob, height: SettingsLayout.toggleKnob)
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                    .padding(SettingsLayout.toggleInset)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? SettingsLayout.dimOpacity : 1)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
        .frame(minHeight: 28)
    }
}
