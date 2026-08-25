import AppKit
import CoreML
import Foundation
@preconcurrency import FluidAudio
import OSLog

private func privacySafeErrorSummary(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain)#\(nsError.code)"
}

enum ASRError: LocalizedError, Sendable {
    case notInitialized
    case modelLibraryNotConfigured
    case modelFolderMissing(version: ASRModelVersion, expectedPath: String)
    case invalidModelFiles(version: ASRModelVersion, expectedPath: String)
    
    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "ASR not initialized yet."
        case .modelLibraryNotConfigured:
            return "No model library folder selected. Open Settings > Models and choose your model library folder."
        case .modelFolderMissing(let version, let expectedPath):
            return "Missing \(version.displayName) model folder at \(expectedPath)."
        case .invalidModelFiles(let version, let expectedPath):
            return "Incomplete or invalid files for \(version.displayName) at \(expectedPath)."
        }
    }

    var isSetupRelated: Bool {
        switch self {
        case .modelLibraryNotConfigured, .modelFolderMissing, .invalidModelFiles:
            return true
        case .notInitialized:
            return false
        }
    }

    var recordingBlockMessage: String {
        switch self {
        case .modelLibraryNotConfigured:
            return "Set model folder in Settings"
        case .modelFolderMissing:
            return "Selected model is missing"
        case .invalidModelFiles:
            return "Selected model files are invalid"
        case .notInitialized:
            return "Model loading..."
        }
    }
}

struct ASRServiceStatus: Sendable {
    let isReady: Bool
    let isSetupIssue: Bool
    let recordingBlockMessage: String
}

