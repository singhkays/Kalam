import CoreGraphics
import Foundation

/// Pure audio-envelope math behind the recording indicator (Phase 1 extraction;
/// provenance: the AppKit WaveformView/PillLevelGlyphView call sites, deleted
/// at the Phase 4 cutover). Framework-free and deterministic so it stays
/// unit-testable; views translate these values into pixels.
///
/// Scale law (2026-09-12): RMS energy in dBFS against an ABSOLUTE floor
/// (silence always reads 0) and a SLOW-ADAPTIVE ceiling (different mics and
/// voices self-calibrate). The ceiling tracks the session peak PLUS headroom,
/// so sustained speech sits around 0.7 with air above it instead of kissing
/// full-scale: it climbs fast toward louder windows (~2 ticks) and drifts
/// down slowly toward sustained speech-like windows only (tau ~1.6s, gated
/// well above room tone) — so a hot mic, a loud room, or a single door-slam
/// can never permanently peg or squash the meter the way per-tick AGC did.
enum IndicatorWaveformMath {

    // MARK: - Waveform envelope (machined deck bars)

    /// Maximum stored history bars; matches the deck's on-screen bar capacity.
    static let maxHistory = 150

    /// Below this, the meter always reads 0 AND the window never moves the
    /// ceiling: room tone must neither show nor calibrate.
    static let absoluteFloorDb: CGFloat = -46.0
    /// Ceiling starting point: near the settled value for the owner's C920,
    /// so the first syllable already reads near-final. Adapts from here.
    static let initialCeilingDb: CGFloat = -21.0
    static let curveGamma: CGFloat = 0.55
    /// Headroom kept above the tracked session peak: sustained peaks read
    /// ~0.7 (tall, not clamped) while louder moments still have somewhere
    /// to go. Onsets briefly flash higher while the attack converges.
    static let ceilingHeadroomDb: CGFloat = 12.0
    /// Only windows louder than this may pull the ceiling DOWN. Speech
    /// qualifies; whispers, room tone, and pauses never do.
    static let ceilingAdaptGateDb: CGFloat = -36.0
    /// Climb rate toward louder windows: converges in ~2 ticks, so onsets
    /// track within ~60ms but single-frame spikes only half-land.
    static let ceilingAttackPerTick: CGFloat = 0.5
    /// Fall rate toward sustained speech-like windows (tau ~1.6s at 30Hz).
    static let ceilingReleasePerTick: CGFloat = 0.02
    /// Only windows within this range below the headroom target may pull the
    /// ceiling down, so post-bang quiet recovers over seconds instead of
    /// sticking high.
    static let ceilingChaseRangeDb: CGFloat = 40.0

    /// dBFS of one tick's RMS energy. Pure helper shared by deck and glyph.
    static func windowDb(rms: CGFloat) -> CGFloat {
        CGFloat(20.0 * log10(max(Double(rms), 1e-5)))
    }

    /// 0...1 meter level for a window against a ceiling. Floor is absolute;
    /// the ceiling slides per `adaptedCeiling`.
    static func level(windowDb: CGFloat, ceilingDb: CGFloat) -> CGFloat {
        let norm = max(0.0, min(1.0, (windowDb - absoluteFloorDb) / max(1.0, ceilingDb - absoluteFloorDb)))
        return pow(norm, curveGamma)
    }

    /// Next-tick ceiling: it tracks the session peak plus `ceilingHeadroomDb`
    /// — instant-ish up, slow gated down. Deterministic in (current, window)
    /// so the whole meter stays headless-testable.
    static func adaptedCeiling(_ current: CGFloat, windowDb: CGFloat) -> CGFloat {
        let target = windowDb + ceilingHeadroomDb
        if target > current {
            return current + (target - current) * ceilingAttackPerTick
        }
        guard windowDb > ceilingAdaptGateDb,
              current - target < ceilingChaseRangeDb else { return current }
        return current + (target - current) * ceilingReleasePerTick
    }

    /// RMS energy of a sample buffer. Non-finite so callers can quarantine it.
    static func rms(_ samples: [Float]) -> CGFloat {
        var sum: CGFloat = 0
        for s in samples {
            let v = CGFloat(s)
            sum += v * v
        }
        return sqrt(sum / CGFloat(max(1, samples.count)))
    }

    /// Session level state carried between waveform ticks. `gain` is retained
    /// for call-site compatibility and stays at 1.0. `ceilingDb` is the slow
    /// adaptive ceiling (see `adaptedCeiling`); it starts at
    /// `initialCeilingDb` so the first syllable already reads near-final.
    struct Envelope {
        var gain: CGFloat = 1.0
        var smoothedAmp: CGFloat = 0.0
        var history: [CGFloat] = []
        var ceilingDb: CGFloat = initialCeilingDb
    }

