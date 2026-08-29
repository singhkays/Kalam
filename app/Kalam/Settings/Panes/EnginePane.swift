import SwiftUI

struct EnginePane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The engine")
                .font(SettingsType.styleDiveKicker)
                .compassTracking(SettingsType.trackDiveKicker)
                .textCase(.uppercase)
                .foregroundStyle(Color.kGreen)
                .accessibilityAddTraits(.isHeader)

            (
                Text("The engine ").font(SettingsType.styleDiveDisplay).compassTracking(SettingsType.trackDiveDisplay).foregroundStyle(Color.kInk)
                    + Text("lives on your disk.").font(SettingsType.styleDiveDisplayItalic).compassTracking(SettingsType.trackDiveDisplay).foregroundStyle(Color.kInk2)
            )
            .padding(.top, 9)

            Text(lede)
                .font(SettingsType.styleLede)
                .foregroundStyle(Color.kInk2)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)

            EngineWhereItLivesCard(model: model)
                .padding(.top, 18)

            EngineGetTheModelCard(model: model)
                .padding(.top, 14)

            EngineActiveCard(model: model)
                .padding(.top, 18)

            VStack(alignment: .leading, spacing: 7) {
                Text("Why there is no download")
                    .font(SettingsFont.mono(9))
                    .tracking(2.0)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.kInk3)
                Text("Kalam is compiled without network entitlements, so you bring the model; the app never fetches one.")
                    .font(SettingsFont.body(12.5))
                    .foregroundStyle(Color.kInk2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(SettingsLayout.cardRadius)
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 8) {
                Text("Crash recovery")
                    .font(SettingsFont.mono(9))
                    .tracking(2.0)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.kInk3)
                Toggle("Keep audio for recovery (7 days)", isOn: Binding(
                    get: { model.retentionEnabled },
                    set: { model.retentionEnabled = $0 }
                ))
                .font(SettingsFont.body(12.5))
                .tint(Color.kGreen)
                Text("When on, Kalam streams each dictation to ~/Library/Application Support/Kalam/recordings/<timestamp>-<uuid>/audio.caf + meta.json. Audio never leaves this Mac. 7-day TTL, 6h sweep. Default OFF — when off, no audio touches disk (verified via fs_usage).")
                    .font(SettingsFont.body(11))
                    .foregroundStyle(Color.kInk2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(SettingsLayout.cardRadius)
            .padding(.top, 14)
        }
        .onAppear { model.rescanEngine() }
    }

    private var lede: String {
        switch model.engine {
        case .verified:
            return "You supply the model and Kalam loads it locally on the Apple Neural Engine."
        case .missing:
            return "No model in this folder yet. Copy the Parakeet files here and return when they are in place."
        case .incomplete:
            return "This folder is not a full model yet. Copy the remaining Parakeet files and return when they are in place."
        }
    }
}
