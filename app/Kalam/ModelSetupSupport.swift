import AppKit
import Foundation
@preconcurrency import FluidAudio

enum SystemSettingsDestination {
    case accessibility
    case microphone

    var deepLinkURLs: [String] {
        switch self {
        case .accessibility:
            return [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_Accessibility",
            ]
        case .microphone:
            return [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_Microphone",
            ]
        }
    }
}

enum SystemSettingsNavigator {
    @MainActor
    static var openURL: (URL) -> Bool = { url in
        NSWorkspace.shared.open(url)
    }

    @MainActor
    @discardableResult
    static func open(_ destination: SystemSettingsDestination) -> Bool {
        for deepLinkURL in destination.deepLinkURLs {
            if let deepLink = URL(string: deepLinkURL), openURL(deepLink) {
                return true
            }
        }
        if let fallback = URL(string: "x-apple.systempreferences:") {
            return openURL(fallback)
        }
        return false
    }
}

enum ModelSetupSupport {
    static let huggingFaceInstallCommand = "brew install hf"

    @discardableResult
    @MainActor
    static func openModelLibraryFolder(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    static func downloadCommand(for version: ASRModelVersion, config: ModelsConfiguration) -> String {
        let repo = "\(version.repositoryFolderName)-coreml"
        let basePath = config.modelLibraryURL?.path ?? "<SELECTED_FOLDER>"
        let destination = shellQuote("\(basePath)/\(version.repositoryFolderName)")
        let includes = version.requiredModelDirectoryNames
            .map { "  --include \"\($0)/*\" \\" }
            .joined(separator: "\n")
        return """
        hf download FluidInference/\(repo) \\
        \(includes)
          --include "*vocab.json" \\
          --local-dir \(destination)
        """
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func installedModelVersions(in config: ModelsConfiguration) -> [ASRModelVersion] {
        ASRModelVersion.allCases.filter { config.availability(for: $0).isInstalled }
    }

    // MARK: - Per-file manifest (v3 adoption, Task 6)

    /// The exact file set FluidAudio's `AsrModels.modelsExist` validates, derived
    /// from the same public source (`ModelNames.ASR`) so the UI can never
    /// disagree with the validator. Kalam's own `requiredModelDirectoryNames`
    /// is deliberately NOT used — it omits the encoder and vocab files.
    static func requiredModelFiles(for version: ASRModelVersion) -> [String] {
        let faVersion = version.fluidAudioVersion
        var files: Set<String>
        if faVersion == .v3 {
            files = ModelNames.ASR.requiredModelsV3(precision: .int8)
        } else if faVersion.hasFusedEncoder {
            files = ModelNames.ASR.requiredModelsFused
        } else {
            files = ModelNames.ASR.requiredModels
        }
        files.insert(ModelNames.ASR.vocabularyFile)
        return files.sorted()
    }

    /// Per-file presence for the selected model inside the library. Mirrors
    /// FluidAudio's repo-path resolution (`library.parent / version.repo.folderName`)
    /// and runs inside the same security scope as the availability check.
    /// `fileExists` is injectable for tests.
    static func modelFileManifest(
        for version: ASRModelVersion,
        libraryURL: URL?,
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [ASRModelFileEntry] {
        guard let libraryURL else { return [] }
        // FluidAudio's modelsExist resolves `directory.parent / repo.folderName`;
        // for Kalam installs that folder is exactly `repositoryFolderName` (the
        // download command's --local-dir target), so use Kalam's public name.
        let repoPath = libraryURL.deletingLastPathComponent()
            .appendingPathComponent(version.repositoryFolderName)
        return requiredModelFiles(for: version).map { name in
            ASRModelFileEntry(
                name: name,
                isPresent: fileExists(repoPath.appendingPathComponent(name).path)
            )
        }
    }

    /// Availability refined with per-file knowledge: distinguishes a partial
    /// download (some files arrived) from an invalid folder (none did).
    static func refinedAvailability(
        base: ASRModelAvailability,
        manifest: [ASRModelFileEntry]
    ) -> ASRModelAvailability {
        switch base {
        case .invalidModelFolder(let expectedPath):
            let missing = manifest.filter { !$0.isPresent }.map(\.name)
            guard manifest.count > missing.count else { return base }
            return .partial(
                expectedPath: expectedPath,
                missing: missing,
                total: manifest.count
            )
        default:
            return base
        }
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

    static func loadPersistedNormalizedSelectedModel(from defaults: UserDefaults = .standard) -> ModelsConfiguration {
        let loaded = ModelsConfiguration.load(from: defaults)
        let normalized = normalizedSelectedModel(in: loaded)
        if normalized != loaded {
            // Persist the promotion (e.g. v2 -> v3 once v3 is installed) so every
            // subsequent plain load sees the same selection. Mirrors the existing
            // load-side-effect pattern for stale bookmark refresh.
            normalized.save(to: defaults)
        }
        return normalized
    }

    static func availabilityMessage(for availability: ASRModelAvailability) -> String {
        switch availability {
        case .modelLibraryNotConfigured:
            return "Choose a model library folder, then install the selected model files into it."
        case .missingModelFolder(let expectedPath):
            return "Missing model folder for the selected model:\n\(expectedPath)"
        case .invalidModelFolder(let expectedPath):
            return "Model folder exists but required files are missing or invalid:\n\(expectedPath)"
        case .partial(_, let missing, let total):
            let names = missing.map { "• \($0)" }.joined(separator: "\n")
            return "\(total - missing.count) of \(total) model files arrived. Still missing:\n\(names)"
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

    @MainActor
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
