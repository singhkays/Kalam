import XCTest
import AVFoundation
import KalamTextEngine
@testable import Kalam_test

final class KalamEngineIntegrationTests: XCTestCase {
    
    struct TestCase: Codable {
        let name: String
        let input: String
        let expected: String
        let description: String
    }

    func testGoldenCases() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "engine_golden_tests", withExtension: "json"))
        let cases = try JSONDecoder().decode([TestCase].self, from: Data(contentsOf: url))
        let processor = TranscriptPostProcessor(cleanupConfig: .defaults, dictionaryEngine: .empty)

        for testCase in cases {
            XCTContext.runActivity(named: testCase.name) { _ in
                let result = processor.process(testCase.input)
                XCTAssertFalse(result.gateRawFallback, testCase.description)
                XCTAssertTrue(result.itnEnabled, testCase.description)
                XCTAssertEqual(result.text.lowercased(), testCase.expected.lowercased(), testCase.description)
            }
        }
    }

    func testCleanupMasterGatesITNInProductionPipeline() throws {
        guard NemoTextProcessing.isAvailable else {
            throw XCTSkip("NemoTextProcessing is unavailable.")
        }

        var config = TextCleanupConfiguration.defaults
        config.grammarMode = .off
        let input = "um call sam at five"
        let enabled = TranscriptPostProcessor(cleanupConfig: config, dictionaryEngine: .empty).process(input)
        XCTAssertEqual(enabled.text, "call sam at 5")
        XCTAssertTrue(enabled.itnEnabled)
        XCTAssertTrue(enabled.itnChanged)

        config.enabled = false
        let disabled = TranscriptPostProcessor(cleanupConfig: config, dictionaryEngine: .empty).process(input)
        XCTAssertEqual(disabled.text, input)
        XCTAssertFalse(disabled.itnEnabled)
        XCTAssertFalse(disabled.itnChanged)
    }

    @MainActor
    func testAudioSmokeFixtureWhenProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixturePath = environment["KALAM_AUDIO_SMOKE_FIXTURE"], !fixturePath.isEmpty else {
            throw XCTSkip("Set KALAM_AUDIO_SMOKE_FIXTURE to run the optional Parakeet audio smoke test.")
        }

        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let samples = try loadMono16kSamples(from: fixtureURL)

        let asr = ASRService()
        do {
            try await asr.initialize()
        } catch {
            throw XCTSkip("Skipping audio smoke test because ASR is not configured on this machine: \(error.localizedDescription)")
        }

        let result = try await KalamTestRunner.shared.runAudioPipeline(samples: samples, asrService: asr)
        XCTAssertFalse(result.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(result.final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        if let expectedSubstring = environment["KALAM_AUDIO_SMOKE_EXPECTED"], !expectedSubstring.isEmpty {
            XCTAssertTrue(
                result.final.localizedCaseInsensitiveContains(expectedSubstring),
                "Expected final transcript to contain '\(expectedSubstring)'."
            )
        }

        result.printSummary()
    }

    private func loadMono16kSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            XCTFail("Unable to allocate PCM buffer for fixture: \(url.path)")
            return []
        }

        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            XCTFail("Fixture is not readable as Float32 PCM: \(url.path)")
            return []
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let sourceRate = buffer.format.sampleRate
        let mono: [Float]

        if channelCount == 1 {
            mono = Array(UnsafeBufferPointer(start: channels[0], count: frameCount))
        } else {
            mono = (0..<frameCount).map { frameIndex in
                var sum: Float = 0
                for channelIndex in 0..<channelCount {
                    sum += channels[channelIndex][frameIndex]
                }
                return sum / Float(channelCount)
            }
        }

        return resample(samples: mono, from: sourceRate, to: 16_000)
    }

    private func resample(samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, abs(sourceRate - targetRate) > 1 else {
            return samples
        }

        let ratio = sourceRate / targetRate
        let targetCount = max(1, Int((Double(samples.count) / ratio).rounded()))
        return (0..<targetCount).map { index in
            let sourcePosition = Double(index) * ratio
            let lowerIndex = min(Int(sourcePosition), samples.count - 1)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))
            if lowerIndex == upperIndex {
                return samples[lowerIndex]
            }
            return samples[lowerIndex] + ((samples[upperIndex] - samples[lowerIndex]) * fraction)
        }
    }
}
