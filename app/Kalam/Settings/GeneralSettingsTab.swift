import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GeneralSettingsTab: View {
    @Binding var generalConfig: GeneralSettingsConfiguration
    @Binding var micPriorityConfig: MicrophonePriorityConfiguration

    @State private var microphoneRows: [MicrophoneDeviceDescriptor] = []
    @State private var activeInputUID: String?

    private enum Metrics {
        static let pickerWidth: CGFloat = 150
    }

    var body: some View {
        generalContent
            .onAppear { refreshMicrophoneRows() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshMicrophoneRows()
            }
    }

    private var generalContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("General Settings")
                        .font(KalamTheme.pageTitleFont)
                        .foregroundColor(KalamTheme.textPrimary)
                    Text("Configure app behavior and microphone routing.")
                        .font(KalamTheme.calloutFont)
                        .foregroundColor(KalamTheme.textSecondary)
                }
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Setup")
                        .font(KalamTheme.sectionTitleFont)
                        .foregroundColor(KalamTheme.textPrimary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            "Reopen the setup flow if you want to review permissions or reconfigure your local dictation model."
                        )
                        .font(KalamTheme.calloutFont)
                        .foregroundColor(KalamTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                        Button("Run Setup Again…") {
                            NotificationCenter.default.post(name: .openSetupFlow, object: nil)
                        }
                        .buttonStyle(OnboardingPremiumButtonStyle(isCompact: true))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .settingsCardSurface()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Behavior")
                        .font(KalamTheme.sectionTitleFont)
                        .foregroundColor(KalamTheme.textPrimary)

                    VStack(spacing: 0) {
                        behaviorToggleRow(
                            icon: "power", title: "Launch at login",
                            isOn: $generalConfig.launchAtLogin)
                        Divider().overlay(KalamTheme.strokeSubtle)
                        behaviorToggleRow(
                            icon: "dock.rectangle", title: "Show in Dock",
                            isOn: $generalConfig.showInDock)
                        Divider().overlay(KalamTheme.strokeSubtle)
                        behaviorToggleRow(
                            icon: "escape", title: "Use Escape to cancel recording",
                            isOn: $generalConfig.escapeCancelsRecording)
                        Divider().overlay(KalamTheme.strokeSubtle)
                        behaviorToggleRow(
                            icon: "speaker.slash", title: "Mute while recording",
                            isOn: $generalConfig.muteWhileRecording)
                        Divider().overlay(KalamTheme.strokeSubtle)
                        indicatorPlacementRow
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .settingsCardSurface()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Microphone Priority")
                        .font(KalamTheme.sectionTitleFont)
                        .foregroundColor(KalamTheme.textPrimary)

                    VStack(spacing: 0) {
                        ForEach(Array(microphoneRows.enumerated()), id: \.element.uid) {
                            index, device in
                            HStack(spacing: 10) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundColor(KalamTheme.textSecondary)
                                    .font(KalamTheme.bodyStrongFont)

                                Text("\(index + 1).")
                                    .font(KalamTheme.bodyStrongFont)
                                    .foregroundColor(KalamTheme.textSecondary)
                                    .frame(width: 20, alignment: .leading)

                                Text(device.name)
                                    .font(KalamTheme.bodyStrongFont)
                                    .foregroundColor(
                                        device.isAvailable
                                            ? KalamTheme.textPrimary : KalamTheme.textSecondary
                                    )
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                if index == 0 {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 10, height: 10)
                                }

                                if activeInputUID == device.uid {
                                    Text("Last used")
                                        .font(KalamTheme.footnoteFont)
                                        .foregroundColor(KalamTheme.textSecondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(
                                            Capsule()
                                                .fill(Color.white.opacity(0.06))
                                        )
                                }

                                if !device.isAvailable {
                                    Image(systemName: "mic.slash")
                                        .foregroundColor(KalamTheme.textTertiary)
                                        .font(KalamTheme.calloutFont)
                                }

                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                            .onDrag { NSItemProvider(object: NSString(string: device.uid)) }
                            .onDrop(
                                of: [.text],
                                delegate: MicrophoneRowDropDelegate(
                                    item: device,
                                    listData: $microphoneRows,
                                    onReorder: syncPriorityConfigFromRows
                                ))

                            if index < microphoneRows.count - 1 {
                                Divider().overlay(KalamTheme.strokeSubtle)
                                    .padding(.leading, 42)
                            }
                        }
                    }
                    .settingsCardSurface()

                    Text("Microphones are tried in priority order. Drag to reorder.")
                        .font(KalamTheme.calloutFont)
                        .foregroundColor(KalamTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxWidth: KalamTheme.contentMaxWidth, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
    @ViewBuilder
    private func behaviorToggleRow(icon: String, title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(KalamTheme.textSecondary)
                .frame(width: 24, alignment: .center)

            Text(title)
                .font(KalamTheme.bodyStrongFont)
                .foregroundColor(KalamTheme.textPrimary)

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(KalamToggleStyle())
                .controlSize(.regular)
        }
        .padding(.vertical, 7)
    }
    private var indicatorPlacementRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.inset.filled.and.person.filled")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(KalamTheme.textSecondary)
                .frame(width: 24, alignment: .center)

            Text("Recording indicator position")
                .font(KalamTheme.bodyStrongFont)
                .foregroundColor(KalamTheme.textPrimary)

            Spacer()

            KalamMenuPicker(
                selection: $generalConfig.indicatorPlacementPreset,
                options: IndicatorPlacementPreset.allCases,
                titleProvider: { $0.title }
            )
            .frame(width: Metrics.pickerWidth, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }
    private func refreshMicrophoneRows() {
        microphoneRows = MicrophoneDeviceService.mergedPriorityList(config: micPriorityConfig)
        let storedUID = UserDefaults.standard.string(forKey: GeneralSettingsKeys.selectedInputUID)
        if let storedUID, microphoneRows.contains(where: { $0.uid == storedUID }) {
            activeInputUID = storedUID
        } else {
            activeInputUID = nil
        }
    }
    private func syncPriorityConfigFromRows() {
        var names = micPriorityConfig.knownDeviceNames
        for device in microphoneRows where device.isAvailable {
            names[device.uid] = device.name
        }
        micPriorityConfig = MicrophonePriorityConfiguration(
            priorityUIDs: microphoneRows.map(\.uid),
            knownDeviceNames: names
        )
    }
}

private struct MicrophoneRowDropDelegate: DropDelegate {
    let item: MicrophoneDeviceDescriptor
    @Binding var listData: [MicrophoneDeviceDescriptor]
    let onReorder: () -> Void

    func dropEntered(info: DropInfo) {
        guard let from = info.itemProviders(for: [.text]).first else { return }
        _ = from.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? NSString else { return }
            let uid = value as String
            DispatchQueue.main.async {
                guard let fromIndex = listData.firstIndex(where: { $0.uid == uid }),
                    let toIndex = listData.firstIndex(of: item),
                    fromIndex != toIndex
                else { return }
                withAnimation {
                    listData.move(
                        fromOffsets: IndexSet(integer: fromIndex),
                        toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
                }
                onReorder()
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        true
    }
}

