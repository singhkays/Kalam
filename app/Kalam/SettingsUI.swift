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
    @State private var step1Expanded = false
    @State private var step2Expanded = false
    @State private var step3Expanded = false
    @State private var installCommandCopied = false
    @State private var downloadCommandCopied = false
    @State private var modelAvailabilityRefreshID = UUID()

    init(initialTab: SettingsTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    // MARK: - Computed Properties

    @State private var selectedDownloadVersion: ASRModelVersion = .v2

    private func downloadCommand(for version: ASRModelVersion) -> String {
        ModelSetupSupport.downloadCommand(for: version, config: modelsConfig)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

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
            modelsContent
                .id(modelAvailabilityRefreshID)
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
            .onChange(of: selectedTab) { _, newTab in
                if newTab == .models {
                    modelAvailabilityRefreshID = UUID()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            ) { _ in
                if selectedTab == .models {
                    modelAvailabilityRefreshID = UUID()
                }
            }
    }

    // MARK: - Extracted View Builders
    /// The content for the Models tab.
    private var modelsContent: some View {
        let selectedAvailability = modelsConfig.availability(for: modelsConfig.asrVersion)
        let installedModels = ModelSetupSupport.installedModelVersions(in: modelsConfig)
        let hasInstalledModels = !installedModels.isEmpty
        let step1Complete = modelsConfig.modelLibraryURL != nil
        let step2Complete = hasInstalledModels
        let step3Complete = selectedAvailability.isInstalled
        let selectedSingleModelFolder = ModelSetupSupport.selectedModelRepoFolderVersion(
            for: modelsConfig.modelLibraryURL)

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Speech Recognition Model")
                        .font(KalamTheme.pageTitleFont)
                        .foregroundColor(KalamTheme.textPrimary)
                    Text(
                        "Follow these 3 steps once. After setup, you can switch between installed models instantly."
                    )
                    .font(KalamTheme.calloutFont)
                    .foregroundColor(KalamTheme.textSecondary)
                }
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Setup Steps")
                        .font(KalamTheme.sectionTitleFont)
                        .foregroundColor(KalamTheme.textPrimary)

                    // Step 1: Choose folder
                    VStack(alignment: .leading, spacing: 12) {
                        let canToggle = step1Complete
                        HStack(spacing: 8) {
                            Image(systemName: step1Complete ? "checkmark.circle.fill" : "1.circle")
                                .foregroundColor(step1Complete ? .green : KalamTheme.textSecondary)
                            Text("Step 1: Choose top-level model folder")
                                .font(KalamTheme.bodyStrongFont)
                                .foregroundColor(KalamTheme.textPrimary)
                            Spacer()
                            if step1Complete {
                                Image(systemName: step1Expanded ? "chevron.up" : "chevron.down")
                                    .font(.caption)
                                    .foregroundColor(KalamTheme.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard canToggle else { return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                step1Expanded.toggle()
                            }
                        }

                        if !step1Complete || step1Expanded {
                            VStack(alignment: .leading, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Current folder")
                                        .font(KalamTheme.footnoteFont)
                                        .foregroundColor(KalamTheme.textSecondary)
                                    Text(modelsConfig.modelLibraryURL?.path ?? "No folder selected")
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundColor(KalamTheme.textPrimary)
                                        .textSelection(.enabled)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }

                                HStack(spacing: 8) {
                                    Button("Choose Folder...") {
                                        chooseModelLibraryFolder()
                                    }
                                    .buttonStyle(OnboardingGlassButtonStyle())

                                    Button("Open in Finder") {
                                        openModelLibraryInFinder()
                                    }
                                    .buttonStyle(OnboardingGlassButtonStyle())
                                    .disabled(modelsConfig.modelLibraryURL == nil)

                                    Button("Clear") {
                                        clearModelLibraryFolder()
                                    }
                                    .buttonStyle(OnboardingGlassButtonStyle())
                                    .disabled(modelsConfig.modelLibraryURL == nil)

                                    Spacer()
                                }

                                if let selectedSingleModelFolder {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(
                                            "You selected a single model repo folder (\(selectedSingleModelFolder.displayName))."
                                        )
                                        .font(KalamTheme.footnoteFont)
                                        .foregroundColor(KalamTheme.textSecondary)
                                        Button("Use Parent Folder Instead") {
                                            useParentFolderForSelectedModelRepo()
                                        }
                                        .buttonStyle(OnboardingGlassButtonStyle())
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }
                    }
                    .settingsCardSurface()

                    // Step 2: Download model files
                    VStack(alignment: .leading, spacing: 12) {
                        let canToggle = step2Complete
                        HStack(spacing: 8) {
                            Image(systemName: step2Complete ? "checkmark.circle.fill" : "2.circle")
                                .foregroundColor(step2Complete ? .green : KalamTheme.textSecondary)
                            Text("Step 2: Download model files")
                                .font(KalamTheme.bodyStrongFont)
                                .foregroundColor(KalamTheme.textPrimary)
                            Spacer()
                            if step2Complete {
                                Image(systemName: step2Expanded ? "chevron.up" : "chevron.down")
                                    .font(.caption)
                                    .foregroundColor(KalamTheme.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard canToggle else { return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                step2Expanded.toggle()
                            }
                        }

                        if !step2Complete || step2Expanded {
                            VStack(alignment: .leading, spacing: 10) {
                                if step1Complete {
                                    Text("Install the Hugging Face CLI (one-time):")
                                        .font(KalamTheme.footnoteFont)
                                        .foregroundColor(KalamTheme.textSecondary)

                                    Text(ModelSetupSupport.huggingFaceInstallCommand)
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundColor(KalamTheme.textPrimary)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(KalamTheme.controlTint)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(KalamTheme.strokeSubtle, lineWidth: 1)
                                        )
                                        .textSelection(.enabled)

                                    Button {
                                        copyToClipboard(ModelSetupSupport.huggingFaceInstallCommand)
                                        installCommandCopied = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                            installCommandCopied = false
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            if installCommandCopied {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundColor(.green)
                                                Text("Copied!")
                                                    .foregroundColor(.green)
                                            } else {
                                                Text("Copy Install Command")
                                            }
                                        }
                                    }

                                    Divider()
                                        .padding(.vertical, 4)

                                    Text("Then download your model:")
                                        .font(KalamTheme.footnoteFont)
                                        .foregroundColor(KalamTheme.textSecondary)

                                    SetupDropdownField(
                                        selection: $selectedDownloadVersion,
                                        options: ASRModelVersion.allCases,
                                        label: { $0.displayName }
                                    )

                                    let command = downloadCommand(for: selectedDownloadVersion)
                                    Text(command)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(KalamTheme.textPrimary)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(KalamTheme.controlTint)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(KalamTheme.strokeSubtle, lineWidth: 1)
                                        )
                                        .textSelection(.enabled)

                                    HStack {
                                        Button {
                                            copyToClipboard(command)
                                            downloadCommandCopied = true
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                                downloadCommandCopied = false
                                            }
                                        } label: {
                                            HStack(spacing: 4) {
                                                if downloadCommandCopied {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .foregroundColor(.green)
                                                    Text("Copied!")
                                                        .foregroundColor(.green)
                                                } else {
                                                    Text("Copy Download Command")
                                                }
                                            }
                                        }
                                        Text(
                                            "Downloads only required files instead of full 2.6 GB repo."
                                        )
                                        .font(KalamTheme.footnoteFont)
                                        .foregroundColor(KalamTheme.textTertiary)
                                    }
                                } else {
                                    Text(
                                        "Select a folder in Step 1 first to see download commands."
                                    )
                                    .font(KalamTheme.footnoteFont)
                                    .foregroundColor(KalamTheme.textSecondary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }
                    }
                    .settingsCardSurface()

                    // Step 3: Select a model
                    VStack(alignment: .leading, spacing: 12) {
                        let canToggle = step3Complete
                        HStack(spacing: 8) {
                            Image(systemName: step3Complete ? "checkmark.circle.fill" : "3.circle")
                                .foregroundColor(step3Complete ? .green : KalamTheme.textSecondary)
                            Text("Step 3: Select a model")
                                .font(KalamTheme.bodyStrongFont)
                                .foregroundColor(KalamTheme.textPrimary)
                            Spacer()
                            if step3Complete {
                                Image(systemName: step3Expanded ? "chevron.up" : "chevron.down")
                                    .font(.caption)
                                    .foregroundColor(KalamTheme.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard canToggle else { return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                step3Expanded.toggle()
                            }
                        }

                        if !step3Complete || step3Expanded {
                            VStack(alignment: .leading, spacing: 10) {
                                if hasInstalledModels {
                                    Text(
                                        "Available in selected folder: \(installedModels.map(\.displayName).joined(separator: ", "))"
                                    )
                                    .font(KalamTheme.footnoteFont)
                                    .foregroundColor(KalamTheme.textSecondary)
                                } else {
                                    Text("No valid models detected in the selected folder yet.")
                                        .font(KalamTheme.footnoteFont)
                                        .foregroundColor(KalamTheme.textSecondary)
                                }

                                VStack(spacing: 12) {
                                    ForEach(ASRModelVersion.allCases) { version in
                                        let availability = modelsConfig.availability(for: version)
                                        ModelSelectionRow(
                                            version: version,
                                            availability: availability,
                                            isSelected: modelsConfig.asrVersion == version,
                                            isEnabled: availability.isInstalled,
                                            onSelect: {
                                                guard availability.isInstalled else { return }
                                                modelsConfig.asrVersion = version
                                            }
                                        )
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        }
                    }
                    .settingsCardSurface()
                }

                if !step3Complete {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Setup Required")
                                .font(KalamTheme.bodyStrongFont)
                                .foregroundColor(KalamTheme.textPrimary)
                            Spacer()
                        }

                        Text(ModelSetupSupport.availabilityMessage(for: selectedAvailability))
                            .font(KalamTheme.footnoteFont)
                            .foregroundColor(KalamTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(KalamTheme.accent)
                        Text("Folder Layout")
                            .font(KalamTheme.bodyStrongFont)
                            .foregroundColor(KalamTheme.textPrimary)
                        Spacer()
                    }

                    Text(
                        "Top-level folder example:\n~/Models/FluidAudio/\n  ├─ parakeet-tdt-0.6b-v2/\n  └─ parakeet-tdt-0.6b-v3/\n\nEach model folder must contain:\n• Preprocessor.mlmodelc/\n• Encoder.mlmodelc/\n• Decoder.mlmodelc/\n• JointDecision.mlmodelc/ for v2 or JointDecisionv3.mlmodelc/ for v3\n• parakeet_vocab.json"
                    )
                    .font(KalamTheme.footnoteFont)
                    .foregroundColor(KalamTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(KalamTheme.accent.opacity(0.25), lineWidth: 1)
                )

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxWidth: KalamTheme.contentMaxWidth, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

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
        normalizeSelectedModelForAvailability()

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


    private func normalizeSelectedModelForAvailability() {
        modelsConfig = ModelSetupSupport.normalizedSelectedModel(in: modelsConfig)
    }

    private func useParentFolderForSelectedModelRepo() {
        guard
            ModelSetupSupport.selectedModelRepoFolderVersion(for: modelsConfig.modelLibraryURL)
                != nil,
            let currentURL = modelsConfig.modelLibraryURL?.standardizedFileURL
        else { return }
        setModelLibraryFolder(currentURL.deletingLastPathComponent())
    }

    private func chooseModelLibraryFolder() {
        ModelSetupSupport.chooseModelLibraryFolder(currentURL: modelsConfig.modelLibraryURL) {
            url in
            guard let url else { return }
            setModelLibraryFolder(url)
        }
    }

    private func openModelLibraryInFinder() {
        guard let url = modelsConfig.modelLibraryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func clearModelLibraryFolder() {
        setModelLibraryFolder(nil)
    }

    private func setModelLibraryFolder(_ folderURL: URL?) {
        do {
            modelsConfig = try ModelSetupSupport.applyingModelLibraryFolder(
                folderURL, to: modelsConfig)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Unable to Use Folder"
            alert.runModal()
        }
    }

}


// MARK: - Word Replacement View

struct WordReplacementView: View {
    @EnvironmentObject var manager: CustomDictionaryManager

    @State private var search: String = ""
    @State private var showingDeleteConfirmation = false
    @State private var entryToDelete: UUID?

    private var activeRuleCount: Int {
        manager.entries.filter(\.isEnabled).count
    }

    var filteredEntries: [DictionaryEntry] {
        let s = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return manager.entries }
        return manager.entries.filter {
            $0.trigger.localizedCaseInsensitiveContains(s)
                || $0.replacement.localizedCaseInsensitiveContains(s)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if manager.entries.isEmpty {
                emptyState
            } else if filteredEntries.isEmpty {
                noResultsState
            } else {
                entryList
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(maxWidth: KalamTheme.contentMaxWidth, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
        .alert("Delete Entry?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let id = entryToDelete {
                    delete(id: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Word Replacement")
                    .font(KalamTheme.pageTitleFont)
                    .foregroundColor(KalamTheme.textPrimary)

                Text("\(manager.entries.count) rules • \(activeRuleCount) active")
                    .font(KalamTheme.calloutFont)
                    .foregroundColor(KalamTheme.textSecondary)
            }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(KalamTheme.textTertiary)

                    TextField("Search dictionary", text: $search)
                        .textFieldStyle(.plain)
                        .font(KalamTheme.bodyFont)
                        .foregroundColor(KalamTheme.textPrimary)

                    if !search.isEmpty {
                        Button(action: { search = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(KalamTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: 32)
                .padding(.horizontal, 10)
                .background(KalamTheme.controlTint)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(KalamTheme.strokeSubtle, lineWidth: 1)
                )

                Button(action: addNew) {
                    Image(systemName: "plus")
                        .font(KalamTheme.sectionTitleFont)
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(KalamTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Add rule")

                Button(action: { manager.sortEntriesByTrigger() }) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(KalamTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(KalamTheme.controlTint)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(KalamTheme.strokeSubtle, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Sort by spoken phrase")
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 64))
                .foregroundColor(KalamTheme.textSecondary)
            Text("Your Dictionary is Empty")
                .font(.title2.weight(.semibold))
                .foregroundColor(KalamTheme.textPrimary)
            Text(
                "Add replacements for common ASR mistakes to make dictation faster and more accurate."
            )
            .foregroundColor(KalamTheme.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 400)
            Button("Add First Entry") {
                addNew()
            }
            .buttonStyle(.borderedProminent)
            .tint(KalamTheme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        ContentUnavailableView {
            Label("No Results", systemImage: "magnifyingglass")
        } description: {
            Text("Try a different search term")
        }
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredEntries) { entry in
                    EditableRow(
                        entry: binding(for: entry),
                        onDelete: {
                            entryToDelete = entry.id
                            showingDeleteConfirmation = true
                        }
                    )
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 14)
        }
    }

    private func binding(for entry: DictionaryEntry) -> Binding<DictionaryEntry> {
        Binding(
            get: {
                manager.entries.first(where: { $0.id == entry.id }) ?? entry
            },
            set: { newValue in
                guard let index = manager.entries.firstIndex(where: { $0.id == entry.id }) else {
                    return
                }
                manager.entries[index] = newValue
            }
        )
    }

    private func addNew() {
        let new = DictionaryEntry(trigger: "", replacement: "", userAdded: true)
        manager.addEntry(new)
    }

    private func delete(id: UUID) {
        manager.removeEntries(withIds: [id])
        entryToDelete = nil
    }
}

// MARK: - Editable Row

struct EditableRow: View {
    @Binding var entry: DictionaryEntry
    let onDelete: () -> Void

    @State private var isExpanded = false
    @State private var showAdvanced = false
    @State private var isHovered = false

    // Case handling options
    enum CaseMatchingMode: String, CaseIterable {
        case smart = "Smart Match"
        case literal = "Literal"

        static func from(entry: DictionaryEntry) -> CaseMatchingMode {
            return (entry.caseInsensitive || entry.preserveCase) ? .smart : .literal
        }
        func apply(to entry: inout DictionaryEntry) {
            switch self {
            case .smart:
                entry.caseInsensitive = true
                entry.preserveCase = true
            case .literal:
                entry.caseInsensitive = false
                entry.preserveCase = false
            }
        }
    }

    @State private var matchingMode: CaseMatchingMode = .smart

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Toggle("", isOn: $entry.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .scaleEffect(0.86)

                HStack(spacing: 8) {
                    Text(entry.trigger.isEmpty ? "Spoken phrase" : entry.trigger)
                        .font(KalamTheme.bodyStrongFont)
                        .foregroundColor(
                            entry.isEnabled ? KalamTheme.textPrimary : KalamTheme.textSecondary
                        )
                        .lineLimit(1)

                    Image(systemName: "arrow.right")
                        .font(KalamTheme.calloutFont)
                        .foregroundColor(KalamTheme.textTertiary)

                    Text(entry.replacement.isEmpty ? "Replacement" : entry.replacement)
                        .font(KalamTheme.bodyStrongFont)
                        .foregroundColor(KalamTheme.accent)
                        .opacity(entry.isEnabled ? 1.0 : 0.6)
                        .lineLimit(1)
                }

                Spacer()

                Text(matchingMode.rawValue)
                    .font(KalamTheme.captionStrongFont)
                    .foregroundColor(
                        matchingMode == .smart ? KalamTheme.accent : KalamTheme.textSecondary
                    )
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        KalamTheme.controlTint.opacity(matchingMode == .smart ? 0.95 : 0.72)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                Button(action: { withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() } }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(KalamTheme.calloutFont)
                }
                .buttonStyle(.plain)
                .foregroundColor(KalamTheme.textSecondary)
                .frame(width: 24, height: 24)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(KalamTheme.calloutFont)
                        .foregroundColor(KalamTheme.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Delete rule")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    Divider().overlay(KalamTheme.strokeSubtle)
                        .padding(.horizontal, -10)

                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Spoken phrase", systemImage: "mouth.fill")
                                .font(KalamTheme.captionStrongFont)
                                .foregroundColor(KalamTheme.textSecondary)

                            TextField("e.g. apple", text: $entry.trigger)
                                .textFieldStyle(.plain)
                                .font(KalamTheme.bodyFont)
                                .foregroundColor(KalamTheme.textPrimary)
                                .padding(.horizontal, 10)
                                .frame(height: 40)
                                .background(KalamTheme.controlTint)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8).stroke(
                                        KalamTheme.strokeSubtle, lineWidth: 1))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Label("Replacement", systemImage: "pencil")
                                .font(KalamTheme.captionStrongFont)
                                .foregroundColor(KalamTheme.textSecondary)

                            TextField("e.g. orange", text: $entry.replacement)
                                .textFieldStyle(.plain)
                                .font(KalamTheme.bodyFont)
                                .foregroundColor(KalamTheme.textPrimary)
                                .padding(.horizontal, 10)
                                .frame(height: 40)
                                .background(KalamTheme.controlTint)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8).stroke(
                                        KalamTheme.strokeSubtle, lineWidth: 1))
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("Covers:")
                                .font(KalamTheme.captionStrongFont)
                                .foregroundColor(KalamTheme.textSecondary)

                            Text(
                                entry.exampleMatches.isEmpty
                                    ? "Start typing to see examples"
                                    : entry.exampleMatches.joined(separator: ", ")
                            )
                            .font(KalamTheme.captionFont)
                            .foregroundColor(KalamTheme.textSecondary)
                            .opacity(entry.exampleMatches.isEmpty ? 0.5 : 1.0)
                        }
                        .lineLimit(3)
                    }

                    HStack {
                        HStack(spacing: 8) {
                            Picker("Matching", selection: $matchingMode) {
                                ForEach(CaseMatchingMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 170)
                            .onChange(of: matchingMode) { _, newValue in
                                newValue.apply(to: &entry)
                            }

                            Button {
                                showAdvanced.toggle()
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(KalamTheme.calloutFont)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(KalamTheme.textSecondary)
                            .popover(isPresented: $showAdvanced, arrowEdge: .top) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Smart Match")
                                        .font(.headline)

                                    Text(
                                        "Automatically handles capitalization, plurals, and possessives of your spoken words."
                                    )
                                    .font(KalamTheme.calloutFont)
                                    .foregroundColor(KalamTheme.textSecondary)
                                }
                                .padding()
                                .frame(width: 220)
                            }
                        }

                        Spacer()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .background(backgroundFill)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(borderColor, lineWidth: isExpanded ? 1.4 : 1)
        )
        .shadow(color: isExpanded ? Color.black.opacity(0.14) : .clear, radius: 5, y: 2)
        .onHover { hover in
            isHovered = hover
        }
        .onAppear {
            matchingMode = CaseMatchingMode.from(entry: entry)
        }
        .onChange(of: entry.caseInsensitive) { _, _ in
            matchingMode = CaseMatchingMode.from(entry: entry)
        }
        .onChange(of: entry.preserveCase) { _, _ in
            matchingMode = CaseMatchingMode.from(entry: entry)
        }
    }

    private var backgroundFill: some View {
        ZStack {
            KalamTheme.controlTint.opacity(isHovered ? 0.95 : 0.72)
            if isExpanded {
                KalamTheme.accent.opacity(0.08)
            }
        }
    }

    private var borderColor: Color {
        if isExpanded {
            return KalamTheme.accent.opacity(0.50)
        }
        if isHovered {
            return KalamTheme.strokeStrong
        }
        return KalamTheme.strokeSubtle
    }
}

// MARK: - Model Selection Row

struct ModelSelectionRow: View {
    let version: ASRModelVersion
    let availability: ASRModelAvailability
    let isSelected: Bool
    let isEnabled: Bool
    let onSelect: () -> Void

    private var availabilityColor: Color {
        switch availability {
        case .installed:
            return .green
        case .modelLibraryNotConfigured:
            return .secondary
        case .missingModelFolder:
            return .orange
        case .invalidModelFolder:
            return .red
        }
    }

    private var availabilityIcon: String {
        switch availability {
        case .installed:
            return "checkmark.circle.fill"
        case .modelLibraryNotConfigured:
            return "questionmark.circle"
        case .missingModelFolder:
            return "exclamationmark.circle"
        case .invalidModelFolder:
            return "xmark.octagon.fill"
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Selection indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? KalamTheme.accent : KalamTheme.textTertiary)

                // Model info
                VStack(alignment: .leading, spacing: 4) {
                    Text(version.displayName)
                        .font(isSelected ? KalamTheme.bodyStrongFont : KalamTheme.bodyFont)
                        .foregroundColor(KalamTheme.textPrimary)

                    Text(version.description)
                        .font(KalamTheme.footnoteFont)
                        .foregroundColor(KalamTheme.textSecondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: availabilityIcon)
                        Text(availability.statusLabel)
                    }
                    .font(KalamTheme.footnoteFont)
                    .foregroundColor(availabilityColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(availabilityColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    Text(version.modelSize)
                        .font(KalamTheme.footnoteFont)
                        .foregroundColor(KalamTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(KalamTheme.controlTint.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.65)
        .background(
            isSelected ? KalamTheme.accent.opacity(0.10) : KalamTheme.controlTint.opacity(0.72)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? KalamTheme.accent.opacity(0.40) : KalamTheme.strokeSubtle,
                    lineWidth: 1)
        )
    }
}





// MARK: - Preview
#Preview {
    SettingsView()
        .environmentObject(CustomDictionaryManager.shared)
        .frame(width: 650, height: 500)
}
