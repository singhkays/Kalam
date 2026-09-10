import XCTest
@testable import Kalam_test

/// Pins the pure waveform envelope behind the machined deck's bars: AGC, noise
/// gate, smoothing, and history capacity. Extraction is behavior-preserving;
/// the tuned constants are the spec.
final class IndicatorWaveformMathTests: XCTestCase {

    // MARK: - Envelope ingestion (inactive ticks and silence)

    func testInactiveTickDecaysAmplitudeAndPushesOneBarPerCall() {
        var envelope = IndicatorWaveformMath.Envelope(smoothedAmp: 0.8)

        IndicatorWaveformMath.ingest(samples: [], active: false, into: &envelope)

        XCTAssertEqual(envelope.smoothedAmp, 0.32, accuracy: 0.0001) // 0.8 decays by 0.4
        XCTAssertEqual(envelope.history.count, 1)
        XCTAssertEqual(envelope.history[0], 0.32, accuracy: 0.0001)

        IndicatorWaveformMath.ingest(samples: [], active: false, into: &envelope)

        XCTAssertEqual(envelope.smoothedAmp, 0.128, accuracy: 0.0001)
        XCTAssertEqual(envelope.history.count, 2, "exactly one bar per ingest tick")
    }

    func testQuietSamplesBelowGateStayAtSilenceWhileGainKeepsClimbing() {
        var envelope = IndicatorWaveformMath.Envelope()
        let quiet: [Float] = [0.004, -0.002, 0.001] // peak 0.4%, under the 0.5% gate

        for _ in 0..<5 {
            IndicatorWaveformMath.ingest(samples: quiet, active: true, into: &envelope)
        }

        XCTAssertEqual(envelope.smoothedAmp, 0.0, accuracy: 0.0001)
        XCTAssertEqual(envelope.history.count, 5)
        for bar in envelope.history {
            XCTAssertEqual(bar, 0.0, accuracy: 0.0001)
        }
        XCTAssertGreaterThan(envelope.gain, 1.0, "AGC boosts quiet input even below the gate")
    }

    // MARK: - Envelope ingestion (active speech)

    func testLoudSignalSettlesGainAtInversePeakAndAmplitudeNearCeiling() throws {
        var envelope = IndicatorWaveformMath.Envelope()
        let loud: [Float] = [0.5, -0.5, 0.5, -0.5]

        for _ in 0..<40 {
            IndicatorWaveformMath.ingest(samples: loud, active: true, into: &envelope)
        }

        XCTAssertEqual(envelope.gain, 3.0, accuracy: 0.01) // AGC settles at 1.5 / 0.5
        let last = try XCTUnwrap(envelope.history.last)
        XCTAssertGreaterThan(last, 0.95)
        XCTAssertLessThanOrEqual(last, 0.96, "eased target tops out at 0.96, never above")
    }

    func testEveryPushedBarStaysWithinUnitRange() {
        var envelope = IndicatorWaveformMath.Envelope()
        let loud: [Float] = [0.5, -0.5]
        let silence: [Float] = [0.0, 0.0]

        for i in 0..<60 {
            IndicatorWaveformMath.ingest(samples: i % 3 == 0 ? silence : loud, active: true, into: &envelope)
        }

        for bar in envelope.history {
            XCTAssertTrue((0.0...1.0).contains(bar), "bar out of range: \(bar)")
        }
    }

    func testHistoryCapsAtTheDeckBarCapacity() {
        var envelope = IndicatorWaveformMath.Envelope()
        let loud: [Float] = [0.5, -0.5]

        for _ in 0..<200 {
            IndicatorWaveformMath.ingest(samples: loud, active: true, into: &envelope)
        }

        XCTAssertEqual(envelope.history.count, IndicatorWaveformMath.maxHistory)
        XCTAssertEqual(IndicatorWaveformMath.maxHistory, 150, "the deck renders at most 150 bars")
    }

    func testResetRestoresTheIdentityEnvelope() {
        var envelope = IndicatorWaveformMath.Envelope()
        let loud: [Float] = [0.5, -0.5]
        for _ in 0..<10 {
            IndicatorWaveformMath.ingest(samples: loud, active: true, into: &envelope)
        }

        IndicatorWaveformMath.reset(&envelope)

        XCTAssertEqual(envelope.gain, 1.0)
        XCTAssertEqual(envelope.smoothedAmp, 0.0)
        XCTAssertTrue(envelope.history.isEmpty)
    }

    // MARK: - Level glyph (three-bar whisper/caret glyph)

    func testEmptyBufferDecaysAllThreeLevels() {
        var gain: CGFloat = 1.0
        var smoothed: [CGFloat] = [0.8, 0.4, 0.0]

        let levels = IndicatorWaveformMath.glyphLevels(samples: [], gain: &gain, smoothed: &smoothed)

        XCTAssertEqual(levels[0], 0.6, accuracy: 0.0001) // 0.8 releases by 0.75
        XCTAssertEqual(levels[1], 0.3, accuracy: 0.0001)
        XCTAssertEqual(levels[2], 0.0, accuracy: 0.0001)
    }

