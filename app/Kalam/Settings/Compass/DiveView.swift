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
                .frame(width: CompassLayout.contentsWidth)

                Rectangle()
                    .fill(Color.kHair)
                    .frame(width: 1)

                CompassScrollView {
                    pane
                        .padding(CompassLayout.diveMainPad)
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.kGreen)
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color.kInk3)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Color.kPanel)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kHair))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to overview")

            Text("Kalam")
                .font(CompassType.styleBarWordmark)
                .compassTracking(CompassType.trackBarWordmark)
                .padding(.leading, 4)

            Spacer()
            PrivacyPill(line: privacyLine)
        }
        .padding(.horizontal, 18)
        .frame(height: CompassLayout.bar)
        .overlay(alignment: .bottom) { Divider().background(Color.kHair) }
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
