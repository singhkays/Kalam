import SwiftUI

struct MapCard: View {
    var destination: Destination
    var title: String
    var state: (text: String, tone: MapStateTone)
    var description: String
    var isAttentionLarge: Bool
    var isWideFill: Bool
    var action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(destination.title)
                        .font(SettingsType.styleMapCardKicker)
                        .compassTracking(SettingsType.trackMapCardKicker)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.kInk3)
                    Spacer()
                    if let n = destination.number {
                        Text(n)
                            .font(SettingsType.styleMapCardNum)
                            .foregroundStyle(Color.kInk3)
                    }
                }

                Text(title)
                    .font(isAttentionLarge ? SettingsType.styleMapCardTitleLarge : SettingsType.styleMapCardTitle)
                    .fontWeight(.regular) // macOS Button semibolds label Text (v1.3.3)
                    .compassTracking(SettingsType.trackMapCardTitle)
                    .foregroundStyle(Color.kInk)
                    .padding(.top, isAttentionLarge ? 6 : 8)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 6, height: 6)
                    Text(state.text)
                        .font(SettingsType.styleMapCardState)
                        .compassTracking(SettingsType.trackMonoState)
                        .textCase(.uppercase)
                        // Mockup (v1.3.2 Part 17): label is ink3; only the 6px dot carries tone.
                        .foregroundStyle(stateLabelColor)
                }
                .padding(.top, 6)
                .accessibilityHidden(true)

                Text(description)
                    .font(SettingsFont.body(SettingsType.mapCardBody, weight: SettingsType.wLight))
                    .fontWeight(.light) // Part 21: description is Light; Button would semibold it
                    .foregroundStyle(Color.kInk2)
                    .padding(.top, 5)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 12)

                Text("Open →")
                    .font(SettingsFont.body(SettingsType.mapOpenHint))
                    .foregroundStyle(Color.kGreen.opacity(hovering ? 0.92 : 0.62))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(SettingsLayout.mapCardPad)
            .frame(maxWidth: .infinity, minHeight: isAttentionLarge ? SettingsLayout.mapCardMinLarge : SettingsLayout.mapCardMin, alignment: .topLeading)
            .background(Color.kPanel)
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayout.mapCardRadius)
                    .stroke(borderColor, lineWidth: 1)
            )
            .cornerRadius(SettingsLayout.mapCardRadius)
            .offset(y: hovering && !reduceMotion ? SettingsLayout.hoverLift : 0)
            .shadow(
                // Light mockup grammar (v1.3): subtle resting shadow; hover elevation.
                color: hovering ? Color.kHoverShadow : SettingsLayout.cardRestShadow,
                radius: hovering ? SettingsLayout.hoverShadowRadius : SettingsLayout.cardRestShadowRadius,
                y: hovering ? SettingsLayout.hoverShadowY : SettingsLayout.cardRestShadowY
            )
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : SettingsLayout.hoverAnim, value: hovering)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(destination.title), \(state.text), \(title)")
    }

    private var stateColor: Color {
        switch state.tone {
        case .ok: return Color.kGreen
        case .neutral: return Color.kInk3
        case .warn: return Color.kWarn
        case .bad: return Color.kBad
        }
    }

    /// Text color for the status word: ink3 for ok/neutral (mockup `.state` is ink3 —
    /// only the pip recolours); warn/bad keep hue so failure states still read.
    private var stateLabelColor: Color {
        switch state.tone {
        case .ok, .neutral: return Color.kInk3
        case .warn: return Color.kWarn
        case .bad: return Color.kBad
        }
    }

    private var borderColor: Color {
        if isAttentionLarge {
            return Color.kAttentionEdge
        }
        if hovering {
            return Color.kHoverEdge
        }
        return Color.kHair
    }
}