    /// Ingests one buffer and pushes exactly one history bar. Inactive ticks,
    /// empty buffers, and non-finite energy (defensive: a NaN must decay, not
    /// poison the meter to full-scale forever) fall back toward silence.
    static func ingest(samples: [Float], active: Bool, into envelope: inout Envelope) {
        guard active, !samples.isEmpty else {
            envelope.smoothedAmp *= 0.82
            push(into: &envelope, amp: envelope.smoothedAmp)
            return
        }

        let energy = rms(samples)
        guard energy.isFinite else {
            envelope.smoothedAmp *= 0.82
            push(into: &envelope, amp: envelope.smoothedAmp)
            return
        }
        let db = windowDb(rms: energy)
        envelope.ceilingDb = adaptedCeiling(envelope.ceilingDb, windowDb: db)
        let target = level(windowDb: db, ceilingDb: envelope.ceilingDb)

        // Fast attack, slow release: transients pop but the meter falls naturally.
        let coeff: CGFloat = target > envelope.smoothedAmp ? 0.65 : 0.18
        envelope.smoothedAmp += (target - envelope.smoothedAmp) * coeff

        push(into: &envelope, amp: envelope.smoothedAmp)
    }

    /// Clears the envelope so the next recording starts from silence.
    static func reset(_ envelope: inout Envelope) {
        envelope = Envelope()
    }

    /// Gain and per-bar smoothing carried between glyph ticks. One glyph surface
    /// is live at a time, so one carrier suffices.
    /// `gain` stays at 1.0 for call-site compatibility; `ceilingDb` tracks the
    /// deck's adaptive ceiling on the same audio, so the pill never disagrees
    /// with the bars about how loud "loud" is.
    struct GlyphEnvelope {
        var gain: CGFloat = 1.0
        var smoothed: [CGFloat] = [0.0, 0.0, 0.0]
        var ceilingDb: CGFloat = initialCeilingDb

        mutating func ingest(_ samples: [Float]) {
            glyphLevels(samples: samples, gain: &gain, smoothed: &smoothed, ceilingDb: &ceilingDb)
        }
    }

    private static func push(into envelope: inout Envelope, amp: CGFloat) {
        envelope.history.append(max(0.0, min(1.0, amp)))
        if envelope.history.count > maxHistory {
            envelope.history.removeFirst(envelope.history.count - maxHistory)
        }
    }

    // MARK: - Level glyph (three-bar whisper glyph)

    /// Computes 3 normalized levels [0.0...1.0] from PCM audio samples with
    /// the shared adaptive scale per time slice and attack/release smoothing.
    /// `gain` is unused (stays 1.0) and kept only for call-site compatibility;
    /// `smoothed` carries bar state and `ceilingDb` the adaptive ceiling
    /// between ticks, both mutated in place. The ceiling adapts once per
    /// frame on the loudest slice (peak-following), then all three bars map
    /// against it.
    static func glyphLevels(
        samples: [Float],
        gain: inout CGFloat,
        smoothed: inout [CGFloat],
        ceilingDb: inout CGFloat
    ) -> [CGFloat] {
        gain = 1.0
        guard !samples.isEmpty else {
            for i in 0..<3 {
                smoothed[i] *= 0.75
            }
            return smoothed
        }

        // Divide samples into 3 time slices, one RMS level each.
        let count = samples.count
        let chunkSize = max(1, count / 3)

        var sliceDb: [CGFloat] = [0, 0, 0]
        for i in 0..<3 {
            let start = i * chunkSize
            let end = (i == 2) ? count : min(count, (i + 1) * chunkSize)
            var sum: CGFloat = 0
            var n = 0
            for j in start..<end {
                let v = CGFloat(samples[j])
                sum += v * v
                n += 1
            }
            let sliceRms = n > 0 ? sqrt(sum / CGFloat(n)) : 0
            sliceDb[i] = sliceRms.isFinite ? windowDb(rms: sliceRms) : absoluteFloorDb
        }
        ceilingDb = adaptedCeiling(ceilingDb, windowDb: sliceDb.max() ?? absoluteFloorDb)

        for i in 0..<3 {
            let target = level(windowDb: sliceDb[i], ceilingDb: ceilingDb)

            // Fast attack (0.65), smooth decay (0.22)
            let coeff: CGFloat = target > smoothed[i] ? 0.65 : 0.22
            smoothed[i] += (target - smoothed[i]) * coeff
        }

        return smoothed
    }
}