import Foundation

/// Rejects clips that are noise or near-silence before they reach ASR.
///
/// Parakeet TDT hallucinates filler words ("yeah") on boosted room tone —
/// the pipeline's trimmer fallback + peak normalization + zero-padding turn
/// noise into model input. The guard requires a sustained run of windows
/// at least `speechMarginDb` above the clip's own noise floor.
enum SpeechQualityGuard {
    /// Privacy-safe diagnostics for the speech-quality verdict. Counts and
    /// energy levels only — never audio content. Intended for the pipeline's
    /// `Clip rejected` / `Clip accepted` log lines so quiet-speech cutoffs
    /// can be distinguished from true silence in user-provided logs.
    struct Diagnostics: Sendable {
        var verdict: Bool
        var noiseFloorDb: Float
        var speechThresholdDb: Float
        /// 95th-percentile window energy: headroom is `peakDb - speechThresholdDb`.
        /// Far-above-threshold + short run = fragmented/short utterance; barely
        /// above = quiet overall. Levels only, never content.
        var peakDb: Float
        var requiredWindows: Int
        var maxRunWindows: Int
        var totalWindows: Int
    }

    static func diagnose(
        samples: [Float],
        sampleRate: Int,
        windowMs: Int = 20,
        minActiveSpeechMs: Int = 120,
        speechMarginDb: Float = 6
    ) -> Diagnostics {
        let requiredWindows = max(1, (minActiveSpeechMs + windowMs - 1) / windowMs)
        guard !samples.isEmpty else {
            return Diagnostics(
                verdict: false, noiseFloorDb: -120, speechThresholdDb: -120 + speechMarginDb,
                peakDb: -120,
                requiredWindows: requiredWindows, maxRunWindows: 0, totalWindows: 0)
        }
        let energiesDb = SilenceTrimmer.windowedEnergiesDb(samples: samples, sampleRate: sampleRate, windowMs: windowMs)
        guard !energiesDb.isEmpty else {
            return Diagnostics(
                verdict: false, noiseFloorDb: -120, speechThresholdDb: -120 + speechMarginDb,
                peakDb: -120,
                requiredWindows: requiredWindows, maxRunWindows: 0, totalWindows: 0)
        }
        let noiseFloorDb = SilenceTrimmer.percentile(energiesDb, p: 0.05)
        let speechThresholdDb = noiseFloorDb + speechMarginDb
        let peakDb = SilenceTrimmer.percentile(energiesDb, p: 0.95)
        var run = 0
        var maxRun = 0
        var verdict = false
        for db in energiesDb {
            if db >= speechThresholdDb {
                run += 1
                maxRun = max(maxRun, run)
                if run >= requiredWindows { verdict = true }
            } else {
                run = 0
            }
        }
        return Diagnostics(
            verdict: verdict, noiseFloorDb: noiseFloorDb, speechThresholdDb: speechThresholdDb,
            peakDb: peakDb,
            requiredWindows: requiredWindows, maxRunWindows: maxRun, totalWindows: energiesDb.count)
    }

    /// - Parameters:
    ///   - samples: 16 kHz mono Float32 (post-trim).
    ///   - sampleRate: sample rate of `samples`.
    ///   - windowMs: energy window size (must match the trimmer).
    ///   - minActiveSpeechMs: minimum CONSECUTIVE speech-level duration.
    ///   - speechMarginDb: windows must exceed the noise floor by this much.
    static func isSpeechLike(
        samples: [Float],
        sampleRate: Int,
        windowMs: Int = 20,
        minActiveSpeechMs: Int = 120,
        speechMarginDb: Float = 6
    ) -> Bool {
        diagnose(
            samples: samples, sampleRate: sampleRate, windowMs: windowMs,
            minActiveSpeechMs: minActiveSpeechMs, speechMarginDb: speechMarginDb
        ).verdict
    }
}

/// Fails loudly when the microphone delivered unusable bytes (Bluetooth
/// dropout hardening). Unlike `SpeechQualityGuard` — which rejects
/// noise-like clips — this catches a broken *capture*: far fewer samples
/// than the hold implies, or near-total digital silence over a long
/// capture. Either way ASR would transcribe garbage, so the pipeline must
/// refuse to paste and point at the microphone instead.
///
/// Pure over counts/levels (never content); thresholds are deliberately
/// lenient so healthy captures — including quiet voices and slow engine
/// starts — never trip it.
enum CaptureHealthGuard {
    enum Reason: Sendable, Equatable {
        /// Long hold, but the buffer holds a fraction of it (stalled engine,
        /// dropped stream, mid-hold device death).
        case shortfall
        /// Long capture that is almost entirely digital zeros (dead stream).
        case silence

        var logName: String {
            switch self {
            case .shortfall: return "shortfall"
            case .silence: return "silence"
            }
        }
    }

    struct Assessment: Sendable, Equatable {
        var healthy: Bool
        var reason: Reason?
        var capturedMs: Int
        var holdMs: Int
        var nonZeroRatio: Float
    }

    /// Minimum hold before any verdict (quick taps and engine-start overhead
    /// must never trip the gate; downstream stages own short clips).
    static let minHoldMsForAssessment = 4000
    /// Captured audio must cover at least this fraction of the hold.
    static let minKeepRatio: Double = 0.5
    /// Minimum capture length before the digital-silence verdict applies.
    static let minCaptureMsForSilenceCheck = 2000
    /// Fraction of samples above 1e-4 required on a long capture.
    static let minNonZeroRatio: Float = 0.02

    static func assess(stats: CaptureStats, holdMs: Int) -> Assessment {
        let capturedMs = stats.durationMs
        let nonZeroRatio: Float = stats.sampleCount > 0
            ? Float(stats.nonZeroCount) / Float(stats.sampleCount)
            : 0
        let base = Assessment(
            healthy: true, reason: nil,
            capturedMs: capturedMs, holdMs: holdMs, nonZeroRatio: nonZeroRatio)
        guard holdMs >= minHoldMsForAssessment else { return base }
        if Double(capturedMs) < Double(holdMs) * minKeepRatio {
            var out = base
            out.healthy = false
            out.reason = .shortfall
            return out
        }
        if capturedMs >= minCaptureMsForSilenceCheck, nonZeroRatio < minNonZeroRatio {
            var out = base
            out.healthy = false
            out.reason = .silence
            return out
        }
        return base
    }
}
