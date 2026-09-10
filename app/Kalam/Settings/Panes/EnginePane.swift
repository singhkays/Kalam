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

            EngineGetTheModelCard(model: model)
                .padding(.top, 18)

            EngineActiveCard(model: model)
                .padding(.top, 18)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Why there is no auto download")
                        .font(SettingsType.styleCardHeaderLabel)
                        .compassTracking(SettingsType.trackCardHeaderLabel)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.kInk3)
                    Spacer()
                }
                .padding(SettingsLayout.diveCardHeaderPad)
                // Header casts its own shadow into its bottom padding
                // (v1.3.8): matches the Setup / Active model / Key headers.
                .overlay(alignment: .bottom) {
                    HeaderWash()
                }

                Text("Kalam is compiled without network entitlements, so you bring the model; the app never fetches one.")
                    .font(SettingsFont.body(12.5))
                    .foregroundStyle(Color.kInk2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
            }
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(SettingsLayout.cardRadius)
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Crash recovery")
                        .font(SettingsType.styleCardHeaderLabel)
                        .compassTracking(SettingsType.trackCardHeaderLabel)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.kInk3)
                    Spacer()
                }
                .padding(SettingsLayout.diveCardHeaderPad)
                // Header casts its own shadow into its bottom padding
                // (v1.3.8): matches the Setup / Active model / Key headers.
                .overlay(alignment: .bottom) {
                    HeaderWash()
                }

                VStack(alignment: .leading, spacing: 8) {
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
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 14)
            }
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(SettingsLayout.cardRadius)
            .padding(.top, 14)
        }
        // No rescan-on-appear: the body above already reads live state on
        // first render (populating the backing memo), and returning later
        // reuses it. An appear-time rescan would wipe the memo and force a
        // second full cold evaluation on every entry. Fresh disk truth comes
        // from Check again, folder change, and config notifications instead.
    }

    /// Lede variants come from the Task 1 wizard routing: first-run Missing
    /// carries the work estimate (`3 steps · ~5 min · Terminal once`, D1);
    /// the other states carry their own D-figure lede. Setup header trailing
    /// likewise comes from routing (`model.setupStep.headerTrailing`,
    /// rendered inside the wizard card).
    private var lede: String {
        model.setupStep.lede
    }
}
