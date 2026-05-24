import Foundation

enum ModelSetupWizardStep: Int, Equatable {
    case folder = 1
    case cli = 2
    case download = 3

    var title: String {
        switch self {
        case .folder: "Model folder"
        case .cli: "Install Hugging Face Download Tool"
        case .download: "Download model"
        }
    }
}

struct ModelSetupWizardState: Equatable {
    let currentStep: ModelSetupWizardStep
    let isFolderComplete: Bool
    let isCLIComplete: Bool
    let isCLIManuallyConfirmed: Bool
    let isDownloadComplete: Bool

    var completedStepCount: Int {
        [isFolderComplete, isCLIComplete, isDownloadComplete].filter { $0 }.count
    }
}

struct ModelSetupPanelPresentation: Equatable {
    let statusMessage: String
    let selectedRepo: ASRModelVersion?
}

enum ModelSetupPresentationState: Equatable {
    case needsFolder
    case needsModel(folderURL: URL, version: ASRModelVersion, statusMessage: String)
    case repoFolderSelected(folderURL: URL, selectedRepo: ASRModelVersion, version: ASRModelVersion, statusMessage: String)
    case ready(folderURL: URL, version: ASRModelVersion, statusMessage: String)
}

extension OnboardingFlowController {
    var isModelCLIManuallyConfirmed: Bool {
        if snapshot.modelStatus.isReady {
            return true
        }
        return loadOnboardingConfiguration().hasConfirmedHFCLIInstall
    }

    var isModelCLIAvailable: Bool {
        isModelCLIManuallyConfirmed
    }

    var modelSetupWizardState: ModelSetupWizardState {
        let isFolderComplete = snapshot.modelLibraryURL != nil && selectedModelRepoFolderVersion == nil
        let isCLIComplete = isFolderComplete && isModelCLIAvailable
        let isDownloadComplete = snapshot.modelStatus.isReady

        let currentStep: ModelSetupWizardStep
        if !isFolderComplete {
            currentStep = .folder
        } else if !isCLIComplete {
            currentStep = .cli
        } else {
            currentStep = .download
        }

        return ModelSetupWizardState(
            currentStep: currentStep,
            isFolderComplete: isFolderComplete,
            isCLIComplete: isCLIComplete,
            isCLIManuallyConfirmed: isModelCLIManuallyConfirmed,
            isDownloadComplete: isDownloadComplete
        )
    }

    var modelSetupPresentationState: ModelSetupPresentationState {
        guard let folderURL = snapshot.modelLibraryURL else {
            return .needsFolder
        }

        if snapshot.modelStatus.isReady {
            return .ready(
                folderURL: folderURL,
                version: snapshot.selectedModelVersion,
                statusMessage: snapshot.modelStatus.message
            )
        }

        if let selectedRepo = selectedModelRepoFolderVersion {
            return .repoFolderSelected(
                folderURL: folderURL,
                selectedRepo: selectedRepo,
                version: selectedDownloadVersion,
                statusMessage: snapshot.modelStatus.message
            )
        }

        return .needsModel(
            folderURL: folderURL,
            version: selectedDownloadVersion,
            statusMessage: snapshot.modelStatus.message
        )
    }

    var modelSetupPresentation: ModelSetupPanelPresentation {
        switch modelSetupPresentationState {
        case .needsFolder:
            return ModelSetupPanelPresentation(
                statusMessage: "Choose where Kalam should store your local speech models.",
                selectedRepo: nil
            )
        case .needsModel(_, _, let statusMessage),
             .ready(_, _, let statusMessage):
            return ModelSetupPanelPresentation(statusMessage: statusMessage, selectedRepo: nil)
        case .repoFolderSelected(_, let selectedRepo, _, let statusMessage):
            return ModelSetupPanelPresentation(statusMessage: statusMessage, selectedRepo: selectedRepo)
        }
    }
}
