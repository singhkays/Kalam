import SwiftUI

struct MapView: View {
    @Bindable var model: SettingsModel
    var privacyLine: PrivacyLine
    var onOpen: (Destination) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            mapBar
            SettingsScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // v1 light layout (mockup grammar): kicker + hero + lede directly on paper.
                    Text("The map")
                        .font(SettingsType.styleMapKicker)
                        .foregroundStyle(Color.kGreen)
                        .compassTracking(SettingsType.trackMapKicker)
                        .textCase(.uppercase)
                        .padding(.top, SettingsLayout.mapPad.top)

                    heroTitle
                        .padding(.top, 9)

                    if let cta = model.mapNeedCTA {
                        Text(cta)
                            .font(SettingsType.styleNeedCTA)
                            .foregroundStyle(Color.kGreen)
                            .padding(.top, 12)
                    } else {
                        Text("Open one to change how it works.")
                            .font(SettingsType.styleLede)
                            .foregroundStyle(Color.kInk2)
                            .padding(.top, 8)
                    }

                    mapGrid
                        .padding(.top, 18)

                    MapFoot(
                        version: model.versionString,
                        action: { onOpen(.updates) }
                    )
                    .padding(.top, 16)
                    .padding(.bottom, SettingsLayout.mapPad.bottom)
                }
                .padding(.horizontal, SettingsLayout.mapPad.leading)
            }
        }
        .background(Color.kPaper)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mapBar: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Text("✕")
                    .font(.system(size: SettingsIcon.s12, weight: SettingsIcon.weight))
                    .frame(width: 24, height: 24)
                    .background(Color.kPanel)
                    .overlay(
                        RoundedRectangle(cornerRadius: SettingsLayout.radiusButton)
                            .stroke(Color.kHair)
                    )
                    .foregroundStyle(Color.kInk3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            Text("Kalam")
                .font(SettingsType.styleBarWordmark)
                .compassTracking(SettingsType.trackBarWordmark)
                .foregroundStyle(Color.kInk)

            Spacer()
            PrivacyPill(line: privacyLine)
        }
        .padding(.horizontal, 18)
        .frame(height: SettingsLayout.bar)
        .overlay(alignment: .bottom) {
            // Mockup `.bar` inset hairline: rgba(26,26,24,.10) light, white @8% dark (body.dark .bar).
            Rectangle().fill(Color.kBarHair).frame(height: 1)
        }
    }

    private var heroTitle: some View {
        let hero = model.hero
        let full = hero.text
        let italic = hero.italicSuffix
        // Render trailing italic emphasis per contract (real Instrument Serif italic).
        // Mockup `.hero`: serif 36 w400, ls -.014em (trackMapHero) — tracking kept.
        if let range = full.range(of: italic, options: [.backwards]) {
            let prefix = String(full[..<range.lowerBound])
            return Text(prefix).font(SettingsType.styleMapHero).compassTracking(SettingsType.trackMapHero).foregroundStyle(Color.kInk)
                + Text(italic).font(SettingsType.styleMapHeroItalic).compassTracking(SettingsType.trackMapHero).foregroundStyle(Color.kInk2)
        }
        return Text(full).font(SettingsType.styleMapHero).compassTracking(SettingsType.trackMapHero).foregroundStyle(Color.kInk)
            + Text("").font(SettingsType.styleMapHero).compassTracking(SettingsType.trackMapHero)
    }

    private var mapGrid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: SettingsLayout.gridGap),
            count: 3
        )
        return LazyVGrid(columns: columns, spacing: SettingsLayout.gridGap) {
            ForEach(Destination.journey) { dest in
                let span = model.spanning == dest
                let attentionStyle = model.attention == dest
                MapCard(
                    destination: dest,
                    title: model.mapCardTitle(for: dest),
                    state: model.mapCardState(for: dest),
                    description: model.mapCardDescription(for: dest),
                    isAttentionLarge: attentionStyle,
                    isWideFill: span && !attentionStyle
                ) {
                    onOpen(dest)
                }
                .gridCellColumns(span ? 2 : 1)
            }
        }
    }
}

struct MapFoot: View {
    var version: String
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Updates")
                        .font(SettingsType.styleMapFootTitle)
                        .fontWeight(.regular) // macOS Button semibolds label Text (v1.3.3)
                        .compassTracking(SettingsType.trackMapFootTitle)
                        .foregroundStyle(Color.kInk)
                    Text("v\(version) · No auto-check")
                        .font(SettingsFont.body(SettingsType.mapCardBody))
                        .foregroundStyle(Color.kInk2)
                }
                Spacer()
                Text("Open →")
                    .font(SettingsFont.body(SettingsType.mapOpenHint))
                    .foregroundStyle(Color.kGreen.opacity(0.72))
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.kPanel)
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayout.cardRadius)
                    .stroke(hovering ? Color.kGreen.opacity(0.35) : Color.kHair)
            )
            .cornerRadius(SettingsLayout.cardRadius)
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
        .accessibilityLabel("Updates, version \(version), No auto-check")
    }
}
