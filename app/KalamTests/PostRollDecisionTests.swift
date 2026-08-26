import XCTest
@testable import Kalam_test

final class PostRollDecisionTests: XCTestCase {
    private func sine(amplitude: Float, seconds: Double, sampleRate: Int = 16_000) -> [Float] {
        (0..<Int(Double(sampleRate) * seconds)).map { index -> Float in
            let sample = Float(index)
            let phase = 2 * Float.pi * 220 * sample / Float(sampleRate)
            return amplitude * sin(phase)
        }
    }

    // MARK: shouldFinish

    func testNeverFinishesBeforeMinimumEvenIfSilent() {
        let config = PostRollDecision.Config(minMs: 100, maxMs: 150)
        XCTAssertFalse(PostRollDecision.shouldFinish(config: config, elapsedMs: 99, consecutiveSilentPolls: 10))
    }

    func testMaxIsHardCeilingEvenDuringSpeech() {
        let config = PostRollDecision.Config(minMs: 100, maxMs: 150)
        XCTAssertTrue(PostRollDecision.shouldFinish(config: config, elapsedMs: 150, consecutiveSilentPolls: 0))
        XCTAssertTrue(PostRollDecision.shouldFinish(config: config, elapsedMs: 200, consecutiveSilentPolls: 0))
    }

    func testRequiresConsecutiveSilentPollsBetweenMinAndMax() {
        let config = PostRollDecision.Config(minMs: 100, maxMs: 150, pollIntervalMs: 15, requiredSilentPolls: 3)
        XCTAssertFalse(PostRollDecision.shouldFinish(config: config, elapsedMs: 120, consecutiveSilentPolls: 2))
        XCTAssertTrue(PostRollDecision.shouldFinish(config: config, elapsedMs: 120, consecutiveSilentPolls: 3))
    }

    func testExactlyAtMinimumWithRequiredSilentPollsFinishes() {
        // Boundary pin: elapsed == minMs (not just >) satisfies the floor.
        let config = PostRollDecision.Config(minMs: 100, maxMs: 150)
        XCTAssertTrue(PostRollDecision.shouldFinish(config: config, elapsedMs: 100, consecutiveSilentPolls: 3))
    }

    func testZeroElapsedNeverFinishes() {
        // Boundary pin: no polls have happened yet; must not finish.
        let config = PostRollDecision.Config(minMs: 100, maxMs: 150)
        XCTAssertFalse(PostRollDecision.shouldFinish(config: config, elapsedMs: 0, consecutiveSilentPolls: 3))
    }

    func testZeroRequiredSilentPollsFinishesAsSoonAsMinimumElapses() {
        // Documented behavior: requiredSilentPolls == 0 disables the silence
        // gate entirely — finishing happens the moment the minimum elapses.
        let config = PostRollDecision.Config(minMs: 100, maxMs: 150, requiredSilentPolls: 0)
        XCTAssertFalse(PostRollDecision.shouldFinish(config: config, elapsedMs: 99, consecutiveSilentPolls: 0))
        XCTAssertTrue(PostRollDecision.shouldFinish(config: config, elapsedMs: 100, consecutiveSilentPolls: 0))
    }

    // MARK: tailIsSilent

    func testDigitalSilenceTailIsSilent() {
        let tail = [Float](repeating: 0, count: 960) // 60 ms at 16 kHz
        XCTAssertTrue(PostRollDecision.tailIsSilent(samples: tail, sampleRate: 16_000))
    }

    func testEmptyTailCountsAsSilent() {
        XCTAssertTrue(PostRollDecision.tailIsSilent(samples: [], sampleRate: 16_000))
    }

    func testSpeechTailIsNotSilent() {
        XCTAssertFalse(PostRollDecision.tailIsSilent(samples: sine(amplitude: 0.4, seconds: 0.06), sampleRate: 16_000))
    }

    func testMixedTailWithTrailingBurstIsNotSilent() {
        var tail = [Float](repeating: 0, count: 640)               // 40 ms room tone
        tail.append(contentsOf: sine(amplitude: 0.3, seconds: 0.02)) // trailing phoneme
        XCTAssertFalse(PostRollDecision.tailIsSilent(samples: tail, sampleRate: 16_000))
    }

    func testUniformlyLoudTailCannotSelfClassifyAsSilent() {
        // Relative-threshold-only logic would call a continuous speech tail
        // "silent" (its own p5 floor tracks it). The absolute cap prevents that.
        XCTAssertFalse(PostRollDecision.tailIsSilent(samples: sine(amplitude: 0.4, seconds: 0.12), sampleRate: 16_000))
    }
}
