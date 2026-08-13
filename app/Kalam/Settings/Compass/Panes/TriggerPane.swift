import SwiftUI

struct TriggerPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The trigger")
                .font(CompassType.styleDiveKicker)
                .compassTracking(CompassType.trackDiveKicker)
                .textCase(.uppercase)
                .foregroundStyle(Color.kGreen)

            (
                Text("One key, ").font(CompassType.styleDiveDisplay).compassTracking(CompassType.trackDiveDisplay).foregroundStyle(Color.kInk)
                    + Text("two ways to press it.").font(CompassType.styleDiveDisplayItalic).compassTracking(CompassType.trackDiveDisplay).foregroundStyle(Color.kInk2)
            )
            .padding(.top, 9)

            Text(lede)
                .font(CompassType.styleLede)
                .foregroundStyle(Color.kInk2)
                .padding(.top, 10)

            // Key card
            VStack(spacing: 0) {
                HStack {
                    Text("Key")
                        .font(CompassType.styleCardHeaderLabel)
                        .compassTracking(CompassType.trackCardHeaderLabel)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.kInk3)
                    Spacer()
                }
                .padding(CompassLayout.diveCardHeaderPad)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Key")
                            .font(CompassType.styleRowTitle).compassTracking(CompassType.trackRowTitle)
                        Text(model.hotkey == nil ? "Pick a preset or record a shortcut." : "Pick a preset or record any shortcut.")
                            .font(CompassType.styleRowDetail)
                            .foregroundStyle(Color.kInk2)
                            .opacity(model.hotkey == nil ? 1 : 0)
                    }
                    Spacer()
                    HotkeyControl(hotkey: $model.hotkey)
                }
                .padding(CompassLayout.diveRowPad)
            }
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: CompassLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(CompassLayout.cardRadius)
            .padding(.top, 18)

            // Modes as radio list (not a dropdown)
            VStack(spacing: 0) {
                HStack {
                    Text("When you press it")
                        .font(CompassType.styleCardHeaderLabel)
                        .compassTracking(CompassType.trackCardHeaderLabel)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.kInk3)
                    Spacer()
                }
                .padding(CompassLayout.diveCardHeaderPad)

                ForEach(ActivationMode.allCases, id: \.self) { mode in
                    let on = model.activation == mode
                    Button {
                        model.activation = mode
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.title)
                                    .font(CompassFont.body(13.5).weight(.semibold))
                                    .foregroundStyle(Color.kInk)
                                Text(mode.detail)
                                    .font(CompassFont.body(11.5))
                                    .foregroundStyle(Color.kInk2)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                            if on {
                                Text("ON")
                                    .font(CompassFont.mono(10))
                                    .tracking(0.8)
                                    .foregroundStyle(Color.kGreen)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .background(on ? Color.kGreenT : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .top) { Divider().background(Color.kHair2) }
                }
            }
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: CompassLayout.cardRadius).stroke(Color.kHair))
            .cornerRadius(CompassLayout.cardRadius)
            .padding(.top, 18)
        }
    }

    private var lede: String {
        if model.hotkey == nil {
            return "Pick a preset or record a shortcut. Until then Kalam has nothing to start a recording."
        }
        return "The key that starts a recording, and how you press it decides when it stops."
    }
}
