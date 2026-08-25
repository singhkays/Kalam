import SwiftUI

struct ContentsNav: View {
    var current: Destination
    @Bindable var model: SettingsModel
    var onSelect: (Destination) -> Void

    @State private var hoveringDest: Destination?

    /// All rows in display order (journey + maintenance footer).
    private var rows: [Destination] { Destination.journey + [.updates] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Destination.journey) { dest in
                row(dest)
            }

            Spacer(minLength: 0)

            Rectangle()
                .fill(Color.kHair)
                .frame(height: 1)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            row(.updates, maintenance: true)
        }
        .padding(SettingsLayout.contentsPad)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.kPaper)
    }

    private func row(_ dest: Destination, maintenance: Bool = false) -> some View {
        let on = current == dest
        return Button {
            onSelect(dest)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Index shares the title line-box (18pt) so caps align with the name, not the multi-line block.
                Text(dest.contentsIndex)
                    .font(SettingsType.styleContentsIndex)
                    .foregroundStyle(on ? Color.kGreen : Color.kInk3)
                    .frame(width: SettingsLayout.contentsIndexWidth, height: SettingsLayout.contentsTitleLine, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(dest.title)
                        .font(SettingsType.styleContentsTitle(selected: on, maintenance: maintenance))
                        .foregroundStyle(on ? Color.kInk : Color.kInk2)
                        .compassTracking(SettingsType.trackContentsTitle)
                        .frame(height: SettingsLayout.contentsTitleLine, alignment: .center)
                    Text(dest.subtitle)
                        .font(SettingsType.styleContentsSubtitle)
                        .foregroundStyle(Color.kInk3)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(on ? Color.kGreen : Color.kInk3)
                            .frame(width: 6, height: 6)
                        Text(model.contentsState(for: dest))
                            .font(SettingsType.styleContentsState)
                            // mixed case for ⌘ and short states
                            .foregroundStyle(on ? Color.kGreen : Color.kInk3)
                    }
                    .padding(.top, 6)
                }
                .padding(.leading, 8)
                Spacer(minLength: 0)
            }
            .padding(SettingsLayout.contentsRowPad)
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground(on: on, for: dest))
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayout.contentsRowRadius)
                    .stroke(on ? Color.kGreen.opacity(0.22) : Color.clear)
            )
            // Full-row hit area (settings redesign fidelity fix).
            .contentShape(RoundedRectangle(cornerRadius: SettingsLayout.contentsRowRadius))
            .cornerRadius(SettingsLayout.contentsRowRadius)
            .opacity(maintenance && !on ? 0.8 : 1)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveringDest = inside ? dest : nil
        }
        .animation(.easeOut(duration: 0.15), value: hoveringDest)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityLabel(
            // VoiceOver announces position in the section list, like the onboarding "step n of m" (F-11).
            "\(dest.title), \(model.contentsState(for: dest)), section \(position(of: dest)) of \(rows.count)"
        )
    }

    /// Mockup: `.chapter.on` = green-tint + hairline; `.chapter:hover:not(.on)` = 4% green tint.
    private func rowBackground(on: Bool, for dest: Destination) -> Color {
        if on { return Color.kGreenT }
        if hoveringDest == dest { return Color.kGreen.opacity(0.04) }
        return .clear
    }

    private func position(of dest: Destination) -> Int {
        (rows.firstIndex(of: dest) ?? 0) + 1
    }
}
