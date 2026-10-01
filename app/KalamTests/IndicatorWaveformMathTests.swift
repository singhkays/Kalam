import XCTest
@testable import Kalam_test

/// Pins the indicator meter: absolute silence floor, slow-adaptive ceiling,
/// attack/release smoothing, and history capacity. The ceiling self-calibrates
/// per mic/voice (fast up, slow gated down) while silence can never move it —
/// so neither a quiet webcam mic nor a hot Mac mic nor a loud room breaks it.
final class IndicatorWaveformMathTests: XCTestCase {

    // MARK: - Envelope ingestion (inactive ticks and silence)

    func testInactiveTickDecaysAmplitudeAndPushesOneBarPerCall() {
        var envelope = IndicatorWaveformMath.Envelope(smoothedAmp: 0.8)

        IndicatorWaveformMath.ingest(samples: [], active: false, into: &envelope)

        XCTAssertEqual(envelope.smoothedAmp, 0.656, accuracy: 0.0001) // 0.8 decays by 0.82
        XCTAssertEqual(envelope.history.count, 1)
        XCTAssertEqual(envelope.history[0], 0.656, accuracy: 0.0001)

        IndicatorWaveformMath.ingest(samples: [], active: false, into: &envelope)

        XCTAssertEqual(envelope.smoothedAmp, 0.53792, accuracy: 0.0001)
        XCTAssertEqual(envelope.history.count, 2, "exactly one bar per ingest tick")
    }

    func testQuietSamplesBelowFloorStayAtSilenceWithoutGainPumping() {
        var envelope = IndicatorWaveformMath.Envelope()
        let quiet: [Float] = [0.004, -0.002, 0.001] // rms ~-51.5dB, under the -46dB floor

        for _ in 0..<5 {
            IndicatorWaveformMath.ingest(samples: quiet, active: true, into: &envelope)
        }

        XCTAssertEqual(envelope.smoothedAmp, 0.0, accuracy: 0.0001)
        XCTAssertEqual(envelope.history.count, 5)
        for bar in envelope.history {
            XCTAssertEqual(bar, 0.0, accuracy: 0.0001)
        }
        XCTAssertEqual(envelope.gain, 1.0, accuracy: 0.0001, "no per-tick boost")
        XCTAssertEqual(envelope.ceilingDb, IndicatorWaveformMath.initialCeilingDb, accuracy: 0.0001,
                       "sub-gate windows must never move the ceiling")
    }

    // MARK: - Envelope ingestion (active speech)

    func testSustainedLoudLeavesHeadroom() throws {
        // Even sustained -6dBFS must NOT clamp at 1.0: the ceiling tracks the
        // peak plus headroom, so the loudest input reads ~0.87 with air above.
        var envelope = IndicatorWaveformMath.Envelope()
        let loud: [Float] = [0.5, -0.5, 0.5, -0.5]

        for _ in 0..<40 {
            IndicatorWaveformMath.ingest(samples: loud, active: true, into: &envelope)
        }

        XCTAssertEqual(envelope.gain, 1.0, accuracy: 0.0001, "no AGC: gain stays unity")
        XCTAssertEqual(envelope.ceilingDb, 6.0, accuracy: 1.0, "ceiling tracks peak plus headroom")
        let last = try XCTUnwrap(envelope.history.last)
        XCTAssertGreaterThan(last, 0.8)
        XCTAssertLessThan(last, 0.95, "sustained loud must leave headroom, never clamp")
    }

    func testConversationalSpeechReadsHigh() throws {
        // rms 0.03 (~-30dBFS): reads in the upper-middle — ~1.5x the old
        // half-height bars, with headroom left for louder moments.
        var envelope = IndicatorWaveformMath.Envelope()
        let mid: [Float] = [0.03, -0.03, 0.03, -0.03]

        for _ in 0..<40 {
            IndicatorWaveformMath.ingest(samples: mid, active: true, into: &envelope)
        }

        let last = try XCTUnwrap(envelope.history.last)
        XCTAssertGreaterThan(last, 0.65, "conversational speech must read tall")
        XCTAssertLessThan(last, 0.8, "conversational level keeps headroom")
    }

    // MARK: - Adaptive ceiling (hot mics, quiet mics, loud rooms)

    func testCeilingClimbsToHotMicWithinTicks() throws {
        // A hot mic (rms 0.15, ~-16dBFS) pulls the ceiling up in a few ticks:
        // it reads high (~0.83) via headroom, never pegged, never squashed.
        var envelope = IndicatorWaveformMath.Envelope()
        let hot: [Float] = [0.15, -0.15, 0.15, -0.15]

        for _ in 0..<8 {
            IndicatorWaveformMath.ingest(samples: hot, active: true, into: &envelope)
        }

        XCTAssertEqual(envelope.ceilingDb, -4.5, accuracy: 1.0, "ceiling converges fast upward")
        let last = try XCTUnwrap(envelope.history.last)
        XCTAssertGreaterThan(last, 0.75)
        XCTAssertLessThan(last, 0.95)
    }

