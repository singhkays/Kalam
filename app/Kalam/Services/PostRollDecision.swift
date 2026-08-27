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

    // MARK: - SNR-aware extension (Task 3 / K-54)

    /// Jot-derived constants mapped onto Kalam's floorDb/percentile model.
    /// The `speechEnergyRatioThreshold` (0.08 linear ≈ -10.9 dB) is retained
    /// for provenance; the operative speech-like margin is `floorMarginDb`.
    struct ExtensionConstants: Sendable, Equatable {
        var speechEnergyRatioThreshold: Float = 0.08
        var quietToStopMs: Int = 250
        var absoluteCapMs: Int = 1500
        var floorMarginDb: Float = 3
        var trustSnrDb: Float = 12
        var relativeCap: Float = 0.30
    }

    enum ExtensionPolicy: Sendable, Equatable {
        case fixed
        case snrAware(ExtensionConstants)
    }

    struct Config {
        /// Floor: the adaptive post-roll value (`postRollForSegment`). Never
        /// finishes before this regardless of tail energy.
        var minMs: Int
        /// Hard ceiling. Elapsed >= max finishes unconditionally (the old
        /// fixed-sleep worst case is never exceeded).
        var maxMs: Int
        var pollIntervalMs: Int = 15
        /// Consecutive silent polls required to finish before the max.
        /// `0` means finish as soon as the minimum elapses.
        var requiredSilentPolls: Int = 3
        /// Task 3: when `.snrAware`, the ceiling and quiet gate extend per SNR.
        var extensionPolicy: ExtensionPolicy = .fixed

        var minIntervalNanos: UInt64 { UInt64(max(1, pollIntervalMs)) * 1_000_000 }

        /// Asserts `maxMs >= minMs`: the configured minimum ALWAYS elapses,
        /// so a config whose ceiling sits below its floor would silently
        /// break that safety posture (debug-only guard).
        init(minMs: Int, maxMs: Int, pollIntervalMs: Int = 15, requiredSilentPolls: Int = 3, extensionPolicy: ExtensionPolicy = .fixed) {
            assert(
                maxMs >= minMs,
                "PostRollDecision.Config: maxMs (\(maxMs)) must be >= minMs (\(minMs))"
            )
            self.minMs = minMs
            self.maxMs = maxMs
            self.pollIntervalMs = pollIntervalMs
            self.requiredSilentPolls = requiredSilentPolls
            self.extensionPolicy = extensionPolicy
        }
    }

    static func shouldFinish(config: Config, elapsedMs: Int, consecutiveSilentPolls: Int) -> Bool {
        if elapsedMs >= config.maxMs { return true }
        guard elapsedMs >= config.minMs else { return false }
        return consecutiveSilentPolls >= config.requiredSilentPolls
    }

    // MARK: - SNR estimation + speech-like tail (Task 3)

    /// Estimated room SNR in dB: peak (95th percentile) minus floor (5th
    /// percentile) over `windowMs` RMS energies, clamped [-60, 60].
    /// Pure; headless-testable. Uses the same `windowedEnergiesDb` /
    /// `percentile` primitives as `tailIsSilent` and `SpeechQualityGuard`.
    static func estimatedSNR(
        samples: [Float],
        sampleRate: Int,
        windowMs: Int = 20
    ) -> Float {
        guard !samples.isEmpty else { return 0 }
        let energies = SilenceTrimmer.windowedEnergiesDb(samples: samples, sampleRate: sampleRate, windowMs: windowMs)
        guard !energies.isEmpty else { return 0 }
        let floor = SilenceTrimmer.percentile(energies, p: 0.05)
        let peak = SilenceTrimmer.percentile(energies, p: 0.95)
        let snr = peak - floor
        return min(60, max(0, snr))
    }

    /// Tail contains speech-like energy: ANY window exceeds
    /// `floorDb + floorMarginDb` (relative) AND is above `absoluteCapDb`.
    /// The `floorMarginDb = 3` mapping is intentionally more sensitive than
    /// `tailIsSilent`'s 6 dB stop margin — the 0.08 linear ratio (≈ -11 dB)
    /// from Jot lands between them; 3 dB is the chosen Kalam probe-verified
    /// operating point (see plan review amendment 1).
    static func tailIsSpeechLike(
        samples: [Float],
        sampleRate: Int,
        windowMs: Int = 20,
        floorMarginDb: Float = 3,
        absoluteCapDb: Float = -35
    ) -> Bool {
        guard !samples.isEmpty else { return false }
        let energiesDb = SilenceTrimmer.windowedEnergiesDb(
            samples: samples, sampleRate: sampleRate, windowMs: windowMs)
        guard !energiesDb.isEmpty else { return false }
        let floorDb = SilenceTrimmer.percentile(energiesDb, p: 0.05)
        let threshold = min(floorDb + floorMarginDb, absoluteCapDb)
        // Speech-like if ANY window exceeds the sensitive threshold.
        return energiesDb.contains { $0 > threshold }
    }

    /// Effective ceiling under the extension policy. Pure.
    static func effectiveMaxMs(
        config: Config,
        segmentEstimateMs: Int,
        snrDb: Float
    ) -> Int {
        switch config.extensionPolicy {
        case .fixed:
            return config.maxMs
        case .snrAware(let c):
            if snrDb < c.trustSnrDb {
                // Low-SNR: extend toward absolute backstop, never clip early.
                return c.absoluteCapMs
            } else {
                // Trusted room: per-segment cap, bounded by absolute.
                let relativeCapMs = Int(Float(segmentEstimateMs) * c.relativeCap)
                let cap = max(config.maxMs, relativeCapMs)
                return min(c.absoluteCapMs, cap)
            }
        }
    }

    /// Quiet polls required before finishing in the post-min window.
    static func requiredQuietPolls(
        config: Config,
        snrDb: Float
    ) -> Int {
        switch config.extensionPolicy {
        case .fixed:
            return config.requiredSilentPolls
        case .snrAware(let c):
            if snrDb < c.trustSnrDb {
                return config.requiredSilentPolls
            } else {
                let quietPolls = (c.quietToStopMs + config.pollIntervalMs - 1) / config.pollIntervalMs
                return max(config.requiredSilentPolls, quietPolls)
            }
        }
    }

    /// SNR-aware finish predicate. Retains the 60 ms floor + 3-poll posture
    /// in ALL modes; low-SNR never clips, trusted waits for quietToStopMs.
    static func shouldFinishExtended(
        config: Config,
        segmentEstimateMs: Int,
        snrDb: Float,
        elapsedMs: Int,
        consecutiveSilentPolls: Int,
        tailIsSpeechLike: Bool
    ) -> Bool {
        let effectiveMax = effectiveMaxMs(config: config, segmentEstimateMs: segmentEstimateMs, snrDb: snrDb)
        if elapsedMs >= effectiveMax { return true }
        guard elapsedMs >= config.minMs else { return false }
        // If tail still carries speech-like energy, don't finish early —
        // the trailing phoneme hasn't landed regardless of silent-poll count.
        if tailIsSpeechLike { return false }
        let required = requiredQuietPolls(config: config, snrDb: snrDb)
        return consecutiveSilentPolls >= required
    }

    /// Tail-silence verdict for a trailing sample slice (16 kHz mono).
    ///
    /// An EMPTY tail counts as silent (nothing published yet this session is
    /// not speech). Otherwise silent iff EVERY `windowMs` window is at or below BOTH:
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
