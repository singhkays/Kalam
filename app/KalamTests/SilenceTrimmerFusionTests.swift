import XCTest
@testable import Kalam_test

final class SilenceTrimmerFusionTests: XCTestCase {
    /// Noise floor + two speech bursts + trailing silence: exercises
    /// segmentation, padding/merge, and every fallback branch across sizes.
    private func speechFixture() -> [Float] {
        var xs: [Float] = []
        let sr = 16_000
        xs.append(contentsOf: (0..<sr / 2).map { _ in Float.random(in: -0.001...0.001) })          // 0.5 s room tone
        xs.append(contentsOf: (0..<2 * sr).map { 0.4 * sin(2 * Float.pi * 180 * Float($0) / Float(sr)) }) // 2 s burst
        xs.append(contentsOf: (0..<sr).map { _ in Float.random(in: -0.002...0.002) })              // 1 s gap
        xs.append(contentsOf: (0..<sr).map { 0.3 * sin(2 * Float.pi * 240 * Float($0) / Float(sr)) })     // 1 s burst
        xs.append(contentsOf: (0..<3 * sr / 2).map { _ in Float.random(in: -0.001...0.001) })      // 1.5 s tail
        return xs
    }

    private func assertParity(_ input: [Float], accuracy: Float = 1e-5) {
        let legacy = SilenceTrimmer.normalizePeak(
            SilenceTrimmer.trim(samples: input, sampleRate: 16_000),
            targetDbFS: -3.0)
        let fused = SilenceTrimmer.trimAndNormalize(samples: input, sampleRate: 16_000)
        XCTAssertEqual(fused.count, legacy.count)
        for (a, b) in zip(fused, legacy) {
            XCTAssertEqual(a, b, accuracy: accuracy)
        }
    }

    func testParityOnSpeechFixture() { assertParity(speechFixture()) }

    func testParityOnShortClipFallback() {          // < 2.5 s: conservative fallback branch
        var xs: [Float] = (0..<8_000).map { _ in Float.random(in: -0.003...0.003) }
        xs.append(contentsOf: (0..<12_000).map { 0.35 * sin(2 * Float.pi * 200 * Float($0) / 16_000.0) })
        assertParity(xs)
    }

    func testParityWhenScaleWithinFivePercentSkips() {  // normalizePeak's no-op band
        let peak: Float = 0.69   // scale ~= 0.7079/0.69 = 1.026 -> within 5%, legacy skips
        let xs: [Float] = (0..<16_000).map { peak * sin(2 * Float.pi * 200 * Float($0) / 16_000.0) }
        assertParity(xs)
    }

    func testAllSilentInputYieldsEmpty() {
        let xs = [Float](repeating: 0, count: 16_000)
        XCTAssertTrue(SilenceTrimmer.trimAndNormalize(samples: xs, sampleRate: 16_000).isEmpty)
    }

    func testEmptyInputYieldsEmpty() {
        XCTAssertTrue(SilenceTrimmer.trimAndNormalize(samples: [], sampleRate: 16_000).isEmpty)
    }

    func testFallbackFullClipStillNormalized() {    // no-speech-but-loud: legacy returns RAW samples then normalizes
        let xs: [Float] = (0..<24_000).map { _ in Float.random(in: -0.4...0.4) }
        assertParity(xs)
    }

    func testSpeechQualityGuardVerdictUnchangedByNormalizationOffset() {
        let input = speechFixture()
        let legacy = SilenceTrimmer.trim(samples: input, sampleRate: 16_000)
        let fused = SilenceTrimmer.trimAndNormalize(samples: input, sampleRate: 16_000)
        XCTAssertEqual(
            SpeechQualityGuard.isSpeechLike(samples: legacy, sampleRate: 16_000),
            SpeechQualityGuard.isSpeechLike(samples: fused, sampleRate: 16_000))
    }
}
