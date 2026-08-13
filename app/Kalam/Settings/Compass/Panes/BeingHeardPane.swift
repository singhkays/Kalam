import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BeingHeardPane: View {
    @Bindable var model: SettingsModel
    /// K-30: drag source (grip-only dragging — the grip is the handle, not the row).
    @State private var draggingMicID: String?
    @State private var dropTargets: [String: Bool] = [:]

    private var behaviorOnCount: Int {
        [model.launchAtLogin, model.showInDock, model.escapeCancels, model.muteOtherAudio]
            .filter(\.self).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Being heard")
                .font(CompassFont.mono(9.5))
                .tracking(2.4)
                .textCase(.uppercase)
                .foregroundStyle(Color.kGreen)

            (
                Text("How Kalam ").font(CompassFont.display(CompassType.diveDisplay)).foregroundStyle(Color.kInk)
                    + Text("hears you.").font(CompassFont.display(CompassType.diveDisplay).italic()).foregroundStyle(Color.kInk2)
            )
            .padding(.top, 9)

            Text(lede)
                .font(CompassFont.body(CompassType.diveLede))
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
                    .font(CompassFont.body(CompassType.rowTitle).weight(.semibold))
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
                        .font(CompassFont.mono(12))
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
                trailing: micHeaderTrailing,
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
                ForEach(Array(model.microphones.enumerated()), id: \.element.id) { _, mic in
                    micRow(mic)
                }
            }
        }
        .background(Color.kPanel)
        .overlay(RoundedRectangle(cornerRadius: CompassLayout.cardRadius).stroke(Color.kHair))
        .cornerRadius(CompassLayout.cardRadius)
        .padding(.top, 18)
    }

    /// Grip-drag reorder: the six-dot grip is the drag handle, not the whole row (D.1).
    private func micRow(_ mic: Microphone) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.grid.3x3")
                .font(.system(size: 10))
                .foregroundStyle(Color.kInk3.opacity(0.5))
                .frame(width: 16)
                .onDrag {
                    draggingMicID = mic.id
                    return NSItemProvider(object: mic.id as NSString)
                }
            Text(mic.name)
                .font(CompassFont.body(13.5).weight(.semibold))
            Spacer()
            let status = model.microphoneStatus(for: mic)
            Text(status)
                .font(CompassFont.mono(10))
                .tracking(0.8)
                .foregroundStyle(status == "IN USE" ? Color.kGreen : Color.kInk3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Divider().background(Color.kHair2) }
        .overlay(
            // Contract: target = 2px green inset hairline @ 45%.
            RoundedRectangle(cornerRadius: 6)
                .stroke(dropTargets[mic.id] == true ? Color.kGreen.opacity(0.45) : Color.clear, lineWidth: 2)
                .padding(2)
        )
        .onDrop(of: [UTType.text.identifier], isTargeted: dropTargetBinding(for: mic.id)) { _ in
            handleDrop(on: mic.id)
            return true
        }
    }

    private func dropTargetBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { dropTargets[id] ?? false },
            set: { dropTargets[id] = $0 }
        )
    }

    private func handleDrop(on targetID: String) {
        let mics = model.microphones
        guard let sourceIndex = mics.firstIndex(where: { $0.id == draggingMicID }),
              let targetIndex = mics.firstIndex(where: { $0.id == targetID }),
              sourceIndex != targetIndex
        else {
            draggingMicID = nil
            return
        }
        // Drop on a row = place at that row's position (move(fromOffsets:toOffset:) semantics:
        // element lands just before the element at `to`).
        let to = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        model.moveMicrophone(from: IndexSet(integer: sourceIndex), to: to)
        draggingMicID = nil
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
                Text(title).font(CompassFont.body(CompassType.rowTitle).weight(.semibold))
                Text(detail).font(CompassFont.body(CompassType.rowDetail)).foregroundStyle(Color.kInk2)
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
                .font(CompassFont.body(11).weight(.bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Color.kInk3)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(CompassFont.mono(9.5))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(trailingDim ? Color.kInk3 : Color.kGreen)
            }
        }
        .padding(CompassLayout.diveCardHeaderPad)
    }

    private func openMicrophonePrivacySettings() {
        // Live helper with legacy + modern deep links (never requestAccess from this button).
        SystemSettingsNavigator.open(.microphone)
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
