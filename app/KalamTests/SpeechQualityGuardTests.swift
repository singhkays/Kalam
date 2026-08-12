import XCTest
@testable import Kalam_test

// K-27: noise-only clips must never reach ASR — Parakeet TDT hallucinates
// filler words ("yeah") on boosted room tone.
final class SpeechQualityGuardTests: XCTestCase {
    private func sine(amplitude: Float, frequency: Float = 220, durationMs: Int, sampleRate: Int = 16_000) -> [Float] {
        let count = sampleRate * durationMs / 1000
        return (0..<count).map { i in
            amplitude * sin(2 * Float.pi * frequency * Float(i) / Float(sampleRate))
        }
    }

    private func whiteNoise(amplitude: Float, durationMs: Int, sampleRate: Int = 16_000, seed: UInt32 = 7) -> [Float] {
        var rng = seed
        let count = sampleRate * durationMs / 1000
        return (0..<count).map { _ in
            rng = rng &* 1_664_525 &+ 1_013_904_223
            let unit = Float(rng >> 24) / Float(0xFF)
            return (unit * 2 - 1) * amplitude
        }
    }

    func testPureSilenceIsRejected() {
        XCTAssertFalse(SpeechQualityGuard.isSpeechLike(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000))
    }

    func testRoomToneNoiseIsRejected() {
        XCTAssertFalse(SpeechQualityGuard.isSpeechLike(samples: whiteNoise(amplitude: 0.001, durationMs: 800), sampleRate: 16_000))
    }

    func testLouderNoiseIsRejected() {
        // Uniform noise has no windows 6 dB above its own floor.
        XCTAssertFalse(SpeechQualityGuard.isSpeechLike(samples: whiteNoise(amplitude: 0.01, durationMs: 800), sampleRate: 16_000))
    }

    func testToneBurstOverNoiseIsAccepted() {
        var clip = whiteNoise(amplitude: 0.001, durationMs: 500)
        clip.append(contentsOf: sine(amplitude: 0.1, durationMs: 300))
        clip.append(contentsOf: whiteNoise(amplitude: 0.001, durationMs: 200))
        XCTAssertTrue(SpeechQualityGuard.isSpeechLike(samples: clip, sampleRate: 16_000))
    }

    func testShortToneBurstIsRejected() {
        // 60 ms of tone is below the 120 ms minimum speech run.
        var clip = whiteNoise(amplitude: 0.001, durationMs: 300)
        clip.append(contentsOf: sine(amplitude: 0.1, durationMs: 60))
        clip.append(contentsOf: whiteNoise(amplitude: 0.001, durationMs: 300))
        XCTAssertFalse(SpeechQualityGuard.isSpeechLike(samples: clip, sampleRate: 16_000))
    }

    func testSingleImpulseIsRejected() {
        var clip = [Float](repeating: 0, count: 16_000)
        clip[8000] = 0.5
        XCTAssertFalse(SpeechQualityGuard.isSpeechLike(samples: clip, sampleRate: 16_000))
    }

    func testEmptyIsRejected() {
        XCTAssertFalse(SpeechQualityGuard.isSpeechLike(samples: [], sampleRate: 16_000))
    }
}
