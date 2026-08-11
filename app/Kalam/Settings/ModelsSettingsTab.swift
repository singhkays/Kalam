import AppKit
import SwiftUI

struct ModelsSettingsTab: View {
    @Binding var modelsConfig: ModelsConfiguration

    @State private var step1Expanded = false
    @State private var step2Expanded = false
    @State private var step3Expanded = false
    @State private var installCommandCopied = false
    @State private var downloadCommandCopied = false
    @State private var selectedDownloadVersion: ASRModelVersion = .v2
    @State private var modelAvailabilityRefreshID = UUID()

    var body: some View {
        modelsContent
            .id(modelAvailabilityRefreshID)
            .onAppear { modelAvailabilityRefreshID = UUID() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                modelAvailabilityRefreshID = UUID()
            }
    }

    private func downloadCommand(for version: ASRModelVersion) -> String {
        ModelSetupSupport.downloadCommand(for: version, config: modelsConfig)
    }
    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
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

