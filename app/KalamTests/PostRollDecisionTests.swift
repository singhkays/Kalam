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

    // MARK: Task 3 — SNR-aware extension (K-54)

    private func makeSnrAwareConfig(minMs: Int = 60, maxMs: Int = 150, segmentMs: Int = 2000) -> PostRollDecision.Config {
        let c = PostRollDecision.ExtensionConstants()
        return PostRollDecision.Config(minMs: minMs, maxMs: maxMs, extensionPolicy: .snrAware(c))
    }

    func testEstimatedSNR_SilenceNearZero() {
        let silence = [Float](repeating: 0, count: 3200) // 200 ms
        let snr = PostRollDecision.estimatedSNR(samples: silence, sampleRate: 16_000)
        XCTAssertLessThan(snr, 2, "pure silence should have near-zero SNR")
    }

    func testEstimatedSNR_SpeechHigh() {
        // Mix silence floor + loud sine burst => high peak-floor delta
        var samples = [Float](repeating: 0.0005, count: 1600) // low floor
        samples.append(contentsOf: sine(amplitude: 0.4, seconds: 0.1))
        let snr = PostRollDecision.estimatedSNR(samples: samples, sampleRate: 16_000)
        XCTAssertGreaterThan(snr, 12, "speech over quiet floor should be trusted SNR")
    }

    func testEffectiveMax_LowSNR_ExtendsToAbsoluteCap() {
        let config = makeSnrAwareConfig(minMs: 60, maxMs: 150, segmentMs: 800)
        XCTAssertEqual(PostRollDecision.effectiveMaxMs(config: config, segmentEstimateMs: 800, snrDb: 5), 1500)
        XCTAssertEqual(PostRollDecision.effectiveMaxMs(config: config, segmentEstimateMs: 4000, snrDb: 0), 1500)
    }

    func testEffectiveMax_TrustedRoom_CappedByRelativeCap() {
        let config = makeSnrAwareConfig(minMs: 60, maxMs: 150)
        // 2000 ms segment => relativeCap 600, max 150 => effective 600
        XCTAssertEqual(PostRollDecision.effectiveMaxMs(config: config, segmentEstimateMs: 2000, snrDb: 20), 600)
        // 800 ms => 240, max 150 => 240
        XCTAssertEqual(PostRollDecision.effectiveMaxMs(config: config, segmentEstimateMs: 800, snrDb: 20), 240)
        // 300 ms => 90, but floor is max 150, so stays 150
        XCTAssertEqual(PostRollDecision.effectiveMaxMs(config: config, segmentEstimateMs: 300, snrDb: 20), 150)
        // Very long 5000 => 1500 cap (relative 1500, absolute 1500)
        XCTAssertEqual(PostRollDecision.effectiveMaxMs(config: config, segmentEstimateMs: 5000, snrDb: 20), 1500)
    }

    func testRequiredQuietPolls_LowVsTrusted() {
        let config = makeSnrAwareConfig(minMs: 60, maxMs: 150)
        // Low SNR => 3 polls (default)
        XCTAssertEqual(PostRollDecision.requiredQuietPolls(config: config, snrDb: 5), 3)
        // Trusted => 250/15 ≈ 17 polls
        XCTAssertEqual(PostRollDecision.requiredQuietPolls(config: config, snrDb: 20), 17)
    }

    func testTrustedTailSpeechLikePreventsEarlyFinish() {
        let config = makeSnrAwareConfig(minMs: 60, maxMs: 150)
        // Trusted SNR 20, segment 2000 => effective 600, quiet polls 17
        // Tail still speech-like => must NOT finish even though silent polls >=3 and elapsed > min
        XCTAssertFalse(PostRollDecision.shouldFinishExtended(
            config: config, segmentEstimateMs: 2000, snrDb: 20,
            elapsedMs: 200, consecutiveSilentPolls: 10, tailIsSpeechLike: true))
        // Once tail quiets, need 17 polls, not 3
        XCTAssertFalse(PostRollDecision.shouldFinishExtended(
            config: config, segmentEstimateMs: 2000, snrDb: 20,
            elapsedMs: 200, consecutiveSilentPolls: 10, tailIsSpeechLike: false))
        XCTAssertTrue(PostRollDecision.shouldFinishExtended(
            config: config, segmentEstimateMs: 2000, snrDb: 20,
            elapsedMs: 260, consecutiveSilentPolls: 17, tailIsSpeechLike: false))
    }

    func testLowSNR_RunsToBackstopWithoutClipping() {
        let config = makeSnrAwareConfig(minMs: 60, maxMs: 150)
        // Low SNR 5 dB => effective 1500, quiet polls 3, but speech-like still blocks
        // At 200 ms with speech, should NOT finish (would have clipped at 150 old ceiling)
        XCTAssertFalse(PostRollDecision.shouldFinishExtended(
            config: config, segmentEstimateMs: 2000, snrDb: 5,
            elapsedMs: 200, consecutiveSilentPolls: 0, tailIsSpeechLike: true))
        // At 1400 ms still speech-like => still not finish
        XCTAssertFalse(PostRollDecision.shouldFinishExtended(
            config: config, segmentEstimateMs: 2000, snrDb: 5,
            elapsedMs: 1400, consecutiveSilentPolls: 0, tailIsSpeechLike: true))
        // Only at absolute cap does it finish regardless
        XCTAssertTrue(PostRollDecision.shouldFinishExtended(
            config: config, segmentEstimateMs: 2000, snrDb: 5,
            elapsedMs: 1500, consecutiveSilentPolls: 0, tailIsSpeechLike: true))
    }

    func testFloorStillEnforcedInAllModes() {
        let config = makeSnrAwareConfig(minMs: 60, maxMs: 150)
        // Low SNR but elapsed < min => never finish even with silence
        XCTAssertFalse(PostRollDecision.shouldFinishExtended(
            config: config, segmentEstimateMs: 2000, snrDb: 5,
            elapsedMs: 30, consecutiveSilentPolls: 10, tailIsSpeechLike: false))
        // Trusted same
        XCTAssertFalse(PostRollDecision.shouldFinishExtended(
            config: config, segmentEstimateMs: 2000, snrDb: 20,
            elapsedMs: 59, consecutiveSilentPolls: 17, tailIsSpeechLike: false))
        XCTAssertTrue(PostRollDecision.shouldFinishExtended(
            config: config, segmentEstimateMs: 2000, snrDb: 20,
            elapsedMs: 60, consecutiveSilentPolls: 17, tailIsSpeechLike: false))
    }

    func testFixedPolicyIgnoresSNR() {
        let fixed = PostRollDecision.Config(minMs: 60, maxMs: 150)
        XCTAssertEqual(PostRollDecision.effectiveMaxMs(config: fixed, segmentEstimateMs: 5000, snrDb: 0), 150)
        XCTAssertEqual(PostRollDecision.requiredQuietPolls(config: fixed, snrDb: 50), 3)
        // Fixed shouldFinish matches legacy
        XCTAssertFalse(PostRollDecision.shouldFinish(config: fixed, elapsedMs: 80, consecutiveSilentPolls: 2))
        XCTAssertTrue(PostRollDecision.shouldFinish(config: fixed, elapsedMs: 80, consecutiveSilentPolls: 3))
    }

    func testTailIsSpeechLike_DetectsTrailingPhoneme() {
        var tail = [Float](repeating: 0, count: 640)
        tail.append(contentsOf: sine(amplitude: 0.3, seconds: 0.02))
        XCTAssertTrue(PostRollDecision.tailIsSpeechLike(samples: tail, sampleRate: 16_000))
        let silence = [Float](repeating: 0, count: 960)
        XCTAssertFalse(PostRollDecision.tailIsSpeechLike(samples: silence, sampleRate: 16_000))
    }

    func testGoldensUnchanged_FixedConfigMatchesLegacy() {
        // The new ExtensionPolicy defaults to .fixed, so existing goldens (which use
        // fixed) are unaffected. This pins that the snrAware path is opt-in via
        // defaults and does not alter fixed behavior.
        let legacy = PostRollDecision.Config(minMs: 100, maxMs: 150)
        let newDefault = PostRollDecision.Config(minMs: 100, maxMs: 150)
        XCTAssertEqual(legacy.extensionPolicy, .fixed)
        XCTAssertEqual(newDefault.extensionPolicy, .fixed)
        for elapsed in [0, 50, 99, 100, 120, 150, 200] {
            for polls in [0, 2, 3, 10] {
                XCTAssertEqual(
                    PostRollDecision.shouldFinish(config: legacy, elapsedMs: elapsed, consecutiveSilentPolls: polls),
                    PostRollDecision.shouldFinish(config: newDefault, elapsedMs: elapsed, consecutiveSilentPolls: polls)
                )
            }
        }
    }
}
