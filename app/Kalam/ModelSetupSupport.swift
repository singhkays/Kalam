import AppKit
import Foundation

enum SystemSettingsDestination {
    case accessibility
    case microphone

    var deepLinkURL: String {
        switch self {
        case .accessibility:
            return "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_Accessibility"
        case .microphone:
            return "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_Microphone"
        }
    }
}

enum SystemSettingsNavigator {
    @discardableResult
    static func open(_ destination: SystemSettingsDestination) -> Bool {
        if let deepLink = URL(string: destination.deepLinkURL), NSWorkspace.shared.open(deepLink) {
            return true
        }
        if let fallback = URL(string: "x-apple.systempreferences:") {
            return NSWorkspace.shared.open(fallback)
        }
        return false
    }
}

enum ModelSetupSupport {
    static let huggingFaceInstallCommand = "curl -LsSf https://hf.co/cli/install.sh | bash"

    static func isHuggingFaceCLIAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v hf >/dev/null 2>&1"]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    @discardableResult
    static func openModelLibraryFolder(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    static func downloadCommand(for version: ASRModelVersion, config: ModelsConfiguration) -> String {
        let repo = version.repositoryFolderName
        let basePath = config.modelLibraryURL?.path ?? "<SELECTED_FOLDER>"
        return """
        hf download FluidInference/\(repo) \\
          --include "Preprocessor.mlmodelc/*" \\
          --include "Encoder.mlmodelc/*" \\
          --include "Decoder.mlmodelc/*" \\
          --include "JointDecision.mlmodelc/*" \\
          --include "parakeet_vocab.json" \\
          --local-dir \(basePath)/\(repo)
        """
    }

    static func installedModelVersions(in config: ModelsConfiguration) -> [ASRModelVersion] {
        ASRModelVersion.allCases.filter { config.availability(for: $0).isInstalled }
    }

    static func normalizedSelectedModel(in config: ModelsConfiguration) -> ModelsConfiguration {
        let installed = installedModelVersions(in: config)
        guard !installed.isEmpty else { return config }
        guard !config.availability(for: config.asrVersion).isInstalled, let firstInstalled = installed.first else {
            return config
        }

        var updated = config
        updated.asrVersion = firstInstalled
        return updated
    }

    static func availabilityMessage(for availability: ASRModelAvailability) -> String {
        switch availability {
        case .modelLibraryNotConfigured:
            return "Choose a model library folder, then install the selected model files into it."
        case .missingModelFolder(let expectedPath):
            return "Missing model folder for the selected model:\n\(expectedPath)"
        case .invalidModelFolder(let expectedPath):
            return "Model folder exists but required files are missing or invalid:\n\(expectedPath)"
        case .installed:
            return "Installed"
        }
    }

    static func selectedModelRepoFolderVersion(for currentURL: URL?) -> ASRModelVersion? {
        guard let currentURL = currentURL?.standardizedFileURL else { return nil }
        return ASRModelVersion.allCases.first { version in
            currentURL.lastPathComponent == version.repositoryFolderName
        }
    }

    static func chooseModelLibraryFolder(currentURL: URL?, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.prompt = "Choose Folder"
        panel.message = "Select the folder that will contain your local speech model directories."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let currentURL {
            panel.directoryURL = currentURL
        }

        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    static func applyingModelLibraryFolder(_ folderURL: URL?, to config: ModelsConfiguration) throws -> ModelsConfiguration {
        var updated = config
        try updated.setModelLibraryURL(folderURL)
        return normalizedSelectedModel(in: updated)
    }
}