    func testCeilingFallsBackAfterLoudBurst() throws {
        // A door-slam parks the ceiling high; sustained soft speech
        // (rms 0.02, ~-34dBFS) pulls it back down over seconds and the level
        // recovers with it — never stuck squashed.
        var envelope = IndicatorWaveformMath.Envelope()
        let loud: [Float] = [0.5, -0.5, 0.5, -0.5]
        for _ in 0..<5 {
            IndicatorWaveformMath.ingest(samples: loud, active: true, into: &envelope)
        }
        let parked = envelope.ceilingDb
        XCTAssertGreaterThan(parked, 0.0, "burst parks the ceiling high")

        let soft: [Float] = [0.02, -0.02, 0.02, -0.02]
        for _ in 0..<150 {
            IndicatorWaveformMath.ingest(samples: soft, active: true, into: &envelope)
        }

        XCTAssertLessThan(envelope.ceilingDb, -15.0, "ceiling falls back toward sustained speech")
        let last = try XCTUnwrap(envelope.history.last)
        XCTAssertGreaterThan(last, 0.55, "level recovers with the ceiling")
        XCTAssertLessThan(last, 0.75)
    }

    func testSilenceNeverDragsCeilingDown() throws {
        // A loud burst sets the ceiling high; trailing silence must decay the
        // BARS but leave the ceiling untouched — otherwise pauses would pump
        // the noise floor up (the original always-full bug, in slow motion).
        var envelope = IndicatorWaveformMath.Envelope()
        let loud: [Float] = [0.5, -0.5, 0.5, -0.5]
        for _ in 0..<5 {
            IndicatorWaveformMath.ingest(samples: loud, active: true, into: &envelope)
        }
        let parked = envelope.ceilingDb

        let silence: [Float] = [0.0, 0.0, 0.0, 0.0]
        for _ in 0..<30 {
            IndicatorWaveformMath.ingest(samples: silence, active: true, into: &envelope)
        }

        XCTAssertEqual(envelope.ceilingDb, parked, accuracy: 0.0001, "silence must not move the ceiling")
        let last = try XCTUnwrap(envelope.history.last)
        XCTAssertLessThan(last, 0.1, "bars still fall to the baseline")
    }

    func testNonFiniteSamplesDecayGracefully() throws {
        // Defensive: a NaN buffer (converter glitch) must decay like silence,
        // never poison smoothedAmp/ceiling to full-scale forever.
        var envelope = IndicatorWaveformMath.Envelope()
        IndicatorWaveformMath.ingest(samples: [Float.nan, Float.nan], active: true, into: &envelope)

        let poisoned = try XCTUnwrap(envelope.history.last)
        XCTAssertTrue(poisoned.isFinite, "NaN must never reach the bars")
        XCTAssertEqual(poisoned, 0.0, accuracy: 0.0001)
        XCTAssertEqual(envelope.ceilingDb, IndicatorWaveformMath.initialCeilingDb, accuracy: 0.0001)

        let loud: [Float] = [0.5, -0.5, 0.5, -0.5]
        for _ in 0..<5 {
            IndicatorWaveformMath.ingest(samples: loud, active: true, into: &envelope)
        }
        let recovered = try XCTUnwrap(envelope.history.last)
        XCTAssertGreaterThan(recovered, 0.5, "meter recovers on real audio")
    }

    func testFarAwaySoundStaysLow() throws {
        // rms 0.008 (~-42dBFS, far-away speech) sits below the adapt gate, so
        // the ceiling never moves for it: it reads low — visible, but clearly
        // below near-mic speech.
        var envelope = IndicatorWaveformMath.Envelope()
        let far: [Float] = [0.008, -0.008, 0.008, -0.008]

        for _ in 0..<40 {
            IndicatorWaveformMath.ingest(samples: far, active: true, into: &envelope)
        }

        XCTAssertEqual(envelope.ceilingDb, IndicatorWaveformMath.initialCeilingDb, accuracy: 0.0001)
        let last = try XCTUnwrap(envelope.history.last)
        XCTAssertGreaterThan(last, 0.2, "far speech must still register")
        XCTAssertLessThan(last, 0.55, "far speech must stay well below near-mic speech")
    }

    func testNormalVoiceAtTheMicReadsHigh() throws {
        // rms 0.07 (~-23dBFS, projected voice): reads high with headroom left.
        var envelope = IndicatorWaveformMath.Envelope()
        let normal: [Float] = [0.07, -0.07, 0.07, -0.07]

        for _ in 0..<40 {
            IndicatorWaveformMath.ingest(samples: normal, active: true, into: &envelope)
        }

        let last = try XCTUnwrap(envelope.history.last)
        XCTAssertGreaterThan(last, 0.7, "projected voice must read high")
        XCTAssertLessThan(last, 0.9, "even projected voice keeps headroom")
    }