    func testFirstLoudTickAttacksToSixtyFivePercentAndStepsGain() {
        var gain: CGFloat = 1.0
        var smoothed: [CGFloat] = [0, 0, 0]
        let loud: [Float] = [Float](repeating: 0.5, count: 512)

        let levels = IndicatorWaveformMath.glyphLevels(samples: loud, gain: &gain, smoothed: &smoothed)

        XCTAssertEqual(gain, 1.5, accuracy: 0.001) // one AGC step: 1.0 + (3.0 - 1.0) * 0.25
        XCTAssertEqual(levels[0], 0.65, accuracy: 0.001, "fast attack from zero")
        XCTAssertEqual(levels[1], 0.65, accuracy: 0.001)
        XCTAssertEqual(levels[2], 0.65, accuracy: 0.001)
    }

    func testSustainedLoudSignalDrivesAllLevelsToUnityWithinUnitRange() {
        var gain: CGFloat = 1.0
        var smoothed: [CGFloat] = [0, 0, 0]
        let loud: [Float] = [Float](repeating: 0.5, count: 512)

        for _ in 0..<30 {
            let levels = IndicatorWaveformMath.glyphLevels(samples: loud, gain: &gain, smoothed: &smoothed)
            for level in levels {
                XCTAssertTrue((0.0...1.0).contains(level), "level out of range: \(level)")
            }
        }

        for level in smoothed {
            XCTAssertGreaterThan(level, 0.9)
        }
        XCTAssertEqual(gain, 3.0, accuracy: 0.01) // AGC settles at 1.5 / 0.5
    }

    func testSilenceAfterLoudReleasesTowardZero() {
        var gain: CGFloat = 1.0
        var smoothed: [CGFloat] = [0, 0, 0]
        let loud: [Float] = [Float](repeating: 0.5, count: 512)

        for _ in 0..<20 {
            _ = IndicatorWaveformMath.glyphLevels(samples: loud, gain: &gain, smoothed: &smoothed)
        }
        for _ in 0..<30 {
            _ = IndicatorWaveformMath.glyphLevels(samples: [], gain: &gain, smoothed: &smoothed)
        }

        for level in smoothed {
            XCTAssertLessThan(level, 0.01)
        }
    }

    func testGlyphEnvelopeCarriesStateAcrossTicks() {
        var glyph = IndicatorWaveformMath.GlyphEnvelope()
        let loud: [Float] = [Float](repeating: 0.5, count: 512)

        glyph.ingest(loud)

        XCTAssertEqual(glyph.gain, 1.5, accuracy: 0.001)
        XCTAssertEqual(glyph.smoothed[0], 0.65, accuracy: 0.001)
    }

    // MARK: - Ring gating law (D-2: transcribing only, both content paths)

    func testRingGatesToTranscribingOnly() {
        for style in IndicatorStyle.allCases {
            XCTAssertEqual(
                IndicatorTokens.ringPeriod(style: style, canonicalState: .transcribing) ?? -1,
                2.4, accuracy: 0.0001,
                "\\(style.rawValue) transcribing must carry the fast ring"
            )
        }
    }

    func testRingNeverAppearsOutsideTranscribing() {
        for style in IndicatorStyle.allCases {
            for state in [IndicatorState.listening, .pausing, .held, .blocked] {
                XCTAssertNil(
                    IndicatorTokens.ringPeriod(style: style, canonicalState: state),
                    "\\(style.rawValue) \\(state.rawValue) must not ring"
                )
            }
            XCTAssertNil(
                IndicatorTokens.ringPeriod(style: style, canonicalState: nil),
                "transient overlays must not ring"
            )
        }
    }

    /// Owner finding 2026-09-09: the SwiftUI glow twin rendered the full stadium
    /// perimeter at constant opacity (only the arc rotated), so every ringed
    /// surface showed a constant blur ring the mockup never had. The glow must
    /// be arc-bound: it exists exactly when the arc exists, and nowhere else.
    func testRingGlowIsArcBound() {
        for style in IndicatorStyle.allCases {
            XCTAssertTrue(
                IndicatorTokens.ringGlowVisible(style: style, canonicalState: .transcribing),
                "\\(style.rawValue) transcribing must carry the arc-bound glow"
            )
            for state in [IndicatorState.listening, .pausing, .held, .blocked] {
                XCTAssertFalse(
                    IndicatorTokens.ringGlowVisible(style: style, canonicalState: state),
                    "\\(style.rawValue) \\(state.rawValue) must carry no glow at all"
                )
            }
            XCTAssertFalse(
                IndicatorTokens.ringGlowVisible(style: style, canonicalState: nil),
                "transient overlays must carry no glow at all"
            )
        }
    }
}