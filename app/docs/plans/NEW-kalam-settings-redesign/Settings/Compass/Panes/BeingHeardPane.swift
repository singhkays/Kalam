import AppKit
import SwiftUI

struct BeingHeardPane: View {
    @Bindable var model: SettingsModel

    private var behaviorOnCount: Int {
        [model.launchAtLogin, model.showInDock, model.escapeCancels, model.muteOtherAudio]
            .filter(\.self).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Being heard")
                .font(CompassType.styleDiveKicker)
                .compassTracking(CompassType.trackDiveKicker)
                .textCase(.uppercase)
                .foregroundStyle(Color.kGreen)

            (
                Text("How Kalam ").font(CompassType.styleDiveDisplay).foregroundStyle(Color.kInk)
                    + Text("hears you.").font(CompassType.styleDiveDisplay.italic()).foregroundStyle(Color.kInk2)
            )
            .padding(.top, 9)

            Text(lede)
                .font(CompassType.styleLede)
                .foregroundStyle(Color.kInk2)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)

            behaviorCard
            microphoneCard
        }
    }

    private var lede: String {
        switch model.microphonePermission {
        case .denied:
            return "macOS has not allowed microphone access, so Kalam cannot hear you until you allow it."
        case .granted, .notDetermined:
            if model.microphones.isEmpty {
                return "Nothing on this list is connected; Kalam will use the highest-priority device that comes back."
            }
            if model.connectedMicrophone == nil {
                return "Nothing on this list is connected; Kalam will use the highest-priority device that comes back."
            }
            return "Behaviors and microphone priority: Kalam records with the highest connected device on this list."
        }
    }

    private var behaviorCard: some View {
        VStack(spacing: 0) {
            cardHeader("Behavior", trailing: "\(behaviorOnCount) on")
            toggleRow("Launch at login", "Starts with the Mac and waits in the menu bar.", $model.launchAtLogin)
            toggleRow("Show in Dock", "Off keeps Kalam out of the app switcher.", $model.showInDock)
            toggleRow("Escape cancels recording", "Discards the take.", $model.escapeCancels)
            toggleRow("Mute other audio while recording", "Pauses playback.", $model.muteOtherAudio)
            indicatorRow
        }
        .background(Color.kPanel)
        .overlay(RoundedRectangle(cornerRadius: CompassLayout.cardRadius).stroke(Color.kHair))
        .cornerRadius(CompassLayout.cardRadius)
        .padding(.top, 18)
    }

    private var indicatorRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording indicator")
                    .font(CompassType.styleRowTitle)
                        .compassTracking(CompassType.trackRowTitle)
                Text("Where the listening pill appears.")
                    .font(CompassFont.body(CompassType.rowDetail))
                    .foregroundStyle(Color.kInk2)
            }
            Spacer()
            // D.1e: Menu anchored to chip — single-select, never toggles inside.
            Menu {
                ForEach(IndicatorPlacement.allCases, id: \.self) { place in
                    Button {
                        model.indicator = place
                    } label: {
                        HStack {
                            Text(place.label)
                            if model.indicator == place {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(model.indicator.label)
                        .font(CompassFont.mono(CompassType.hotkeyChip))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.kInk3)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kHair))
                .cornerRadius(8)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(CompassLayout.diveRowPad)
        .overlay(alignment: .top) { Divider().background(Color.kHair2) }
    }

    private var microphoneCard: some View {
        VStack(spacing: 0) {
            cardHeader(
                "Microphone priority",
                trailing: micHeaderTrailing ?? "Highest connected wins",
                trailingDim: model.connectedMicrophone == nil
            )

            if model.microphonePermission == .denied {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Microphone access is off")
                        .font(CompassFont.body(13.5).weight(.semibold))
                        .foregroundStyle(Color.kInk)
                    Text("Privacy & Security → Microphone → Kalam")
                        .font(CompassFont.body(13))
                        .foregroundStyle(Color.kInk2)
                    Button("Open System Settings") {
                        openMicrophonePrivacySettings()
                    }
                    .buttonStyle(CompassPrimaryButtonStyle())
                    .padding(.top, 14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            } else if model.microphones.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No microphones yet")
                        .font(CompassFont.body(13.5).weight(.semibold))
                    Text("When macOS lists an input it shows up here. Plug in a mic or enable one in System Settings.")
                        .font(CompassFont.body(13))
                        .foregroundStyle(Color.kInk2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            } else {
                ForEach(Array(model.microphones.enumerated()), id: \.element.id) { index, mic in
                    let status = model.microphoneStatus(for: mic)
                    let inUse = status == "IN USE"
                    let offline = status == "OFFLINE"
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(CompassType.styleMicRank)
                            .foregroundStyle(inUse ? Color.kGreen : Color.kInk3)
                            .frame(width: 28, alignment: .center)

                        Text(mic.name)
                            .font(CompassType.styleMicName)
                            .compassTracking(CompassType.trackRowTitle)
                            .foregroundStyle(offline ? Color.kInk2 : Color.kInk)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(status)
                            .font(CompassType.styleStatusTag)
                            .compassTracking(CompassType.trackStatusTag)
                            .foregroundStyle(inUse ? Color.kGreen : Color.kInk3)

                        VStack(spacing: 2) {
                            Button {
                                model.moveMicrophoneUp(id: mic.id)
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 9, weight: .semibold))
                                    .frame(width: 28, height: 18)
                            }
                            .buttonStyle(MicStepButtonStyle())
                            .disabled(index == 0)
                            .accessibilityLabel("Move \(mic.name) up")

                            Button {
                                model.moveMicrophoneDown(id: mic.id)
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .frame(width: 28, height: 18)
                            }
                            .buttonStyle(MicStepButtonStyle())
                            .disabled(index >= model.microphones.count - 1)
                            .accessibilityLabel("Move \(mic.name) down")
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .opacity(offline ? 0.72 : 1)
                    .overlay(alignment: .top) { Divider().background(Color.kHair2) }
                }
            }
        }
        .background(Color.kPanel)
        .overlay(RoundedRectangle(cornerRadius: CompassLayout.cardRadius).stroke(Color.kHair))
        .cornerRadius(CompassLayout.cardRadius)
        .padding(.top, 18)
    }

    private var micHeaderTrailing: String? {
        if model.microphonePermission == .denied { return "Permission denied" }
        if model.microphones.isEmpty { return "None found" }
        if model.connectedMicrophone == nil { return "None connected" }
        return nil
    }

    private func toggleRow(_ title: String, _ detail: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(CompassType.styleRowTitle)
                        .compassTracking(CompassType.trackRowTitle)
                Text(detail).font(CompassType.styleRowDetail).foregroundStyle(Color.kInk2)
            }
            Spacer()
            PaperToggle(isOn: binding)
        }
        .padding(CompassLayout.diveRowPad)
        .overlay(alignment: .top) { Divider().background(Color.kHair2) }
    }

    private func cardHeader(_ title: String, trailing: String? = nil, trailingDim: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(CompassType.styleCardHeaderLabel)
                .compassTracking(CompassType.trackCardHeaderLabel)
                .textCase(.uppercase)
                .foregroundStyle(Color.kInk3)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(CompassType.styleCardHeaderState)
                    .compassTracking(CompassType.trackMonoState)
                    .textCase(.uppercase)
                    .foregroundStyle(trailingDim ? Color.kInk3 : Color.kGreen)
            }
        }
        .padding(CompassLayout.diveCardHeaderPad)
    }

    private func openMicrophonePrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
        ]
        for s in urls {
            if let u = URL(string: s) {
                NSWorkspace.shared.open(u)
                return
            }
        }
    }
}

struct CompassPrimaryButtonStyle: ButtonStyle {
    var disabled: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CompassFont.body(12.5))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(Color.kGreen)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kGreenD))
            .cornerRadius(8)
            .opacity(disabled ? CompassLayout.disabledPrimaryOpacity : (configuration.isPressed ? 0.9 : 1))
    }
}

struct MicStepButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.kInk2 : Color.kInk3.opacity(0.35))
            .background(Color.kPanel)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.kHair)
            )
            .cornerRadius(6)
            .opacity(configuration.isPressed && isEnabled ? 0.85 : 1)
    }
}