    func testDynamicContrastBetweenQuietMidAndLoud() {
        // Same tick count, different input energy -> ordered outputs with wide
        // headroom between them. Guards the "everything looks flat" regression
        // in both directions: room tone hugs the baseline, speech throws peaks.
        func settled(_ sample: Float) -> CGFloat {
            var e = IndicatorWaveformMath.Envelope()
            let buf: [Float] = [sample, -sample, sample, -sample]
            for _ in 0..<40 {
                IndicatorWaveformMath.ingest(samples: buf, active: true, into: &e)
            }
            return e.smoothedAmp
        }
        let quiet = settled(0.004) // -48dBFS, below the silence floor
        let mid = settled(0.015) // ~-36dBFS, soft speech (below the adapt gate)
        let loud = settled(0.5) // -6dBFS
        XCTAssertLessThan(quiet, 0.05, "room tone must hug the baseline")
        XCTAssertGreaterThan(mid, 0.5, "soft speech must be clearly visible")
        XCTAssertGreaterThan(loud, 0.8, "loud stays on top")
        XCTAssertGreaterThan(loud, mid + 0.15, "loud must separate from mid")
        XCTAssertLessThanOrEqual(loud, 1.0)
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
        XCTAssertEqual(envelope.ceilingDb, IndicatorWaveformMath.initialCeilingDb)
        XCTAssertTrue(envelope.history.isEmpty)
    }

    // MARK: - Level glyph (three-bar whisper glyph)

    func testEmptyBufferDecaysAllThreeLevels() {
        var gain: CGFloat = 1.0
        var smoothed: [CGFloat] = [0.8, 0.4, 0.0]
        var ceiling: CGFloat = IndicatorWaveformMath.initialCeilingDb

        let levels = IndicatorWaveformMath.glyphLevels(samples: [], gain: &gain, smoothed: &smoothed, ceilingDb: &ceiling)

        XCTAssertEqual(levels[0], 0.6, accuracy: 0.0001) // 0.8 releases by 0.75
        XCTAssertEqual(levels[1], 0.3, accuracy: 0.0001)
        XCTAssertEqual(levels[2], 0.0, accuracy: 0.0001)
    }

    func testFirstLoudTickAttacksToSixtyFivePercentWithUnityGain() {
        var gain: CGFloat = 1.0
        var smoothed: [CGFloat] = [0, 0, 0]
        var ceiling: CGFloat = IndicatorWaveformMath.initialCeilingDb
        let loud: [Float] = [Float](repeating: 0.5, count: 512) // rms -6dBFS -> target 1.0

        let levels = IndicatorWaveformMath.glyphLevels(samples: loud, gain: &gain, smoothed: &smoothed, ceilingDb: &ceiling)

        XCTAssertEqual(gain, 1.0, accuracy: 0.0001, "glyph has no AGC")
        XCTAssertEqual(levels[0], 0.65, accuracy: 0.001, "fast attack from zero")
        XCTAssertEqual(levels[1], 0.65, accuracy: 0.001)
        XCTAssertEqual(levels[2], 0.65, accuracy: 0.001)
    }

    func testSustainedLoudSignalDrivesAllLevelsToUnityWithinUnitRange() {
        var gain: CGFloat = 1.0
        var smoothed: [CGFloat] = [0, 0, 0]
        var ceiling: CGFloat = IndicatorWaveformMath.initialCeilingDb
        let loud: [Float] = [Float](repeating: 0.5, count: 512)

        for _ in 0..<30 {
            let levels = IndicatorWaveformMath.glyphLevels(samples: loud, gain: &gain, smoothed: &smoothed, ceilingDb: &ceiling)
            for level in levels {
                XCTAssertTrue((0.0...1.0).contains(level), "level out of range: \(level)")
            }
        }

        for level in smoothed {
            XCTAssertGreaterThan(level, 0.8, "sustained loud must read high with headroom")
        }
        XCTAssertEqual(gain, 1.0, accuracy: 0.0001, "glyph gain stays unity")
    }

    func testSilenceAfterLoudReleasesTowardZero() {
        var gain: CGFloat = 1.0
        var smoothed: [CGFloat] = [0, 0, 0]
        var ceiling: CGFloat = IndicatorWaveformMath.initialCeilingDb
        let loud: [Float] = [Float](repeating: 0.5, count: 512)

        for _ in 0..<20 {
            _ = IndicatorWaveformMath.glyphLevels(samples: loud, gain: &gain, smoothed: &smoothed, ceilingDb: &ceiling)
        }
        for _ in 0..<30 {
            _ = IndicatorWaveformMath.glyphLevels(samples: [], gain: &gain, smoothed: &smoothed, ceilingDb: &ceiling)
        }

        for level in smoothed {
            XCTAssertLessThan(level, 0.01)
        }
    }

    func testGlyphEnvelopeCarriesStateAcrossTicks() {
        var glyph = IndicatorWaveformMath.GlyphEnvelope()
        let loud: [Float] = [Float](repeating: 0.5, count: 512)

        glyph.ingest(loud)

        XCTAssertEqual(glyph.gain, 1.0, accuracy: 0.0001)
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