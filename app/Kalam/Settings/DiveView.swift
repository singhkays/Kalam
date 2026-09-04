import SwiftUI

struct DiveView: View {
    var destination: Destination
    @Binding var path: [Destination]
    @Bindable var model: SettingsModel
    var privacyLine: PrivacyLine

    var body: some View {
        VStack(spacing: 0) {
            diveBar
            HStack(spacing: 0) {
                ContentsNav(
                    current: destination,
                    model: model,
                    onSelect: { path = [$0] }
                )
                .frame(width: SettingsLayout.contentsWidth)

                Rectangle()
                    .fill(Color.kRailHair) // mockup `.contents` divider; white @8% in dark (body.dark .contents)
                    .frame(width: 1)

                SettingsScrollView {
                    pane
                        .padding(SettingsLayout.diveMainPad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.kPaper)
        .navigationBarBackButtonHidden(true)
    }

    private var diveBar: some View {
        HStack(spacing: 12) {
            Button {
                path = []
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: SettingsIcon.s12, weight: SettingsIcon.weight))
                        .foregroundStyle(Color.kGreen)
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: SettingsIcon.s12, weight: SettingsIcon.weight))
                        .foregroundStyle(Color.kInk3)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Color.kPanel)
                .overlay(RoundedRectangle(cornerRadius: SettingsLayout.radiusButton).stroke(Color.kHair))
                .cornerRadius(SettingsLayout.radiusButton)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to overview")

            Text("Kalam")
                .font(SettingsType.styleBarWordmark)
                .compassTracking(SettingsType.trackBarWordmark)
                .foregroundStyle(Color.kInk)
                .padding(.leading, 4)

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

    @ViewBuilder
    private var pane: some View {
        switch destination {
        case .beingHeard: BeingHeardPane(model: model)
        case .trigger: TriggerPane(model: model)
        case .cleanup: CleanupPane(model: model)
        case .dictionary: DictionaryPane(model: model)
        case .engine: EnginePane(model: model)
        case .updates: UpdatesPane(model: model)
        }
    }
}
