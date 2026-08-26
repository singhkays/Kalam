import Foundation

/// Pure policy for the adaptive post-roll early exit (K-49). After PTT key-up
/// the stop path polls trailing-buffer energy; this type decides when the stop
/// may finish. Headless-testable by design — the polling loop that consumes it
/// lives in `AudioRecorder.stopWithEarlyExit`.
///
/// Safety posture: the configured minimum ALWAYS elapses (trailing-phoneme
/// protection inherited from the fixed-sleep behavior), the maximum is a hard
/// ceiling, and finishing between them requires N CONSECUTIVE silent polls so
/// a brief inter-word pause can never truncate mid-speech.
enum PostRollDecision {

    struct Config {
        /// Floor: the adaptive post-roll value (`postRollForSegment`). Never
        /// finishes before this regardless of tail energy.
        var minMs: Int
        /// Hard ceiling. Elapsed >= max finishes unconditionally (the old
        /// fixed-sleep worst case is never exceeded).
        var maxMs: Int
        var pollIntervalMs: Int = 15
        /// Consecutive silent polls required to finish before the max.
        var requiredSilentPolls: Int = 3

        var minIntervalNanos: UInt64 { UInt64(max(1, pollIntervalMs)) * 1_000_000 }
    }

    static func shouldFinish(config: Config, elapsedMs: Int, consecutiveSilentPolls: Int) -> Bool {
        if elapsedMs >= config.maxMs { return true }
        guard elapsedMs >= config.minMs else { return false }
        return consecutiveSilentPolls >= config.requiredSilentPolls
    }

    /// Tail-silence verdict for a trailing sample slice (16 kHz mono).
    ///
    /// Silent iff EVERY `windowMs` window is at or below BOTH:
    ///  - the slice's own 5th-percentile floor + `stopMarginDb` (relative,
    ///    matching the endpointer's stop margin), AND
    ///  - the `absoluteCapDb` cap — so a uniformly LOUD tail (continuous
    ///    speech) can never self-classify as silent, since its own floor
    ///    would track it under a purely relative rule.
    ///
    /// Known accepted trade-off: a steady very-low-level tone (<= -35 dBFS)
    /// classifies as silent. Harmless: such a tail carries no speech, the
    /// minimum still elapses, and the endpointer would discard it anyway.
    static func tailIsSilent(
        samples: [Float],
        sampleRate: Int,
        windowMs: Int = 20,
        stopMarginDb: Float = 6,
        absoluteCapDb: Float = -35
    ) -> Bool {
        guard !samples.isEmpty else { return true }
        let energiesDb = SilenceTrimmer.windowedEnergiesDb(
            samples: samples, sampleRate: sampleRate, windowMs: windowMs)
        guard !energiesDb.isEmpty else { return true }
        let floorDb = SilenceTrimmer.percentile(energiesDb, p: 0.05)
        let threshold = min(floorDb + stopMarginDb, absoluteCapDb)
        return energiesDb.allSatisfy { $0 <= threshold }
    }
}
