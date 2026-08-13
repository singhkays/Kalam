import SwiftUI

struct PaperSegment<T: Hashable>: View {
    @Binding var selection: T
    var options: [(T, String)]
    var disabled: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let on = selection == value
                Button {
                    guard !disabled else { return }
                    selection = value
                } label: {
                    Text(title)
                        .font(CompassFont.body(12).weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.kInk : Color.kInk3)
                        .padding(CompassLayout.segmentPad)
                        .background(on ? Color.kPanel : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: CompassLayout.segmentRadius)
                                .stroke(on ? Color.kHair : Color.clear)
                        )
                        .cornerRadius(CompassLayout.segmentRadius)
                        .shadow(color: on ? Color.black.opacity(0.06) : .clear, radius: 0.5, y: 1)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .opacity(disabled ? CompassLayout.dimOpacity : 1)
        .allowsHitTesting(!disabled)
    }
}
