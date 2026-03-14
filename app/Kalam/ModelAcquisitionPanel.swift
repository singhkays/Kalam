import SwiftUI

struct ModelAcquisitionPanel: View {
    let folderURL: URL?
    let statusMessage: String
    let wizardState: ModelSetupWizardState
    @Binding var selectedVersion: ASRModelVersion
    let downloadCommand: String
    let downloadCommandCopied: Bool
    let installCommand: String
    let installCommandCopied: Bool
    let onChooseFolder: () -> Void
    let onChangeFolder: () -> Void
    let onOpenInFinder: () -> Void
    let onClearFolder: () -> Void
    var selectedRepo: ASRModelVersion?
    var onUseParentFolder: (() -> Void)?
    let onRecheckCLI: () -> Void
    let onCopyDownloadCommand: () -> Void
    let onCopyInstallCommand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            folderStep
            Divider()
            cliStep
            Divider()
            downloadStep
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var folderStep: some View {
        wizardStepContainer(
            number: 1,
            title: "Model folder",
            isComplete: wizardState.isFolderComplete,
            isActive: wizardState.currentStep == .folder,
            summary: folderStepSummary,
            trailingActionTitle: wizardState.isFolderComplete && wizardState.currentStep != .folder ? "Change" : nil,
            trailingAction: wizardState.isFolderComplete && wizardState.currentStep != .folder ? onChangeFolder : nil
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose the folder where Kalam will store your local speech models. Kalam keeps these files on your Mac and checks this folder when loading dictation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let folderURL {
                    Text(folderURL.path)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)

                    HStack(spacing: 10) {
                        Button("Change", action: onChangeFolder)
                            .buttonStyle(OnboardingGlassButtonStyle())

                        folderOverflowMenu
                    }

                    if let selectedRepo {
                        repoWarning(selectedRepo)
                    }
                } else {
                    Button("Choose Folder…", action: onChooseFolder)
                        .buttonStyle(OnboardingPremiumButtonStyle(isCompact: true))
                }
            }
        }
    }

    private var cliStep: some View {
        wizardStepContainer(
            number: 2,
            title: "Install CLI",
            isComplete: wizardState.isCLIComplete,
            isActive: folderStepUnlocked && wizardState.currentStep == .cli,
            summary: wizardState.isCLIComplete ? "Hugging Face CLI is available on this Mac." : "Install the Hugging Face CLI once before downloading models.",
            isLocked: !folderStepUnlocked
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Run this in Terminal to install the `hf` command.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                installCommandRow

                Text("After installing, open a new Terminal window or restart Terminal before continuing to step 3.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Check Again", action: onRecheckCLI)
                    .font(.footnote.bold())
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.ultraThinMaterial.opacity(0.78))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(0.14), lineWidth: 0.75)
                    )
                    .buttonStyle(.plain)
            }
        }
    }

    private var downloadStep: some View {
        wizardStepContainer(
            number: 3,
            title: "Download model",
            isComplete: wizardState.isDownloadComplete,
            isActive: wizardState.currentStep == .download && folderStepUnlocked && wizardState.isCLIComplete,
            summary: wizardState.isDownloadComplete ? "Compatible model installed." : "Choose a model version, then download it into the selected folder.",
            isLocked: !folderStepUnlocked || !wizardState.isCLIComplete
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(statusMessage)
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Model version")
                        .font(.subheadline.bold())

                    SetupDropdownField(
                        selection: $selectedVersion,
                        options: ASRModelVersion.allCases,
                        label: { $0.displayName }
                    )

                    Text(selectedVersion.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                CommandCopyRow(
                    buttonTitle: "Copy Download Command",
                    copiedTitle: "Copied Download Command",
                    commandText: downloadCommand,
                    disclosureTitle: "Download command",
                    helpText: "Run this after the CLI is installed to download the selected model into your folder.",
                    isCopied: downloadCommandCopied,
                    buttonPlacement: .prominent,
                    copyAction: onCopyDownloadCommand
                )
            }
        }
    }

    private var folderStepUnlocked: Bool {
        folderURL != nil && selectedRepo == nil
    }

    private var folderStepSummary: String {
        if let folderURL, selectedRepo == nil {
            return folderURL.lastPathComponent.isEmpty ? folderURL.path : folderURL.path
        }
        if selectedRepo != nil {
            return "Choose the parent folder for your model library."
        }
        return "Choose where Kalam will store your local speech models."
    }

    private var folderOverflowMenu: some View {
        Menu("More", systemImage: "ellipsis.circle") {
            Button("Open Folder", action: onOpenInFinder)
            Button("Clear", role: .destructive, action: onClearFolder)
        }
        .buttonStyle(OnboardingGlassButtonStyle())
    }

    private var installCommandRow: some View {
        HStack(spacing: 12) {
            Text(installCommand)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            Button(action: onCopyInstallCommand) {
                Image(systemName: installCommandCopied ? "checkmark" : "doc.on.doc")
                    .font(.footnote.bold())
                    .foregroundStyle(installCommandCopied ? .green : .secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(installCommandCopied ? "Copied Install Command" : "Copy Install Command")
            .accessibilityInputLabels([
                Text("Copy Install Command"),
                Text("Copied Install Command")
            ])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private func wizardStepContainer<Content: View>(
        number: Int,
        title: String,
        isComplete: Bool,
        isActive: Bool,
        summary: String,
        isLocked: Bool = false,
        trailingActionTitle: String? = nil,
        trailingAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: isActive ? 3 : 0) {
            HStack(alignment: .top, spacing: 12) {
                stepBadge(number: number, isComplete: isComplete, isLocked: isLocked)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .font(.subheadline.bold())
                            .foregroundStyle(isLocked ? .tertiary : .primary)
                    }

                    if !isActive {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        content()
                            .padding(.top, 2)
                            .padding(.bottom, 4)
                    }
                }

                Spacer(minLength: 0)

                if !isActive, let trailingActionTitle, let trailingAction {
                    Button(trailingActionTitle, action: trailingAction)
                        .buttonStyle(OnboardingGlassButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isLocked ? 0.6 : 1)
    }

    private func stepBadge(number: Int, isComplete: Bool, isLocked: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isComplete ? AnyShapeStyle(Color.green.opacity(0.18)) : AnyShapeStyle(.quaternary))
                .frame(width: 28, height: 28)

            if isComplete {
                Image(systemName: "checkmark")
                    .font(.footnote.bold())
                    .foregroundStyle(.green)
            } else {
                Text("\(number)")
                    .font(.footnote.bold())
                    .foregroundStyle(isLocked ? .tertiary : .secondary)
            }
        }
        .accessibilityHidden(true)
    }

    private func repoWarning(_ selectedRepo: ASRModelVersion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("This folder is already the \(selectedRepo.displayName) repo.", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)

            Text("Choose the parent folder instead so Kalam can manage your model library consistently.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let onUseParentFolder {
                Button("Use Parent Folder Instead", action: onUseParentFolder)
                    .buttonStyle(OnboardingGlassButtonStyle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }
}
