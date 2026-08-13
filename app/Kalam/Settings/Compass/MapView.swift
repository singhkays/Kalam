import SwiftUI

struct MapView: View {
    @Bindable var model: SettingsModel
    var privacyLine: PrivacyLine
    var onOpen: (Destination) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            mapBar
            CompassScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("The map")
                        .font(CompassType.styleMapKicker)
                        .foregroundStyle(Color.kGreen)
                        .compassTracking(CompassType.trackMapKicker)
                        .textCase(.uppercase)
                        .padding(.top, CompassLayout.mapPad.top)

                    heroBlock
                        .padding(.top, 8)

                    mapGrid
                        .padding(.top, 18)

                    MapFoot(
                        version: model.versionString,
                        action: { onOpen(.updates) }
                    )
                    .padding(.top, 16)
                    .padding(.bottom, CompassLayout.mapPad.bottom)
                }
                .padding(.horizontal, CompassLayout.mapPad.leading)
            }
        }
        .background(Color.kPaper)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mapBar: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Text("✕")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
                    .background(Color.kPanel)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.kHair))
                    .foregroundStyle(Color.kInk3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            Text("Kalam")
                .font(CompassType.styleBarWordmark)
                .compassTracking(CompassType.trackBarWordmark)
                .foregroundStyle(Color.kInk)

            Spacer()
            PrivacyPill(line: privacyLine)
        }
        .padding(.horizontal, 18)
        .frame(height: CompassLayout.bar)
        .overlay(alignment: .bottom) { Divider().background(Color.kHair) }
    }

    @ViewBuilder
    private var heroBlock: some View {
        let hero = model.hero
        heroTitle(hero)
        if let cta = model.mapNeedCTA {
            Text(cta)
                .font(CompassType.styleNeedCTA)
                .foregroundStyle(Color.kGreen)
                .padding(.top, 12)
        } else {
            Text("Open one to change how it works.")
                .font(CompassType.styleLede)
                .foregroundStyle(Color.kInk2)
                .padding(.top, 8)
        }
    }

    private func heroTitle(_ hero: MapHero) -> some View {
        let full = hero.text
        let italic = hero.italicSuffix
        // Render trailing italic emphasis per contract. Mockup `.hero`: serif 32 w400, ls -.022em.
        if let range = full.range(of: italic, options: [.backwards]) {
            let prefix = String(full[..<range.lowerBound])
            return Text(prefix).font(CompassType.styleMapHero).compassTracking(CompassType.trackMapHero).foregroundStyle(Color.kInk)
                + Text(italic).font(CompassType.styleMapHeroItalic).compassTracking(CompassType.trackMapHero).foregroundStyle(Color.kInk2)
        }
        return Text(full).font(CompassType.styleMapHero).compassTracking(CompassType.trackMapHero).foregroundStyle(Color.kInk)
            + Text("").font(CompassType.styleMapHero).compassTracking(CompassType.trackMapHero)
    }

    private var mapGrid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: CompassLayout.gridGap),
            count: 3
        )
        return LazyVGrid(columns: columns, spacing: CompassLayout.gridGap) {
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

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Updates")
                        .font(CompassType.styleMapFootTitle)
                        .compassTracking(CompassType.trackMapFootTitle)
                        .foregroundStyle(Color.kInk)
                    Text("v\(version) · No auto-check")
                        .font(CompassFont.body(CompassType.mapCardBody))
                        .foregroundStyle(Color.kInk2)
                }
                Spacer()
                Text("Open →")
                    .font(CompassFont.body(12))
                    .foregroundStyle(Color.kGreen.opacity(0.72))
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.kPanel)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(hovering ? Color.kGreen.opacity(0.35) : Color.kHair)
            )
            .cornerRadius(14)
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
        .accessibilityLabel("Updates, version \(version), No auto-check")
    }
}
