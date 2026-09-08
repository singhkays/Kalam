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
