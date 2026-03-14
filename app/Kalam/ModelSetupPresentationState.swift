import Foundation

enum ModelSetupWizardStep: Int, Equatable {
    case folder = 1
    case cli = 2
    case download = 3

    var title: String {
        switch self {
        case .folder: "Model folder"
        case .cli: "Install CLI"
        case .download: "Download model"
        }
    }
}

struct ModelSetupWizardState: Equatable {
    let currentStep: ModelSetupWizardStep
    let isFolderComplete: Bool
    let isCLIComplete: Bool
    let isDownloadComplete: Bool

    var completedStepCount: Int {
        [isFolderComplete, isCLIComplete, isDownloadComplete].filter { $0 }.count
    }
}

enum ModelSetupPresentationState: Equatable {
    case needsFolder
    case needsModel(folderURL: URL, version: ASRModelVersion, statusMessage: String)
    case repoFolderSelected(folderURL: URL, selectedRepo: ASRModelVersion, version: ASRModelVersion, statusMessage: String)
    case ready(folderURL: URL, version: ASRModelVersion, statusMessage: String)
}

extension OnboardingFlowController {
    var isModelCLIAvailable: Bool {
        if snapshot.modelStatus.isReady {
            return true
        }
        return ModelSetupSupport.isHuggingFaceCLIAvailable()
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
}