actor ASRService {
    private let logger = Logger(subsystem: "singhkays.Kalam", category: "ASRService")

    /// FluidAudio must never touch the network: Kalam has no network
    /// entitlement (hard convention, see IMPROVEMENT_PLAN "What looks solid").
    /// This blocks ModelHub's delete-cache-and-redownload fallback and any
    /// HuggingFace fetch, surfacing typed `DownloadError.modelMissing`/`networkDisabled`
    /// instead (adopted with FluidAudio 0.15.5 — see app/docs/dev-design/2026-08-11-fluidaudio-0.15.x-adoption.md).
    /// Idempotent; must run before any FluidAudio loader is touched.
    static func enforceOfflineMode() {
        ModelHub.offlineMode = true
    }

    /// Opt-in GPU encoder placement (FluidAudio 0.15.1 #659): upstream measured
    /// ~+8% end-to-end RTFx, WER-neutral on Apple Silicon for the Parakeet v3
    /// conformer encoder (17.8ms vs 23.5ms per 15s window). ANE remains the
    /// default for power efficiency on iOS; a plugged-in macOS dictation app is
    /// the throughput workload the docstring targets. Scoped to v3 because
    /// upstream measured v3 only (Q1 in the adoption dev-design doc) — v2/110m
    /// keep the default until measured. `nil` = FluidAudio default.
    private static func encoderComputeUnits(for version: ASRModelVersion) -> MLComputeUnits? {
        #if arch(arm64)
        return version == .v3 ? .cpuAndGPU : nil
        #else
        return nil
        #endif
    }

    private var asrManager: AsrManager?
    private var initialized = false
    private var currentModelVersion: ASRModelVersion?
    private var currentModelDirectoryPath: String?
    private(set) var lastInitializationErrorDescription: String?
    private(set) var isSetupIssue = false
    private var lastASRError: ASRError?
    private var warmupTask: Task<Void, Never>?
    
    // Public read-only property for readiness check
    var isReady: Bool {
        asrManager != nil && initialized
    }

    var recordingBlockMessage: String {
        recordingBlockMessageValue
    }

    var status: ASRServiceStatus {
        ASRServiceStatus(
            isReady: isReady,
            isSetupIssue: isSetupIssue,
            recordingBlockMessage: recordingBlockMessageValue
        )
    }

    private var recordingBlockMessageValue: String {
        if let lastASRError {
            return lastASRError.recordingBlockMessage
        }
        if let lastInitializationErrorDescription, !lastInitializationErrorDescription.isEmpty {
            return "Model initialization failed"
        }
        return "Model loading..."
    }
    
    func initialize() async throws {
        try await initialize(using: ModelSetupSupport.loadPersistedNormalizedSelectedModel())
    }
    
    func initialize(with version: ASRModelVersion) async throws {
        var config = ModelsConfiguration.load()
        config.asrVersion = version
        try await initialize(using: config)
    }

    private func initialize(using config: ModelsConfiguration) async throws {
        Self.enforceOfflineMode()
        do {
            let version = config.asrVersion
            let availability = config.availability(for: version)
            let modelDirectory: URL
            let modelLibraryURL: URL

            switch availability {
            case .modelLibraryNotConfigured:
                throw ASRError.modelLibraryNotConfigured
            case .missingModelFolder(let expectedPath):
                throw ASRError.modelFolderMissing(version: version, expectedPath: expectedPath)
            case .invalidModelFolder(let expectedPath):
                throw ASRError.invalidModelFiles(version: version, expectedPath: expectedPath)
            case .partial(let expectedPath, let missing, _):
                // A partial download cannot load; surface as invalid files with a
                // precise reason (the manifest names the missing files).
                throw ASRError.invalidModelFiles(version: version, expectedPath: expectedPath + missing.map { "\nmissing: \($0)" }.joined())
            case .installed(let path):
                modelDirectory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                guard let libraryURL = config.modelLibraryURL else {
                    throw ASRError.modelLibraryNotConfigured
                }
                modelLibraryURL = libraryURL.standardizedFileURL
            }

            if initialized && currentModelVersion == version && currentModelDirectoryPath == modelDirectory.path {
                return
            }

            let models = try await ModelsConfiguration.withSecurityScopedAccess(to: modelLibraryURL) {
                try await AsrModels.load(
                    from: modelDirectory,
                    version: version.fluidAudioVersion,
                    encoderComputeUnits: Self.encoderComputeUnits(for: version)
                )
            }
            
            var asrConfig = ASRConfig.default
            asrConfig = ASRConfig(
                sampleRate: asrConfig.sampleRate,
                tdtConfig: asrConfig.tdtConfig,
                encoderHiddenSize: asrConfig.encoderHiddenSize,
                parallelChunkConcurrency: 4, 
                streamingEnabled: asrConfig.streamingEnabled,
                streamingThreshold: asrConfig.streamingThreshold
            )
            
            let manager = AsrManager(config: asrConfig, models: models)
            warmupTask?.cancel()
            self.asrManager = manager
            self.initialized = true
            self.currentModelVersion = version
            self.currentModelDirectoryPath = modelDirectory.path
            self.lastInitializationErrorDescription = nil
            self.isSetupIssue = false
            self.lastASRError = nil
            
            logger.info("ASR initialized with model=\(version.displayName, privacy: .public)")
            
            // Warm-up: actor-owned task avoids detached captures of non-Sendable ASR state.
            warmupTask = Task(priority: .utility) { [modelPath = modelDirectory.path] in
                await self.warmUpCurrentManager(expectedModelDirectoryPath: modelPath)
            }
        } catch {
            warmupTask?.cancel()
            warmupTask = nil
            self.asrManager = nil
            self.initialized = false
            self.currentModelVersion = nil
            self.currentModelDirectoryPath = nil
            self.lastInitializationErrorDescription = error.localizedDescription
            if let asrError = error as? ASRError {
                self.isSetupIssue = asrError.isSetupRelated
                self.lastASRError = asrError
            } else {
                self.isSetupIssue = true
                self.lastASRError = nil
            }
            throw error
        }
    }
    
    func reinitializeIfNeeded() async throws {
        let config = ModelsConfiguration.load()
        let version = config.asrVersion
        let targetPath = config.modelDirectoryURL(for: version)?.standardizedFileURL.path

        if !initialized || currentModelVersion != version || currentModelDirectoryPath != targetPath {
            logger.info("ASR model configuration changed; reinitializing")
            warmupTask?.cancel()
            warmupTask = nil
            asrManager = nil
            initialized = false
            try await initialize(using: config)
        }
    }
    
    private func warmUpCurrentManager(expectedModelDirectoryPath: String) async {
        guard currentModelDirectoryPath == expectedModelDirectoryPath,
              let asrManager,
              initialized
        else {
            return
        }

        do {
            let warm = [Float](repeating: 0.0, count: 240_000)  // 15s at 16kHz to match [1, 240000] shape and min requirements
            var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
            _ = try await asrManager.transcribe(warm, decoderState: &decoderState)
            guard !Task.isCancelled else { return }
            logger.info("ASR warm-up completed")
        } catch is CancellationError {
            return
        } catch {
            logger.warning("ASR warm-up skipped or failed errorSummary=\(privacySafeErrorSummary(error), privacy: .public)")
        }
    }

    func transcribe(samples: [Float]) async throws -> String {
        let config = ModelsConfiguration.load()
        let targetPath = config.modelDirectoryURL(for: config.asrVersion)?.standardizedFileURL.path
        if !initialized || currentModelVersion != config.asrVersion || currentModelDirectoryPath != targetPath {
            try await reinitializeIfNeeded()
        }
        
        guard let asrManager = asrManager, initialized else {
            throw ASRError.notInitialized
        }
        // Parakeet TDT expects 16kHz mono Float32
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(samples, decoderState: &decoderState)
        return result.text
    }
}

// MARK: - Paste into focused app
