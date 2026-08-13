import SwiftUI

struct MapCard: View {
    var destination: Destination
    var title: String
    var state: (text: String, ok: Bool)
    var description: String
    var isAttentionLarge: Bool
    var isWideFill: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(destination.title)
                        .font(CompassFont.mono(CompassType.mapCardKicker))
                        .tracking(1.6)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.kInk3)
                    Spacer()
                    if let n = destination.number {
                        Text(n)
                            .font(CompassFont.mono(9.5))
                            .foregroundStyle(Color.kInk3)
                    }
                }

                Text(title)
                    .font(CompassFont.display(isAttentionLarge ? CompassType.mapCardTitleLarge : CompassType.mapCardTitle))
                    .foregroundStyle(Color.kInk)
                    .padding(.top, isAttentionLarge ? 6 : 8)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Circle()
                        .fill(state.ok ? Color.kGreen : Color.kInk3)
                        .frame(width: 6, height: 6)
                    Text(state.text)
                        .font(CompassFont.mono(9))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.kInk3)
                }
                .padding(.top, 6)
                .accessibilityHidden(true)

                Text(description)
                    .font(CompassFont.body(CompassType.mapCardBody))
                    .foregroundStyle(Color.kInk2)
                    .padding(.top, 5)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 12)

                Text("Open →")
                    .font(CompassFont.body(CompassType.mapOpenHint))
                    .foregroundStyle(Color.kGreen.opacity(hovering ? 0.92 : 0.62))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(CompassLayout.mapCardPad)
            .frame(maxWidth: .infinity, minHeight: isAttentionLarge ? CompassLayout.mapCardMinLarge : CompassLayout.mapCardMin, alignment: .topLeading)
            .background(Color.kPanel)
            .overlay(
                RoundedRectangle(cornerRadius: CompassLayout.mapCardRadius)
                    .stroke(borderColor, lineWidth: 1)
            )
            .cornerRadius(CompassLayout.mapCardRadius)
            .offset(y: hovering ? CompassLayout.hoverLift : 0)
            .shadow(
                color: hovering ? Color.black.opacity(0.12) : .clear,
                radius: hovering ? CompassLayout.hoverShadowRadius : 0,
                y: hovering ? CompassLayout.hoverShadowY : 0
            )
        }
        .buttonStyle(.plain)
        .animation(CompassLayout.hoverAnim, value: hovering)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(destination.title), \(state.text), \(title)")
    }

    private var borderColor: Color {
        if isAttentionLarge {
            return Color.kGreen.opacity(CompassLayout.attentionHairOpacity)
        }
        if hovering {
            return Color.kGreen.opacity(0.35)
        }
        return Color.kHair
    }
}
