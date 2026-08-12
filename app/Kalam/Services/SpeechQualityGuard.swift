import Foundation

/// Rejects clips that are noise or near-silence before they reach ASR.
///
/// Parakeet TDT hallucinates filler words ("yeah") on boosted room tone —
/// the pipeline's trimmer fallback + peak normalization + zero-padding turn
/// noise into model input. The guard requires a sustained run of windows
/// at least `speechMarginDb` above the clip's own noise floor.
enum SpeechQualityGuard {
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
        guard !samples.isEmpty else { return false }
        let energiesDb = SilenceTrimmer.windowedEnergiesDb(samples: samples, sampleRate: sampleRate, windowMs: windowMs)
        guard !energiesDb.isEmpty else { return false }
        let noiseFloorDb = SilenceTrimmer.percentile(energiesDb, p: 0.05)
        let speechThresholdDb = noiseFloorDb + speechMarginDb
        let requiredWindows = max(1, (minActiveSpeechMs + windowMs - 1) / windowMs)
        var run = 0
        for db in energiesDb {
            if db >= speechThresholdDb {
                run += 1
                if run >= requiredWindows { return true }
            } else {
                run = 0
            }
        }
        return false
    }
}
