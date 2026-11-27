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

    private struct PendingLoad {
        let selection: ASRModelSelection
        let task: Task<Void, Error>
    }

    private var asrManager: AsrManager?
    private var currentSelection: ASRModelSelection?
    private var pendingLoad: PendingLoad?
    private var loadGeneration = 0
    var currentModelVersion: ASRModelVersion? { currentSelection?.version }
    private(set) var lastInitializationErrorDescription: String?
    private(set) var isSetupIssue = false
    private var lastASRError: ASRError?
    private var warmupTask: Task<Void, Never>?
    
    typealias ModelLoader = @Sendable (URL, URL, ASRModelVersion) async throws -> AsrManager
    private let loadModel: ModelLoader

    init(loadModel: @escaping ModelLoader = ASRService.loadFromDisk) {
        self.loadModel = loadModel
    }

    // Public read-only property for readiness check
    var isReady: Bool {
        asrManager != nil
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

    func initialize(using config: ModelsConfiguration) async throws {
        let selection = config.asrSelection
        if currentSelection == selection, isReady { return }

        if let pendingLoad, pendingLoad.selection == selection {
            try await waitForLoad(pendingLoad.task, generation: loadGeneration)
            return
        }

        pendingLoad?.task.cancel()
        warmupTask?.cancel()
        warmupTask = nil
        asrManager = nil
        currentSelection = nil
        lastInitializationErrorDescription = nil
        isSetupIssue = false
        lastASRError = nil
        loadGeneration += 1
        let generation = loadGeneration
        let task = Task {
            try await self.loadAndActivate(using: config, selection: selection, generation: generation)
        }
        pendingLoad = PendingLoad(selection: selection, task: task)
        try await waitForLoad(task, generation: generation)
    }

    private func waitForLoad(_ task: Task<Void, Error>, generation: Int) async throws {
        let result = await task.result
        try Task.checkCancellation()
        guard generation == loadGeneration else { throw CancellationError() }
        try result.get()
    }

    private func loadAndActivate(
        using config: ModelsConfiguration, selection: ASRModelSelection, generation: Int
    ) async throws {
        defer {
            if generation == loadGeneration { pendingLoad = nil }
        }
        do {
            try Task.checkCancellation()
            Self.enforceOfflineMode()
            let version = selection.version
            let modelDirectory: URL
            switch config.availability(for: version) {
            case .modelLibraryNotConfigured:
                throw ASRError.modelLibraryNotConfigured
            case .missingModelFolder(let expectedPath):
                throw ASRError.modelFolderMissing(version: version, expectedPath: expectedPath)
            case .invalidModelFolder(let expectedPath):
                throw ASRError.invalidModelFiles(version: version, expectedPath: expectedPath)
            case .partial(let expectedPath, let missing, _):
                throw ASRError.invalidModelFiles(
                    version: version, expectedPath: expectedPath + missing.map { "\nmissing: \($0)" }.joined()
                )
            case .installed(let path):
                modelDirectory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            }
            guard let library = selection.library else { throw ASRError.modelLibraryNotConfigured }

            let manager = try await loadModel(modelDirectory, library, version)
            guard generation == loadGeneration else { throw CancellationError() }
            asrManager = manager
            currentSelection = selection
            logger.info("ASR initialized with model=\(version.displayName, privacy: .public)")
            warmupTask = Task(priority: .utility) {
                await self.warmUpCurrentManager(generation: generation)
            }
        } catch {
            guard generation == loadGeneration else { throw CancellationError() }
            lastInitializationErrorDescription = error.localizedDescription
            lastASRError = error as? ASRError
            isSetupIssue = lastASRError?.isSetupRelated ?? true
            throw error
        }
    }

    private static func loadFromDisk(
        _ modelDirectory: URL, _ modelLibraryURL: URL, _ version: ASRModelVersion
    ) async throws -> AsrManager {
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

        return AsrManager(config: asrConfig, models: models)
    }

    private func warmUpCurrentManager(generation: Int) async {
        guard loadGeneration == generation, let asrManager else { return }

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

    func transcribe(samples: consuming [Float]) async throws -> String {
        var pcm = consume samples
        defer { pcm.secureZero() }
        let config = ModelsConfiguration.load()
        try await initialize(using: config)
        guard currentSelection == config.asrSelection, let asrManager else {
            throw ASRError.notInitialized
        }
        // Parakeet TDT expects 16kHz mono Float32
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(pcm, decoderState: &decoderState)
        return result.text
    }
}

// MARK: - Paste into focused app
