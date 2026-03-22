import XCTest
import AVFoundation
@testable import Kalam_test

final class KalamEngineIntegrationTests: XCTestCase {
    
    struct TestCase: Codable {
        let name: String
        let input: String
        let expected: String
        let description: String
    }

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: "internal.itn.enabled")
    }
    
    func testGoldenCases() throws {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "engine_golden_tests", withExtension: "json") else {
            XCTFail("Missing engine_golden_tests.json in test bundle")
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            print("KalamTests: Data loaded successfully (\(data.count) bytes)")
            
            let cases = try JSONDecoder().decode([TestCase].self, from: data)
            print("KalamTests: Decoded \(cases.count) test cases")
            
            for testCase in cases {
                XCTContext.runActivity(named: "Running Test Case: \(testCase.name)") { _ in
                    print("\n--- Running Test Case: \(testCase.name) ---")
                    print("Description: \(testCase.description)")
                    
                    let result = KalamTestRunner.shared.runTextPipeline(testCase.input)
                    result.printSummary()
                    
                    XCTAssertEqual(result.final.lowercased(), testCase.expected.lowercased(), "Test case '\(testCase.name)' failed.")
                }
            }
        } catch {
            print("KalamTests: FATAL ERROR during test setup: \(error)")
            XCTFail("Fatal error during test setup: \(error)")
        }
    }

    func testITNDefaultsToEnabledWhenUnset() throws {
        guard NemoTextProcessing.isAvailable else {
            throw XCTSkip("NemoTextProcessing is not linked in this test environment.")
        }

        let smoke = NemoTextProcessing.normalize("two hundred and five")
        guard smoke != "two hundred and five" else {
            throw XCTSkip("NemoTextProcessing is available but not normalizing in this test environment.")
        }

        UserDefaults.standard.removeObject(forKey: "internal.itn.enabled")

        let result = KalamTestRunner.shared.runTextPipeline(
            "two hundred and five",
            configuration: TextCleanupConfiguration(
                enabled: true,
                removeFillers: false,
                backtrack: false,
                listFormatting: false,
                punctuation: true,
                grammarMode: .off,
                grammarTimeoutMs: 100
            )
        )

        XCTAssertEqual(result.afterCleanup.lowercased(), "two hundred and five")
        XCTAssertEqual(result.afterITN, "205")
        XCTAssertEqual(result.final, "205")
    }

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
