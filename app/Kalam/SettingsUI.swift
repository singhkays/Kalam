import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KalamTextEngine

// MARK: - Settings UI (SwiftUI)

struct SettingsView: View {
    @EnvironmentObject var manager: CustomDictionaryManager

    // Enum to define the available tabs
    enum SettingsTab: CaseIterable {
        case general
        case wordReplacement
        case keyboardControls
        case refine
        case models
        case updates

        var navTitle: String {
            switch self {
            case .general: return "General"
            case .wordReplacement: return "Dictionary"
            case .keyboardControls: return "Hotkey"
            case .refine: return "Cleanup"
            case .models: return "Models"
            case .updates: return "Updates"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .wordReplacement: return "text.word.spacing"
            case .keyboardControls: return "keyboard"
            case .refine: return "wand.and.stars"
            case .models: return "cpu"
            case .updates: return "arrow.down.circle"
            }
        }
    }

    // MARK: - State Properties
    @State private var selectedTab: SettingsTab
    @State private var isInitializingSettingsState = true
    @State private var hotkeyDraft: PTTHotkeyConfiguration = .load()
    @State private var modelsConfig: ModelsConfiguration = .load()
    @State private var generalConfig: GeneralSettingsConfiguration = .load()
    @State private var micPriorityConfig: MicrophonePriorityConfiguration = .load()

    init(initialTab: SettingsTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    // MARK: - Computed Properties


    @ViewBuilder
    private var mainContent: some View {
        if selectedTab == .general {
            GeneralSettingsTab(
                generalConfig: $generalConfig,
                micPriorityConfig: $micPriorityConfig
            )
        } else if selectedTab == .updates {
            UpdatesSettingsTab()
        } else if selectedTab == .wordReplacement {
            WordReplacementView()
        } else if selectedTab == .keyboardControls {
            ShortcutSettingsTab(hotkeyDraft: $hotkeyDraft)
        } else if selectedTab == .refine {
            CleanupSettingsTab(modelsConfig: $modelsConfig)
        } else {
            ModelsSettingsTab(modelsConfig: $modelsConfig)
        }
    }

    private var rootContent: some View {
        NavigationSplitView {
            sidebarNavigation
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 280)
        } detail: {
            ZStack {
                Rectangle()
                    .fill(KalamTheme.contentBackground)
                NoiseView()
                    .blendMode(.overlay)

                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .tint(KalamTheme.accent)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 640)
    }

    private var selectedTabBinding: Binding<SettingsTab?> {
        Binding<SettingsTab?>(
            get: { selectedTab },
            set: { newValue in
                if let newValue {
                    selectedTab = newValue
                }
            }
        )
    }

    private var sidebarNavigation: some View {
        List(selection: selectedTabBinding) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Label(tab.navTitle, systemImage: tab.icon)
                    .tag(tab)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Main Body
    var body: some View {
        rootContent
            .onAppear {
                onAppear()
            }
            .onChange(of: manager.entries) { _, _ in
                manager.entriesDidChange()
            }
            .onChange(of: hotkeyDraft) { _, _ in
                persistHotkeyConfigurationIfNeeded()
            }
            .onChange(of: modelsConfig) { _, _ in
                persistModelsConfigurationIfNeeded()
            }
            .onChange(of: micPriorityConfig) { _, _ in
                persistMicrophonePriorityIfNeeded()
            }
            .onChange(of: generalConfig) { _, _ in
                guard !isInitializingSettingsState else { return }
                generalConfig.saveAndNotify()
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectModelsSettingsTab)) { _ in
                selectedTab = .models
            }
    }

    // MARK: - Extracted View Builders
    /// The content for the Models tab.

    /// The content for the Refine tab.





    // MARK: - Actions & Event Handlers


    private func onAppear() {
        if manager.isFirstLaunch {
            manager.entries.removeAll { !$0.userAdded }
            manager.saveImmediately()
        }
        isInitializingSettingsState = true
        let currentHotkey = PTTHotkeyConfiguration.load()
        hotkeyDraft = currentHotkey
        let currentModelsConfig = ModelsConfiguration.load()
        modelsConfig = currentModelsConfig

        let currentGeneral = GeneralSettingsConfiguration.load()
        generalConfig = currentGeneral

        let currentPriority = MicrophoneDeviceService.normalize(
            config: MicrophonePriorityConfiguration.load())
        micPriorityConfig = currentPriority
        DispatchQueue.main.async {
            isInitializingSettingsState = false
        }
    }

    private func persistHotkeyConfigurationIfNeeded() {
        guard !isInitializingSettingsState else { return }
        let safeHotkey = hotkeyDraft.normalized()
        safeHotkey.save()
        if hotkeyDraft != safeHotkey {
            hotkeyDraft = safeHotkey
            return
        }
        NotificationCenter.default.post(
            name: Notification.Name.pttHotkeyConfigurationDidChange, object: nil)
    }

    private func persistModelsConfigurationIfNeeded() {
        guard !isInitializingSettingsState else { return }
        modelsConfig.save()
        NotificationCenter.default.post(
            name: Notification.Name.modelsConfigurationDidChange, object: nil)
    }

    private func persistMicrophonePriorityIfNeeded() {
        guard !isInitializingSettingsState else { return }
        let normalized = MicrophoneDeviceService.normalize(config: micPriorityConfig)
        if micPriorityConfig != normalized {
            micPriorityConfig = normalized
            return
        }
        normalized.saveAndNotify()
    }

}
// MARK: - Preview
#Preview {
    SettingsView()
        .environmentObject(CustomDictionaryManager.shared)
        .frame(width: 650, height: 500)
}
