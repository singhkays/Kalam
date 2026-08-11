import XCTest
@preconcurrency import FluidAudio
@testable import Kalam_test

/// Real-model Parakeet smoke tests (FluidAudio 0.15.5 adoption, Phase 1.6).
///
/// These tests load the actual CoreML model folders and transcribe a fixed
/// TTS-generated fixture (`fixtures/dictation_fixture.wav`, 9.3s @16kHz mono)
/// through the same `AsrModels`/`AsrManager` path Kalam's `ASRService` uses.
/// They prove: (1) the 0.15.5 `ModelHub` load path works offline against the
/// real artifacts, (2) transcription produces meaningful output, and (3) the
/// `ModelHub.offlineMode` invariant holds with real models on disk.
///
/// Setup: place model folders (`parakeet-tdt-0.6b-v2`, `-v3`, `-ctc-110m`) in
/// `<repo>/Models/`, or point `KALAM_MODEL_LIBRARY` at a directory containing
/// them. Tests for absent/incomplete models are SKIPPED (never fail), so the
/// suite stays green on machines without models. Run via
/// `./scripts/parakeet-smoke.sh`.
///
/// Privacy note: the transcript printed below is the fixed test fixture's
/// transcription (synthesized speech), not user dictation — the app's own
/// logging conventions (never log transcript text) are unaffected.
final class RealModelSmokeTests: XCTestCase {

    private static let envModelLibrary = ProcessInfo.processInfo.environment["KALAM_MODEL_LIBRARY"]

    /// <repo>/app/KalamTests/RealModelSmokeTests.swift → <repo>
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KalamTests
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // <repo>
    }

    private static var modelLibrary: URL {
        if let envModelLibrary, !envModelLibrary.isEmpty {
            return URL(fileURLWithPath: envModelLibrary, isDirectory: true)
        }
        return repoRoot.appendingPathComponent("Models", isDirectory: true)
    }

    private static func fixtureURL() -> URL? {
        let repo = repoRoot.appendingPathComponent("fixtures/dictation_fixture.wav")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    func testParakeetV2Smoke() async throws {
        try await runSmoke(for: .v2)
    }

    func testParakeetV3Smoke() async throws {
        try await runSmoke(for: .v3)
    }

    func testParakeetTdtCtc110mSmoke() async throws {
        try await runSmoke(for: .tdtCtc110m)
    }

    // MARK: - Core

    private func runSmoke(for version: ASRModelVersion) async throws {
        let folder = Self.modelLibrary
            .appendingPathComponent(version.repositoryFolderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw XCTSkip(
                "No model folder at \(folder.path). Place models in <repo>/Models or set KALAM_MODEL_LIBRARY."
            )
        }
        guard AsrModels.modelsExist(at: folder, version: version.fluidAudioVersion) else {
            throw XCTSkip("Incomplete model folder at \(folder.path).")
        }
        guard let fixture = Self.fixtureURL() else {
            throw XCTSkip("Missing fixture at fixtures/dictation_fixture.wav.")
        }

        // Production invariant: FluidAudio must never attempt a network fetch /
        // delete-cache-and-redownload (Kalam has no network entitlement).
        XCTAssertTrue(ModelHub.offlineMode, "ModelHub.offlineMode must be true (no network entitlement)")

        let samples = try Self.decodeWav(fixture)
        XCTAssertEqual(samples.count, 148_154, "fixture should be 9.26s at 16kHz")

        let loadStart = Date()
        let models = try await AsrModels.load(from: folder, version: version.fluidAudioVersion)
        let loadTime = Date().timeIntervalSince(loadStart)

        // Mirror ASRService.initialize's production config shape exactly.
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

        let transcribeStart = Date()
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        let transcribeTime = Date().timeIntervalSince(transcribeStart)

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = text.split(separator: " ").count
        let report = "[RealModelSmoke] \(version.rawValue): load=\(String(format: "%.1f", loadTime))s "
            + "transcribe=\(String(format: "%.1f", transcribeTime))s words=\(wordCount)"
        let transcriptLine = "[RealModelSmoke] \(version.rawValue) transcript: \(text)"
        NSLog("%@", report)
        NSLog("%@", transcriptLine)
        // App-hosted test stdout is not captured by xcodebuild and env vars do
        // not propagate through testmanagerd (Xcode 26), so evidence goes to a
        // deterministic path: /tmp/parakeet-smoke-report.txt (the runner cats
        // it). KALAM_SMOKE_OUTPUT overrides when env propagation works.
        let outputPath = ProcessInfo.processInfo.environment["KALAM_SMOKE_OUTPUT"]
            ?? "/tmp/parakeet-smoke-report.txt"
        let outputURL = URL(fileURLWithPath: outputPath)
        let header = "fixture: The quick brown fox jumps over the lazy dog. "
            + "Please schedule a meeting for tomorrow at three o'clock.\n"
        let line = "\(report)\n\(transcriptLine)\n"
        if FileManager.default.fileExists(atPath: outputURL.path) {
            if let handle = try? FileHandle(forWritingTo: outputURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
            }
        } else {
            try? (header + line).write(to: outputURL, atomically: true, encoding: .utf8)
        }

        XCTAssertFalse(text.isEmpty, "transcript must be non-empty")
        XCTAssertGreaterThanOrEqual(wordCount, 5, "transcript implausibly short")
        let lowered = text.lowercased()
        let keywords = ["quick", "brown", "lazy", "meeting"]
        XCTAssertTrue(
            keywords.contains { lowered.contains($0) },
            "transcript missing any expected keyword: \(text)"
        )
    }

    // MARK: - WAV decode (16kHz mono PCM16, hand-rolled to avoid AVAsset async)

    private enum WavError: Error {
        case notRIFF
        case unsupportedFormat
    }

    private static func decodeWav(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > 44, Array(data[0..<4]) == Array("RIFF".utf8) else {
            throw WavError.notRIFF
        }
        var offset = 12
        var sampleRate = 0
        var channels = 0
        var bits = 0
        var audio: Data?
        while offset + 8 <= data.count {
            let chunkID = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let chunkSize = Int(data[offset + 4])
                | (Int(data[offset + 5]) << 8)
                | (Int(data[offset + 6]) << 16)
                | (Int(data[offset + 7]) << 24)
            switch chunkID {
            case "fmt ":
                channels = Int(data[offset + 10]) | (Int(data[offset + 11]) << 8)
                sampleRate = Int(data[offset + 12])
                    | (Int(data[offset + 13]) << 8)
                    | (Int(data[offset + 14]) << 16)
                    | (Int(data[offset + 15]) << 24)
                bits = Int(data[offset + 22]) | (Int(data[offset + 23]) << 8)
            case "data":
                audio = data.subdata(in: (offset + 8)..<(offset + 8 + chunkSize))
            default:
                break
            }
            offset += 8 + chunkSize + (chunkSize % 2)
        }
        guard let audio, sampleRate == 16_000, bits == 16, channels == 1 else {
            throw WavError.unsupportedFormat
        }
        var samples = [Float](repeating: 0, count: audio.count / 2)
        audio.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            for i in 0..<samples.count {
                samples[i] = Float(ints[i]) / 32768.0
            }
        }
        return samples
    }
}
