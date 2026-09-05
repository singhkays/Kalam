import SwiftUI

struct TriggerPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The trigger")
                .font(SettingsType.styleDiveKicker)
                .compassTracking(SettingsType.trackDiveKicker)
                .textCase(.uppercase)
                .foregroundStyle(Color.kGreen)
                .accessibilityAddTraits(.isHeader)

            (
                Text("One key, ").font(SettingsType.styleDiveDisplay).compassTracking(SettingsType.trackDiveDisplay).foregroundStyle(Color.kInk)
                    + Text("two ways to press it.").font(SettingsType.styleDiveDisplayItalic).compassTracking(SettingsType.trackDiveDisplay).foregroundStyle(Color.kInk2)
            )
            .padding(.top, 9)

            Text(lede)
                .font(SettingsType.styleLede)
                .foregroundStyle(Color.kInk2)
                .padding(.top, 10)

            // Key card
            VStack(spacing: 0) {
                HStack {
                    Text("Key")
                        .font(SettingsType.styleCardHeaderLabel)
                        .compassTracking(SettingsType.trackCardHeaderLabel)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.kInk3)
                    Spacer()
                }
                .padding(SettingsLayout.diveCardHeaderPad)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start recording with")
                            .font(SettingsType.styleRowTitle).compassTracking(SettingsType.trackRowTitle)
                        // Helper reserves no space once a key is set: an
                        // opacity-hidden line still centers the title against
                        // a two-line block and floats it above the chip.
                        if model.hotkey == nil {
                            Text("Pick a preset or record a shortcut.")
                                .font(SettingsType.styleRowDetail)
                                .foregroundStyle(Color.kInk2)
                        }
                    }
                    Spacer()
                    HotkeyControl(hotkey: $model.hotkey)
                }
                .padding(SettingsLayout.diveRowPad)
                .rowTopEdge(first: true)
            }
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(SettingsLayout.cardRadius)
            .padding(.top, 18)

            // Modes as radio list (not a dropdown)
            VStack(spacing: 0) {
                HStack {
                    Text("When you press it")
                        .font(SettingsType.styleCardHeaderLabel)
                        .compassTracking(SettingsType.trackCardHeaderLabel)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.kInk3)
                    Spacer()
                }
                .padding(SettingsLayout.diveCardHeaderPad)
                // Header casts its own shadow into its bottom padding: it sits
                // above all row paint, so it shows in every selection state
                // and never stacks with a selected row's ring (wash-on-row
                // could not survive the ring; padding-gap alternatives jump).
                .overlay(alignment: .bottom) {
                    HeaderWash()
                }

                let lastIndex = ActivationMode.allCases.count - 1
                ForEach(Array(ActivationMode.allCases.enumerated()), id: \.element) { index, mode in
                    let on = model.activation == mode
                    // First row stands 8pt below the header in every state
                    // (mockup `.radiolist` 4 + `.rrow` 4): the header-cast wash
                    // then never abuts the ring, so both states read the same.
                    // Static air only — never selection-dependent.
                    modeRowButton(mode: mode, on: on, bottomMargin: index == 0 ? 4 : (index == lastIndex ? 6 : 4))
                        .padding(.top, index == 0 ? 8 : 0)
                }
            }
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(SettingsLayout.cardRadius)
            .padding(.top, 18)
        }
    }

    @ViewBuilder
    private func modeRowButton(mode: ActivationMode, on: Bool, bottomMargin: CGFloat) -> some View {
        Button {
            model.activation = mode
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(SettingsType.styleRowTitle).compassTracking(SettingsType.trackRowTitle)
                        .foregroundStyle(Color.kInk)
                    Text(mode.detail)
                        .font(SettingsFont.body(11.5))
                        .foregroundStyle(Color.kInk2)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if on {
                    Text("ON")
                        .font(SettingsFont.mono(10))
                        .tracking(0.8)
                        .foregroundStyle(Color.kGreen)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(on ? Color.kGreenT : Color.clear)
            // Green ring on the selected row — onboarding .opt.on grammar (F-10).
            // Inset from the card edge by the outer margins (mockup `.rrow`
            // grammar shared with the Engine Active list); the ring never
            // touches the card border.
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayout.radiusButton)
                    .stroke(on ? Color.kGreen : Color.clear)
            )
            .cornerRadius(SettingsLayout.radiusButton)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, bottomMargin)
    }

    private var lede: String {
        if model.hotkey == nil {
            return "Pick a preset or record a shortcut. Until then Kalam has nothing to start a recording."
        }
        return "The key that starts a recording, and how you press it decides when it stops."
    }
}
